import CoreDomain
import SwiftUI

/// A chapter heading for the pantry index and its first visit.
struct PantryJournalHeading: View {
    let title: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(verbatim: title)
                .marketJournalTitle(.largeTitle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize {
                Image(decorative: "MarketGroceries").resizable().scaledToFit()
                    .frame(width: 87, height: 60).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Keep the status symbol and its wording in one text element, including in native list cells.
struct PantryNoticeLabel: View {
    let notice: PantryModel.Notice
    let identifier: String

    var body: some View {
        let title = pantryNotice(notice)
        let symbol = Image(systemName: notice.isSaved ? "checkmark.circle" : "exclamationmark.circle")
        Text("\(symbol)  \(title)")
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityIdentifier(identifier)
    }
}

enum PantrySheet: Identifiable {
    case add, found(InventoryLocation), recount(UUID), purchase(PantryRecentPurchase), review, receipt, products, prices, aliases
    var id: String {
        switch self { case .found(let location): return "found-" + location.rawValue; case .add: return "add"; case .recount(let id): return "recount-\(id)"; case .purchase(let row): return "purchase-\(row.id)"; case .review: return "review"; case .receipt: return "receipt"; case .products: return "products"; case .prices: return "prices"; case .aliases: return "aliases" }
    }
}

/// Composition owns authorization and migration. This surface never activates a database.
struct PantryHomeView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.pantryDigestAccess) private var digestAccess
    @ObservedObject var model: PantryModel
    let accessAllowed: Bool
    var offersTonight = false
    var offersStaplePrompts = false
    var allowsPackageReview = false
    var household: HouseholdModel?
    var holdsLoadedReview: () -> Bool = { false }
    var recoveredHistoryAccess: (@MainActor () -> Bool)? = nil
    var initialSheet: Binding<PantrySheet?>? = nil
    var openShelfLot: ((UUID) -> Void)? = nil
    @State private var sheet: PantrySheet?
    @State private var selectedLocation: InventoryLocation?
    @State private var choosingLocation = false
    @State private var selectedDigest: DigestSelection?
    private struct DigestSelection {
        let model: PantryModel
        let access: PantryDigestAccess
    }
    @AccessibilityFocusState private var focusedLot: UUID?

    var body: some View {
        ScrollViewReader { reader in
            pantryList.modifier(PantryEntryPresentation(model: model, accessAllowed: accessAllowed, sheet: $sheet,
                holdsLoadedReview: holdsLoadedReview, handlesReview: sheet != nil, revealSavedLot: { id in
                    guard accessAllowed, model.phase == .ready, model.snapshot?.lots.contains(where: { $0.id == id }) == true else { return }
                    selectedLocation = nil
                    Task { @MainActor in
                        await Task.yield()
                        guard accessAllowed, model.phase == .ready, model.snapshot?.lots.contains(where: { $0.id == id }) == true else { return }
                        reader.scrollTo(id, anchor: .center)
                        focusedLot = id
                    }
                }))
        }
        .onDisappear { model.dismissConsumptionReceipt() }
        .onChange(of: sheet?.id) { _, destination in
            if destination != nil { model.dismissConsumptionReceipt() }
        }
        .navigationTitle(pantryText("My Pantry"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onChange(of: model.canEdit, initial: true) { _, ready in
            if ready, accessAllowed, let initialSheet, let requested = initialSheet.wrappedValue {
                initialSheet.wrappedValue = nil
                sheet = requested
            }
        }
        .navigationDestination(isPresented: Binding(get: { selectedDigest != nil }, set: { if !$0 { selectedDigest = nil } })) {
            if let selectedDigest { PantryDigestList(model: selectedDigest.model, access: selectedDigest.access) }
        }
        .privacySensitive()
    }

    @ViewBuilder private var locationFilter: some View {
        let title = pantryText("Filter by location")
        let allLocations = pantryText("All locations")
        if typeSize.isAccessibilitySize {
            let value = selectedLocation.map(pantryLocationName) ?? allLocations
            Button { choosingLocation = true } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline).foregroundStyle(Theme.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(value)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").imageScale(.small).accessibilityHidden(true)
                    }
                    .foregroundStyle(Theme.action)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(title).accessibilityValue(value).accessibilityIdentifier("pantry.locationFilter")
            .sheet(isPresented: $choosingLocation) {
                NavigationStack {
                    JournalList {
                        locationChoice(nil)
                        ForEach(InventoryLocation.allCases, id: \.self) { location in
                            locationChoice(location)
                        }
                    }
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(pantryText("Cancel")) { choosingLocation = false }
                                .accessibilityLabel(pantryText("Cancel"))
                                .accessibilityIdentifier("pantry.cancelLocationFilter")
                        }
                    }
                }
            }
        } else {
            Picker(title, selection: $selectedLocation) {
                Text(allLocations).tag(nil as InventoryLocation?)
                ForEach(InventoryLocation.allCases, id: \.self) { location in
                    Text(pantryLocationName(location)).tag(Optional(location))
                }
            }
            .accessibilityIdentifier("pantry.locationFilter")
        }
    }

