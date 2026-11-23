import Foundation
import CoreBluetooth
import UIKit

/// FreeClip 2 核心双通道蓝牙管理器：
///   1. 通道 A（主通道）：扫描 FDEE 广播 Service Data，直接解析开盖/合盖/充电时的真实三电量
///   2. 通道 B（辅助通道）：连接 0xFD21 GATT 服务，发送 5A0003000108DF73 查电量并订阅主动上报
@MainActor
final class FreeClipBluetoothManager: NSObject, ObservableObject {
    static let shared = FreeClipBluetoothManager()

    @Published var latestSnapshot: FreeClipSnapshot?
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var isScanning: Bool = false
    @Published var isGattConnected: Bool = false
    @Published var discoveredDeviceName: String?
    @Published var settings: MonitorSettings
    @Published var logs: [String] = []

    private var centralManager: CBCentralManager!
    private var activePeripheral: CBPeripheral?
    private var fd21NotifyChar: CBCharacteristic?
    private var fd21WriteChar: CBCharacteristic?

    private let fdeeUUID = CBUUID(string: FreeClipProtocol.fdeeUUIDString)
    private let fd9aUUID = CBUUID(string: FreeClipProtocol.fd9aUUIDString)
    private let fd21ServiceUUID = CBUUID(string: FreeClipProtocol.fd21ServiceUUIDString)
    private let fd21NotifyUUID = CBUUID(string: FreeClipProtocol.fd21NotifyCharUUIDString)
    private let fd21WriteUUID = CBUUID(string: FreeClipProtocol.fd21WriteCharUUIDString)

    /// 供 AppIntent / 快捷指令调用的一次性扫描回调
    private var pendingScanCompletion: ((FreeClipSnapshot?) -> Void)?
    private var pendingScanTimer: Timer?
    private var lastAutoNotifiedCaseFull = false

    private override init() {
        let store = SharedBatteryStore.shared
        self.latestSnapshot = store.loadSnapshot()
        self.settings = store.loadSettings()
        self.logs = store.loadLogs()
        super.init()

        // 启用 CoreBluetooth 状态恢复，支持系统后台唤醒
        self.centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.freeclip.monitor.central.v1"]
        )
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
    // 前台 / 后台扫描控制
    // ------------------------------------------------------------------------

    func startForegroundScanning() {
        guard centralManager.state == .poweredOn else {
            log("蓝牙未就绪，等待开启后自动扫描")
            return
        }
        isScanning = true
        // 前台传 withServices: nil 可捕获所有含 FDEE Service Data 的非连接态广播（包括合盖与充电状态）
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        log("已开始实时雷达扫描（FDEE 广播 + FD21 服务）")
        attemptGattAttachIfConnected()
    }

    func switchToBackgroundMode() {
        guard centralManager.state == .poweredOn else { return }
        centralManager.stopScan()
        // 后台模式遵守 iOS 规则：传入明确 Service UUID 列表，同时挂起对已保存外设的自动重连监听
        centralManager.scanForPeripherals(
            withServices: [fdeeUUID, fd21ServiceUUID, fd9aUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        reconnectSavedPeripheralIfPossible()
    }

    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        log("已停止扫描")
    }

    /// 尝试从系统已连接设备中直接捞出 0xFD21 外设（适用于佩戴中停止广播的场景）
    func attemptGattAttachIfConnected() {
        guard centralManager.state == .poweredOn else { return }
        let connected = centralManager.retrieveConnectedPeripherals(withServices: [fd21ServiceUUID])
        if let peripheral = connected.first {
            log("从系统已连接列表发现 \(peripheral.name ?? "FreeClip 2")，尝试连接 FD21")
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
        if let peripheral = peripherals.first, peripheral.state != .connected {
            activePeripheral = peripheral
            peripheral.delegate = self
            centralManager.connect(peripheral, options: nil)
        }
    }

    private func connectGatt(_ peripheral: CBPeripheral) {
        activePeripheral = peripheral
        peripheral.delegate = self
        if settings.savedPeripheralUUID != peripheral.identifier.uuidString {
            var updated = settings
            updated.savedPeripheralUUID = peripheral.identifier.uuidString
            updateSettings(updated)
        }
        centralManager.connect(peripheral, options: nil)
    }

    func sendFD21BatteryQuery() {
        guard let peripheral = activePeripheral,
              peripheral.state == .connected,
              let writeChar = fd21WriteChar else { return }
        peripheral.writeValue(FreeClipProtocol.queryBatteryFrame, for: writeChar, type: .withoutResponse)
        log("已向 FD21 发送查电量帧: \(FreeClipProtocol.queryBatteryFrame.hexString)")
    }

    // ------------------------------------------------------------------------
    // 供 AppIntent / 快捷指令调用的一键扫描并推送（核心闭环）
    // ------------------------------------------------------------------------

    func performOneShotScan(
        timeoutSeconds: TimeInterval = 5.0,
        isForeground: Bool,
        notifyAlways: Bool,
        reason: String
    ) async -> FreeClipSnapshot? {
        log("触发扫描：\(reason)（模式：\(isForeground ? "前台全量" : "后台静默")）")

        // 等待蓝牙中心状态就绪（冷启动时最多等 1.5 秒）
        var waitCycles = 0
        while centralManager.state == .unknown && waitCycles < 15 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waitCycles += 1
        }

        guard centralManager.state == .poweredOn else {
            log("蓝牙未开启，无法扫描")
            if notifyAlways {
                BatteryNotificationManager.shared.sendScanFallbackNotice(cached: latestSnapshot, reason: "蓝牙未开启")
            }
            return nil
        }

        let result: FreeClipSnapshot? = await withCheckedContinuation { continuation in
            self.finishPendingScan(with: nil)

            self.pendingScanCompletion = { snapshot in
                continuation.resume(returning: snapshot)
            }

            // 1. 先尝试从已连接的 FD21 通道直接查电量
            self.attemptGattAttachIfConnected()
            if self.isGattConnected {
                self.sendFD21BatteryQuery()
            }

            // 2. 启动 BLE 扫描捕获 FDEE 真实广播包
            let services: [CBUUID]? = isForeground ? nil : [self.fdeeUUID, self.fd21ServiceUUID, self.fd9aUUID]
            self.centralManager.scanForPeripherals(
                withServices: services,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: isForeground]
            )
            self.isScanning = true

            // 3. 超时保护
            self.pendingScanTimer = Timer.scheduledTimer(withTimeInterval: timeoutSeconds, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finishPendingScan(with: nil)
                }
            }
        }

