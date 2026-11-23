import Foundation
import AppIntents

/// 快捷指令动作 1：快速扫出真实电量并推送（100% 必中 FDEE 合盖/充电广播）
/// 推荐绑定到 iPhone 快捷指令自动化：「蓝牙 -> HUAWEI FreeClip 2 -> 已断开连接 -> 立即运行」
struct InstantScanFreeClipIntent: AppIntent {
    static var title: LocalizedStringResource = "扫描 FreeClip 2 真实电量并推送"
    static var description = IntentDescription("立即扫描华为 FreeClip 2 的 FDEE 真实蓝牙电量并推送通知到 iPhone（支持合盖与充电状态）。")

    /// 为确保 100% 捕获 iOS 后台可能过滤的纯 ServiceData 广播（如合盖后的 FDEE），短时唤起完成扫描
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let manager = FreeClipBluetoothManager.shared
        let snap = await manager.performOneShotScan(
            timeoutSeconds: 4.5,
            isForeground: true,
            notifyAlways: true,
            reason: "蓝牙断开自动扫描"
        )
        let text = snap?.summaryLine ?? "暂未扫描到 FreeClip 2 信号"
        return .result(value: text)
    }
}

/// 快捷指令动作 2：纯后台静默扫描并推送（不弹出 App 界面）
struct SilentScanFreeClipIntent: AppIntent {
    static var title: LocalizedStringResource = "后台静默扫描 FreeClip 2 电量"
    static var description = IntentDescription("不打开 App 界面，在后台尝试通过 FD21 / FDEE 扫描电量并推送通知。")

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let manager = FreeClipBluetoothManager.shared
        let snap = await manager.performOneShotScan(
            timeoutSeconds: 5.0,
            isForeground: false,
            notifyAlways: true,
            reason: "后台自动扫描"
        )
        let text = snap?.summaryLine ?? "后台未捕获到新广播"
        return .result(value: text)
    }
}

struct FreeClipShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: InstantScanFreeClipIntent(),
            phrases: [
                "扫描 \(.applicationName) 电量",
                "查看 \(.applicationName) 电量"
            ],
            shortTitle: "扫描 FreeClip 2 电量",
            systemImageName: "earbuds"
        )
        AppShortcut(
            intent: SilentScanFreeClipIntent(),
            phrases: [
                "后台扫描 \(.applicationName) 电量"
            ],
            shortTitle: "后台扫描电量",
            systemImageName: "antenna.radiowaves.left.and.right"
        )
    }
}
