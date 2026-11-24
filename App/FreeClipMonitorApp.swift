import SwiftUI

@main
struct FreeClipMonitorApp: App {
    @StateObject private var btManager = FreeClipBluetoothManager.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 同步注册 UNUserNotificationCenterDelegate，确保冷启动与前台通知均可正常弹窗
        _ = BatteryNotificationManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(btManager)
                .task {
                    _ = await BatteryNotificationManager.shared.requestAuthorization()
                    await btManager.refreshNotificationStatus()
                    FreeClipShortcutsProvider.updateAppShortcutParameters()
                    btManager.startForegroundScanning()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task { await btManager.refreshNotificationStatus() }
                btManager.startForegroundScanning()
            case .background:
                btManager.switchToBackgroundMode()
            default:
                break
            }
        }
    }
}
