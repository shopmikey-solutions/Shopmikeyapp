//
//  ReviewView.swift
//  POScannerApp
//

import SwiftUI
import ShopmikeyCoreModels
import ShopmikeyCoreParsing
import ShopmikeyCoreNetworking

struct ReviewView: View {
    private enum FocusedField: Hashable {
        case vendor
        case vendorPhone
        case vendorEmail
        case invoice
        case po
        case order
        case service
    }

    @StateObject var viewModel: ReviewViewModel
    @State private var focusNeedsReviewOnly: Bool = false
    @State private var hasLoadedInitialMetrics: Bool = false
    @State private var isSelectionMode: Bool = false
    @State private var isBulkTypeDialogPresented: Bool = false
    @State private var isBulkCostAlertPresented: Bool = false
    @State private var isBulkDeleteConfirmationPresented: Bool = false
    @State private var bulkCostInput: String = ""
    @State private var isVendorMismatchBannerDismissed: Bool = false
    @FocusState private var focusedField: FocusedField?
    @Environment(\.dismiss) private var dismiss

    init(environment: AppEnvironment, parsedInvoice: ParsedInvoice, draftSnapshot: ReviewDraftSnapshot? = nil) {
        _viewModel = StateObject(
            wrappedValue: ReviewViewModel(
                environment: environment,
                parsedInvoice: parsedInvoice,
                draftSnapshot: draftSnapshot
            )
        )
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage, !error.isEmpty {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            if let status = viewModel.statusMessage, !status.isEmpty {
                Section {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppSurfaceStyle.success)
                }
            }

            Section("Parts Intake Status") {
                reviewHealthCard
                if viewModel.confidenceScore < 0.75 {
                    Label("Some intake fields still need review.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppSurfaceStyle.warning)
                }
            }

            Section("Vendor") {
                vendorSection
            }

            Section {
                identifierSection
            } header: {
                Text("Invoice & PO")
            }

            Section("Parts, Tires & Fees to Add") {
                if canFilterNeedsReview {
                    Toggle("Focus on items needing review", isOn: $focusNeedsReviewOnly)
                        .accessibilityIdentifier("review.focusNeedsReviewToggle")
                }

                if !viewModel.items.isEmpty {
                    Text("Swipe right to set type quickly, swipe left to delete.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                itemsList

                Button {
                    AppHaptics.impact(.light, intensity: 0.8)
                    viewModel.addEmptyItem()
                } label: {
                    Label("Add Part Line", systemImage: "plus")
                }
                .appSecondaryActionButton()
            }

            Section("Shopmonkey Destination") {
                Text("Production mode keeps this simple: add scanned lines to a Shopmonkey draft purchase order.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                taxBehaviorRow
                Text("Attach creates or updates a draft purchase order. Only Shopmonkey draft POs can be targeted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Save Intake Draft") {
                    AppHaptics.impact(.light, intensity: 0.85)
                    Task { await viewModel.saveDraft() }
                }
                .appSecondaryActionButton()
                .accessibilityIdentifier("review.saveDraftButton")

                if let lastSaved = viewModel.lastDraftSavedAt {
                    Text("Saved \(lastSaved.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if viewModel.activeDraftID != nil {
                    Button("Discard Saved Draft", role: .destructive) {
                        AppHaptics.warning()
                        Task { await viewModel.discardDraft() }
                    }
                }
            }

            Section("PO Totals") {
                LabeledContent("Subtotal", value: viewModel.subtotalFormatted)
                if !viewModel.shouldIgnoreTax {
                    LabeledContent("Tax", value: viewModel.taxFormatted)
                }
                LabeledContent("Total", value: viewModel.grandTotalFormatted)
                    .font(.headline)
                LabeledContent("Scans Today", value: "\(viewModel.todayCount)")
            }

            Section("Parts Intake Notes") {
                NativeTextView(
                    text: $viewModel.notes,
                    placeholder: "Add notes for parts intake or Shopmonkey handoff",
                    accessibilityIdentifier: "review.notesField"
                )
                    .frame(minHeight: 120)
            }

            #if DEBUG
            Section("Debug Metrics") {
                LabeledContent("Unknown Type Rate", value: percentageString(viewModel.unknownKindRate))
                LabeledContent("Type Overrides", value: String(viewModel.typeOverrideCount))
                LabeledContent("Vendor Auto-Select", value: percentageString(viewModel.vendorAutoSelectSuccessRate))
            }
            #endif
        }
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .keyboardDoneToolbar()
        .scrollDismissesKeyboard(.interactively)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("Parts Intake Review")
        .navigationBarTitleDisplayMode(.inline)
        .onSubmit {
            advanceKeyboardFocus()
        }
        .animation(.snappy(duration: 0.24), value: focusNeedsReviewOnly)
        .animation(.snappy(duration: 0.24), value: filteredItemIndices.count)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if canEditItems && !isSelectionMode {
                    EditButton()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !viewModel.items.isEmpty {
                    Button(selectionToggleTitle) {
                        AppHaptics.selection()
                        setSelectionMode(!isSelectionMode)
                    }
                    .accessibilityIdentifier("review.selectModeButton")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(viewModel.isSubmitting ? "Submitting..." : submitButtonTitle) {
                    focusedField = nil
                    setSelectionMode(false)
                    AppHaptics.impact(.medium, intensity: 0.9)
                    Task { await viewModel.submitTapped() }
                }
                .disabled(!viewModel.canSubmit || viewModel.isSubmitting)
                .accessibilityIdentifier("review.submitButton")
            }
        }
        .alert("Submission Complete", isPresented: $viewModel.showSuccessAlert) {
            Button("OK") { dismiss() }
        } message: {
            Text("Parts, tires, and fees were sent to Shopmonkey.")
        }
        .confirmationDialog("Set Line Type", isPresented: $isBulkTypeDialogPresented, titleVisibility: .visible) {
            ForEach(POItem.LineType.allCases, id: \.self) { type in
                Button(type.displayName) {
                    viewModel.bulkSetLineType(type)
                }
            }
        } message: {
            Text("Apply a line type to selected rows.")
        }
        .alert("Set Unit Cost", isPresented: $isBulkCostAlertPresented) {
            TextField("Unit Cost", text: $bulkCostInput)
                .keyboardType(.decimalPad)
            Button("Apply") {
                guard let cost = parsedBulkCostInput else { return }
                viewModel.bulkSetUnitCost(cost)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a unit cost to apply to selected rows.")
        }
        .alert("Delete Selected Items?", isPresented: $isBulkDeleteConfirmationPresented) {
            Button("Delete", role: .destructive) {
                viewModel.bulkDeleteSelected()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes \(viewModel.selectedItemIDs.count) selected line items.")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelectionMode && viewModel.hasSelection {
                bulkActionBar
            }
        }
        .onAppear {
            if !hasLoadedInitialMetrics {
                hasLoadedInitialMetrics = true
                viewModel.loadTodayMetrics()
            }
            viewModel.applyProductionPolishMode()
        }
        .onDisappear {
            Task { await viewModel.persistDraftOnExitIfNeeded() }
        }
        .onChange(of: viewModel.modeUI) { _, _ in
            AppHaptics.selection()
        }
        .onChange(of: viewModel.showSuccessAlert) { _, presented in
            if presented {
                setSelectionMode(false)
            }
            if presented { AppHaptics.success() }
        }
        .onChange(of: isSelectionMode) { _, isActive in
            if !isActive {
                viewModel.clearSelection()
            }
        }
        .onChange(of: viewModel.isSubmitting) { _, isSubmitting in
            if isSubmitting {
                setSelectionMode(false)
            }
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            if message != nil { AppHaptics.error() }
        }
        .onChange(of: viewModel.shouldShowVendorMismatchWarning) { _, showWarning in
            if !showWarning {
                isVendorMismatchBannerDismissed = false
            }
        }
    }

    private var reviewHealthCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Readiness") {
                Text("\(Int((safeReviewReadinessScore * 100).rounded()))%")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: safeReviewReadinessScore)
                .animation(.smooth(duration: 0.24), value: safeReviewReadinessScore)

            LabeledContent("Line Items") {
                Text("\(viewModel.items.count)")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            LabeledContent("Needs Review") {
                Text("\(viewModel.unknownKindCount)")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            Text(viewModel.canSubmit ? "Ready to add lines in Shopmonkey." : "Pick a vendor match and required IDs before sending.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("review.readinessHint")
        }
    }

    private var vendorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                viewModel.vendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (viewModel.suggestedVendorName ?? "Vendor")
                    : "Vendor",
                text: Binding(
                    get: { viewModel.vendorName },
                    set: { viewModel.setVendorName($0) }
                )
            )
            .textInputAutocapitalization(.words)
            .focused($focusedField, equals: .vendor)
            .submitLabel(.next)
            .accessibilityIdentifier("review.vendorField")

            vendorConfidenceBadge

            if viewModel.shouldShowVendorMismatchWarning && !isVendorMismatchBannerDismissed {
                vendorMismatchBanner
            }

            if !viewModel.vendorSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Potential vendor matches")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(viewModel.vendorSuggestions.prefix(5)) { vendor in
                        Button {
                            viewModel.selectVendorSuggestion(vendor)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(vendor.name)
                                        .foregroundStyle(.primary)
                                    if let detail = vendorContactSummary(for: vendor) {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if viewModel.selectedVendorId == vendor.id ||
                                    vendor.name.normalizedVendorName == viewModel.vendorName.normalizedVendorName {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(AppSurfaceStyle.success)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            TextField("Vendor Phone (optional)", text: $viewModel.vendorPhone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .focused($focusedField, equals: .vendorPhone)
                .submitLabel(.next)
                .accessibilityIdentifier("review.vendorPhoneField")

            TextField("Vendor Email (optional)", text: $viewModel.vendorEmail)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textContentType(.emailAddress)
                .focused($focusedField, equals: .vendorEmail)
                .submitLabel(.next)
                .accessibilityIdentifier("review.vendorEmailField")

            NativeTextView(
                text: $viewModel.vendorNotes,
                placeholder: "Vendor notes (optional)",
                accessibilityIdentifier: "review.vendorNotesField"
            )
            .frame(minHeight: 84)

            Label(
                viewModel.selectedVendorId == nil ? "Vendor not selected" : "Vendor selected",
                systemImage: viewModel.selectedVendorId == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
            )
            .font(.footnote)
            .foregroundStyle(viewModel.selectedVendorId == nil ? AppSurfaceStyle.warning : AppSurfaceStyle.success)

            if let suggestedVendorName = viewModel.suggestedVendorName, !suggestedVendorName.isEmpty {
                Text("OCR suggested vendor: \(suggestedVendorName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if viewModel.vendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let suggestedVendorName = viewModel.suggestedVendorName,
               !suggestedVendorName.isEmpty {
                Button("Use vendor suggestion: \(suggestedVendorName)") {
                    viewModel.applySuggestedVendorName()
                }
                .font(.footnote)
            }

            if viewModel.selectedVendorId == nil {
                Button {
                    AppHaptics.impact(.light, intensity: 0.85)
                    Task { await viewModel.createVendorFromCurrentInput() }
                } label: {
                    Label(
                        viewModel.isCreatingVendor ? "Creating Vendor..." : "Create Vendor",
                        systemImage: "person.crop.circle.badge.plus"
                    )
                }
                .appSecondaryActionButton()
                .disabled(!viewModel.canCreateVendorFromCurrentInput || viewModel.isCreatingVendor)
                .accessibilityIdentifier("review.createVendorButton")

                Text("No match found? Create a new Shopmonkey vendor with these contact details.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var vendorConfidenceBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: vendorConfidenceIcon)
                .foregroundStyle(vendorConfidenceColor)
            Text("Vendor confidence: \(vendorConfidenceLabel)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(vendorConfidenceColor.opacity(0.14))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vendor confidence: \(vendorConfidenceLabel)")
    }

    private var vendorMismatchBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppSurfaceStyle.warning)
                Text("Vendor name on document differs from selected vendor.")
                    .font(.footnote.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    isVendorMismatchBannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss vendor mismatch warning")
            }

            Button("Review Suggested Vendor") {
                isVendorMismatchBannerDismissed = false
                viewModel.applySuggestedVendorName()
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(10)
        .background(AppSurfaceStyle.warning.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var vendorConfidenceLabel: String {
        switch viewModel.vendorMatchConfidence {
        case .high:
            return "High"
        case .medium:
            return "Medium"
        case .low:
            return "Low"
        case .mismatch:
            return "Mismatch"
        }
    }

    private var vendorConfidenceIcon: String {
        switch viewModel.vendorMatchConfidence {
        case .high:
            return "checkmark.seal.fill"
        case .medium:
            return "exclamationmark.circle.fill"
        case .low:
            return "exclamationmark.triangle.fill"
        case .mismatch:
            return "xmark.octagon.fill"
        }
    }

    private var vendorConfidenceColor: Color {
        switch viewModel.vendorMatchConfidence {
        case .high:
            return AppSurfaceStyle.success
        case .medium:
            return AppSurfaceStyle.warning
        case .low:
            return .orange
        case .mismatch:
            return .red
        }
    }

    private var identifierSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                viewModel.vendorInvoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (viewModel.suggestedInvoiceNumber ?? "Vendor Invoice Number")
                    : "Vendor Invoice Number",
                text: $viewModel.vendorInvoiceNumber
            )
            .textInputAutocapitalization(.characters)
            .focused($focusedField, equals: .invoice)
            .submitLabel(.next)

            if viewModel.vendorInvoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let suggestedInvoice = viewModel.suggestedInvoiceNumber,
               !suggestedInvoice.isEmpty {
                Button("Use invoice suggestion: \(suggestedInvoice)") {
                    viewModel.applySuggestedInvoiceNumber()
                }
                .font(.footnote)
            }

            TextField(
                viewModel.poReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (viewModel.suggestedPONumber ?? "PO Reference (optional)")
                    : "PO Reference (optional)",
                text: Binding(
                    get: { viewModel.poReference },
                    set: { viewModel.setPOReference($0) }
                )
            )
            .textInputAutocapitalization(.characters)
            .focused($focusedField, equals: .po)
            .submitLabel(.done)

            if viewModel.poReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let suggestedPO = viewModel.suggestedPONumber,
               !suggestedPO.isEmpty {
                Button("Use PO suggestion: \(suggestedPO)") {
                    viewModel.applySuggestedPONumber()
                }
                .font(.footnote)
            }
        }
    }

    private var taxBehaviorRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Ignore tax and totals", isOn: $viewModel.ignoreTaxOverride)
                .disabled(viewModel.isGlobalIgnoreTaxEnabled)

            if viewModel.isGlobalIgnoreTaxEnabled {
                Text("Global Parts Intake Preferences has Ignore tax and totals enabled, so this review always excludes tax and total math.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var itemsList: some View {
        if filteredItemIndices.isEmpty {
            Text("No line items match the current filter.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }

        ForEach(filteredItemIndices, id: \.self) { index in
            let item = viewModel.items[index]
            let itemBinding = $viewModel.items[index]
            let itemID = item.id
            let isSelected = viewModel.selectedItemIDs.contains(itemID)
            let canConfirmSuggestion = item.isKindConfidenceMedium && item.kind != .unknown

            if isSelectionMode {
                Button {
                    AppHaptics.selection()
                    viewModel.toggleSelection(id: itemID)
                } label: {
                    lineItemRow(
                        item: item,
                        isSelectionMode: true,
                        isSelected: isSelected
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("review.itemRow")
                .accessibilityLabel(item.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Item" : item.description)
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                .contextMenu {
                    rowContextMenu(index: index, itemID: itemID, isSelected: isSelected)
                }
            } else {
                NavigationLink {
                    LineItemEditView(
                        item: itemBinding,
                        allowTaxEditing: !viewModel.shouldIgnoreTax
                    ) { oldKind, newKind in
                        viewModel.noteLineItemKindEdited(itemID: itemID, from: oldKind, to: newKind)
                    }
                } label: {
                    lineItemRow(item: item)
                }
                .contextMenu {
                    rowContextMenu(index: index, itemID: itemID, isSelected: isSelected)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    kindSwipeButton(title: "Part", kind: .part, color: AppSurfaceStyle.info, at: index)
                    kindSwipeButton(title: "Tire", kind: .tire, color: AppSurfaceStyle.warning, at: index)
                    kindSwipeButton(title: "Fee", kind: .fee, color: .teal, at: index)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if canConfirmSuggestion {
                        Button {
                            AppHaptics.selection()
                            viewModel.confirmItemSuggestion(at: index)
                        } label: {
                            Label("Confirm", systemImage: "checkmark.circle")
                        }
                        .tint(AppSurfaceStyle.success)
                    }

                    Button(role: .destructive) {
                        AppHaptics.warning()
                        viewModel.deleteItems(at: IndexSet(integer: index))
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .moveDisabled(focusNeedsReviewOnly)
            }
        }
        .onDelete(perform: deleteFilteredItems)
        .onMove(perform: moveFilteredItems)
    }

    private var canEditItems: Bool {
        !focusNeedsReviewOnly && viewModel.items.count > 1
    }

    private var canFilterNeedsReview: Bool {
        viewModel.unknownKindCount > 0 || viewModel.suggestedKindCount > 0
    }

    private var filteredItemIndices: [Int] {
        let allIndices = Array(viewModel.items.indices)
        guard focusNeedsReviewOnly, canFilterNeedsReview else { return allIndices }
        return allIndices.filter { index in
            let item = viewModel.items[index]
            return item.kind == .unknown || item.isKindConfidenceMedium
        }
    }

    private func deleteFilteredItems(at offsets: IndexSet) {
        let sourceIndices = offsets.compactMap { offset in
            filteredItemIndices.indices.contains(offset) ? filteredItemIndices[offset] : nil
        }
        let mapped = IndexSet(sourceIndices)
        viewModel.deleteItems(at: mapped)
    }

    private func moveFilteredItems(from source: IndexSet, to destination: Int) {
        guard !focusNeedsReviewOnly else { return }
        viewModel.moveItems(from: source, to: destination)
    }

    private func kindSwipeButton(title: String, kind: POItemKind, color: Color, at index: Int) -> some View {
        Button(title) {
            AppHaptics.selection()
            viewModel.setItemKind(at: index, to: kind)
        }
        .tint(color)
    }

    private func lineItemRow(
        item: POItem,
        isSelectionMode: Bool = false,
        isSelected: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AppSurfaceStyle.info : .secondary)
                    .accessibilityLabel(isSelected ? "Selected" : "Not selected")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Item" : item.description)
                    .font(.body)

                HStack(spacing: 8) {
                    Label(item.kind.displayName, systemImage: kindSymbol(for: item.kind))
                        .font(.footnote)
                        .foregroundStyle(kindTint(for: item.kind))

                    if item.kind == .unknown {
                        Text("Needs review")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if item.isKindConfidenceMedium {
                        Text("Suggested • confirm")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !item.sku.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(item.sku)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack {
                    Text("\(quantityString(item.quantity)) x \(item.unitPriceFormatted)")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer()
                    Text(item.subtotalFormatted)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if let feeHint = item.feeInferenceHint {
                    Text(feeHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, isSelectionMode ? 4 : 0)
        .background(isSelectionMode && isSelected ? AppSurfaceStyle.info.opacity(0.12) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func kindTint(for kind: POItemKind) -> Color {
        switch kind {
        case .part:
            return AppSurfaceStyle.info
        case .tire:
            return AppSurfaceStyle.warning
        case .fee:
            return .teal
        case .unknown:
            return .gray
        }
    }

    private func kindSymbol(for kind: POItemKind) -> String {
        switch kind {
        case .part:
            return "shippingbox"
        case .tire:
            return "circle.grid.cross"
        case .fee:
            return "dollarsign.circle"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private func quantityString(_ value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    private func percentageString(_ value: Double) -> String {
        let clamped = max(0, min(1, value.isFinite ? value : 0))
        return "\(Int((clamped * 100).rounded()))%"
    }

    private var selectionToggleTitle: String {
        isSelectionMode ? "Done" : "Select"
    }

    private var parsedBulkCostInput: Decimal? {
        let normalized = bulkCostInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard !normalized.isEmpty else { return nil }
        return Decimal(string: normalized)
    }

    private var bulkActionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(viewModel.selectedItemIDs.count) selected")
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("review.selectedCountLabel")
                Spacer()
                Button("Clear") {
                    AppHaptics.selection()
                    viewModel.clearSelection()
                }
                .font(.footnote)
                .accessibilityIdentifier("review.clearSelectionButton")
            }

            HStack(spacing: 8) {
                Button("Set Type") {
                    AppHaptics.selection()
                    isBulkTypeDialogPresented = true
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("review.bulkSetTypeButton")

                Button("Set Cost") {
                    AppHaptics.selection()
                    bulkCostInput = ""
                    isBulkCostAlertPresented = true
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("review.bulkSetCostButton")

                Button("Delete", role: .destructive) {
                    AppHaptics.warning()
                    isBulkDeleteConfirmationPresented = true
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("review.bulkDeleteButton")
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var safeReviewReadinessScore: Double {
        let score = viewModel.reviewReadinessScore
        guard score.isFinite else { return 0 }
        return min(1, max(0, score))
    }

    @ViewBuilder
    private func rowContextMenu(index: Int, itemID: UUID, isSelected: Bool) -> some View {
        Button(isSelected ? "Deselect" : "Select") {
            AppHaptics.selection()
            if !isSelectionMode {
                setSelectionMode(true)
            }
            viewModel.toggleSelection(id: itemID)
        }

        Button(role: .destructive) {
            AppHaptics.warning()
            viewModel.deleteItems(at: IndexSet(integer: index))
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func setSelectionMode(_ enabled: Bool) {
        isSelectionMode = enabled
        if !enabled {
            viewModel.clearSelection()
        }
    }

    private func vendorContactSummary(for vendor: VendorSummary) -> String? {
        let phone = vendor.phone?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = vendor.email?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let phone, !phone.isEmpty, let email, !email.isEmpty {
            return "\(phone) • \(email)"
        }
        if let phone, !phone.isEmpty {
            return phone
        }
        if let email, !email.isEmpty {
            return email
        }
        return nil
    }

    private var submitButtonTitle: String {
        "Add to Purchase Order"
    }

    private func advanceKeyboardFocus() {
        switch focusedField {
        case .vendor:
            focusedField = .vendorPhone
        case .vendorPhone:
            focusedField = .vendorEmail
        case .vendorEmail:
            focusedField = .invoice
        case .invoice:
            focusedField = .po
        case .po:
            focusedField = nil
        case .order:
            focusedField = viewModel.modeUI == .quickAdd ? .service : nil
        case .service:
            focusedField = nil
        case .none:
            break
        }
    }
}

#if DEBUG
#Preview("Review") {
    NavigationStack {
        ReviewView(
            environment: PreviewFixtures.makeEnvironment(seedHistory: true),
            parsedInvoice: PreviewFixtures.parsedInvoice
        )
    }
}
#endif
