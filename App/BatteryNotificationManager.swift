import Foundation
import UserNotifications

enum NotificationDeliveryResult: Equatable {
    case delivered
    case denied
    case failed(String)
}

final class BatteryNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = BatteryNotificationManager()
    private var lastNotificationSentAt: Date?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// 让 App 在前台时也能弹出系统横幅与提示音
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings().authorizationStatus
        if current == .authorized || current == .provisional || current == .ephemeral {
            return true
        }
        if current == .denied {
            return false
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if !granted {
                SharedBatteryStore.shared.appendLog("用户未授予通知权限")
            }
            return granted
        } catch {
            SharedBatteryStore.shared.appendLog("通知授权失败: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func sendBatteryReport(
        _ snapshot: FreeClipSnapshot,
        settings: MonitorSettings,
        force: Bool = true
    ) async -> NotificationDeliveryResult {
        if !force, let last = lastNotificationSentAt, Date().timeIntervalSince(last) < 4 {
            return .delivered
        }

        let content = UNMutableNotificationContent()
        if snapshot.isCaseLow(threshold: settings.lowBatteryThreshold),
           let caseLvl = snapshot.caseBattery.level {
            content.title = "FreeClip 2 电量偏低"
            content.body = "充电盒 \(caseLvl)%，耳机 \(snapshot.earbud1.shortPercent) / \(snapshot.earbud2.shortPercent)"
        } else {
            content.title = "FreeClip 2"
            content.body = snapshot.summaryLine
        }
        content.sound = .default

        let result = await deliver(content: content, idPrefix: "freeclip-battery")
        if result == .delivered {
            lastNotificationSentAt = Date()
        }
        return result
    }

    @discardableResult
    func sendFullChargeNotice(_ snapshot: FreeClipSnapshot) async -> NotificationDeliveryResult {
        let content = UNMutableNotificationContent()
        content.title = "FreeClip 2 已充满"
        content.body = "充电盒电量 100%"
        content.sound = .default
        return await deliver(content: content, idPrefix: "freeclip-full")
    }

    @discardableResult
    func sendLowBatteryNotice(_ snapshot: FreeClipSnapshot) async -> NotificationDeliveryResult {
        let content = UNMutableNotificationContent()
        content.title = "FreeClip 2 电量偏低"
        let caseText = snapshot.caseBattery.shortPercent
        content.body = "充电盒仅剩 \(caseText)，请及时充电"
        content.sound = .default
        return await deliver(content: content, idPrefix: "freeclip-low")
    }

    @discardableResult
    func sendScanFallbackNotice(cached: FreeClipSnapshot?) async -> NotificationDeliveryResult {
        let content = UNMutableNotificationContent()
        content.title = "FreeClip 2"
        if let cached {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            content.body = "\(cached.summaryLine)（\(fmt.string(from: cached.timestamp))）"
        } else {
            content.body = "未发现附近设备"
        }
        content.sound = .default
        return await deliver(content: content, idPrefix: "freeclip-fallback")
    }

    private func deliver(
        content: UNMutableNotificationContent,
        idPrefix: String
    ) async -> NotificationDeliveryResult {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = await requestAuthorization()
            status = await center.notificationSettings().authorizationStatus
        }

        guard status == .authorized || status == .provisional || status == .ephemeral else {
            SharedBatteryStore.shared.appendLog("发送通知中止：系统通知权限未开启")
            return .denied
        }

        // trigger: nil 立即投递，避免短时后台/快捷指令进程在定时触发前挂起
        let request = UNNotificationRequest(
            identifier: "\(idPrefix)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            return .delivered
        } catch {
            SharedBatteryStore.shared.appendLog("发送通知失败: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }
}
