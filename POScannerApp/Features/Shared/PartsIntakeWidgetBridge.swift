//
//  PartsIntakeWidgetBridge.swift
//  POScannerApp
//

import Foundation

struct PartsIntakeWidgetSnapshot: Codable {
    let generatedAt: Date
    let scansToday: Int
    let submittedCount: Int
    let failedCount: Int
    let pendingCount: Int
    let draftCount: Int
    let reviewCount: Int
    let totalValueCents: Int
}

enum PartsIntakeWidgetBridge {
    private static let defaultsKey = "partsIntake.widgetSnapshot.v1"
    private static let toggleKey = "scanWidgetRefreshEnabled"
    private static let appGroupKey = "AppGroupIdentifier"
    private static let fallbackAppGroupID = "group.com.mikey.POScannerApp"

    static func publish(
        scansToday: Int,
        submittedCount: Int,
        failedCount: Int,
        pendingCount: Int,
        draftCount: Int,
        reviewCount: Int,
        totalValue: Decimal
    ) {
        guard isEnabled else { return }

        let snapshot = PartsIntakeWidgetSnapshot(
            generatedAt: Date(),
            scansToday: scansToday,
            submittedCount: submittedCount,
            failedCount: failedCount,
            pendingCount: pendingCount,
            draftCount: draftCount,
            reviewCount: reviewCount,
            totalValueCents: Self.cents(from: totalValue)
        )

        guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(encoded, forKey: defaultsKey)
        sharedDefaults?.set(encoded, forKey: defaultsKey)

        #if canImport(WidgetKit)
        if #available(iOS 17.0, *) {
            importWidgetKitReload()
        }
        #endif
    }

    private static var isEnabled: Bool {
        if let stored = UserDefaults.standard.object(forKey: toggleKey) as? Bool {
            return stored
        }
        return true
    }

    private static func cents(from decimal: Decimal) -> Int {
        let number = NSDecimalNumber(decimal: decimal)
        return Int((number.doubleValue * 100).rounded())
    }

    private static var sharedDefaults: UserDefaults? {
        let configuredID = (Bundle.main.object(forInfoDictionaryKey: appGroupKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let groupID = (configuredID?.isEmpty == false) ? configuredID : fallbackAppGroupID
        return UserDefaults(suiteName: groupID)
    }
}

#if canImport(WidgetKit)
import WidgetKit

@available(iOS 17.0, *)
private func importWidgetKitReload() {
    WidgetCenter.shared.reloadAllTimelines()
}
#endif