    private func locationChoice(_ location: InventoryLocation?) -> some View {
        let name = location.map(pantryLocationName) ?? pantryText("All locations")
        let selected = selectedLocation == location
        return Button {
            selectedLocation = location
            choosingLocation = false
        } label: {
            HStack {
                Text(name)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var pantryList: some View {
        Group {
            if accessAllowed {
                JournalList {
                    if let notice = model.notice {
                        Section {
                            PantryNoticeLabel(notice: notice, identifier: "pantry.status")
                                .foregroundStyle(notice.isSaved ? Theme.ink : Theme.warning)
                        }
                    }
                    if model.pending != nil {
                        Section {
                            Button(pantryText("Review pending save")) { sheet = .review }
                                .buttonStyle(PrimaryAction())
                        }
                    }
                    if model.phase == .ready, let snapshot = model.snapshot {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                PantryJournalHeading(title: pantryText("Food at home"))
                                BrandScopeLabel(recoveredHistoryAccess == nil ? pantryText("Private · On this iPhone") : recordsText("Recovered workspace"), systemImage: recoveredHistoryAccess == nil ? "lock" : "archivebox")
                                Button { sheet = .add } label: {
                                    Label(pantryText("Add food"), systemImage: "plus")
                                }
                                .buttonStyle(PrimaryAction()).disabled(!model.canEdit)
                                .accessibilityIdentifier("pantry.add")
                            }
                            .padding(.vertical, 4)
                            if let household {
                                NavigationLink {
                                    PantryVoiceView(model: model, household: household, origin: snapshot.state.workspaceID)
                                } label: {
                                    Label(pantryText("Talk or type about pantry food"), systemImage: "waveform")
                                }
                                .disabled(!model.canEdit)
                                .accessibilityIdentifier("pantry.voiceEntry")
                            }
                            NavigationLink {
                                PantryPackFind(model: model, origin: snapshot.state.workspaceID,
                                               allowsPackageReview: accessAllowed && allowsPackageReview)
                            } label: {
                                Label(pantryText("Find a package in Pantry"), systemImage: "barcode.viewfinder")
                            }.accessibilityIdentifier("pantry.findPack")
                            Button { sheet = .receipt } label: {
                                JournalActionLabel(pantryText("Review a receipt"), systemImage: pantryReceiptSymbol)
                            }
                            .disabled(!model.canEdit).accessibilityIdentifier("pantry.receipt")
                        }
                        Section {
                            if let digestAccess, digestAccess.scope.origin == snapshot.state.workspaceID, digestAccess.authorized() {
                                Button {
                                    selectedDigest = DigestSelection(model: model, access: digestAccess)
                                } label: {
                                    HStack {
                                        Label(pantryText("Use soon"), systemImage: "calendar.badge.clock")
                                        Spacer()
                                        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold))
                                            .foregroundStyle(Theme.secondary).accessibilityHidden(true)
                                    }
                                }
                                .accessibilityIdentifier("pantry.digest")
                            }
                            locationFilter
                            if snapshot.lots.isEmpty {
                                Text(pantryText("No food recorded here.")).foregroundStyle(Theme.secondary)
                            }
                        }
                        ForEach(InventoryLocation.allCases, id: \.self) { location in
                            let lots = snapshot.lots.filter { $0.location == location }.sorted {
                                $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                            }
                            let names = Dictionary(grouping: lots, by: { $0.name.lowercased() })
                            if (selectedLocation == location || selectedLocation == nil && !lots.isEmpty) && !snapshot.lots.isEmpty {
                                Section {
                                    if lots.isEmpty { Text(pantryText("No food recorded here.")).foregroundStyle(Theme.secondary) }
                                    ForEach(lots) { lot in
                                        let label = PantryShelfLotLabel(lot: lot, availability: snapshot.availability.lots.first { $0.id == lot.id },
                                                                        distinguishesBatches: (names[lot.name.lowercased()]?.count ?? 0) > 1)
                                        Group {
                                            if let openShelfLot {
                                                Button { openShelfLot(lot.id) } label: {
                                                    HStack {
                                                        label
                                                        Spacer(minLength: 4)
                                                        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold))
                                                            .foregroundStyle(Theme.secondary).accessibilityHidden(true)
                                                    }.contentShape(Rectangle())
                                                }
                                            } else {
                                                NavigationLink {
                                                    PantryLotEntryView(model: model, lotID: lot.id, accessAllowed: accessAllowed, offersTonight: offersTonight,
                                                                       household: household, recoveredHistoryAccess: recoveredHistoryAccess)
                                                } label: { label }
                                            }
                                        }
                                        .accessibilityIdentifier("pantry.lot.\(lot.id)")
                                        .accessibilityFocused($focusedLot, equals: lot.id)
                                        .id(lot.id)
                                    }
                                } header: {
                                    Label(pantryLocationName(location), systemImage: location == .fridge ? "refrigerator" : location == .freezer ? "snowflake" : "cabinet")
                                }
                            }
                        }
                        Section(pantryText("Pantry tools")) {
                            if recoveredHistoryAccess == nil {
                                PantryShelfPhotoLink(expectedOrigin: snapshot.state.workspaceID)
                            }
                            if let digestAccess, digestAccess.scope.origin == snapshot.state.workspaceID, digestAccess.authorized() {
                                NavigationLink {
                                    PantryShelfView(model: model, scope: digestAccess.scope)
                                } label: { Label(pantryText("Count one shelf"), systemImage: "checklist") }
                            }
                            if let digestAccess, digestAccess.scope.origin == snapshot.state.workspaceID, digestAccess.authorized() {
                                NavigationLink(pantryText("Standing stock checks")) {
                                    PantryStandingChecksView(scope: digestAccess.scope)
                                }.accessibilityIdentifier("pantry.standingChecks")
                                NavigationLink(pantryText("Staple minimums")) {
                                    PantryMinimumsView(model: model, scope: digestAccess.scope)
                                }
                            }
                            NavigationLink(pantryText("Named pantry places")) {
                                PantryNamedPlacesView(model: model, origin: snapshot.state.workspaceID)
                            }.accessibilityIdentifier("pantry.namedPlaces")
                            NavigationLink(pantryText("Import pantry CSV")) {
                                PantryCSVImportView(model: model, origin: snapshot.state.workspaceID)
                            }.disabled(!model.canEdit).accessibilityIdentifier("pantry.importCSV")
                            Button { sheet = .products } label: {
                                Label(pantryText("Scan products"), systemImage: "barcode.viewfinder")
                            }
                            .disabled(!model.canEdit).accessibilityIdentifier("pantry.productBatch")
                            if model.supportsReceiptAliases {
                                Button(pantryText("Saved receipt spellings")) { sheet = .aliases }
                            }
                            Button(pantryText("Receipt history")) { sheet = .prices }
                                .disabled(!model.canEdit).accessibilityIdentifier("pantry.receiptHistory")
                            if offersStaplePrompts && model.supportsReceiptAliases {
                                NavigationLink(pantryText("Running-low staples")) { PantryStaplesView(model: model) }
                                    .accessibilityIdentifier("pantry.staples")
                            }
                            if offersTonight {
                                NavigationLink(tonightText("Tonight")) { TonightEntry() }
                                    .accessibilityIdentifier("pantry.tonight")
                                if let household { HouseholdTonightLink(household: household) }
                            }
                            let purchases = model.recentPurchases
                            if !purchases.isEmpty {
                                DisclosureGroup(pantryText("Choose a recent purchase")) {
                                    ForEach(purchases) { row in
                                        Button {
                                            sheet = .purchase(row)
                                        } label: {
                                            VStack(alignment: .leading) {
                                                Text(row.reviewedFood.name)
                                                Text(pantryFormat("Received %@ on %@", pantryQuantity(row.received),
                                                    row.receivedAt.formatted(date: .abbreviated, time: .omitted)))
                                                Text(pantryFormat("Batch %@", String(row.id.uuidString.suffix(8))))
                                            }.accessibilityElement(children: .combine)
                                        }.disabled(!model.canEdit)
                                        .frame(minHeight: 44)
                                        .accessibilityIdentifier("pantry.purchase.\(row.id)")
                                    }
                                }.accessibilityIdentifier("pantry.recentPurchases")
                            }
                        }
                    } else {
                        Section { Text(pantryPhase(model.phase)) }
                    }
                    if model.phase != .accessDenied {
                        Section {
                            Button(pantryText("Refresh pantry")) { Task { await model.load() } }
                                .frame(minHeight: 44).disabled(model.busy).accessibilityIdentifier("pantry.refresh")
                        }
                    }
                    if model.busy { ProgressView(pantryText("Working…")) }
                }
            } else { Text(pantryText("Unlock the authorized private workspace to view pantry food.")) }
        }
    }
}

