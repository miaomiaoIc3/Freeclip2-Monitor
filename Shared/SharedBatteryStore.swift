import Foundation
import WidgetKit

/// 主 App 与桌面/锁屏小组件共享的本地存储（支持 App Group，降级到 UserDefaults.standard）
final class SharedBatteryStore {
    static let shared = SharedBatteryStore()

    // 若使用个人免费证书自签且未配 App Group，会自动安全降级到 standard
    static let appGroupID = "group.com.freeclip.monitor"
    private let snapshotKey = "freeclip_latest_snapshot_v1"
    private let settingsKey = "freeclip_monitor_settings_v1"
    private let logsKey = "freeclip_debug_logs_v1"

    private var defaults: UserDefaults {
        UserDefaults(suiteName: Self.appGroupID) ?? .standard
    }

    func saveSnapshot(_ snapshot: FreeClipSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
            UserDefaults.standard.set(data, forKey: snapshotKey)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    func loadSnapshot() -> FreeClipSnapshot? {
        if let data = defaults.data(forKey: snapshotKey),
           let snap = try? JSONDecoder().decode(FreeClipSnapshot.self, from: data) {
            return snap
        }
        if let data = UserDefaults.standard.data(forKey: snapshotKey),
           let snap = try? JSONDecoder().decode(FreeClipSnapshot.self, from: data) {
            return snap
        }
        return nil
    }

    func saveSettings(_ settings: MonitorSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsKey)
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    func loadSettings() -> MonitorSettings {
        if let data = defaults.data(forKey: settingsKey),
           let settings = try? JSONDecoder().decode(MonitorSettings.self, from: data) {
            return settings
        }
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let settings = try? JSONDecoder().decode(MonitorSettings.self, from: data) {
            return settings
        }
        return MonitorSettings()
    }

    func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        var logs = loadLogs()
        logs.insert(line, at: 0)
        if logs.count > 40 {
            logs = Array(logs.prefix(40))
        }
        defaults.set(logs, forKey: logsKey)
    }

    func loadLogs() -> [String] {
        defaults.stringArray(forKey: logsKey) ?? []
    }

    func clearLogs() {
        defaults.removeObject(forKey: logsKey)
    }
}
