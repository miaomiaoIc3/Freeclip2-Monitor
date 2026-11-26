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
    @Published var logs: [String] = []
    @Published var notificationStatus: UNAuthorizationStatus = .notDetermined

    /// 综合连接态（BLE FD21 连接或系统音频路由连接到 FreeClip 均视为已连接）
    var isDeviceConnected: Bool {
        isGattConnected || isAudioConnected
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
    private var lastAutoNotifiedCaseFull = false
    private var lastAutoNotifiedCaseLow = false
    private var lastSnapshotLogAt: Date?

    /// 记录上一次综合连接状态，确保连接与断开事件严格按边沿（false <-> true）各触发一次
    private var previousEffectiveConnected: Bool = false
    private var connectTransitionTask: Task<Void, Never>?
    private var disconnectTransitionTask: Task<Void, Never>?

    private override init() {
        let store = SharedBatteryStore.shared
        self.latestSnapshot = store.loadSnapshot()
        self.settings = store.loadSettings()
        self.logs = store.loadLogs()
        super.init()

        // 初始化时同步检测当前系统音频输出是否已连着 FreeClip
        let initialAudio = Self.detectFreeClipAudioRoute()
        self.isAudioConnected = initialAudio.connected
        if let routeName = initialAudio.name {
            self.discoveredDeviceName = routeName
        }
        self.previousEffectiveConnected = initialAudio.connected

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
            evaluateConnectionTransition()
        }
    }

    // ------------------------------------------------------------------------
    // 连接 / 断开严格隔离状态机（各自只看各自开关，绝不串台）
    // ------------------------------------------------------------------------

    private func evaluateConnectionTransition() {
        let nowConnected = isDeviceConnected
        guard nowConnected != previousEffectiveConnected else { return }
        previousEffectiveConnected = nowConnected

        if nowConnected {
            disconnectTransitionTask?.cancel()
            disconnectTransitionTask = nil
            BatteryNotificationManager.shared.resetChannelCooldown(for: .connect)
            triggerConnectPipeline()
        } else {
            connectTransitionTask?.cancel()
            connectTransitionTask = nil
            BatteryNotificationManager.shared.resetChannelCooldown(for: .disconnect)
            triggerDisconnectPipeline()
        }
    }

    /// 耳机连接事件处理：仅受 settings.notifyOnConnect 控制
    private func triggerConnectPipeline() {
        connectTransitionTask?.cancel()
        let connectNotifyEnabled = settings.notifyOnConnect

        connectTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let connectedAt = Date()

            // 主动查询一次最新电量（同时给 FD21 服务发现与 FDEE 广播留出最多 1.8 秒刷新窗口）
            if self.centralManager.state == .poweredOn {
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
            }

            // 等待最新快照到达（最多 1.8 秒，一旦收到新快照立即提前结束等待）
            var waited = 0
            while waited < 18 {
                if Task.isCancelled { return }
                if let snap = self.latestSnapshot, snap.timestamp >= connectedAt {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }

            guard !Task.isCancelled else { return }

            // 重新读取实时开关状态，严格只检查 notifyOnConnect
            guard self.settings.notifyOnConnect && connectNotifyEnabled else {
                self.log("连接推送已关闭，跳过连接通知")
                return
            }

            if let snap = self.latestSnapshot {
                self.log("触发连接电量通知：\(snap.summaryLine)")
                await BatteryNotificationManager.shared.sendBatteryReport(
                    snap,
                    settings: self.settings,
                    channel: .connect
                )
            } else {
                self.log("已连接，但暂无可用电量快照")
            }
        }
    }

    /// 耳机断开事件处理：仅受 settings.notifyOnDisconnect 控制
    private func triggerDisconnectPipeline() {
        disconnectTransitionTask?.cancel()
        let disconnectNotifyEnabled = settings.notifyOnDisconnect

        disconnectTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let disconnectedAt = Date()

            // 耳机入盒瞬间往往伴随新的 FDEE 广播，短时等待最多 1.0 秒抓取入盒最新电量
            if self.centralManager.state == .poweredOn {
                let isFg = (UIApplication.shared.applicationState == .active)
                let services: [CBUUID]? = isFg ? nil : [self.fdeeUUID, self.fd21ServiceUUID, self.fd9aUUID]
                self.centralManager.scanForPeripherals(
                    withServices: services,
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: isFg]
                )
            }

            var waited = 0
            while waited < 10 {
                if Task.isCancelled { return }
                if let snap = self.latestSnapshot, snap.timestamp >= disconnectedAt {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }

            guard !Task.isCancelled else { return }

            // 重新读取实时开关状态，严格只检查 notifyOnDisconnect
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
            evaluateConnectionTransition()
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

        let shouldNotify: Bool
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

        var notifyResult: NotificationDeliveryResult? = nil

        if let fresh = result {
            if shouldNotify {
                notifyResult = await BatteryNotificationManager.shared.sendBatteryReport(
                    fresh,
                    settings: settings,
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
            } else {
                self.isScanning = false
                self.isGattConnected = false
                self.previousEffectiveConnected = self.isAudioConnected
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
                self.evaluateConnectionTransition()
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
            self.evaluateConnectionTransition()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.isGattConnected = false
            self.fd21NotifyChar = nil
            self.fd21WriteChar = nil
            self.log("蓝牙 GATT 已断开")

            // 重新核对音频路由，避免系统在 GATT 断开同时音频也刚断开的竞态
            self.isAudioConnected = Self.detectFreeClipAudioRoute().connected
            self.evaluateConnectionTransition()

            // 重新挂起自动连接监听，确保下次耳机出盒/开盖连上时系统后台立即唤醒 didConnect！
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