/// Shared canonical lot entry for My Pantry and live pickup readers. A source
/// alias never becomes a new acquisition: every action names this canonical ID.
struct PantryLotEntryView: View {
    @ObservedObject var model: PantryModel
    let lotID: UUID
    let accessAllowed: Bool
    var offersTonight = false
    var availabilityNeedsReview = false
    var household: HouseholdModel? = nil
    var recoveredHistoryAccess: (@MainActor () -> Bool)? = nil
    var returnToShelf: (() -> Void)? = nil
    @State private var sheet: PantrySheet?

    var body: some View {
        PantryLotView(model: model, lotID: lotID, accessAllowed: accessAllowed, offersTonight: offersTonight,
                      availabilityNeedsReview: availabilityNeedsReview, household: household,
                      recoveredHistoryAccess: recoveredHistoryAccess,
                      returnFromExpiredUse: returnToShelf) { sheet = .recount(lotID) }
            .safeAreaInset(edge: .bottom) {
                if accessAllowed, model.pending != nil {
                    Button(pantryText("Review pending save")) { sheet = .review }
                        .frame(minHeight: 44).buttonStyle(.borderedProminent)
                } else if let returnToShelf, !accessAllowed || model.phase == .accessDenied {
                    Button(action: returnToShelf) {
                        Text(pantryText("Return to My Pantry"))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }.accessibilityIdentifier("pantry.lot.returnToShelf")
                } else if accessAllowed, model.phase != .ready, model.phase != .accessDenied {
                    Button(pantryText("Refresh pantry")) { Task { await model.load() } }
                        .frame(minHeight: 44).disabled(model.busy)
                }
            }
            .navigationBarBackButtonHidden(model.busy || model.pending != nil)
            .interactiveDismissDisabled(model.busy || model.pending != nil)
            .modifier(PantryEntryPresentation(model: model, accessAllowed: accessAllowed, sheet: $sheet,
                                             availabilityNeedsReview: availabilityNeedsReview))
    }
}

/// Shared manual acquisition entry. Pending recovery is shown before another
/// batch can be entered; the repository retains the exact original command.
struct PantryAddFoodEntryView: View {
    @ObservedObject var model: PantryModel
    let accessAllowed: Bool
    var reviewedFood: PantryReviewedFood? = nil
    let refreshContext: () async -> Void
    @State private var sheet: PantrySheet?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if accessAllowed, model.phase == .ready, model.pending == nil, !model.requiresFreshReview {
                PantryFoodEditor(model: model, lotID: nil, accessAllowed: accessAllowed, reviewedFood: reviewedFood)
            } else {
                WorkingForm {
                    Text(accessAllowed ? pantryPhase(model.phase)
                         : pantryText("Unlock the authorized private workspace to view pantry food."))
                    if accessAllowed {
                        if let notice = model.notice { Text(pantryNotice(notice)) }
                        if model.pending != nil {
                            Button(pantryText("Review pending save")) { sheet = .review }.frame(minHeight: 44)
                        }
                        if model.phase != .accessDenied {
                            Button(pantryText("Refresh pantry")) {
                                Task {
                                    if model.pending == nil { await refreshContext() }
                                    else { await model.load() }
                                }
                            }.frame(minHeight: 44).disabled(model.busy)
                        }
                        if model.busy { ProgressView(pantryText("Working…")) }
                    }
                }
            }
        }
        .navigationTitle(pantryText("Add food"))
        .privacySensitive()
        .navigationBarBackButtonHidden(model.busy || model.pending != nil)
        .interactiveDismissDisabled(model.busy || model.pending != nil)
        .modifier(PantryEntryPresentation(model: model, accessAllowed: accessAllowed, sheet: $sheet, didSave: { dismiss() }))
    }
}

