import Foundation
import CoreBluetooth
import AVFoundation
import UIKit
import UserNotifications

struct OneShotScanOutcome {
    let snapshot: FreeClipSnapshot?
    let isFresh: Bool
    let notificationResult: NotificationDeliveryResult?
}

enum ScanTriggerMode {
    case manual
    case connectShortcut
    case disconnectShortcut
}

@MainActor
final class FreeClipBluetoothManager: NSObject, ObservableObject {
    static let shared = FreeClipBluetoothManager()

    @Published var latestSnapshot: FreeClipSnapshot?
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var isScanning: Bool = false
    @Published var isGattConnected: Bool = false
    @Published var isAudioConnected: Bool = false
    @Published var discoveredDeviceName: String?
    @Published var settings: MonitorSettings
    @Published private(set) var sessionState: EarbudSessionState
    @Published var logs: [String] = []
    @Published var notificationStatus: UNAuthorizationStatus = .notDetermined

    /// 底层链路综合连接态（BLE FD21 连接或系统音频路由连接到 FreeClip）
    var isDeviceConnected: Bool {
        isGattConnected || isAudioConnected
    }

    /// 供界面展示的会话在线状态（佩戴期间即使 BLE GATT 短暂省电休眠也不闪烁断开）
    var isSessionActiveForUI: Bool {
        isDeviceConnected || sessionState == .openedInCase || sessionState == .wearing
    }

    private var centralManager: CBCentralManager!
    private var activePeripheral: CBPeripheral?
    private var fd21NotifyChar: CBCharacteristic?
    private var fd21WriteChar: CBCharacteristic?

    private let fdeeUUID = CBUUID(string: FreeClipProtocol.fdeeUUIDString)
    private let fd9aUUID = CBUUID(string: FreeClipProtocol.fd9aUUIDString)
    private let fd21ServiceUUID = CBUUID(string: FreeClipProtocol.fd21ServiceUUIDString)
    private let fd21NotifyUUID = CBUUID(string: FreeClipProtocol.fd21NotifyCharUUIDString)
    private let fd21WriteUUID = CBUUID(string: FreeClipProtocol.fd21WriteCharUUIDString)

    private var pendingScanCompletion: ((FreeClipSnapshot?) -> Void)?
    private var pendingScanTimer: Timer?
    private var pendingOneShotTriggerMode: ScanTriggerMode? = nil
    private var lastAutoNotifiedCaseFull = false
    private var lastAutoNotifiedCaseLow = false
    private var lastSnapshotLogAt: Date?

    /// 会话状态持久化与防抖任务
    private var lastSessionSavedAt: Date
    private var lastSessionConnectedAt: Date = .distantPast
    private var initialAudioConnectedAtLaunch: Bool = false
    private var pendingColdLaunchReconcile: Bool = false
    private var connectTransitionTask: Task<Void, Never>?
    private var disconnectTransitionTask: Task<Void, Never>?
    private var disconnectWatchdogTask: Task<Void, Never>?
    private var returnedIdleResetTask: Task<Void, Never>?
    private var coldLaunchReconcileTask: Task<Void, Never>?

    /// 蓝牙与音频全部断开后的超时确认窗口（秒合盖休眠兜底，防止佩戴时短暂断连误触发）
    private let fullDisconnectTimeoutSeconds: TimeInterval = 12.0
    /// 进程冷启动时判定历史会话需重新核对的静默间隔阈值
    private let coldLaunchStaleThresholdSeconds: TimeInterval = 180.0

    private override init() {
        let store = SharedBatteryStore.shared
        self.latestSnapshot = store.loadSnapshot()
        self.settings = store.loadSettings()
        let savedSession = store.loadSessionRecord()
        self.sessionState = savedSession.state
        self.lastSessionSavedAt = savedSession.updatedAt
        self.logs = store.loadLogs()
        super.init()

        // 初始化时同步检测当前系统音频输出是否已连着 FreeClip
        let initialAudio = Self.detectFreeClipAudioRoute()
        self.isAudioConnected = initialAudio.connected
        self.initialAudioConnectedAtLaunch = initialAudio.connected
        if let routeName = initialAudio.name {
            self.discoveredDeviceName = routeName
        }

        // 若上次持久化的活跃会话距今已超过阈值，标记冷启动待核对（防止进程被杀期间已归盒导致状态卡死，同时避免仍在佩戴时重弹）
        let age = Date().timeIntervalSince(savedSession.updatedAt)
        if savedSession.state != .idle && age > coldLaunchStaleThresholdSeconds {
            if initialAudio.connected && (savedSession.state == .wearing || savedSession.state == .openedInCase) {
                // 启动瞬间音频仍在输出到耳机，说明用户从未摘下，直接续期当前活跃会话
                self.touchSessionTimestamp(forceWrite: true)
            } else {
                self.pendingColdLaunchReconcile = true
            }
        }

        self.centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.freeclip.monitor.central.v1"]
        )

