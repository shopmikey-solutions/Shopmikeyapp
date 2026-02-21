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
    let draftCount: Int
    let reviewCount: Int
    let totalValueCents: Int
    let currencyCode: String

    init(
        generatedAt: Date,
        scansToday: Int,
        submittedCount: Int,
        failedCount: Int,
        pendingCount: Int,
        draftCount: Int,
        reviewCount: Int,
        totalValueCents: Int,
        currencyCode: String
    ) {
        self.generatedAt = generatedAt
        self.scansToday = scansToday
        self.submittedCount = submittedCount
        self.failedCount = failedCount
        self.pendingCount = pendingCount
        self.draftCount = draftCount
        self.reviewCount = reviewCount
        self.totalValueCents = totalValueCents
        self.currencyCode = currencyCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        scansToday = try container.decode(Int.self, forKey: .scansToday)
        submittedCount = try container.decode(Int.self, forKey: .submittedCount)
        failedCount = try container.decode(Int.self, forKey: .failedCount)
        pendingCount = try container.decode(Int.self, forKey: .pendingCount)
        draftCount = try container.decodeIfPresent(Int.self, forKey: .draftCount) ?? 0
        reviewCount = try container.decodeIfPresent(Int.self, forKey: .reviewCount) ?? 0
        totalValueCents = try container.decode(Int.self, forKey: .totalValueCents)
        currencyCode = try container.decodeIfPresent(String.self, forKey: .currencyCode) ?? "USD"
    }
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
            draftCount: 0,
            reviewCount: 0,
            totalValueCents: 0,
            currencyCode: "USD"
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
                draftCount: 0,
                reviewCount: 0,
                totalValueCents: 0,
                currencyCode: "USD"
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
                draftCount: 0,
                reviewCount: 0,
                totalValueCents: 0,
                currencyCode: "USD"
            )
        }

        return PartsIntakeWidgetEntry(
            date: snapshot.generatedAt,
            scansToday: snapshot.scansToday,
            submittedCount: snapshot.submittedCount,
            failedCount: snapshot.failedCount,
            pendingCount: snapshot.pendingCount,
            draftCount: snapshot.draftCount,
            reviewCount: snapshot.reviewCount,
            totalValueCents: snapshot.totalValueCents,
            currencyCode: snapshot.currencyCode
        )
    }

    private var sharedDefaults: UserDefaults? {
        let configuredID = (Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let groupID = ((configuredID?.isEmpty == false) ? configuredID : nil) ?? "group.com.mikey.POScannerApp"
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil else {
            return nil
        }
        return UserDefaults(suiteName: groupID)
    }
}

struct PartsIntakeWidgetEntry: TimelineEntry {
    let date: Date
    let scansToday: Int
    let submittedCount: Int
    let failedCount: Int
    let pendingCount: Int
    let draftCount: Int
    let reviewCount: Int
    let totalValueCents: Int
    let currencyCode: String
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
                metric(title: "Drafts", value: entry.draftCount)
                metric(title: "Review", value: entry.reviewCount)
                metric(title: "Submitted", value: entry.submittedCount)
            }

            ProgressView(value: progress)
                .tint(.accentColor)

            HStack(spacing: 8) {
                Text(totalValueString)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())

                Spacer(minLength: 6)

                Label("\(attentionCount)", systemImage: "exclamationmark.triangle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(attentionTint)
                    .contentTransition(.numericText())
                    .accessibilityLabel("Needs attention \(attentionCount)")
            }
        }
        .padding(.vertical, 2)
    }

    private var inlineAccessoryView: some View {
        Text("D\(entry.draftCount) R\(entry.reviewCount) S\(entry.submittedCount) A\(attentionCount)")
            .font(.caption.weight(.semibold))
            .contentTransition(.numericText())
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
                Label("\(entry.draftCount)", systemImage: "doc.badge.plus")
                Label("\(entry.reviewCount)", systemImage: "slider.horizontal.3")
                Label("\(entry.submittedCount)", systemImage: "checkmark.circle")
                Label("\(attentionCount)", systemImage: "exclamationmark.triangle")
            }
            .font(.caption2)
            .foregroundStyle(attentionTint)
            .lineLimit(1)
            .contentTransition(.numericText())
        }
    }

    private var progress: Double {
        let denominator = entry.submittedCount + entry.reviewCount + entry.draftCount
        guard denominator > 0 else { return 0 }
        let rate = Double(entry.submittedCount) / Double(denominator)
        guard rate.isFinite else { return 0 }
        return min(1, max(0, rate))
    }

    private var totalValueString: String {
        let value = Double(entry.totalValueCents) / 100
        let code = normalizedCurrencyCode(entry.currencyCode)
        return value.formatted(.currency(code: code))
    }

    private var attentionCount: Int {
        max(0, entry.pendingCount + entry.failedCount)
    }

    private func normalizedCurrencyCode(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.isEmpty ? "USD" : trimmed
    }

    private var attentionTint: Color {
        attentionCount == 0 ? Color.secondary : Color.orange
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
        draftCount: 3,
        reviewCount: 1,
        totalValueCents: 9088003,
        currencyCode: "USD"
    )
}
