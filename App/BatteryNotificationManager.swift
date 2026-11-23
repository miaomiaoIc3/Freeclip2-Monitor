import Foundation
import UserNotifications

final class BatteryNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = BatteryNotificationManager()
    private var lastNotificationSentAt: Date?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// 关键：让 App 处于前台时也能弹出系统横幅与提示音（否则 iOS 默认静默吞掉前台通知）
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            SharedBatteryStore.shared.appendLog("通知授权失败: \(error.localizedDescription)")
            return false
        }
    }

    func sendBatteryReport(_ snapshot: FreeClipSnapshot, reason: String, settings: MonitorSettings, force: Bool = true) {
        if !force, let last = lastNotificationSentAt, Date().timeIntervalSince(last) < 4 {
            return
        }

        let content = UNMutableNotificationContent()
        let isLow = snapshot.isCaseLow(threshold: settings.lowBatteryThreshold)
        let prefix = isLow ? "🔴 充电盒低电" : "🎧 FreeClip 2"

        content.title = "\(prefix) · \(snapshot.summaryLine)"

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        let timeStr = timeFmt.string(from: snapshot.timestamp)

        var detailParts: [String] = []
        if let caseLvl = snapshot.caseBattery.level {
            let chgText = snapshot.caseBattery.isCharging ? "充电中" : "未充电"
            detailParts.append("充电盒 \(caseLvl)%（\(chgText)）")
        }
        detailParts.append("盒盖：\(snapshot.lidState.rawValue)")
        detailParts.append("通道：\(snapshot.source.rawValue)")
        detailParts.append("扫描于 \(timeStr)")

        if isLow {
            detailParts.append("⚠️ 建议尽快给充电盒充电")
        }

        content.body = "\(reason)\n" + detailParts.joined(separator: " | ")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "freeclip-battery-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                SharedBatteryStore.shared.appendLog("发送通知失败: \(error.localizedDescription)")
            }
        }
        lastNotificationSentAt = Date()
    }

    func sendFullChargeNotice(_ snapshot: FreeClipSnapshot) {
        let content = UNMutableNotificationContent()
        content.title = "⚡ FreeClip 2 充电盒已充满 100%"
        content.body = "当前真实电量：\(snapshot.summaryLine)，可以拔掉充电线啦。"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "freeclip-full-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendScanFallbackNotice(cached: FreeClipSnapshot?, reason: String) {
        let content = UNMutableNotificationContent()
        if let cached {
            let fmt = DateFormatter()
            fmt.dateFormat = "MM-dd HH:mm"
            content.title = "🎧 FreeClip 2 最近一次电量：\(cached.summaryLine)"
            content.body = "\(reason) 未搜到新蓝牙广播，展示 \(fmt.string(from: cached.timestamp)) 缓存的真实电量。"
        } else {
            content.title = "🎧 FreeClip 2 暂未扫描到电量"
            content.body = "\(reason) 未捕获到 FreeClip 2 广播，请靠近耳机盒或打开 App 重试。"
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "freeclip-fallback-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }
}
