//
//  ScanResultActionsViewModel.swift
//  POScannerApp
//

import Combine
import Foundation

@MainActor
final class ScanResultActionsViewModel: ObservableObject {
    struct ContextSnapshot: Equatable {
        var activeTicketID: String?
        var activeTicketLabel: String?
        var activeServiceID: String?
    }

    enum Action: String, CaseIterable, Identifiable {
        case addToTicket
        case receivePO
        case restockDraft
        case lookupInventory

        var id: String { rawValue }

        var title: String {
            switch self {
            case .addToTicket:
                return "Add to ticket"
            case .receivePO:
                return "Receive on purchase order"
            case .restockDraft:
                return "Restock draft"
            case .lookupInventory:
                return "Look up in inventory"
            }
        }
    }

    enum CallToAction: Equatable {
        case chooseTicket
        case chooseService

        var title: String {
            switch self {
            case .chooseTicket:
                return "Choose ticket"
            case .chooseService:
                return "Choose service"
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .chooseTicket:
                return "scanNextStep.cta.chooseTicket"
            case .chooseService:
                return "scanNextStep.cta.chooseService"
            }
        }
    }

    struct ActionState: Equatable {
        var isEnabled: Bool
        var reason: String?
        var callToAction: CallToAction?
    }

    let scannedCode: String
    let suggestion: ScanSuggestion
    let context: ContextSnapshot

    private let performSuggestionAction: (ScanSuggestion) -> Void
    private let requestTabSwitchToTickets: () -> Void
    private let requestTabSwitchToInventory: () -> Void

    init(
        scannedCode: String,
        suggestion: ScanSuggestion,
        context: ContextSnapshot,
        performSuggestionAction: @escaping (ScanSuggestion) -> Void,
        requestTabSwitchToTickets: @escaping () -> Void,
        requestTabSwitchToInventory: @escaping () -> Void
    ) {
        self.scannedCode = scannedCode
        self.suggestion = suggestion
        self.context = context
        self.performSuggestionAction = performSuggestionAction
        self.requestTabSwitchToTickets = requestTabSwitchToTickets
        self.requestTabSwitchToInventory = requestTabSwitchToInventory
    }

    var suggestedAction: Action? {
        switch suggestion {
        case .receivePO:
            return .receivePO
        case .addToTicket:
            return .addToTicket
        case .addToPODraft:
            return .restockDraft
        case .none:
            return nil
        }
    }

    func state(for action: Action) -> ActionState {
        switch action {
        case .addToTicket:
            guard context.activeTicketID != nil else {
                return ActionState(
                    isEnabled: false,
                    reason: "Select a ticket to add this part.",
                    callToAction: .chooseTicket
                )
            }
            guard context.activeServiceID != nil else {
                return ActionState(
                    isEnabled: false,
                    reason: "You’re offline. Select a previously saved service to continue.",
                    callToAction: .chooseService
                )
            }
            return ActionState(isEnabled: true, reason: nil, callToAction: nil)

        case .receivePO:
            guard case .receivePO = suggestion else {
                return ActionState(
                    isEnabled: false,
                    reason: "No matching open PO found.",
                    callToAction: nil
                )
            }
            return ActionState(isEnabled: true, reason: nil, callToAction: nil)

        case .restockDraft:
            return ActionState(isEnabled: true, reason: nil, callToAction: nil)

        case .lookupInventory:
            return ActionState(isEnabled: true, reason: nil, callToAction: nil)
        }
    }

    func performSuggestedAction() {
        guard let suggestedAction else { return }
        performAction(suggestedAction)
    }

    func performAction(_ action: Action) {
        guard state(for: action).isEnabled else { return }

        switch action {
        case .addToTicket:
            guard let activeTicketID = context.activeTicketID else { return }
            performSuggestionAction(.addToTicket(ticketId: activeTicketID))
        case .receivePO:
            guard case .receivePO(let poID, let lineItemID) = suggestion else { return }
            performSuggestionAction(.receivePO(poId: poID, lineItemId: lineItemID))
        case .restockDraft:
            performSuggestionAction(.addToPODraft)
        case .lookupInventory:
            requestTabSwitchToInventory()
        }
    }

    func performCallToAction(_ action: CallToAction) {
        switch action {
        case .chooseTicket, .chooseService:
            requestTabSwitchToTickets()
        }
    }
}