/// One lifecycle keeps add/recount/review behavior and access-loss redaction the
/// same regardless of the reader that opened a lot.
struct PantryEntryPresentation: ViewModifier {
    @ObservedObject var model: PantryModel
    let accessAllowed: Bool
    @Binding var sheet: PantrySheet?
    var holdsLoadedReview: () -> Bool = { false }
    // The list owns its add and purchase sheets. A pushed lot owns its own actions.
    var handlesReview = true
    var availabilityNeedsReview = false
    var revealSavedLot: (UUID) -> Void = { _ in }
    var didSave: () -> Void = {}
    @State private var lotToReveal: UUID?

    func body(content: Content) -> some View {
        content
        .task(id: accessAllowed) {
            if !accessAllowed { sheet = nil }
            await model.loadOnAppearance(accessAllowed: accessAllowed, holdsLoadedReview: holdsLoadedReview())
        }
        .onChange(of: accessAllowed) { _, allowed in
            if !allowed { sheet = nil; model.accessLost() }
        }
        .onChange(of: model.review?.command.id) { _, id in
            if id != nil && accessAllowed && handlesReview { sheet = .review }
        }
        .onChange(of: model.savedLotID) { _, id in
            if let id, handlesReview {
                lotToReveal = id
                sheet = nil
                didSave()
            }
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .accessDenied { sheet = nil }
        }
        .sheet(isPresented: Binding(get: { accessAllowed && model.phase != .accessDenied && sheet != nil }, set: { shown in
            if !shown {
                if case .review = sheet, model.pending == nil { model.cancelReview() }
                sheet = nil
            }
        }), onDismiss: {
            if let id = lotToReveal, accessAllowed { revealSavedLot(id) }
            lotToReveal = nil
        }) {
            NavigationStack {
                if let value = sheet {
                    switch value {
                    case .found(let location): PantryFoodEditor(model: model, lotID: nil, accessAllowed: accessAllowed, initialLocation: location)
                    case .add: PantryFoodEditor(model: model, lotID: nil, accessAllowed: accessAllowed, finishScan: finishProductScan)
                    case .recount(let id): PantryFoodEditor(model: model, lotID: id, accessAllowed: accessAllowed)
                    case .purchase(let row): PantryFoodEditor(model: model, lotID: row.id, accessAllowed: accessAllowed, purchase: row)
                    case .products:
                        if let state = model.snapshot?.state {
                            PantryProductBatchView(model: model, workspaceID: state.workspaceID, didFinishWithLot: finishProductScan)
                        }
                    case .receipt: PantryReceiptEntry(model: model, didFinishWithLot: { lotToReveal = $0 })
                    case .aliases: PantryReceiptAliasList(model: model)
                    case .prices: PantryReceiptHistory(model: model)
                    case .review: PantryReviewView(model: model, accessAllowed: accessAllowed,
                                                   availabilityNeedsReview: availabilityNeedsReview)
                    }
                }
            }
        }
    }

    private func finishProductScan(_ lotID: UUID) {
        lotToReveal = lotID
        sheet = nil
    }
}

/// The shelf index keeps the current count with its food. Full history and batch identifiers stay in detail.
private struct PantryShelfLotLabel: View {
    let lot: InventoryLot
    let availability: InventoryLotAvailability?
    let distinguishesBatches: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    name.fixedSize()
                    Spacer(minLength: 0)
                    count.fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) { name; count }
            }
            if let place = lot.namedPlace {
                Text(verbatim: pantryPlacePath(lot.location, place)).font(.caption).foregroundStyle(Theme.secondary)
            }
            if let availability, availability.issues.isEmpty, let held = availability.held, held.amount > .zero {
                Text(pantryFormat("%@ reserved · %@ available", pantryQuantity(held), pantryQuantity(availability.free)))
                    .font(.subheadline).foregroundStyle(Theme.secondary)
            } else if availability == nil || (availability?.issues.isEmpty == false && availability?.issues != [.countUnknown]) {
                Text(pantryText("Availability needs review. Unknown food is not counted as free."))
                    .font(.subheadline).foregroundStyle(Theme.warning)
            }
            if distinguishesBatches {
                Text(lot.packageBatchLabel).font(.caption).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var name: some View {
        Text(verbatim: lot.name).font(.headline).foregroundStyle(Theme.ink)
    }

    @ViewBuilder private var count: some View {
        let value = pantryCount(lot.count, estimate: lot.countWording)
        if lot.count == .someLeft || lot.count == .haveEnough {
            Label(value, systemImage: "text.quote").foregroundStyle(Theme.secondary)
        } else {
            Text(value).monospacedDigit()
                .foregroundStyle(lot.count.quantity == nil ? Theme.secondary : Theme.ink)
        }
    }
}

private func onlyNeedsRecount(_ lot: InventoryLot, _ availability: InventoryLotAvailability?) -> Bool {
    lot.countWording != nil && availability?.issues == [.countUnknown]
}

/// Identifies the physical batch when an editor or history screen has its own navigation title.
struct PantryBatchHeading: View {
    let lot: InventoryLot
    var showsBatchIdentifier = true

    var body: some View {
        let location = pantryPlacePath(lot.location, lot.namedPlace)
        let detail = showsBatchIdentifier ? location + " · " + lot.packageBatchLabel : location
        WorkingRecordHeading(lot.name, detail: detail, systemImage: "shippingbox")
    }
}

