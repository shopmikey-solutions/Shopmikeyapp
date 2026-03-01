//
//  ScanSuggestion.swift
//  POScannerApp
//

import Foundation

enum ScanSuggestion: Equatable, Sendable {
    case receivePO(poId: String, lineItemId: String)
    case addToTicket(ticketId: String)
    case addToPODraft
    case none
}
