import SwiftUI
import CoreBluetooth
import UIKit
import UserNotifications

struct ContentView: View {
    @EnvironmentObject private var bt: FreeClipBluetoothManager
    @State private var isManualScanning = false
    @State private var scanFeedback: String? = nil
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusHeaderCard
                    batteryDashboardCard
                    actionButtonSection

                    if bt.notificationStatus == .denied {
                        notificationPermissionBanner
                    }

                    settingsSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("FreeClip 2")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            if bt.isScanning {
                                bt.stopScanning()
                            } else {
                                bt.startForegroundScanning()
                            }
                        } label: {
                            Label(
                                bt.isScanning ? "暂停扫描" : "继续扫描",
                                systemImage: bt.isScanning ? "pause.circle" : "play.circle"
                            )
                        }

                        Button {
                            showDiagnostics = true
                        } label: {
                            Label("诊断信息", systemImage: "doc.text.magnifyingglass")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsSheetView()
                    .environmentObject(bt)
            }
        }
    }

    // MARK: - 设备状态

    private var statusHeaderCard: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(bt.discoveredDeviceName ?? "HUAWEI FreeClip 2")
                    .font(.headline)
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let snap = bt.latestSnapshot, snap.lidState != .unknown {
                Text(snap.lidState.rawValue)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var statusDotColor: Color {
        if bt.bluetoothState != .poweredOn { return .red }
        if bt.isDeviceConnected { return .green }
        if bt.isScanning { return .blue }
        return .gray
    }

    private var statusSubtitle: String {
        switch bt.bluetoothState {
        case .poweredOff: return "蓝牙未开启"
        case .unauthorized: return "需要蓝牙权限"
        case .poweredOn:
            if bt.isDeviceConnected { return "已连接" }
            if bt.isScanning { return "正在扫描" }
            return "已暂停"
        default:
            return "正在初始化"
        }
    }

    // MARK: - 电量仪表盘

    private var batteryDashboardCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                BatteryGaugeView(
                    title: "充电盒",
                    icon: "batteryblock",
                    unit: bt.latestSnapshot?.caseBattery ?? BatteryUnit(level: nil, isCharging: false),
                    lowThreshold: bt.settings.lowBatteryThreshold
                )
                BatteryGaugeView(
                    title: "耳机 1",
                    icon: "earbuds",
                    unit: bt.latestSnapshot?.earbud1 ?? BatteryUnit(level: nil, isCharging: false),
                    lowThreshold: 15
                )
                BatteryGaugeView(
                    title: "耳机 2",
                    icon: "earbuds",
                    unit: bt.latestSnapshot?.earbud2 ?? BatteryUnit(level: nil, isCharging: false),
                    lowThreshold: 15
                )
            }

            Divider()

            HStack {
                if let snap = bt.latestSnapshot {
                    Text("更新于 \(formatTime(snap.timestamp))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    Text("将耳机靠近手机以获取电量")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - 刷新与通知

    private var actionButtonSection: some View {
        VStack(spacing: 8) {
            Button {
                guard !isManualScanning else { return }
                isManualScanning = true
                scanFeedback = nil
                Task {
                    let outcome = await bt.performOneShotScan(
                        timeoutSeconds: 4.5,
                        isForeground: true,
                        triggerMode: .manual,
                        reason: "手动刷新"
                    )
                    switch outcome.notificationResult {
                    case .denied:
                        scanFeedback = "未开启通知权限，请在系统设置中允许"
                    case .failed(let message):
                        scanFeedback = "通知发送失败：\(message)"
                    default:
                        if outcome.isFresh {
                            scanFeedback = "已更新并发送通知"
                        } else if outcome.snapshot != nil {
                            scanFeedback = "未检测到新广播，已发送最近记录"
                        } else {
                            scanFeedback = "未发现附近设备"
                        }
                    }
                    isManualScanning = false
                }
            } label: {
                HStack(spacing: 8) {
                    if isManualScanning {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "bell.fill")
                    }
                    Text(isManualScanning ? "正在刷新..." : "刷新并发送通知")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            if let feedback = scanFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var notificationPermissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.slash.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("通知权限已关闭")
                    .font(.subheadline.weight(.medium))
                Text("开启后可接收电量与低电提醒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("去设置") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 通知设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("通知")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle("连接时推送电量", isOn: Binding(
                get: { bt.settings.notifyOnConnect },
                set: { val in
                    var s = bt.settings
                    s.notifyOnConnect = val
                    bt.updateSettings(s)
                }
            ))

            Divider()

            Toggle("断开时推送电量", isOn: Binding(
                get: { bt.settings.notifyOnDisconnect },
                set: { val in
                    var s = bt.settings
                    s.notifyOnDisconnect = val
                    bt.updateSettings(s)
                }
            ))

            Divider()

            Toggle("充满提醒", isOn: Binding(
                get: { bt.settings.notifyWhenFull },
                set: { val in
                    var s = bt.settings
                    s.notifyWhenFull = val
                    bt.updateSettings(s)
                }
            ))

            Divider()

            Stepper(
                "低电量提醒：\(bt.settings.lowBatteryThreshold)%",
                value: Binding(
                    get: { bt.settings.lowBatteryThreshold },
                    set: { val in
                        var s = bt.settings
                        s.lowBatteryThreshold = val
                        bt.updateSettings(s)
                    }
                ),
                in: 5...50,
                step: 5
            )
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func formatTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "MM-dd HH:mm"
        return fmt.string(from: date)
    }
}

// MARK: - 环形电量仪表

struct BatteryGaugeView: View {
    let title: String
    let icon: String
    let unit: BatteryUnit
    let lowThreshold: Int

    private var progress: Double {
        guard let level = unit.level else { return 0 }
        return Double(level) / 100.0
    }

    private var ringColor: Color {
        guard let level = unit.level else { return .gray.opacity(0.35) }
        if level <= lowThreshold { return .red }
        if level <= 40 { return .yellow }
        return .green
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 8)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.35), value: progress)

                VStack(spacing: 2) {
                    if unit.isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: icon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(unit.shortPercent)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
            }
            .frame(width: 78, height: 78)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 诊断信息页

private struct DiagnosticsSheetView: View {
    @EnvironmentObject private var bt: FreeClipBluetoothManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("状态") {
                    LabeledContent("App Group", value: SharedBatteryStore.shared.resolvedAppGroupID ?? "不可用")
                    LabeledContent("通知权限", value: notificationStatusText)
                    if let snap = bt.latestSnapshot {
                        LabeledContent("数据通道", value: snap.source.rawValue)
                    }
                }

                if let raw = bt.latestSnapshot?.rawHex, !raw.isEmpty {
                    Section("最新报文") {
                        Text(raw)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                Section {
                    if bt.logs.isEmpty {
                        Text("暂无日志")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(bt.logs.prefix(30), id: \.self) { line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HStack {
                        Text("日志")
                        Spacer()
                        if !bt.logs.isEmpty {
                            Button("清空", role: .destructive) {
                                bt.clearLogs()
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("诊断信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var notificationStatusText: String {
        switch bt.notificationStatus {
        case .authorized: return "已开启"
        case .provisional: return "临时允许"
        case .ephemeral: return "限时允许"
        case .denied: return "已关闭"
        case .notDetermined: return "未请求"
        @unknown default: return "未知"
        }
    }
}
