//
//  TicketPickerView.swift
//  POScannerApp
//

import ShopmikeyCoreModels
import SwiftUI

struct TicketPickerView: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var context: ActiveTicketContext

    var body: some View {
        NavigationStack {
            List {
                if context.openTickets.isEmpty {
                    Text("No open tickets available.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ticketPicker.empty")
                } else {
                    ForEach(context.openTickets) { ticket in
                        Button {
                            Task { @MainActor in
                                await context.setActiveTicketID(ticket.id)
                                dismiss()
                            }
                        } label: {
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ticket.displayNumber ?? ticket.number ?? ticket.id)
                                        .font(.headline)
                                    if let customerName = ticket.customerName, !customerName.isEmpty {
                                        Text(customerName)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let status = ticket.status, !status.isEmpty {
                                        Text(status)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                if context.activeTicketID == ticket.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ticketPicker.ticket.\(ticket.id)")
                    }
                }
            }
            .navigationTitle("Select Ticket")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") {
                        Task { @MainActor in
                            await context.refreshOpenTickets(forceRemote: true)
                        }
                    }
                    .accessibilityIdentifier("ticketPicker.refresh")
                }
            }
            .overlay {
                if context.isLoading {
                    ProgressView("Loading tickets…")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .task {
                await context.loadCachedState()
            }
        }
    }
}