struct PantryLotSummary: View {
    let lot: InventoryLot
    let availability: InventoryLotAvailability?
    var availabilityNeedsReview = false
    var addedAsOnePackage = false
    private var canRecountForMeals: Bool { !availabilityNeedsReview && onlyNeedsRecount(lot, availability) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(lot.name).font(.subheadline.weight(.semibold))
                if addedAsOnePackage {
                    Text(pantryText("Added as 1 package")).font(.headline)
                }
                Text(addedAsOnePackage && lot.count == .unknown
                     ? pantryText("Usable amount unknown") : pantryCount(lot.count, estimate: lot.countWording))
                    .font(.title2.weight(.semibold)).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.onSelection)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.selection, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if availabilityNeedsReview || availability == nil || availability?.issues.contains(where: { $0 != .countUnknown }) == true {
                Label(pantryText("Availability needs review. Unknown food is not counted as free."), systemImage: "questionmark.circle")
                    .foregroundStyle(Theme.warning)
            }
            if canRecountForMeals || availabilityNeedsReview || availability?.held?.amount != .zero {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) { allocation }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 10) { allocation }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pantry.lotSummary")
    }

    @ViewBuilder private var allocation: some View {
        allocationFact("Reserved", value: pantryQuantity(availability?.held))
        allocationFact("Available for other meals", value: canRecountForMeals
                       ? pantryText("Recount to check") : pantryQuantity(availabilityNeedsReview ? nil : availability?.free))
    }

    private func allocationFact(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pantryText(title)).font(.subheadline).foregroundStyle(Theme.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
    }
}

