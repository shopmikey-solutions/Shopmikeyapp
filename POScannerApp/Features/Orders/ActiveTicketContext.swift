//
//  ActiveTicketContext.swift
//  POScannerApp
//

import Foundation
import Observation
import ShopmikeyCoreModels
import ShopmikeyCoreNetworking

struct TicketLineItemMutationPayload: Hashable, Codable, Sendable {
    static let fingerprintPrefix = "ticket_line_item_add_v1"

    var ticketID: String
    var serviceID: String
    var sku: String?
    var partNumber: String?
    var description: String
    var quantity: Decimal
    var unitPrice: Decimal?
    var vendorID: String
    var mergeMode: TicketLineMergeMode

    var payloadFingerprint: String {
        let parts: [(String, String)] = [
            ("ticketId", ticketID),
            ("serviceId", serviceID),
            ("sku", sku ?? ""),
            ("partNumber", partNumber ?? ""),
            ("description", description),
            ("quantity", decimalString(quantity)),
            ("unitPrice", unitPrice.map(decimalString) ?? ""),
            ("vendorId", vendorID),
            ("mergeMode", mergeMode.rawValue)
        ]

        return Self.fingerprintPrefix + "|" + parts
            .map { key, value in
                "\(key)=\(Self.percentEncode(value))"
            }
            .joined(separator: "|")
    }

    static func from(payloadFingerprint: String) -> TicketLineItemMutationPayload? {
        guard payloadFingerprint.hasPrefix(fingerprintPrefix + "|") else { return nil }

        let rawPairs = payloadFingerprint
            .dropFirst((fingerprintPrefix + "|").count)
            .split(separator: "|")

        var values: [String: String] = [:]
        values.reserveCapacity(rawPairs.count)

        for pair in rawPairs {
            let components = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard components.count == 2 else { continue }
            values[components[0]] = percentDecode(components[1]) ?? ""
        }

        guard let ticketID = normalized(values["ticketId"]),
              let serviceID = normalized(values["serviceId"]),
              let description = normalized(values["description"]),
              let quantityRaw = normalized(values["quantity"]),
              let quantity = Decimal(string: quantityRaw),
              let vendorID = normalized(values["vendorId"]),
              let mergeModeRaw = normalized(values["mergeMode"]),
              let mergeMode = TicketLineMergeMode(rawValue: mergeModeRaw) else {
            return nil
        }

        let unitPrice = normalized(values["unitPrice"]).flatMap { Decimal(string: $0) }

        return TicketLineItemMutationPayload(
            ticketID: ticketID,
            serviceID: serviceID,
            sku: normalized(values["sku"]),
            partNumber: normalized(values["partNumber"]),
            description: description,
            quantity: quantity,
            unitPrice: unitPrice,
            vendorID: vendorID,
            mergeMode: mergeMode
        )
    }

    private func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "|=&")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func percentDecode(_ value: String) -> String? {
        value.removingPercentEncoding
    }
}

@Observable
final class ActiveTicketContext {
    private let ticketStore: any TicketStoring
    private let shopmonkeyAPI: any ShopmonkeyServicing

    private(set) var openTickets: [TicketModel] = []
    private(set) var activeTicketID: String?
    private(set) var activeServiceID: String?
    private(set) var isLoading = false
    var errorMessage: String?

    init(
        ticketStore: any TicketStoring,
        shopmonkeyAPI: any ShopmonkeyServicing
    ) {
        self.ticketStore = ticketStore
        self.shopmonkeyAPI = shopmonkeyAPI
    }

    var activeTicket: TicketModel? {
        guard let activeTicketID else { return nil }
        return openTickets.first(where: { $0.id == activeTicketID })
    }

    func loadCachedState() async {
        activeTicketID = await ticketStore.activeTicketID()
        if let activeTicketID {
            activeServiceID = await ticketStore.selectedServiceID(forTicketID: activeTicketID)
        } else {
            activeServiceID = nil
        }
        openTickets = await ticketStore.loadOpenTickets()
        if openTickets.isEmpty {
            await refreshOpenTickets(forceRemote: true)
        }
    }

    func refreshOpenTickets(forceRemote: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        if !forceRemote {
            let cached = await ticketStore.loadOpenTickets()
            if !cached.isEmpty {
                openTickets = cached
                if let activeTicketID,
                   !cached.contains(where: { $0.id == activeTicketID }) {
                    await setActiveTicketID(nil)
                }
                return
            }
        }

        do {
            let fetched = try await shopmonkeyAPI.fetchOpenTickets()
            await ticketStore.save(tickets: fetched)
            openTickets = await ticketStore.loadOpenTickets()
            errorMessage = nil

            if let activeTicketID,
               !openTickets.contains(where: { $0.id == activeTicketID }) {
                await setActiveTicketID(nil)
            }
            if let activeTicketID {
                activeServiceID = await ticketStore.selectedServiceID(forTicketID: activeTicketID)
            } else {
                activeServiceID = nil
            }
        } catch {
            errorMessage = "Could not load open tickets."
            openTickets = await ticketStore.loadOpenTickets()
        }
    }

    func setActiveTicketID(_ ticketID: String?) async {
        activeTicketID = ticketID
        await ticketStore.setActiveTicketID(ticketID)
        if let ticketID {
            activeServiceID = await ticketStore.selectedServiceID(forTicketID: ticketID)
        } else {
            activeServiceID = nil
        }
    }

    func setActiveServiceID(_ serviceID: String?) async {
        guard let activeTicketID else {
            activeServiceID = nil
            return
        }
        await ticketStore.setSelectedServiceID(serviceID, forTicketID: activeTicketID)
        activeServiceID = await ticketStore.selectedServiceID(forTicketID: activeTicketID)
    }

    func selectedServiceID(for ticketID: String) async -> String? {
        await ticketStore.selectedServiceID(forTicketID: ticketID)
    }

    func setSelectedServiceID(_ serviceID: String?, for ticketID: String) async {
        await ticketStore.setSelectedServiceID(serviceID, forTicketID: ticketID)
        if ticketID == activeTicketID {
            activeServiceID = await ticketStore.selectedServiceID(forTicketID: ticketID)
        }
    }
}
