import Foundation
import CoreBluetooth
import UIKit
import UserNotifications

struct OneShotScanOutcome {
    let snapshot: FreeClipSnapshot?
    let isFresh: Bool
    let notificationResult: NotificationDeliveryResult?
}

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
    @Published var notificationStatus: UNAuthorizationStatus = .notDetermined

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

    private override init() {
        let store = SharedBatteryStore.shared
        self.latestSnapshot = store.loadSnapshot()
        self.settings = store.loadSettings()
        self.logs = store.loadLogs()
        super.init()

        self.centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.freeclip.monitor.central.v1"]
        )
    }

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
    // 前台 / 后台扫描控制
    // ------------------------------------------------------------------------

    func startForegroundScanning() {
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
        reconnectSavedPeripheralIfPossible()
    }

    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        log("已暂停扫描")
    }

    func attemptGattAttachIfConnected() {
        guard centralManager.state == .poweredOn else { return }
        let connected = centralManager.retrieveConnectedPeripherals(withServices: [fd21ServiceUUID])
        if let peripheral = connected.first {
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
    }

    // ------------------------------------------------------------------------
    // 单次扫描并推送通知（供手动按钮与快捷指令调用）
    // ------------------------------------------------------------------------

    func performOneShotScan(
        timeoutSeconds: TimeInterval = 4.5,
        isForeground: Bool,
        notifyAlways: Bool,
        reason: String
    ) async -> OneShotScanOutcome {
        log("触发扫描：\(reason)")

        var waitCycles = 0
        while centralManager.state == .unknown && waitCycles < 15 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waitCycles += 1
        }

        guard centralManager.state == .poweredOn else {
            log("蓝牙未开启")
            let notifyRes: NotificationDeliveryResult?
            if notifyAlways {
                notifyRes = await BatteryNotificationManager.shared.sendScanFallbackNotice(cached: latestSnapshot)
            } else {
                notifyRes = nil
            }
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
            if notifyAlways || settings.notifyOnEveryScan || fresh.isCaseLow(threshold: settings.lowBatteryThreshold) {
                notifyResult = await BatteryNotificationManager.shared.sendBatteryReport(
                    fresh,
                    settings: settings,
                    force: true
                )
            }
            await refreshNotificationStatus()
            return OneShotScanOutcome(snapshot: fresh, isFresh: true, notificationResult: notifyResult)
        } else {
            log("扫描超时，未捕获到新广播")
            if let cached = latestSnapshot {
                SharedBatteryStore.shared.saveSnapshot(cached, forceWidgetReload: true)
            }
            if notifyAlways {
                notifyResult = await BatteryNotificationManager.shared.sendScanFallbackNotice(cached: latestSnapshot)
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
                }
            } else {
                self.isScanning = false
                self.isGattConnected = false
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
                }
            }

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
            self.log("GATT 已连接")
            peripheral.discoverServices([self.fd21ServiceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.isGattConnected = false
            self.fd21NotifyChar = nil
            self.fd21WriteChar = nil
            self.log("设备已断开")

            if self.settings.notifyOnEveryScan, let snap = self.latestSnapshot {
                let settingsCopy = self.settings
                Task {
                    await BatteryNotificationManager.shared.sendBatteryReport(
                        snap,
                        settings: settingsCopy,
                        force: false
                    )
                }
            }

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
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