private struct PantryLotView: View {
    @Environment(\.pantryDigestAccess) private var digestAccess
    @ObservedObject var model: PantryModel
    let lotID: UUID
    let accessAllowed: Bool
    var offersTonight = false
    var availabilityNeedsReview = false
    var household: HouseholdModel?
    var recoveredHistoryAccess: (@MainActor () -> Bool)?
    var returnFromExpiredUse: (() -> Void)?
    let recount: () -> Void
    @FocusState private var reservationAmountFocused: Bool
    @AccessibilityFocusState private var resultFocused: Bool
    private var lot: InventoryLot? { accessAllowed ? model.snapshot?.lots.first { $0.id == lotID } : nil }
    var body: some View {
        WorkingForm {
            if let lot {
                Section {
                    PantryLotSummary(lot: lot, availability: model.snapshot?.availability.lots.first { $0.id == lotID },
                                     availabilityNeedsReview: availabilityNeedsReview,
                                     addedAsOnePackage: model.snapshot?.singlePackageIntakes.contains(lot.id) == true)
                    if let wording = lot.countWording, lot.count == .someLeft {
                        DisclosureGroup(pantryText("Last reported estimate")) {
                            Text(verbatim: wording).font(.body.weight(.medium)).textSelection(.enabled)
                        }
                        .accessibilityIdentifier("pantry.estimateEvidence")
                    }
                    LabeledContent {
                        Text(lot.confirmedAt.formatted(date: .abbreviated, time: .shortened))
                    } label: {
                        JournalSourceLabel(kind: .pantryCount, title: pantryText("Last count update"))
                    }
                    PantryStorageReadout(value: pantryPlacePath(lot.location, lot.namedPlace))
                    if let source = lot.spreadsheetRow { PantrySpreadsheetEvidenceView(evidence: source) }
                    if let opened = lot.openedAt {
                        LabeledContent(pantryText("Opened"), value: opened.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let household, let origin = model.snapshot?.state.workspaceID {
                    Section {
                        NavigationLink(pantryText("Used some")) {
                            PantryVoiceView(model: model, household: household, origin: origin, startingLot: lot, returnFromExpiredLot: returnFromExpiredUse)
                        }
                        .disabled(!model.canEdit || lot.count.quantity?.amount == .zero)
                        .accessibilityIdentifier("pantry.voiceUsedSome")
                        if let digestAccess, digestAccess.scope.origin == origin, digestAccess.authorized() {
                            PantryUsageHistoryView(model: model, lotID: lot.id, origin: origin,
                                                  authorized: digestAccess.authorized, showsLink: true)
                        }
                    }
                } else if let recoveredHistoryAccess, recoveredHistoryAccess(), let origin = model.snapshot?.state.workspaceID {
                    PantryUsageHistoryView(model: model, lotID: lot.id, origin: origin,
                                          authorized: recoveredHistoryAccess, showsLink: true)
                }
                if let access = digestAccess, access.scope.origin == model.snapshot?.state.workspaceID, access.canPresent() {
                    PantryPackageDateSection(model: model, lot: lot, access: access, store: PantryDigestStore.shared.packageDates)
                    if lot.count.quantity?.amount != .zero {
                        PantryCheckDayLink(model: model, access: access, lot: lot)
                    }
                }
                Section {
                    Button(pantryText("Recount food"), action: recount)
                        .frame(minHeight: 44).accessibilityIdentifier("pantry.recount")
                    DisclosureGroup(pantryText("Update without a measurement")) {
                        action("Have enough", .haveEnough)
                        action("Some left", .someLeft)
                        Text(pantryText("Have enough and Some left replace the old count with an unknown amount. Reservations stay protected and may need review."))
                            .font(.subheadline)
                    }.accessibilityIdentifier("pantry.unmeasuredCount")
                } header: {
                    Text(pantryText("Check what is left"))
                } footer: {
                    Text(pantryText("Checking the amount does not record a use."))
                }.disabled(!model.canEdit)
                if let access = digestAccess, access.authorized(), access.scope.origin == lot.source.originID,
                   let doc = try? PantryDigestStore.shared.document(access.scope),
                   let seen = doc.presence?.first(where: { $0.lotID == lot.id }) {
                    LabeledContent(pantryText("Last seen on shelf"), value: seen.date.formatted(date: .abbreviated, time: .shortened))
                }
                if let source = lot.splitFromLotID {
                    LabeledContent(pantryText("Split from batch"), value: String(source.uuidString.suffix(8)))
                    if let access = digestAccess, access.authorized(), access.scope.origin == lot.source.originID,
                       let date = try? PantryDigestStore.shared.packageDates.inherited(access.scope, lot: lot, among: model.snapshot?.lots ?? []) {
                        if let chosen = date.verifiedDay { LabeledContent(date.sourceLabel, value: dinnerDay(chosen)) }
                        if let original = date.originalPrintedWording {
                            LabeledContent(pantryText("Original printed wording"), value: original)
                        }
                    }
                    Text(pantryText("Review storage guidance for the new location."))
                }
                PantryLotFoodKeeperSection(model: model, lot: lot, accessAllowed: accessAllowed)
                if offersTonight, let originID = model.snapshot?.state.workspaceID {
                    NavigationLink(tonightText("Find meals that use this batch")) {
                        TonightEntry(batch: .init(originID: originID, lotID: lot.id))
                    }.accessibilityIdentifier("pantry.batch.meals")
                }
                PantryReservationSection(model: model, lot: lot, availabilityNeedsReview: availabilityNeedsReview,
                                        amountFocus: $reservationAmountFocused)
                    .id(lot.id)
                Section {
                    action("Opened now", .opened).accessibilityIdentifier("pantry.opened")
                    ForEach(InventoryLocation.allCases.filter { $0 != lot.location }, id: \.self) { location in
                        Button(pantryFormat("Move to %@", pantryLocationName(location))) {
                            Task { await model.prepare(lotID: lotID, action: .move(location)) }
                        }.frame(minHeight: 44).accessibilityIdentifier("pantry.move." + location.rawValue)
                    }
                    PantryPortionControls(model: model, lot: lot, allowSplit: !availabilityNeedsReview)
                    action("Used up", .usedUp).disabled(lot.count.quantity?.amount == .zero)
                }.disabled(!model.canEdit)
                DisclosureGroup(pantryText("Batch details")) {
                    LabeledContent(pantryText("Batch"), value: String(lot.id.uuidString.suffix(8)))
                    LabeledContent(pantryText(lot.count.quantity == nil ? "Last count update" : "Last quantity confirmation"),
                                   value: lot.confirmedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let notice = model.notice { Text(pantryNotice(notice)).accessibilityFocused($resultFocused) }
            } else if !accessAllowed {
                Text(pantryText("Unlock the authorized private workspace to view pantry food."))
            } else if model.phase != .ready {
                Text(pantryPhase(model.phase))
                if model.busy { ProgressView(pantryText("Working…")) }
            } else { Text(pantryText("This food is unavailable. Return to My Pantry and refresh.")) }
        }
        .keyboardDoneAction(visible: reservationAmountFocused, title: pantryText("Done"), identifier: "pantry.reservationAmountDone") {
            reservationAmountFocused = false
        }
        .navigationTitle(lot?.name ?? pantryText("Pantry food"))
        .onChange(of: model.notice) { _, notice in if notice?.isSaved == true { resultFocused = true } }
        .privacySensitive()
    }
    private func action(_ title: String, _ action: PantryModel.Action) -> some View {
        Button(pantryText(title)) { Task { await model.prepare(lotID: lotID, action: action) } }
            .frame(minHeight: 44)
    }
}

private struct PantryStorageReadout: View {
    let value: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let title = pantryText("Storage location")
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline).foregroundStyle(Theme.secondary)
                Text(verbatim: value)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            LabeledContent(title, value: value)
        }
    }
}

private struct PantryFoodEditor: View {
    @ObservedObject var model: PantryModel
    let lotID: UUID?
    let accessAllowed: Bool
    var reviewedFood: PantryReviewedFood? = nil
    var purchase: PantryRecentPurchase? = nil
    var initialLocation: InventoryLocation? = nil
    var finishScan: ((UUID) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    private struct ProductScan: Identifiable { let id: UUID }
    @State private var productScan: ProductScan?
    @State private var existingFoodID: UUID?
    @State private var name = ""
    @State private var amount = ""
    @State private var unit = UnitOfMeasure.count
    @State private var location = InventoryLocation.cupboard
    private enum Field { case name, amount }
    @FocusState private var editing: Field?
    @Environment(\.dynamicTypeSize) private var typeSize
    private var lot: InventoryLot? { lotID.flatMap { id in model.snapshot?.lots.first { $0.id == id } } }
    private var foods: [InventoryLot] {
        var seen = Set<UUID>()
        return (model.snapshot?.lots ?? []).sorted { $0.id.uuidString < $1.id.uuidString }.filter { seen.insert($0.foodID).inserted }
    }
    // Return to an unfinished manual entry even when a separate scan succeeds.
    private var finishScanFromEmptyEditor: ((UUID) -> Void)? {
        guard name.isEmpty, amount.isEmpty, existingFoodID == nil, unit == .count,
              location == (initialLocation ?? .cupboard) else { return nil }
        return finishScan
    }
    private var scanProductsLabel: some View {
        Label(pantryText("Scan products"), systemImage: "barcode.viewfinder")
    }

    @ViewBuilder private var storagePicker: some View {
        let title = pantryText("Storage location")
        let picker = Picker(title, selection: $location) {
            ForEach(InventoryLocation.allCases, id: \.self) { Text(pantryLocationName($0)).tag($0) }
        }
        if typeSize.isAccessibilitySize {
            journalStackedMenu(title, value: pantryLocationName(location), id: "pantry.foodLocation") {
                picker.pickerStyle(.inline)
            }
        } else {
            picker.accessibilityIdentifier("pantry.foodLocation")
        }
    }

    var body: some View {
        WorkingForm {
            if accessAllowed && model.phase == .ready {
                if lotID == nil {
                    if reviewedFood == nil, let origin = model.snapshot?.state.workspaceID {
                        if #available(iOS 18, *) {
                            NavigationLink {
                                PantryProductBatchView(model: model, workspaceID: origin, didFinishWithLot: finishScanFromEmptyEditor)
                            } label: { scanProductsLabel }
                        } else {
                            // Present independently of the editor’s form on iOS 17.
                            Button { productScan = ProductScan(id: origin) } label: { scanProductsLabel }
                        }
                    }
                    Section {
                        if let reviewedFood {
                            LabeledContent(pantryText("Food identity"), value: reviewedFood.name)
                        } else {
                            if !foods.isEmpty {
                                Picker(pantryText("Food"), selection: $existingFoodID) {
                                    Text(pantryText("New food")).tag(nil as UUID?)
                                    ForEach(foods) { food in
                                        Text(food.name + " · " + food.foodID.uuidString.suffix(8)).tag(Optional(food.foodID))
                                    }
                                }
                            }
                            if existingFoodID == nil {
                                WorkingField(pantryText("Food name")) {
                                    TextField("", text: $name)
                                        .textFieldStyle(WorkingInputStyle())
                                        .focused($editing, equals: .name)
                                        .accessibilityIdentifier("pantry.foodName")
                                }
                                .contentShape(Rectangle())
                                .simultaneousGesture(TapGesture().onEnded { editing = .name })
                            }
                        }
                        storagePicker
                    } footer: {
                        if !foods.isEmpty && reviewedFood == nil {
                            Text(pantryText("Choose the same food to add another batch of it."))
                        }
                    }
                }
                if let purchase {
                    Section {
                        Text(purchase.reviewedFood.name).font(.headline)
                        LabeledContent(pantryText("Received quantity"), value: pantryQuantity(purchase.received))
                        storagePicker
                    }
                }
                Section {
                    WorkingField(pantryText(purchase == nil ? "Amount, if known" : "Amount remaining")) {
                        TextField("", text: $amount)
                            .textFieldStyle(WorkingInputStyle())
                            .focused($editing, equals: .amount)
                            .accessibilityIdentifier("pantry.amount")
                    }
                    // iOS 17 includes the caption in the editable row’s accessibility frame.
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { editing = .amount })
                    if purchase != nil {
                        LabeledContent(pantryText("Unit"), value: pantryUnit(unit))
                    } else {
                        Picker(pantryText("Unit"), selection: $unit) {
                            ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pantryUnit($0)).tag($0) }
                        }.accessibilityIdentifier("pantry.foodUnit")
                    }
                } footer: {
                    Text(pantryText("Leave blank if unknown. Enter 0 only for confirmed none. Count means individual units, not an assumed package size."))
                }
                if let notice = model.notice { Text(pantryNotice(notice)) }
            } else { Text(pantryText("Unlock the authorized private workspace to view pantry food.")) }
        }
        .navigationTitle(pantryText(purchase != nil ? "Review recent purchase" : lotID == nil ? "Add food" : "Recount food"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(pantryText("Cancel")) { dismiss() }.disabled(model.busy)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(pantryText("Review")) {
                    editing = nil
                    Task {
                        if let purchase { await model.prepareRecentPurchase(purchase, amount: amount, location: location) }
                        else if let lotID { await model.prepare(lotID: lotID, action: .recount(amount, unit)) }
                        else { await model.prepareNewFood(name: name, existingFoodID: existingFoodID, reviewedFood: reviewedFood, location: location, amount: amount, unit: unit) }
                    }
                }.disabled(!accessAllowed || !model.canEdit || (lotID == nil && reviewedFood == nil && existingFoodID == nil && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .accessibilityIdentifier("pantry.review")
            }
        }
        .onAppear { if let lot { amount = lot.count.quantity?.amount.description ?? ""; unit = lot.unit; location = lot.location } else if let initialLocation { location = initialLocation } }
        .sheet(item: $productScan) { scan in
            NavigationStack { PantryProductBatchView(model: model, workspaceID: scan.id, didFinishWithLot: finishScanFromEmptyEditor) }
        }
        .interactiveDismissDisabled(model.busy)
        .privacySensitive()
    }
}

private struct PantryReviewView: View {
    @ObservedObject var model: PantryModel
    let accessAllowed: Bool
    var availabilityNeedsReview = false
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false
    @State private var confirming = false
    private var saving: Bool { confirming || (model.busy && model.pending != nil) }

