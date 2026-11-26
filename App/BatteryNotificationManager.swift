import Foundation
import UserNotifications

enum NotificationDeliveryResult: Equatable {
    case delivered
    case denied
    case failed(String)
}

enum NotificationChannel {
    case manual
    case connect
    case disconnect
}

final class BatteryNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = BatteryNotificationManager()

    /// 连接与断开各自独立记录冷却时间，绝不互相阻塞
    private var lastConnectSentAt: Date?
    private var lastDisconnectSentAt: Date?

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

    func resetChannelCooldown(for oppositeOf: NotificationChannel) {
        switch oppositeOf {
        case .connect:
            lastDisconnectSentAt = nil
        case .disconnect:
            lastConnectSentAt = nil
        case .manual:
            break
        }
    }

    @discardableResult
    func sendBatteryReport(
        _ snapshot: FreeClipSnapshot,
        settings: MonitorSettings,
        channel: NotificationChannel = .manual
    ) async -> NotificationDeliveryResult {
        let now = Date()
        switch channel {
        case .connect:
            if let last = lastConnectSentAt, now.timeIntervalSince(last) < 6 {
                return .delivered
            }
        case .disconnect:
            if let last = lastDisconnectSentAt, now.timeIntervalSince(last) < 6 {
                return .delivered
            }
        case .manual:
            break
        }

        let content = UNMutableNotificationContent()
        if snapshot.isCaseLow(threshold: settings.lowBatteryThreshold) {
            content.title = "FreeClip 2 · 电量偏低"
        } else {
            content.title = "FreeClip 2"
        }
        content.body = snapshot.summaryLine
        content.sound = .default

        let idTag: String
        switch channel {
        case .connect: idTag = "freeclip-connect"
        case .disconnect: idTag = "freeclip-disconnect"
        case .manual: idTag = "freeclip-manual"
        }

        let result = await deliver(content: content, idPrefix: idTag)
        if result == .delivered {
            switch channel {
            case .connect:
                lastConnectSentAt = Date()
            case .disconnect:
                lastDisconnectSentAt = Date()
            case .manual:
                break
            }
        }
        return result
    }

    @discardableResult
    func sendFullChargeNotice(_ snapshot: FreeClipSnapshot) async -> NotificationDeliveryResult {
        let content = UNMutableNotificationContent()
        content.title = "FreeClip 2 · 已充满"
        content.body = snapshot.summaryLine
        content.sound = .default
        return await deliver(content: content, idPrefix: "freeclip-full")
    }

    @discardableResult
    func sendLowBatteryNotice(_ snapshot: FreeClipSnapshot) async -> NotificationDeliveryResult {
        let content = UNMutableNotificationContent()
        content.title = "FreeClip 2 · 电量偏低"
        content.body = snapshot.summaryLine
        content.sound = .default
        return await deliver(content: content, idPrefix: "freeclip-low")
    }

    @discardableResult
    func sendScanFallbackNotice(cached: FreeClipSnapshot?) async -> NotificationDeliveryResult {
        let content = UNMutableNotificationContent()
        content.title = "FreeClip 2"
        content.body = cached?.summaryLine ?? "充电盒 -- · 左耳 -- · 右耳 --"
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
