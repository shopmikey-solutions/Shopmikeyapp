//
//  TicketPickerView.swift
//  POScannerApp
//

import ShopmikeyCoreModels
import SwiftUI

struct TicketPickerView: View {
    private static let pageSize = TicketStore.defaultPageSize
    private static let stalenessThreshold: TimeInterval = 10 * 60

    @Environment(\.dismiss) private var dismiss

    @Bindable var context: ActiveTicketContext
    @State private var currentPage = 0
    @State private var visibleTickets: [TicketModel] = []
    @State private var hasMorePages = false
    @State private var stalePromptDismissed = false

    var body: some View {
        NavigationStack {
            List {
                if likelyStale && !stalePromptDismissed {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ticket data may be stale.")
                            .font(.subheadline.weight(.semibold))
                        Text("Refresh before selecting a ticket for line-item changes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Refresh") {
                                Task { @MainActor in
                                    stalePromptDismissed = true
                                    await context.refreshOpenTickets(forceRemote: true)
                                    resetPagination()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("ticketPicker.staleRefresh")

                            Button("Cancel") {
                                stalePromptDismissed = true
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("ticketPicker.staleCancel")
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("ticketPicker.stalePrompt")
                }

                if visibleTickets.isEmpty {
                    Text("No open tickets available.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ticketPicker.empty")
                } else {
                    ForEach(visibleTickets) { ticket in
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

                    if hasMorePages {
                        Button("Load More") {
                            loadNextPage()
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("ticketPicker.loadMore")
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
                            stalePromptDismissed = true
                            resetPagination()
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
                resetPagination()
            }
            .onChange(of: context.openTickets) { _, _ in
                resetPagination()
            }
        }
    }

    private var likelyStale: Bool {
        guard let latestUpdatedAt = context.openTickets.compactMap(\.updatedAt).max() else {
            return false
        }
        return Date().timeIntervalSince(latestUpdatedAt) > Self.stalenessThreshold
    }

    private func resetPagination() {
        currentPage = 0
        let firstPageCount = min(context.openTickets.count, Self.pageSize)
        visibleTickets = Array(context.openTickets.prefix(firstPageCount))
        hasMorePages = visibleTickets.count < context.openTickets.count
        if !likelyStale {
            stalePromptDismissed = false
        }
    }

    private func loadNextPage() {
        guard hasMorePages else { return }
        currentPage += 1
        let nextLimit = min(context.openTickets.count, (currentPage + 1) * Self.pageSize)
        visibleTickets = Array(context.openTickets.prefix(nextLimit))
        hasMorePages = visibleTickets.count < context.openTickets.count
    }
}
