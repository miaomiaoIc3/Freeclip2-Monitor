import Foundation
import WidgetKit

/// 主 App 与桌面/锁屏小组件共享的本地存储：
/// 自动从已签名的 embedded.mobileprovision 解析真实 App Group ID（完美兼容 SideStore/AltStore 自动追加 TeamID 后缀！）
final class SharedBatteryStore {
    static let shared = SharedBatteryStore()

    static let defaultAppGroupID = "group.com.freeclip.monitor"
    private let snapshotKey = "freeclip_latest_snapshot_v1"
    private let settingsKey = "freeclip_monitor_settings_v1"
    private let logsKey = "freeclip_debug_logs_v1"
    private let snapshotFilename = "freeclip_latest_snapshot_v1.json"

    /// 动态解析出的真实可用 App Group ID（例如 group.com.freeclip.monitor.GTQZ3P9DJ3）
    let resolvedAppGroupID: String?
    private let sharedContainerURL: URL?

    private init() {
        let detected = Self.detectWorkingAppGroup()
        self.resolvedAppGroupID = detected?.id
        self.sharedContainerURL = detected?.url
    }

    private var defaults: UserDefaults {
        if let groupID = resolvedAppGroupID, let suite = UserDefaults(suiteName: groupID) {
            return suite
        }
        return .standard
    }

    private static func detectWorkingAppGroup() -> (id: String, url: URL)? {
        var candidates: [String] = []

        // 1. 优先从签名后的 embedded.mobileprovision 提取真实授权的 App Group ID（兼容 SideStore Auto-Fix AppGroup IDs）
        if let provURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: provURL),
           let plistStart = data.range(of: Data("<plist".utf8)),
           let plistEnd = data.range(of: Data("</plist>".utf8), in: plistStart.lowerBound..<data.endIndex) {
            let plistData = data[plistStart.lowerBound..<plistEnd.upperBound]
            if let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
               let entitlements = plist["Entitlements"] as? [String: Any],
               let groups = entitlements["com.apple.security.application-groups"] as? [String] {
                candidates.append(contentsOf: groups)
            }
        }

        // 2. 兜底：基于当前 Bundle ID 推导（例如 com.freeclip.monitor.TEAMID 或 .widget 后缀）
        if let bundleID = Bundle.main.bundleIdentifier {
            let baseID = bundleID.hasSuffix(".widget")
                ? String(bundleID.dropLast(".widget".count))
                : bundleID
            candidates.append("group.\(baseID)")
        }

        // 3. 默认静态 ID
        candidates.append(defaultAppGroupID)

        // 按顺序验证哪一个 App Group 容器真正可访问
        var seen = Set<String>()
        for groupID in candidates where seen.insert(groupID).inserted {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
                return (groupID, url)
            }
        }
        return nil
    }

    func saveSnapshot(_ snapshot: FreeClipSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            // 优先写入共享容器文件（跨进程 WidgetKit 读取零缓存延迟）
            if let dir = sharedContainerURL {
                let fileURL = dir.appendingPathComponent(snapshotFilename)
                try? data.write(to: fileURL, options: .atomic)
            }
            defaults.set(data, forKey: snapshotKey)
            UserDefaults.standard.set(data, forKey: snapshotKey)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    func loadSnapshot() -> FreeClipSnapshot? {
        if let dir = sharedContainerURL {
            let fileURL = dir.appendingPathComponent(snapshotFilename)
            if let data = try? Data(contentsOf: fileURL),
               let snap = try? JSONDecoder().decode(FreeClipSnapshot.self, from: data) {
                return snap
            }
        }
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
