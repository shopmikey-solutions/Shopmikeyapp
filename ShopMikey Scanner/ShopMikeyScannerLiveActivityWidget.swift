//
//  ShopMikeyScannerLiveActivityWidget.swift
//  ShopMikey Scanner
//
//  Created by Michael Bordeaux on 2/18/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct PartsIntakeActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var statusText: String
        var detailText: String
        var progress: Double
        var updatedAt: Date
        var deepLinkURL: String?
        var stageToken: String?
    }

    var title: String
}

struct ShopMikeyScannerLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PartsIntakeActivityAttributes.self) { context in
            let stage = resolvedStage(for: context.state)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label(context.attributes.title, systemImage: "doc.text.viewfinder")
                        .font(.caption.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(context.state.updatedAt, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(context.state.statusText)
                    .font(.headline)
                    .lineLimit(1)

                ProgressView(value: clampedProgress(context.state.progress))
                    .tint(stage.tint)

                Text(context.state.detailText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .activityBackgroundTint(stage.tint.opacity(0.14))
            .activitySystemActionForegroundColor(.primary)
            .widgetURL(deepLinkURL(for: context))
        } dynamicIsland: { context in
            let stage = resolvedStage(for: context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 3) {
                    Label(stage.label, systemImage: stage.iconName)
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                DynamicIslandExpandedRegion(.trailing, priority: 2) {
                    Text("\(progressPercent(clampedProgress(context.state.progress)))%")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .contentTransition(.numericText())
                }
                DynamicIslandExpandedRegion(.center, priority: 1) {
                    Text(context.state.statusText)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            ProgressView(value: clampedProgress(context.state.progress))
                                .tint(stage.tint)
                            Text(context.state.updatedAt, style: .relative)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(context.state.detailText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                    }
                }
            } compactLeading: {
                Image(systemName: stage.iconName)
            } compactTrailing: {
                Text("\(progressPercent(clampedProgress(context.state.progress)))%")
                    .font(.caption2.monospacedDigit())
                    .contentTransition(.numericText())
            } minimal: {
                Image(systemName: stage.iconName)
            }
            .widgetURL(deepLinkURL(for: context))
            .keylineTint(stage.tint)
        }
    }

    private func clampedProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0.02 }
        return min(1, max(0.02, progress))
    }

    private func progressPercent(_ progress: Double) -> Int {
        Int((progress * 100).rounded())
    }

    private func resolvedStage(for state: PartsIntakeActivityAttributes.ContentState) -> Stage {
        if let token = state.stageToken?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           let stage = Stage(rawValue: token) {
            return stage
        }

        let normalized = state.statusText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("step 1") || normalized.contains("capture") {
            return .capture
        }
        if normalized.contains("step 2") || normalized.contains("ocr") || normalized.contains("parsing") {
            return .ocr
        }
        if normalized.contains("step 3") || normalized.contains("draft") {
            return .draft
        }
        if normalized.contains("step 4") || normalized.contains("submit") {
            return .submit
        }
        if normalized.contains("success") || normalized.contains("complete") {
            return .success
        }
        if normalized.contains("fail") || normalized.contains("attention") {
            return .fail
        }
        if normalized.contains("pause") || normalized.contains("inactive") {
            return .paused
        }
        return .intake
    }

    private func deepLinkURL(for context: ActivityViewContext<PartsIntakeActivityAttributes>) -> URL? {
        if let raw = context.state.deepLinkURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "shopmikey://scan?compose=1")
    }
}

private extension ShopMikeyScannerLiveActivityWidget {
    enum Stage: String {
        case capture
        case ocr
        case parse
        case draft
        case submit
        case success
        case fail
        case paused
        case intake

        var label: String {
            switch self {
            case .capture:
                return "Capture"
            case .ocr:
                return "OCR"
            case .parse:
                return "Parse"
            case .draft:
                return "Draft"
            case .submit:
                return "Submit"
            case .success:
                return "Submitted"
            case .fail:
                return "Attention"
            case .paused:
                return "Paused"
            case .intake:
                return "Parts Intake"
            }
        }

        var iconName: String {
            switch self {
            case .capture:
                return "camera.viewfinder"
            case .ocr:
                return "doc.text.magnifyingglass"
            case .parse:
                return "text.badge.checkmark"
            case .draft:
                return "square.and.pencil"
            case .submit:
                return "paperplane"
            case .success:
                return "checkmark.circle"
            case .fail:
                return "exclamationmark.triangle"
            case .paused:
                return "pause.circle"
            case .intake:
                return "doc.text.viewfinder"
            }
        }

        var tint: Color {
            switch self {
            case .fail:
                return .orange
            case .success:
                return .green
            case .paused:
                return .gray
            default:
                return .accentColor
            }
        }
    }
}

extension PartsIntakeActivityAttributes {
    fileprivate static var preview: PartsIntakeActivityAttributes {
        PartsIntakeActivityAttributes(title: "Parts Intake")
    }
}

extension PartsIntakeActivityAttributes.ContentState {
    fileprivate static var parsing: PartsIntakeActivityAttributes.ContentState {
        PartsIntakeActivityAttributes.ContentState(
            statusText: "Classifying parts",
            detailText: "Applying on-device AI and deterministic rules.",
            progress: 0.64,
            updatedAt: .now,
            deepLinkURL: "shopmikey://scan?compose=1",
            stageToken: "parse"
        )
    }

    fileprivate static var finalizing: PartsIntakeActivityAttributes.ContentState {
        PartsIntakeActivityAttributes.ContentState(
            statusText: "Preparing review",
            detailText: "Finishing purchase-order intake checks.",
            progress: 0.9,
            updatedAt: .now,
            deepLinkURL: "shopmikey://scan?compose=1",
            stageToken: "draft"
        )
    }
}

#Preview("Notification", as: .content, using: PartsIntakeActivityAttributes.preview) {
   ShopMikeyScannerLiveActivityWidget()
} contentStates: {
    PartsIntakeActivityAttributes.ContentState.parsing
    PartsIntakeActivityAttributes.ContentState.finalizing
}
