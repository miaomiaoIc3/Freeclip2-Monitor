import WidgetKit
import SwiftUI

struct FreeClipWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: FreeClipSnapshot?
    let lowThreshold: Int
}

struct FreeClipWidgetProvider: TimelineProvider {
    private func sampleSnapshot() -> FreeClipSnapshot {
        FreeClipSnapshot(
            caseBattery: BatteryUnit(level: 85, isCharging: false),
            earbud1: BatteryUnit(level: 100, isCharging: true),
            earbud2: BatteryUnit(level: 100, isCharging: true),
            lidState: .closed,
            source: .fdeeBroadcast,
            timestamp: Date(),
            rawHex: ""
        )
    }

    func placeholder(in context: Context) -> FreeClipWidgetEntry {
        FreeClipWidgetEntry(date: Date(), snapshot: sampleSnapshot(), lowThreshold: 20)
    }

    func getSnapshot(in context: Context, completion: @escaping (FreeClipWidgetEntry) -> Void) {
        let store = SharedBatteryStore.shared
        let settings = store.loadSettings()
        let snap = store.loadSnapshot() ?? (context.isPreview ? sampleSnapshot() : nil)
        completion(FreeClipWidgetEntry(date: Date(), snapshot: snap, lowThreshold: settings.lowBatteryThreshold))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FreeClipWidgetEntry>) -> Void) {
        let store = SharedBatteryStore.shared
        let settings = store.loadSettings()
        let snap = store.loadSnapshot()
        let entry = FreeClipWidgetEntry(date: Date(), snapshot: snap, lowThreshold: settings.lowBatteryThreshold)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct FreeClipWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FreeClipWidgetEntry

    var body: some View {
        switch family {
        case .systemSmall:
            smallHomeView
        case .systemMedium:
            mediumHomeView
        case .accessoryCircular:
            lockScreenCircularView
        case .accessoryRectangular:
            lockScreenRectangularView
        default:
            smallHomeView
        }
    }

    private var snap: FreeClipSnapshot? { entry.snapshot }

    private func ringColor(for unit: BatteryUnit?, lowThreshold: Int) -> Color {
        guard let lvl = unit?.level else { return .gray.opacity(0.4) }
        if lvl <= lowThreshold { return .red }
        if lvl <= 40 { return .yellow }
        return .green
    }

    // MARK: - 桌面小号 (2x2)

    private var smallHomeView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "earbuds")
                    .font(.caption)
                    .foregroundStyle(ringColor(for: snap?.caseBattery, lowThreshold: entry.lowThreshold))
                Text("FreeClip 2")
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer()
            }

            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.22), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: Double(snap?.caseBattery.level ?? 0) / 100.0)
                    .stroke(
                        ringColor(for: snap?.caseBattery, lowThreshold: entry.lowThreshold),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 1) {
                    if snap?.caseBattery.isCharging == true {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                    Text(snap?.caseBattery.shortPercent ?? "--")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("充电盒")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 74, height: 74)

            Text("耳机 \(snap?.earbud1.shortPercent ?? "--") / \(snap?.earbud2.shortPercent ?? "--")")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }

    // MARK: - 桌面中号 (4x2)

    private var mediumHomeView: some View {
        VStack(spacing: 10) {
            HStack {
                Label("FreeClip 2", systemImage: "earbuds")
                    .font(.caption.bold())
                Spacer()
                if let snap {
                    Text(headerMeta(for: snap))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("暂无数据")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                miniRing(title: "充电盒", unit: snap?.caseBattery, lowThreshold: entry.lowThreshold)
                miniRing(title: "耳机 1", unit: snap?.earbud1, lowThreshold: 15)
                miniRing(title: "耳机 2", unit: snap?.earbud2, lowThreshold: 15)
            }
        }
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }

    private func headerMeta(for snap: FreeClipSnapshot) -> String {
        if snap.lidState != .unknown {
            return "\(snap.lidState.rawValue) · \(shortTime(snap.timestamp))"
        }
        return shortTime(snap.timestamp)
    }

    private func miniRing(title: String, unit: BatteryUnit?, lowThreshold: Int) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.22), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: Double(unit?.level ?? 0) / 100.0)
                    .stroke(
                        ringColor(for: unit, lowThreshold: lowThreshold),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 1) {
                    if unit?.isCharging == true {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                    }
                    Text(unit?.shortPercent ?? "--")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(width: 62, height: 62)

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 锁屏圆形组件

    private var lockScreenCircularView: some View {
        Gauge(value: Double(snap?.caseBattery.level ?? 0), in: 0...100) {
            Image(systemName: "earbuds")
        } currentValueLabel: {
            Text(snap?.caseBattery.shortPercent ?? "--")
                .font(.system(.caption, design: .rounded).bold())
        }
        .gaugeStyle(.accessoryCircular)
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    // MARK: - 锁屏矩形组件

    private var lockScreenRectangularView: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "earbuds")
                Text("FreeClip 2")
                    .font(.headline)
            }
            Text("盒 \(snap?.caseBattery.displayText ?? "--") · 耳机 \(snap?.earbud1.shortPercent ?? "--")/\(snap?.earbud2.shortPercent ?? "--")")
                .font(.caption)
            if let snap {
                Text(shortTime(snap.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private func shortTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }
}

@main
struct FreeClipWidgetBundle: WidgetBundle {
    var body: some Widget {
        FreeClipBatteryWidget()
    }
}

struct FreeClipBatteryWidget: Widget {
    let kind: String = "FreeClipBatteryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FreeClipWidgetProvider()) { entry in
            FreeClipWidgetView(entry: entry)
        }
        .configurationDisplayName("FreeClip 2")
        .description("查看充电盒与耳机电量。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}
