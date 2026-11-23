import SwiftUI

@main
struct FreeClipMonitorApp: App {
    @StateObject private var btManager = FreeClipBluetoothManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(btManager)
                .task {
                    _ = await BatteryNotificationManager.shared.requestAuthorization()
                    FreeClipShortcutsProvider.updateAppShortcutParameters()
                    btManager.startForegroundScanning()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                btManager.startForegroundScanning()
            case .background:
                btManager.switchToBackgroundMode()
            default:
                break
            }
        }
    }
}
