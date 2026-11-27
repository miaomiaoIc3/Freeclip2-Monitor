import Foundation
import WidgetKit

/// 主 App 与桌面/锁屏小组件共享的本地存储。
/// 自动从已签名的 embedded.mobileprovision / ALTAppGroups 解析实际生效的 App Group ID，
/// 兼容 SideStore / AltStore 重签时附加个人 TeamID 后缀的场景。
final class SharedBatteryStore {
    static let shared = SharedBatteryStore()

    static let defaultAppGroupID = "group.com.freeclip.monitor"
    private let snapshotKey = "freeclip_latest_snapshot_v1"
    private let settingsKey = "freeclip_monitor_settings_v1"
    private let sessionKey = "freeclip_earbud_session_v1"
    private let logsKey = "freeclip_debug_logs_v1"
    private let snapshotFilename = "freeclip_latest_snapshot_v1.json"

    let resolvedAppGroupID: String?
    let detectionCandidates: [String]
    private let sharedContainerURL: URL?

    private var lastSavedSnapshot: FreeClipSnapshot?
    private var lastDiskWriteAt: Date?
    private var lastWidgetReloadAt: Date?

    private init() {
        let candidates = Self.collectAppGroupCandidates()
        self.detectionCandidates = candidates
        if let detected = Self.resolveWorkingAppGroup(from: candidates) {
            self.resolvedAppGroupID = detected.id
            self.sharedContainerURL = detected.url
        } else {
            self.resolvedAppGroupID = nil
            self.sharedContainerURL = nil
        }
    }

    private var defaults: UserDefaults {
        if let groupID = resolvedAppGroupID, let suite = UserDefaults(suiteName: groupID) {
            return suite
        }
        return .standard
    }

    private static func collectAppGroupCandidates() -> [String] {
        var candidates: [String] = []

        // 1. 从签名后的 embedded.mobileprovision 提取实际授权的 App Group ID
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

        // 2. SideStore / AltStore 会在 Info.plist 写入重签后的 ALTAppGroups
        if let altGroups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] {
            candidates.append(contentsOf: altGroups)
        }

        // 3. 基于当前 Bundle ID 推导（兼容主 App 与 .widget 扩展的不同后缀顺序）
        if let bundleID = Bundle.main.bundleIdentifier {
            if bundleID.hasSuffix(".widget") {
                let base = String(bundleID.dropLast(".widget".count))
                candidates.append("group.\(base)")
            } else if bundleID.contains(".widget.") {
                let base = bundleID.replacingOccurrences(of: ".widget.", with: ".")
                candidates.append("group.\(base)")
            } else {
                candidates.append("group.\(bundleID)")
            }
        }

        // 4. 默认静态 ID
        candidates.append(defaultAppGroupID)

        var unique: [String] = []
        var seen = Set<String>()
        for raw in candidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("*") else { continue }
            if seen.insert(trimmed).inserted {
                unique.append(trimmed)
            }
        }
        return unique
    }

    private static func resolveWorkingAppGroup(from candidates: [String]) -> (id: String, url: URL)? {
        for groupID in candidates {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
                return (groupID, url)
            }
        }
        return nil
    }

    func saveSnapshot(_ snapshot: FreeClipSnapshot, forceWidgetReload: Bool = false) {
        let now = Date()
        let changed = snapshot.hasSignificantChange(comparedTo: lastSavedSnapshot)
        let shouldWriteDisk = forceWidgetReload
            || changed
            || lastDiskWriteAt == nil
            || now.timeIntervalSince(lastDiskWriteAt!) >= 10

        if shouldWriteDisk, let data = try? JSONEncoder().encode(snapshot) {
            if let dir = sharedContainerURL {
                let fileURL = dir.appendingPathComponent(snapshotFilename)
                try? data.write(to: fileURL, options: .atomic)
            }
            defaults.set(data, forKey: snapshotKey)
            UserDefaults.standard.set(data, forKey: snapshotKey)
            lastSavedSnapshot = snapshot
            lastDiskWriteAt = now
        }

        let shouldReloadWidget = forceWidgetReload
            || changed
            || lastWidgetReloadAt == nil
            || now.timeIntervalSince(lastWidgetReloadAt!) >= 60

        if shouldReloadWidget {
            lastWidgetReloadAt = now
            WidgetCenter.shared.reloadAllTimelines()
        }
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

    func saveSessionRecord(_ record: PersistedSessionRecord) {
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: sessionKey)
            UserDefaults.standard.set(data, forKey: sessionKey)
        }
    }

    func loadSessionRecord() -> PersistedSessionRecord {
        if let data = defaults.data(forKey: sessionKey),
           let record = try? JSONDecoder().decode(PersistedSessionRecord.self, from: data) {
            return record
        }
        if let data = UserDefaults.standard.data(forKey: sessionKey),
           let record = try? JSONDecoder().decode(PersistedSessionRecord.self, from: data) {
            return record
        }
        return PersistedSessionRecord(state: .idle, updatedAt: .distantPast)
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
