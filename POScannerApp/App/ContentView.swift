//
//  ContentView.swift
//  POScannerApp
//

import SwiftUI
import ShopmikeyCoreModels

/// Preview-only screen catalog for tuning hierarchy and native iOS rhythm in one place.
struct ContentView: View {
    private let environment = PreviewFixtures.makeEnvironment(seedHistory: true)

    var body: some View {
        NavigationStack {
            List {
                Section("Primary Flow") {
                    NavigationLink("Scan") {
                        ScanView(environment: environment)
                    }

                    NavigationLink("Review") {
                        ReviewView(environment: environment, parsedInvoice: PreviewFixtures.parsedInvoice)
                    }

                    NavigationLink("Line Item Edit") {
                        ContentViewLineItemEditPreview(item: PreviewFixtures.lineItem)
                    }
                }

                Section("Management") {
                    NavigationLink("History") {
                        HistoryView(environment: environment)
                    }

                    NavigationLink("Settings") {
                        SettingsView(environment: environment)
                    }
                }

                Section("Pickers & Detail") {
                    NavigationLink("Order Picker") {
                        OrderPickerView(service: PreviewFixtures.previewShopmonkeyService) { _ in }
                    }

                    NavigationLink("Service Picker") {
                        ServicePickerView(
                            service: PreviewFixtures.previewShopmonkeyService,
                            orderId: "preview-order-1"
                        ) { _ in }
                    }

                    NavigationLink("History Detail") {
                        let order = PreviewFixtures.firstHistoryOrder(in: environment.dataController.viewContext)
                        HistoryDetailView(purchaseOrder: order)
                    }
                }
            }
            .navigationTitle("Screen Catalog")
        }
    }
}

private struct ContentViewLineItemEditPreview: View {
    @State var item: POItem

    var body: some View {
        LineItemEditView(item: $item)
    }
}

#Preview("Screen Catalog") {
    ContentView()
}
