//
//  ShopMikeyScannerWidget.swift
//  ShopMikey Scanner
//
//  Created by Michael Bordeaux on 2/18/26.
//

import WidgetKit
import SwiftUI

struct PartsIntakeWidgetSnapshot: Codable {
    let generatedAt: Date
    let scansToday: Int
    let submittedCount: Int
    let failedCount: Int
    let pendingCount: Int
    let totalValueCents: Int
}

struct PartsIntakeWidgetProvider: TimelineProvider {
    typealias Entry = PartsIntakeWidgetEntry

    func placeholder(in context: Context) -> PartsIntakeWidgetEntry {
        PartsIntakeWidgetEntry(
            date: Date(),
            scansToday: 0,
            submittedCount: 0,
            failedCount: 0,
            pendingCount: 0,
            totalValueCents: 0
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (PartsIntakeWidgetEntry) -> Void) {
        completion(loadEntry(fallbackDate: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PartsIntakeWidgetEntry>) -> Void) {
        let entry = loadEntry(fallbackDate: Date())
        let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date) ?? entry.date.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func loadEntry(fallbackDate: Date) -> PartsIntakeWidgetEntry {
        let defaults = sharedDefaults ?? .standard
        guard let data = defaults.data(forKey: "partsIntake.widgetSnapshot.v1"),
              let snapshot = try? JSONDecoder().decode(PartsIntakeWidgetSnapshot.self, from: data) else {
            return PartsIntakeWidgetEntry(
                date: fallbackDate,
                scansToday: 0,
                submittedCount: 0,
                failedCount: 0,
                pendingCount: 0,
                totalValueCents: 0
            )
        }

        // Avoid stale "today" metrics after date rollover when app hasn't published a fresh snapshot yet.
        guard Calendar.current.isDate(snapshot.generatedAt, inSameDayAs: fallbackDate) else {
            return PartsIntakeWidgetEntry(
                date: fallbackDate,
                scansToday: 0,
                submittedCount: 0,
                failedCount: 0,
                pendingCount: 0,
                totalValueCents: 0
            )
        }

        return PartsIntakeWidgetEntry(
            date: snapshot.generatedAt,
            scansToday: snapshot.scansToday,
            submittedCount: snapshot.submittedCount,
            failedCount: snapshot.failedCount,
            pendingCount: snapshot.pendingCount,
            totalValueCents: snapshot.totalValueCents
        )
    }

    private var sharedDefaults: UserDefaults? {
        let configuredID = (Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let groupID = (configuredID?.isEmpty == false) ? configuredID : "group.com.mikey.POScannerApp"
        return UserDefaults(suiteName: groupID)
    }
}

struct PartsIntakeWidgetEntry: TimelineEntry {
    let date: Date
    let scansToday: Int
    let submittedCount: Int
    let failedCount: Int
    let pendingCount: Int
    let totalValueCents: Int
}

struct ShopMikeyScannerEntryView: View {
    var entry: PartsIntakeWidgetProvider.Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            inlineAccessoryView
        case .accessoryRectangular:
            rectangularAccessoryView
        default:
            dashboardWidgetView
        }
    }

    private var dashboardWidgetView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Parts Intake", systemImage: "doc.text.viewfinder")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(entry.date, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                metric(title: "Scans", value: entry.scansToday)
                metric(title: "Submitted", value: entry.submittedCount)
                metric(title: "Attention", value: entry.pendingCount + entry.failedCount)
            }

            ProgressView(value: progress)
                .tint(.accentColor)

            Text(totalValueString)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var inlineAccessoryView: some View {
        Text("Intake \(entry.submittedCount)/\(max(1, entry.scansToday))")
            .font(.caption.weight(.semibold))
    }

    private var rectangularAccessoryView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Parts Intake", systemImage: "doc.text.viewfinder")
                    .font(.caption.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                Spacer(minLength: 4)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: progress)
                .tint(.accentColor)

            HStack(spacing: 12) {
                Label("\(entry.scansToday)", systemImage: "doc.text.viewfinder")
                Label("\(entry.submittedCount)", systemImage: "checkmark.circle")
                Label("\(entry.pendingCount + entry.failedCount)", systemImage: "exclamationmark.triangle")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var progress: Double {
        guard entry.scansToday > 0 else { return 0 }
        let rate = Double(entry.submittedCount) / Double(entry.scansToday)
        guard rate.isFinite else { return 0 }
        return min(1, max(0, rate))
    }

    private var totalValueString: String {
        let value = Double(entry.totalValueCents) / 100
        return value.formatted(.currency(code: "USD"))
    }

    private func metric(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ShopMikeyScannerWidget: Widget {
    let kind: String = "ShopMikeyScannerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PartsIntakeWidgetProvider()) { entry in
            ShopMikeyScannerEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "shopmikey://scan"))
        }
        .configurationDisplayName("Parts Intake")
        .description("Snapshot of today’s Shopmikey parts intake pipeline.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryRectangular])
    }
}

#Preview(as: .systemMedium) {
    ShopMikeyScannerWidget()
} timeline: {
    PartsIntakeWidgetEntry(
        date: .now,
        scansToday: 18,
        submittedCount: 14,
        failedCount: 2,
        pendingCount: 2,
        totalValueCents: 9088003
    )
}