    var body: some View {
        WorkingForm {
            if accessAllowed && saving {
                ProgressView(pantryText("Saving your change…"))
                    .accessibilityIdentifier("pantry.saveProgress")
            } else if accessAllowed, let review = model.review {
                Section(pantryText("Proposed food record")) {
                    PantryLotSummary(lot: review.proposedLot,
                        availability: review.proposedAvailability.lots.first { $0.id == review.command.lotID },
                        availabilityNeedsReview: availabilityNeedsReview)
                    PantryStorageReadout(value: pantryLocationName(review.proposedLot.location))
                        .accessibilityIdentifier("pantry.reviewLocation")
                    if let opened = review.proposedLot.openedAt {
                        LabeledContent(pantryText("Opened"), value: opened.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let before = review.before.lots.first(where: { $0.id == review.command.lotID }) {
                        LabeledContent(pantryText("Previously recorded"), value: pantryCount(before.count))
                        LabeledContent(pantryText("Previous location"), value: pantryLocationName(before.location))
                    }
                }
                if case let .revise(edit) = review.command.change, let portion = edit.portion {
                    Section(pantryText("Batch action")) {
                        PantryPortionSummary(action: portion)
                        if let child = review.splitLot {
                            LabeledContent(pantryLocationName(child.location), value: pantryCount(child.count))
                        }
                    }
                }
                if case let .reservation(edit) = review.command.change {
                    Section(pantryText("Reservation change")) {
                        PantryReservationSummary(edit: edit, claim: review.before.reservations.first { $0.id == edit.id })
                        LabeledContent(pantryText("Previously available"), value: pantryQuantity(review.before.availability.lots.first {
                            $0.id == review.command.lotID
                        }?.free))
                    }
                }
                if !review.affectedReservations.isEmpty {
                    Section(pantryText("Affected reservations")) {
                        ForEach(review.affectedReservations) { coverage in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(review.before.reservations.first { $0.id == coverage.id }?.name ?? pantryText("Reservation")).font(.headline)
                                LabeledContent(pantryText("Reserved need"), value: pantryQuantity(coverage.requested))
                                LabeledContent(pantryText("Covered before"), value: pantryQuantity(review.before.availability.reservations.first { $0.id == coverage.id }?.backed))
                                LabeledContent(pantryText("Covered after"), value: pantryQuantity(coverage.backed))
                                LabeledContent(pantryText("Still missing"), value: pantryQuantity(coverage.shortfall))
                                if coverage.unresolved { Text(pantryText("This reservation needs review. Its promise is not released.")) }
                            }.accessibilityElement(children: .combine)
                        }
                        Toggle(pantryText("I reviewed the affected reservations."), isOn: $acknowledged)
                            .accessibilityIdentifier("pantry.acknowledgeReservations")
                    }
                }
                if let notice = model.notice {
                    Text(model.pendingWasCommitted ? pantryText("Your change is saved. Retry to finish recovery.") : pantryNotice(notice))
                        .accessibilityIdentifier("pantry.reviewStatus")
                }
            } else if accessAllowed, let pending = model.pending {
                Section(pantryText("Review pending save")) {
                    PantryPendingSummary(entry: pending)
                    Text(pantryText("A saved change is waiting for recovery. Retry it or review its saved status."))
                    if let notice = model.notice {
                        Text(model.pendingWasCommitted ? pantryText("Your change is saved. Retry to finish recovery.") : pantryNotice(notice))
                    }
                }
            } else if accessAllowed, let notice = model.notice, notice.isSaved {
                Text(pantryNotice(notice))
            } else { Text(pantryText("This review is unavailable. Return to My Pantry.")) }
            if accessAllowed && !saving {
                if model.pending != nil {
                    Section {
                        if model.requiresFreshReview {
                            Button(pantryText("Discard stale review and refresh")) {
                                Task { await model.discardStaleReview(); if model.pending == nil { dismiss() } }
                            }.frame(minHeight: 44).disabled(model.busy)
                        } else {
                            Button(pantryText("Retry exact save")) { Task { await model.retryPending() } }
                                .frame(minHeight: 44).disabled(model.busy).accessibilityIdentifier("pantry.retrySave")
                            Text(pantryText(model.pendingWasCommitted || model.pending?.acknowledgment != nil
                                ? "Your change is saved. Retry to finish recovery."
                                : "The save result is uncertain. Retry the same reviewed change before starting another."))
                        }
                    }
                }
            }

        }
        .navigationTitle(pantryText("Review food")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(pantryText("Cancel")) { model.cancelReview(); dismiss() }
                    .disabled(model.busy || model.pending != nil)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(pantryText("Confirm")) {
                    confirming = true
                    Task {
                        defer { confirming = false }
                        await model.confirmReview(acknowledgingReservations: acknowledged)
                    }
                }
                    .disabled(!accessAllowed || confirming || model.busy || model.pending != nil || model.review == nil || (!acknowledged && model.review?.affectedReservations.isEmpty == false))
                    .accessibilityIdentifier("pantry.confirm")
            }
        }
        .interactiveDismissDisabled(model.busy || model.pending != nil)
        .privacySensitive()
    }
}

/// Original intent only. No old before/after reservation preview is reconstructed
/// from today's inventory when an editor reopens after process death.
private struct PantryPendingSummary: View {
    let entry: PantryPendingStore.Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let intent = entry.consumption {
                ForEach(Array(intent.selections.enumerated()), id: \.offset) { _, selection in
                    Text(pantryFormat("Batch %@", String(selection.lotID.uuidString.suffix(8))))
                    switch selection.use {
                    case .amount(let amount): LabeledContent(pantryText("Amount used"), value: pantryQuantity(amount))
                    case .all: Text(pantryText("Used all of the selected batch"))
                    case .low(let wording): Text(pantryFormat("Remaining estimate: %@", wording))
                    case .unknown: Text(pantryText("Amount unknown"))
                    case .empty: Text(pantryText("The selected batch is empty"))
                    case .usedSome(let wording):
                        Text(pantryText("Used some"))
                        if let wording { Text(pantryFormat("Remaining estimate: %@", wording)) }
                    }
                }
            } else {
                Text(pantryFormat("Batch %@", String(entry.command.lotID.uuidString.suffix(8))))
                changeSummary
            }
            Text(entry.command.occurredAt.formatted(date: .abbreviated, time: .shortened))
        }.accessibilityElement(children: .combine)
    }

    @ViewBuilder private var changeSummary: some View {
        switch entry.command.change {
        case .create(let seed, _):
            Text(pantryText("Add food")).font(.headline)
            Text(seed.name)
            Text(pantryCount(seed.count))
            Text(pantryLocationName(seed.location))
        case .count(let count, _):
            Text(pantryText("Recount food")).font(.headline)
            Text(pantryCount(count))
        case .opened(let date):
            LabeledContent(pantryText("Opened"), value: date.formatted(date: .abbreviated, time: .shortened))
        case .move(let location): Text(pantryFormat("Move to %@", pantryLocationName(location)))
        case .usedUp: Text(pantryText("Used up"))
        case .revise(let edit):
            if let action = edit.portion { PantryPortionSummary(action: action) }
            else { Text(pantryText("Review pantry change")) }
        case .reservation(let edit): PantryReservationSummary(edit: edit, claim: nil)
        }
    }
}
