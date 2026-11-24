import Foundation
import AppIntents

struct InstantScanFreeClipIntent: AppIntent {
    static var title: LocalizedStringResource = "获取 FreeClip 2 电量"
    static var description = IntentDescription("扫描 FreeClip 2 电量并发送通知。")

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let manager = FreeClipBluetoothManager.shared
        let outcome = await manager.performOneShotScan(
            timeoutSeconds: 4.5,
            isForeground: true,
            notifyAlways: true,
            reason: "快捷指令扫描"
        )
        let text = outcome.snapshot?.summaryLine ?? "未发现附近设备"
        return .result(value: text)
    }
}

struct SilentScanFreeClipIntent: AppIntent {
    static var title: LocalizedStringResource = "后台获取 FreeClip 2 电量"
    static var description = IntentDescription("在后台获取 FreeClip 2 电量并发送通知。")

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let manager = FreeClipBluetoothManager.shared
        let outcome = await manager.performOneShotScan(
            timeoutSeconds: 5.0,
            isForeground: false,
            notifyAlways: true,
            reason: "后台扫描"
        )
        let text = outcome.snapshot?.summaryLine ?? "未发现附近设备"
        return .result(value: text)
    }
}

struct FreeClipShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: InstantScanFreeClipIntent(),
            phrases: [
                "查看 \(.applicationName) 电量",
                "刷新 \(.applicationName) 电量"
            ],
            shortTitle: "获取 FreeClip 2 电量",
            systemImageName: "earbuds"
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
