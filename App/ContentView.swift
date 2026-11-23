import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @EnvironmentObject private var bt: FreeClipBluetoothManager
    @State private var isManualScanning = false
    @State private var showDebugLogs = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusHeaderCard
                    batteryDashboardCard
                    actionButtonsSection
                    settingsSection
                    debugLogSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("FreeClip 2 电量")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if bt.isScanning {
                            bt.stopScanning()
                        } else {
                            bt.startForegroundScanning()
                        }
                    } label: {
                        Label(bt.isScanning ? "扫描中" : "开始扫描", systemImage: bt.isScanning ? "antenna.radiowaves.left.and.right" : "play.circle")
                    }
                }
            }
        }
    }

    // MARK: - 顶部连接与雷达状态

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

            if let snap = bt.latestSnapshot {
                Text(snap.lidState.rawValue)
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var statusDotColor: Color {
        if bt.bluetoothState != .poweredOn { return .red }
        if bt.isGattConnected { return .green }
        if bt.isScanning { return .blue }
        return .gray
    }

    private var statusSubtitle: String {
        switch bt.bluetoothState {
        case .poweredOff: return "系统蓝牙未开启"
        case .unauthorized: return "请在系统设置中允许蓝牙权限"
        case .poweredOn:
            if bt.isGattConnected { return "FD21 已连接 · 实时监听中" }
            if bt.isScanning { return "正在扫描 FDEE 实时广播（支持合盖与充电）" }
            return "蓝牙就绪 · 扫描已暂停"
        default:
            return "正在初始化蓝牙..."
        }
    }

    // MARK: - 三路真实电量仪表盘

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
                    Label(snap.source.rawValue, systemImage: "wave.3.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("更新于 \(formatTime(snap.timestamp))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("暂未扫到数据，请将 FreeClip 2 靠近手机（开盖或合盖均可）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - 快捷操作区

    private var actionButtonsSection: some View {
        VStack(spacing: 10) {
            Button {
                guard !isManualScanning else { return }
                isManualScanning = true
                Task {
                    _ = await bt.performOneShotScan(
                        timeoutSeconds: 4.5,
                        isForeground: true,
                        notifyAlways: true,
                        reason: "手动扫描测试"
                    )
                    isManualScanning = false
                }
            } label: {
                HStack {
                    if isManualScanning {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "bell.badge.fill")
                    }
                    Text(isManualScanning ? "正在扫描实时电量..." : "立即扫描真实电量并推送通知")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - 通知策略设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("推送策略")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            Toggle("每次断开/扫描都推送电量", isOn: Binding(
                get: { bt.settings.notifyOnEveryScan },
                set: { val in
                    var s = bt.settings
                    s.notifyOnEveryScan = val
                    bt.updateSettings(s)
                }
            ))

            Divider()

            Toggle("充电盒充满 100% 时推送通知", isOn: Binding(
                get: { bt.settings.notifyWhenFull },
                set: { val in
                    var s = bt.settings
                    s.notifyWhenFull = val
                    bt.updateSettings(s)
                }
            ))

            Divider()

            Stepper(
                "充电盒低电红字标记：≤ \(bt.settings.lowBatteryThreshold)%",
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

    // MARK: - 原始报文与调试日志

    private var debugLogSection: some View {
        DisclosureGroup("实时协议日志（\(bt.logs.count)）", isExpanded: $showDebugLogs) {
            VStack(alignment: .leading, spacing: 8) {
                if let raw = bt.latestSnapshot?.rawHex {
                    Text("最新原始 Hex：\(raw)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.blue)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("清空日志", role: .destructive) {
                        bt.clearLogs()
                    }
                    .font(.caption)
                    Spacer()
                }

                ForEach(bt.logs.prefix(20), id: \.self) { line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 8)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func formatTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }
}

// MARK: - 环形电量仪表组件

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
        guard let level = unit.level else { return .gray.opacity(0.4) }
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