        observeAudioRouteChanges()
    }

    // ------------------------------------------------------------------------
    // 系统蓝牙音频路由监听（无需激活音频会话，不打断任何音乐/通话）
    // ------------------------------------------------------------------------

    private func observeAudioRouteChanges() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateAudioRouteState()
            }
        }
    }

    private static func detectFreeClipAudioRoute() -> (connected: Bool, name: String?) {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        for port in outputs {
            if port.portName.localizedCaseInsensitiveContains("FreeClip") {
                return (true, port.portName)
            }
        }
        return (false, nil)
    }

    private func evaluateAudioRouteState() {
        let route = Self.detectFreeClipAudioRoute()
        let changed = (route.connected != isAudioConnected)
        isAudioConnected = route.connected
        if let name = route.name {
            discoveredDeviceName = name
        }
        if route.connected {
            attemptGattAttachIfConnected()
        }
        if changed {
            log(route.connected ? "检测到耳机音频已连接" : "检测到耳机音频已断开")
            evaluateLinkStateChange()
        }
    }

    // ------------------------------------------------------------------------
    // AirPods 式物理在盒/佩戴会话状态机（方案 B：开盖即连、佩戴免打扰、归盒/长断联才断）
    // ------------------------------------------------------------------------

    private func updateSessionState(_ newState: EarbudSessionState) {
        let now = Date()
        sessionState = newState
        lastSessionSavedAt = now
        SharedBatteryStore.shared.saveSessionRecord(
            PersistedSessionRecord(state: newState, updatedAt: now)
        )
    }

    private func touchSessionTimestamp(forceWrite: Bool = false) {
        let now = Date()
        guard forceWrite || now.timeIntervalSince(lastSessionSavedAt) >= 15 else { return }
        lastSessionSavedAt = now
        SharedBatteryStore.shared.saveSessionRecord(
            PersistedSessionRecord(state: sessionState, updatedAt: now)
        )
    }

    private func cancelDisconnectWatchdog() {
        disconnectWatchdogTask?.cancel()
        disconnectWatchdogTask = nil
        returnedIdleResetTask?.cancel()
        returnedIdleResetTask = nil
    }

    /// 处理底层链路（BLE GATT / 系统音频）通断变化
    private func evaluateLinkStateChange() {
        if isDeviceConnected {
            cancelDisconnectWatchdog()

            if pendingColdLaunchReconcile {
                scheduleColdLaunchReconciliation()
                return
            }

            switch sessionState {
            case .idle:
                // 方案 B：从待机态首次连上手机（如开盖瞬间），立即开启会话并触发一次连接推送
                enterConnectedSession(
                    targetState: .openedInCase,
                    eventAt: Date(),
                    reason: "耳机已连接手机（开盖/唤醒）",
                    suppressNotify: pendingOneShotTriggerMode == .manual
                )
            case .openedInCase, .wearing:
                // 佩戴或开盖会话已处于激活态：链路重连/声道切回不重复推送，仅静默刷新电量与心跳
                touchSessionTimestamp()
                sendFD21BatteryQuery()
            case .returnedToCase:
                // 双耳刚放回未合盖的充电盒内（已发过断开通知）：保持归盒态，静默监测是否再次取出
                sendFD21BatteryQuery()
            }
        } else {
            if pendingColdLaunchReconcile {
                scheduleColdLaunchReconciliation()
                return
            }

            switch sessionState {
            case .idle:
                break
            case .returnedToCase:
                // 此前双耳入盒充电时已发过断开通知，链路断开后延迟归位至 idle，不重复发通知
                scheduleReturnedToCaseIdleReset()
            case .openedInCase, .wearing:
                // 佩戴期间可能发生 GATT 省电断连或暂停音乐，启动 12 秒失联确认兜底而非立即断开
                startDisconnectWatchdog()
            }
        }
    }

    /// 处理新到达的电量报文（以双耳是否在盒充电作为核心物理判据）
    private func evaluateSnapshotTransition(_ snapshot: FreeClipSnapshot, suppressAutoNotify: Bool) {
        if pendingColdLaunchReconcile {
            resolveColdLaunchWithSnapshot(snapshot, suppressAutoNotify: suppressAutoNotify)
            return
        }

        switch sessionState {
        case .idle:
            if snapshot.anyBudOutOfCase {
                cancelDisconnectWatchdog()
                enterConnectedSession(
                    targetState: .wearing,
                    eventAt: snapshot.timestamp,
                    reason: "检测到耳机离开充电盒",
                    suppressNotify: suppressAutoNotify
                )
            } else if snapshot.lidState == .open {
                cancelDisconnectWatchdog()
                enterConnectedSession(
                    targetState: .openedInCase,
                    eventAt: snapshot.timestamp,
                    reason: "检测到充电盒开盖",
                    suppressNotify: suppressAutoNotify
                )
            }

        case .openedInCase:
            if snapshot.anyBudOutOfCase {
                cancelDisconnectWatchdog()
                updateSessionState(.wearing)
                log("耳机已出盒佩戴，维持当前连接会话")
            } else if snapshot.lidState == .closed {
                cancelDisconnectWatchdog()
                enterDisconnectedSession(
                    targetState: .idle,
                    eventAt: snapshot.timestamp,
                    reason: "充电盒已合盖",
                    suppressNotify: suppressAutoNotify
                )
            } else if isDeviceConnected {
                touchSessionTimestamp()
            }

        case .wearing:
            if snapshot.anyBudOutOfCase {
                // 至少一只耳机仍在盒外（含单耳佩戴且另一只在盒合盖充电的场景），维持佩戴态绝不打扰
                cancelDisconnectWatchdog()
                touchSessionTimestamp()
            } else if snapshot.allBudsInCaseCharging {
                // 双耳均回到盒内开始充电：判定本次佩戴结束，立即推送一次断开通知
                cancelDisconnectWatchdog()
                let nextState: EarbudSessionState = (snapshot.lidState == .closed) ? .idle : .returnedToCase
                enterDisconnectedSession(
                    targetState: nextState,
                    eventAt: snapshot.timestamp,
                    reason: "双耳已放回充电盒开始充电",
                    suppressNotify: suppressAutoNotify
                )
                if nextState == .returnedToCase && !isDeviceConnected {
                    scheduleReturnedToCaseIdleReset()
                }
            }

        case .returnedToCase:
            if snapshot.anyBudOutOfCase {
                // 用户未关盖又重新取出耳机佩戴，开启新一轮连接会话
                cancelDisconnectWatchdog()
                enterConnectedSession(
                    targetState: .wearing,
                    eventAt: snapshot.timestamp,
                    reason: "耳机重新从充电盒取出",
                    suppressNotify: suppressAutoNotify
                )
            } else if snapshot.lidState == .closed {
                cancelDisconnectWatchdog()
                updateSessionState(.idle)
                log("充电盒已合盖，会话归位待机")
            }
        }
    }

    /// 冷启动历史会话对账（解决后台进程被系统回收后“仍在佩戴不重弹”与“早已归盒不卡死”的兼顾问题）
    private func scheduleColdLaunchReconciliation() {
        guard coldLaunchReconcileTask == nil else { return }
        coldLaunchReconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.coldLaunchReconcileTask = nil }

            // 先给蓝牙上电与自动挂载最多 2.5 秒窗口
            var probeTicks = 0
            while probeTicks < 25 {
                if Task.isCancelled || !self.pendingColdLaunchReconcile { return }
                if self.isDeviceConnected { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
                probeTicks += 1
            }

            guard !Task.isCancelled, self.pendingColdLaunchReconcile else { return }

            if !self.isDeviceConnected {
                // 设备完全未连接，说明进程挂起期间耳机早已收纳休眠，静默归位待机
                self.pendingColdLaunchReconcile = false
                self.updateSessionState(.idle)
                self.log("清理历史未闭合会话，归位待机态")
                return
            }

            // 设备当前已连接：主动拉取一次实时报文核对耳机是在耳上还是刚开盖在盒
            self.sendFD21BatteryQuery()
            var waitSnap = 0
            while waitSnap < 18 {
                if Task.isCancelled || !self.pendingColdLaunchReconcile { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
                waitSnap += 1
            }

            guard !Task.isCancelled, self.pendingColdLaunchReconcile else { return }
            self.pendingColdLaunchReconcile = false

            if self.initialAudioConnectedAtLaunch {
                self.updateSessionState(.wearing)
            } else {
                self.enterConnectedSession(
                    targetState: .openedInCase,
                    eventAt: Date(),
                    reason: "唤醒重连确认开启新会话",
                    suppressNotify: self.pendingOneShotTriggerMode == .manual
                )
            }
        }
    }

    private func resolveColdLaunchWithSnapshot(_ snapshot: FreeClipSnapshot, suppressAutoNotify: Bool) {
        pendingColdLaunchReconcile = false
        coldLaunchReconcileTask?.cancel()
        coldLaunchReconcileTask = nil

        if snapshot.anyBudOutOfCase {
            // 耳机仍在耳朵上未充电，无缝延续佩戴态，不弹重复连接通知
            updateSessionState(.wearing)
            log("后台唤醒确认耳机仍在佩戴中，跳过重复通知")
        } else if snapshot.lidState == .open || (snapshot.allBudsInCaseCharging && isDeviceConnected) {
            // 双耳均在盒充电且当前刚开盖连接，按新开盖会话处理
            enterConnectedSession(
                targetState: .openedInCase,
                eventAt: snapshot.timestamp,
                reason: "检测到新开盖会话",
                suppressNotify: suppressAutoNotify
            )
        } else {
            updateSessionState(.idle)
        }
    }

    /// 12 秒彻底失联兜底（应对“秒入盒秒关盖”未能抓到最后一帧充电广播的场景）
    private func startDisconnectWatchdog() {
        guard disconnectWatchdogTask == nil else { return }

        // 先启动扫描，争取在入盒合盖后 1 秒内直接抓到 FDEE 充电广播立即触发断开
        if centralManager.state == .poweredOn {
            let isFg = (UIApplication.shared.applicationState == .active)
            let services: [CBUUID]? = isFg ? nil : [fdeeUUID, fd21ServiceUUID, fd9aUUID]
            centralManager.scanForPeripherals(
                withServices: services,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: isFg]
            )
        }

        let totalTicks = Int(fullDisconnectTimeoutSeconds * 4) // 每 0.25s 检查一次，共 48 次 = 12s
        let midProbeTick = totalTicks / 2

        disconnectWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for tick in 0..<totalTicks {
                if Task.isCancelled { return }
                if self.isDeviceConnected || (self.sessionState != .wearing && self.sessionState != .openedInCase) {
                    self.disconnectWatchdogTask = nil
                    return
                }
                if tick == midProbeTick {
                    self.isAudioConnected = Self.detectFreeClipAudioRoute().connected
                    if self.isAudioConnected {
                        self.disconnectWatchdogTask = nil
                        return
                    }
                    self.attemptGattAttachIfConnected()
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            guard !Task.isCancelled else { return }
            self.disconnectWatchdogTask = nil
            self.isAudioConnected = Self.detectFreeClipAudioRoute().connected

            guard !self.isDeviceConnected,
                  (self.sessionState == .wearing || self.sessionState == .openedInCase) else {
                return
            }

            self.enterDisconnectedSession(
                targetState: .idle,
                eventAt: Date(),
                reason: "蓝牙与音频持续断开满 12 秒（合盖休眠兜底）",
                suppressNotify: false
            )
        }
    }

    private func scheduleReturnedToCaseIdleReset() {
        guard returnedIdleResetTask == nil else { return }
        returnedIdleResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.returnedIdleResetTask = nil
            if !self.isDeviceConnected && self.sessionState == .returnedToCase {
                self.updateSessionState(.idle)
                self.log("归盒断联确认完成，会话归位待机")
            }
        }
    }

    private func enterConnectedSession(
        targetState: EarbudSessionState,
        eventAt: Date,
        reason: String,
        suppressNotify: Bool
    ) {
        disconnectTransitionTask?.cancel()
        disconnectTransitionTask = nil
        updateSessionState(targetState)
        lastSessionConnectedAt = Date()
        BatteryNotificationManager.shared.resetChannelCooldown(for: .connect)
        log("进入连接会话[\(targetState.rawValue)]：\(reason)")

        guard !suppressNotify else { return }
        triggerConnectPipeline(since: eventAt)
    }

    private func enterDisconnectedSession(
        targetState: EarbudSessionState,
        eventAt: Date,
        reason: String,
        suppressNotify: Bool
    ) {
        connectTransitionTask?.cancel()
        connectTransitionTask = nil
        updateSessionState(targetState)
        BatteryNotificationManager.shared.resetChannelCooldown(for: .disconnect)
        log("结束连接会话[\(targetState.rawValue)]：\(reason)")

        guard !suppressNotify else { return }
        triggerDisconnectPipeline(since: eventAt)
    }

    /// 耳机连接通知流水线：仅受 settings.notifyOnConnect 控制
    private func triggerConnectPipeline(since eventAt: Date) {
        connectTransitionTask?.cancel()
        let connectNotifyEnabled = settings.notifyOnConnect
        let freshnessFloor = eventAt.addingTimeInterval(-0.5)

        connectTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // 若尚未拿到刚到达的新鲜快照，主动查询一次并最多等待 1.8 秒
            let alreadyFresh = (self.latestSnapshot?.timestamp ?? .distantPast) >= freshnessFloor
            if !alreadyFresh && self.centralManager.state == .poweredOn {
                if UIApplication.shared.applicationState == .active {
                    self.centralManager.scanForPeripherals(
                        withServices: nil,
                        options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
                    )
                } else {
                    self.centralManager.scanForPeripherals(
                        withServices: [self.fdeeUUID, self.fd21ServiceUUID, self.fd9aUUID],
                        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                    )
                }
                self.sendFD21BatteryQuery()

                var waited = 0
                while waited < 18 {
                    if Task.isCancelled { return }
                    if let snap = self.latestSnapshot, snap.timestamp >= freshnessFloor {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
            }

            guard !Task.isCancelled else { return }

            guard self.settings.notifyOnConnect && connectNotifyEnabled else {
                self.log("连接推送已关闭，跳过连接通知")
                return
            }

            if let snap = self.latestSnapshot {
                self.log("触发连接电量通知：\(snap.summaryLine)")
                await BatteryNotificationManager.shared.sendBatteryReport(
                    snap,
                    settings: self.settings,
                    deviceName: self.discoveredDeviceName,
                    channel: .connect
                )
            } else {
                self.log("已连接，但暂无可用电量快照")
            }
        }
    }

    /// 耳机断开/归盒通知流水线：仅受 settings.notifyOnDisconnect 控制
    private func triggerDisconnectPipeline(since eventAt: Date) {
        disconnectTransitionTask?.cancel()
        let disconnectNotifyEnabled = settings.notifyOnDisconnect
        let freshnessFloor = eventAt.addingTimeInterval(-0.5)

        disconnectTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // 若并非由最新归盒充电帧直接触发（如超时兜底），短时扫描最多 1.0 秒尝试补抓最新广播
            let alreadyFresh = (self.latestSnapshot?.timestamp ?? .distantPast) >= freshnessFloor
            if !alreadyFresh && self.centralManager.state == .poweredOn {
                let isFg = (UIApplication.shared.applicationState == .active)
                let services: [CBUUID]? = isFg ? nil : [self.fdeeUUID, self.fd21ServiceUUID, self.fd9aUUID]
                self.centralManager.scanForPeripherals(
                    withServices: services,
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: isFg]
                )

                var waited = 0
                while waited < 10 {
                    if Task.isCancelled { return }
                    if let snap = self.latestSnapshot, snap.timestamp >= freshnessFloor {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
            }

            guard !Task.isCancelled else { return }

            guard self.settings.notifyOnDisconnect && disconnectNotifyEnabled else {
                self.log("断开推送已关闭，跳过断开通知")
                return
            }

            if let snap = self.latestSnapshot {
                self.log("触发断开电量通知：\(snap.summaryLine)")
                await BatteryNotificationManager.shared.sendBatteryReport(
                    snap,
                    settings: self.settings,
                    channel: .disconnect
                )
            }
        }
    }

    // ------------------------------------------------------------------------
    // 基础设置与日志
    // ------------------------------------------------------------------------

    func refreshNotificationStatus() async {
        notificationStatus = await BatteryNotificationManager.shared.authorizationStatus()
    }

    func updateSettings(_ newSettings: MonitorSettings) {
        settings = newSettings
        SharedBatteryStore.shared.saveSettings(newSettings)
    }

    func log(_ message: String) {
        SharedBatteryStore.shared.appendLog(message)
        logs = SharedBatteryStore.shared.loadLogs()
    }

    func clearLogs() {
        SharedBatteryStore.shared.clearLogs()
        logs = []
    }

    // ------------------------------------------------------------------------
    // 前台 / 后台扫描与 GATT 重连控制
    // ------------------------------------------------------------------------

    func startForegroundScanning() {
        evaluateAudioRouteState()
        guard centralManager.state == .poweredOn else { return }
        isScanning = true
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        attemptGattAttachIfConnected()
    }

    func switchToBackgroundMode() {
        guard centralManager.state == .poweredOn else { return }
        centralManager.stopScan()
        centralManager.scanForPeripherals(
            withServices: [fdeeUUID, fd21ServiceUUID, fd9aUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        attemptGattAttachIfConnected()
    }

    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        log("已暂停扫描")
    }

    func attemptGattAttachIfConnected() {
        guard centralManager.state == .poweredOn else { return }
        let probeServices = [
            fd21ServiceUUID,
            fdeeUUID,
            fd9aUUID,
            CBUUID(string: "180F"),
            CBUUID(string: "180A")
        ]
        let connected = centralManager.retrieveConnectedPeripherals(withServices: probeServices)
        if let peripheral = connected.first(where: {
            ($0.name?.localizedCaseInsensitiveContains("FreeClip") == true)
            || ($0.identifier.uuidString == settings.savedPeripheralUUID)
        }) ?? connected.first(where: { $0.name == nil && connected.count == 1 && isAudioConnected }) {
            connectGatt(peripheral)
        } else {
            reconnectSavedPeripheralIfPossible()
        }
    }

    private func reconnectSavedPeripheralIfPossible() {
        guard centralManager.state == .poweredOn,
              let uuidStr = settings.savedPeripheralUUID,
              let uuid = UUID(uuidString: uuidStr) else { return }
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        if let peripheral = peripherals.first {
            activePeripheral = peripheral
            peripheral.delegate = self
            if peripheral.state != .connected && peripheral.state != .connecting {
                centralManager.connect(peripheral, options: nil)
            }
        }
    }

    /// 仅对可连接 GATT 外设调用并持久化 UUID（防止被不可连接 FDEE 广播的随机地址覆盖！）
    private func connectGatt(_ peripheral: CBPeripheral) {
        activePeripheral = peripheral
        peripheral.delegate = self
        if settings.savedPeripheralUUID != peripheral.identifier.uuidString {
            var updated = settings
            updated.savedPeripheralUUID = peripheral.identifier.uuidString
            updateSettings(updated)
        }
        if peripheral.state != .connected && peripheral.state != .connecting {
            centralManager.connect(peripheral, options: nil)
        } else if peripheral.state == .connected && !isGattConnected {
            isGattConnected = true
            peripheral.discoverServices([fd21ServiceUUID])
            evaluateLinkStateChange()
        }
    }

    func sendFD21BatteryQuery() {
        guard let peripheral = activePeripheral,
              peripheral.state == .connected,
              let writeChar = fd21WriteChar else { return }
        peripheral.writeValue(FreeClipProtocol.queryBatteryFrame, for: writeChar, type: .withoutResponse)
    }

    // ------------------------------------------------------------------------
    // 单次扫描（供手动按钮与快捷指令调用，按 triggerMode 严格区分通知策略）
    // ------------------------------------------------------------------------

    func performOneShotScan(
        timeoutSeconds: TimeInterval = 4.5,
        isForeground: Bool,
        triggerMode: ScanTriggerMode = .manual,
        reason: String
    ) async -> OneShotScanOutcome {
        log("触发扫描：\(reason)")

        let wasContinuousWearing = (sessionState == .wearing)
            && !pendingColdLaunchReconcile
            && Date().timeIntervalSince(lastSessionConnectedAt) > 12

        var shouldNotify: Bool
        let channel: NotificationChannel
        switch triggerMode {
        case .manual:
            shouldNotify = true
            channel = .manual
        case .connectShortcut:
            shouldNotify = settings.notifyOnConnect
            channel = .connect
        case .disconnectShortcut:
            shouldNotify = settings.notifyOnDisconnect
            channel = .disconnect
        }

        var waitCycles = 0
        while centralManager.state == .unknown && waitCycles < 15 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waitCycles += 1
        }

        guard centralManager.state == .poweredOn else {
            log("蓝牙未开启")
            let notifyRes: NotificationDeliveryResult? = shouldNotify
                ? await BatteryNotificationManager.shared.sendScanFallbackNotice(cached: latestSnapshot)
                : nil
            await refreshNotificationStatus()
            return OneShotScanOutcome(snapshot: latestSnapshot, isFresh: false, notificationResult: notifyRes)
        }

        let result: FreeClipSnapshot? = await withCheckedContinuation { continuation in
            self.finishPendingScan(with: nil)
            self.pendingOneShotTriggerMode = triggerMode

            self.pendingScanCompletion = { snapshot in
                continuation.resume(returning: snapshot)
            }

            self.attemptGattAttachIfConnected()
            if self.isGattConnected {
                self.sendFD21BatteryQuery()
            }

            let services: [CBUUID]? = isForeground ? nil : [self.fdeeUUID, self.fd21ServiceUUID, self.fd9aUUID]
            self.centralManager.scanForPeripherals(
                withServices: services,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: isForeground]
            )
            self.isScanning = true

            self.pendingScanTimer = Timer.scheduledTimer(withTimeInterval: timeoutSeconds, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finishPendingScan(with: nil)
                }
            }
        }

        // 同步对齐快捷指令触发后的会话状态与防重复策略
        switch triggerMode {
        case .manual:
            break
        case .connectShortcut:
            if wasContinuousWearing && result?.allBudsInCaseCharging != true {
                log("当前处于持续佩戴会话中，跳过重复快捷指令连接通知")
                shouldNotify = false
            } else {
                cancelDisconnectWatchdog()
                if sessionState == .idle || sessionState == .returnedToCase {
                    let target: EarbudSessionState = (result?.anyBudOutOfCase == true) ? .wearing : .openedInCase
                    updateSessionState(target)
                    lastSessionConnectedAt = Date()
                    BatteryNotificationManager.shared.resetChannelCooldown(for: .connect)
                }
            }
        case .disconnectShortcut:
            cancelDisconnectWatchdog()
            let target: EarbudSessionState = (isDeviceConnected && result?.lidState == .open) ? .returnedToCase : .idle
            if sessionState != target {
                updateSessionState(target)
            }
            BatteryNotificationManager.shared.resetChannelCooldown(for: .disconnect)
        }

        var notifyResult: NotificationDeliveryResult? = nil

        if let fresh = result {
            if shouldNotify {
                notifyResult = await BatteryNotificationManager.shared.sendBatteryReport(
                    fresh,
                    settings: settings,
                    deviceName: discoveredDeviceName,
                    channel: channel
                )
            }
            await refreshNotificationStatus()
            return OneShotScanOutcome(snapshot: fresh, isFresh: true, notificationResult: notifyResult)
        } else {
            log("扫描超时，未捕获到新广播")
            if let cached = latestSnapshot {
                SharedBatteryStore.shared.saveSnapshot(cached, forceWidgetReload: true)
            }
            if shouldNotify {
                if let cached = latestSnapshot, triggerMode != .manual {
                    notifyResult = await BatteryNotificationManager.shared.sendBatteryReport(
                        cached,
                        settings: settings,
                        deviceName: discoveredDeviceName,
                        channel: channel
                    )
                } else {
                    notifyResult = await BatteryNotificationManager.shared.sendScanFallbackNotice(cached: latestSnapshot)
                }
            }
            await refreshNotificationStatus()
            return OneShotScanOutcome(snapshot: latestSnapshot, isFresh: false, notificationResult: notifyResult)
        }
    }

    private func finishPendingScan(with snapshot: FreeClipSnapshot?) {
        pendingScanTimer?.invalidate()
        pendingScanTimer = nil
        pendingOneShotTriggerMode = nil
        if let completion = pendingScanCompletion {
            pendingScanCompletion = nil
            completion(snapshot)
        }
    }

    // ------------------------------------------------------------------------
    // 统一处理电量快照
    // ------------------------------------------------------------------------

    private func acceptSnapshot(_ snapshot: FreeClipSnapshot) {
        let previous = latestSnapshot
        let changed = snapshot.hasSignificantChange(comparedTo: previous)
        latestSnapshot = snapshot

        let isPendingOneShot = (pendingScanCompletion != nil)
        SharedBatteryStore.shared.saveSnapshot(snapshot, forceWidgetReload: isPendingOneShot)

        let now = Date()
        if changed || lastSnapshotLogAt == nil || now.timeIntervalSince(lastSnapshotLogAt!) >= 30 {
            lastSnapshotLogAt = now
            log("[\(snapshot.source.rawValue)] \(snapshot.summaryLine) (\(snapshot.lidState.rawValue))")
        }

        // 充电盒充满 100% 提醒
        if settings.notifyWhenFull, let newLvl = snapshot.caseBattery.level {
            if newLvl < 100 {
                lastAutoNotifiedCaseFull = false
            } else if newLvl == 100 && !lastAutoNotifiedCaseFull {
                let wasBelowFull = (previous?.caseBattery.level ?? 100) < 100
                if wasBelowFull {
                    lastAutoNotifiedCaseFull = true
                    log("充电盒已充满 100%")
                    Task {
                        await BatteryNotificationManager.shared.sendFullChargeNotice(snapshot)
                    }
                }
            }
        }

        // 充电盒低电量提醒
        if let newLvl = snapshot.caseBattery.level {
            if newLvl > settings.lowBatteryThreshold || snapshot.caseBattery.isCharging {
                lastAutoNotifiedCaseLow = false
            } else if snapshot.isCaseLow(threshold: settings.lowBatteryThreshold) && !lastAutoNotifiedCaseLow {
                let wasAboveThreshold = (previous?.caseBattery.level ?? 100) > settings.lowBatteryThreshold
                if wasAboveThreshold {
                    lastAutoNotifiedCaseLow = true
                    log("充电盒低电量（\(newLvl)%）")
                    Task {
                        await BatteryNotificationManager.shared.sendLowBatteryNotice(snapshot)
                    }
                }
            }
        }

        // 驱动在盒充电 / 出盒佩戴状态机（单次扫描期间仅同步状态，由单次扫描统一负责通知投递）
        evaluateSnapshotTransition(snapshot, suppressAutoNotify: isPendingOneShot)

        if isPendingOneShot {
            finishPendingScan(with: snapshot)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension FreeClipBluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            self.bluetoothState = central.state
            if central.state == .poweredOn {
                if UIApplication.shared.applicationState == .active {
                    self.startForegroundScanning()
                } else {
                    // 后台唤醒时同样挂载重连与后台服务扫描，确保连接/断开事件都能捕获
                    self.switchToBackgroundMode()
                }
                self.evaluateLinkStateChange()
            } else {
                self.isScanning = false
                self.isGattConnected = false
                self.isAudioConnected = false
                self.cancelDisconnectWatchdog()
                if central.state == .poweredOff {
                    if self.sessionState == .wearing || self.sessionState == .openedInCase {
                        self.enterDisconnectedSession(
                            targetState: .idle,
                            eventAt: Date(),
                            reason: "系统蓝牙已关闭",
                            suppressNotify: false
                        )
                    } else if self.sessionState == .returnedToCase {
                        self.updateSessionState(.idle)
                    }
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        Task { @MainActor in
            self.log("后台恢复蓝牙会话")
            if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
               let first = peripherals.first {
                self.activePeripheral = first
                first.delegate = self
                let connected = (first.state == .connected)
                self.isGattConnected = connected
                if connected {
                    first.discoverServices([self.fd21ServiceUUID])
                } else if first.state != .connecting {
                    central.connect(first, options: nil)
                }
                self.evaluateLinkStateChange()
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        let isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false

        Task { @MainActor in
            let isFreeClipByName = (name?.localizedCaseInsensitiveContains("FreeClip") == true)
            let fdeeData = serviceData?[self.fdeeUUID]

            // 若发现可连接的 FreeClip 外设，优先建立/保持 GATT 连接以实时感知连接与断开事件
            if isFreeClipByName && isConnectable {
                self.discoveredDeviceName = name
                if self.activePeripheral == nil || self.activePeripheral?.state == .disconnected {
                    self.connectGatt(peripheral)
                }
            }

            if let fdeeData, let snapshot = FreeClipProtocol.parseFDEE(fdeeData) {
                self.discoveredDeviceName = name ?? self.discoveredDeviceName ?? "HUAWEI FreeClip 2"
                // 注意：只有可连接帧才更新 savedPeripheralUUID，避免被非连接广播的随机地址覆盖！
                if isConnectable && self.settings.savedPeripheralUUID != peripheral.identifier.uuidString {
                    var updated = self.settings
                    updated.savedPeripheralUUID = peripheral.identifier.uuidString
                    self.updateSettings(updated)
                }
                self.acceptSnapshot(snapshot)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.isGattConnected = true
            self.discoveredDeviceName = peripheral.name ?? self.discoveredDeviceName ?? "HUAWEI FreeClip 2"
            if self.settings.savedPeripheralUUID != peripheral.identifier.uuidString {
                var updated = self.settings
                updated.savedPeripheralUUID = peripheral.identifier.uuidString
                self.updateSettings(updated)
            }
            self.log("蓝牙 GATT 已连接")
            peripheral.discoverServices([self.fd21ServiceUUID])
            self.evaluateLinkStateChange()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.isGattConnected = false
            self.fd21NotifyChar = nil
            self.fd21WriteChar = nil
            self.log("蓝牙 GATT 已断开")

            // 重新核对音频路由，进入防抖/会话判定（佩戴期间短暂断连不会触发断开或重置连接）
            self.isAudioConnected = Self.detectFreeClipAudioRoute().connected
            self.evaluateLinkStateChange()

            // 重新挂起自动连接监听，确保佩戴时重连以及下次开盖连上时系统后台立即唤醒 didConnect！
            self.reconnectSavedPeripheralIfPossible()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension FreeClipBluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let services = peripheral.services else { return }
            for service in services where service.uuid == self.fd21ServiceUUID {
                peripheral.discoverCharacteristics([self.fd21NotifyUUID, self.fd21WriteUUID], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard let chars = service.characteristics else { return }
            for c in chars {
                if c.uuid == self.fd21NotifyUUID {
                    self.fd21NotifyChar = c
                    peripheral.setNotifyValue(true, for: c)
                } else if c.uuid == self.fd21WriteUUID {
                    self.fd21WriteChar = c
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.sendFD21BatteryQuery()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        Task { @MainActor in
            if let snapshot = FreeClipProtocol.parseFD21Frame(data) {
                self.acceptSnapshot(snapshot)
            }
        }
    }
}