        if let fresh = result {
            if notifyAlways || settings.notifyOnEveryScan || fresh.isCaseLow(threshold: settings.lowBatteryThreshold) {
                BatteryNotificationManager.shared.sendBatteryReport(fresh, reason: reason, settings: settings, force: true)
            }
            return fresh
        } else {
            log("本次扫描超时（\(Int(timeoutSeconds))s），未捕获到新报文")
            if notifyAlways {
                BatteryNotificationManager.shared.sendScanFallbackNotice(cached: latestSnapshot, reason: reason)
            }
            return latestSnapshot
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
    // 统一处理解析出的真实快照（更新状态、刷新小组件、检测 100% 充满）
    // ------------------------------------------------------------------------

    private func acceptSnapshot(_ snapshot: FreeClipSnapshot) {
        let previous = latestSnapshot
        latestSnapshot = snapshot
        SharedBatteryStore.shared.saveSnapshot(snapshot)

        log("真实电量 [\(snapshot.source.rawValue)]: \(snapshot.summaryLine) (\(snapshot.lidState.rawValue))")

        // 检测充电盒是否刚刚充满到 100%
        if settings.notifyWhenFull,
           let newLvl = snapshot.caseBattery.level {
            if newLvl < 100 {
                lastAutoNotifiedCaseFull = false
            } else if newLvl == 100 && snapshot.caseBattery.isCharging && !lastAutoNotifiedCaseFull {
                let wasBelowFull = (previous?.caseBattery.level ?? 100) < 100
                if wasBelowFull {
                    lastAutoNotifiedCaseFull = true
                    BatteryNotificationManager.shared.sendFullChargeNotice(snapshot)
                    log("检测到充电盒充满 100%，已推送通知")
                }
            }
        }

        // 若有正在等待的快捷指令/手动单次扫描，立刻交付结果
        if pendingScanCompletion != nil {
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
                self.log("蓝牙已就绪")
                if UIApplication.shared.applicationState == .active {
                    self.startForegroundScanning()
                }
            } else {
                self.isScanning = false
                self.isGattConnected = false
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        Task { @MainActor in
            self.log("系统后台恢复 CoreBluetooth 状态")
            if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
               let first = peripherals.first {
                self.activePeripheral = first
                first.delegate = self
                self.isGattConnected = (first.state == .connected)
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

            // 1. 优先解析 FDEE 状态电量广播（无须建立 GATT 连接即可秒出真实三电量）
            if let fdeeData {
                if let snapshot = FreeClipProtocol.parseFDEE(fdeeData) {
                    self.discoveredDeviceName = name ?? "HUAWEI FreeClip 2"
                    if self.settings.savedPeripheralUUID != peripheral.identifier.uuidString {
                        var updated = self.settings
                        updated.savedPeripheralUUID = peripheral.identifier.uuidString
                        self.updateSettings(updated)
                    }
                    self.acceptSnapshot(snapshot)
                    return
                } else if isFreeClipByName {
                    self.discoveredDeviceName = name
                    self.log("收到 FreeClip 非电量 FDEE 帧: \(fdeeData.hexString)")
                }
            }

            // 2. 如果是 FreeClip 2 的可连接发现帧（00100001...），顺带记住 UUID 并尝试挂接 FD21
            if isFreeClipByName && isConnectable {
                self.discoveredDeviceName = name
                if self.activePeripheral == nil || self.activePeripheral?.state == .disconnected {
                    self.connectGatt(peripheral)
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.isGattConnected = true
            self.discoveredDeviceName = peripheral.name ?? "HUAWEI FreeClip 2"
            self.log("FD21 GATT 已连接，正在发现服务...")
            peripheral.discoverServices([self.fd21ServiceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.isGattConnected = false
            self.fd21NotifyChar = nil
            self.fd21WriteChar = nil
            self.log("检测到 FreeClip 2 断开连接，准备推送最新真实电量")

            // 断开瞬间推送最近一次读到的真实电量（符合“每次断开都主动推送”）
            if self.settings.notifyOnEveryScan, let snap = self.latestSnapshot {
                BatteryNotificationManager.shared.sendBatteryReport(
                    snap,
                    reason: "耳机已断开连接",
                    settings: self.settings,
                    force: false
                )
            }

            // 重新挂起后台连接等待，以便下次设备唤醒时 iOS 自动重连
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
                    self.log("已订阅 FD21 Notify 通道")
                } else if c.uuid == self.fd21WriteUUID {
                    self.fd21WriteChar = c
                }
            }
            // 稍等 0.3 秒让 Notify 订阅生效后主动查一次电量
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.sendFD21BatteryQuery()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        Task { @MainActor in
            self.log("FD21 收到报文: \(data.hexString)")
            if let snapshot = FreeClipProtocol.parseFD21Frame(data) {
                self.acceptSnapshot(snapshot)
            }
        }
    }
}
