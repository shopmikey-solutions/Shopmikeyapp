//
//  TicketDetailView.swift
//  POScannerApp
//

import ShopmikeyCoreModels
import ShopmikeyCoreNetworking
import SwiftUI

struct TicketDetailView: View {
    let environment: AppEnvironment
    let ticketID: String

    @State private var ticket: TicketModel?
    @State private var services: [ServiceSummary] = []
    @State private var selectedServiceID: String?
    @State private var activeTicketID: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            summarySection
            serviceSection
            lineItemsSection
        }
        .navigationTitle(ticket?.displayNumber ?? ticket?.number ?? "Ticket")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && ticket == nil {
                ProgressView("Loading ticket…")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("tickets.detail.loading")
            }
        }
        .refreshable {
            await load(forceRemote: true)
        }
        .task {
            await load(forceRemote: false)
        }
        .onChange(of: selectedServiceID) { _, value in
            Task {
                await environment.ticketStore.setSelectedServiceID(value, forTicketID: ticketID)
            }
        }
    }

    private var summarySection: some View {
        Section("Summary") {
            if let ticket {
                LabeledContent("Ticket", value: ticket.displayNumber ?? ticket.number ?? ticket.id)
                    .accessibilityIdentifier("tickets.detail.ticketNumber")

                if let customerName = ticket.customerName, !customerName.isEmpty {
                    LabeledContent("Customer", value: customerName)
                        .accessibilityIdentifier("tickets.detail.customer")
                }

                if let vehicleSummary = ticket.vehicleSummary, !vehicleSummary.isEmpty {
                    LabeledContent("Vehicle", value: vehicleSummary)
                        .accessibilityIdentifier("tickets.detail.vehicle")
                }

                if let status = ticket.status, !status.isEmpty {
                    LabeledContent("Status", value: status)
                        .accessibilityIdentifier("tickets.detail.status")
                }

                if activeTicketID == ticket.id {
                    Text("Active ticket")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("tickets.detail.activeBadge")
                }

                Button(activeTicketID == ticket.id ? "Active Ticket" : "Set Active Ticket") {
                    Task {
                        await environment.ticketStore.setActiveTicketID(ticket.id)
                        activeTicketID = await environment.ticketStore.activeTicketID()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(activeTicketID == ticket.id)
                .accessibilityIdentifier("tickets.detail.setActiveButton")
            } else {
                Text("Ticket unavailable")
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("tickets.detail.error")
            }
        }
    }

    private var serviceSection: some View {
        Section("Service Context") {
            if services.isEmpty {
                Text("No services loaded for this ticket.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("tickets.detail.servicesEmpty")
            } else if services.count == 1 {
                let service = services[0]
                let serviceName = service.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                LabeledContent("Selected Service", value: serviceName?.isEmpty == false ? serviceName! : service.id)
                    .accessibilityIdentifier("tickets.detail.singleService")
            } else {
                Picker("Selected Service", selection: $selectedServiceID) {
                    Text("Select a service").tag(String?.none)
                    ForEach(services, id: \.id) { service in
                        let title = service.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                        Text(title?.isEmpty == false ? title! : service.id)
                            .tag(Optional(service.id))
                    }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("tickets.detail.servicePicker")
            }

            if selectedServiceID == nil {
                Text("A selected service is required for add-to-ticket mutations.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("tickets.detail.serviceRequiredHint")
            }
        }
    }

    private var lineItemsSection: some View {
        Section("Line Items") {
            if let ticket {
                if ticket.lineItems.isEmpty {
                    Text("No line items available.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("tickets.detail.lineItemsEmpty")
                } else {
                    ForEach(ticket.lineItems, id: \.id) { lineItem in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lineItem.description)
                                .font(.subheadline.weight(.semibold))
                            HStack {
                                if let partNumber = lineItem.partNumber, !partNumber.isEmpty {
                                    Text(partNumber)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if let sku = lineItem.sku, !sku.isEmpty {
                                    Text(sku)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                                Text("Qty \(NSDecimalNumber(decimal: lineItem.quantity).stringValue)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("tickets.detail.lineItem.\(lineItem.id)")
                    }
                }
            } else {
                Text("Line items unavailable.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("tickets.detail.lineItemsUnavailable")
            }
        }
    }

    @MainActor
    private func load(forceRemote: Bool) async {
        isLoading = true
        defer { isLoading = false }

        activeTicketID = await environment.ticketStore.activeTicketID()
        selectedServiceID = await environment.ticketStore.selectedServiceID(forTicketID: ticketID)

        if let cached = await environment.ticketStore.loadTicket(id: ticketID) {
            ticket = cached
        }

        if forceRemote || ticket == nil {
            do {
                let fetched = try await environment.shopmonkeyAPI.fetchTicket(id: ticketID)
                await environment.ticketStore.save(ticket: fetched)
                ticket = await environment.ticketStore.loadTicket(id: ticketID)
                errorMessage = nil
            } catch {
                if ticket == nil {
                    errorMessage = "Could not load ticket details."
                }
            }
        }

        do {
            let fetchedServices = try await environment.shopmonkeyAPI.fetchServices(orderId: ticketID)
            services = fetchedServices
            if fetchedServices.count == 1, let only = fetchedServices.first {
                selectedServiceID = only.id
                await environment.ticketStore.setSelectedServiceID(only.id, forTicketID: ticketID)
            }
            if selectedServiceID == nil, fetchedServices.count > 1 {
                errorMessage = "Select a service before adding inventory items."
            } else if selectedServiceID != nil {
                errorMessage = nil
            }
        } catch {
            services = []
            if selectedServiceID == nil {
                errorMessage = "Service context unavailable while offline. Use a cached service selection before mutating."
            }
        }
    }
}
