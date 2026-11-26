import Foundation
import AppIntents

struct ConnectScanFreeClipIntent: AppIntent {
    static var title: LocalizedStringResource = "连接时获取 FreeClip 2 电量"
    static var description = IntentDescription("耳机连接时扫描电量，并根据「连接时推送电量」开关决定是否通知。")

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let manager = FreeClipBluetoothManager.shared
        let outcome = await manager.performOneShotScan(
            timeoutSeconds: 4.5,
            isForeground: false,
            triggerMode: .connectShortcut,
            reason: "快捷指令（已连接）"
        )
        let text = outcome.snapshot?.summaryLine ?? "未发现附近设备"
        return .result(value: text)
    }
}

struct InstantScanFreeClipIntent: AppIntent {
    static var title: LocalizedStringResource = "断开时获取 FreeClip 2 电量"
    static var description = IntentDescription("耳机断开时扫描电量，并根据「断开时推送电量」开关决定是否通知。")

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let manager = FreeClipBluetoothManager.shared
        let outcome = await manager.performOneShotScan(
            timeoutSeconds: 4.5,
            isForeground: true,
            triggerMode: .disconnectShortcut,
            reason: "快捷指令（已断开）"
        )
        let text = outcome.snapshot?.summaryLine ?? "未发现附近设备"
        return .result(value: text)
    }
}

struct SilentScanFreeClipIntent: AppIntent {
    static var title: LocalizedStringResource = "后台获取 FreeClip 2 电量"
    static var description = IntentDescription("在后台扫描电量并刷新小组件（按断开开关决定是否通知）。")

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let manager = FreeClipBluetoothManager.shared
        let outcome = await manager.performOneShotScan(
            timeoutSeconds: 5.0,
            isForeground: false,
            triggerMode: .disconnectShortcut,
            reason: "后台扫描"
        )
        let text = outcome.snapshot?.summaryLine ?? "未发现附近设备"
        return .result(value: text)
    }
}

struct FreeClipShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectScanFreeClipIntent(),
            phrases: [
                "连接时查看 \(.applicationName) 电量"
            ],
            shortTitle: "连接时获取电量",
            systemImageName: "earbuds"
        )
        AppShortcut(
            intent: InstantScanFreeClipIntent(),
            phrases: [
                "查看 \(.applicationName) 电量",
                "刷新 \(.applicationName) 电量"
            ],
            shortTitle: "断开时获取电量",
            systemImageName: "earbuds.case"
        )
        AppShortcut(
            intent: SilentScanFreeClipIntent(),
            phrases: [
                "后台查看 \(.applicationName) 电量"
            ],
            shortTitle: "后台获取电量",
            systemImageName: "antenna.radiowaves.left.and.right"
        )
    }
}
