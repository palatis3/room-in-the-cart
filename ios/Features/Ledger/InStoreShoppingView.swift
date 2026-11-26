import SwiftUI
import CoreDomain

func shoppingText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "ShoppingLists")
}

func shoppingFormat(_ key: String, _ values: CVarArg...) -> String {
    String(format: shoppingText(key), locale: Locale.current, arguments: values)
}

func pickedSubtotalText(_ subtotal: PickedCartSubtotal) -> String {
    if subtotal.picked == 0 { return shoppingFormat("%@ · No items picked", moneyText(subtotal.total)) }
    if subtotal.priced == 0 { return shelfText("Picked subtotal unknown") }
    if subtotal.picked == 1 { return shoppingFormat("%@ for 1 picked item", moneyText(subtotal.total)) }
    return shoppingFormat("%@ for %lld of %lld picked items", moneyText(subtotal.total),
                          Int64(subtotal.priced), Int64(subtotal.picked))
}

func pickedPriceLabels(_ price: PickedLinePrice) -> [String] {
    var parts = [price.total.map { shoppingFormat("Saved price · %@", moneyText($0)) } ?? shoppingText("Price unknown")]
    if let discount = price.discount {
        parts.append(shelfFormat("Line discount · %@", moneyText(discount)))
        if let net = price.includedTotal { parts.append(shelfFormat("Picked line total · %@", moneyText(net))) }
    }
    if price.membership { parts.append(shoppingText("Member price")) }
    if price.weighted { parts.append(shoppingText("Sold by weight")) }
    if price.includedTotal == nil { parts.append(shoppingText("Excluded from subtotal")) }
    return parts
}

private struct ShoppingListAuthorizationKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Bool = { false }
}

extension EnvironmentValues {
    var shoppingListAuthorization: @MainActor () -> Bool {
        get { self[ShoppingListAuthorizationKey.self] }
        set { self[ShoppingListAuthorizationKey.self] = newValue }
    }
}

struct PrivateShoppingSheet<Content: View>: View {
    @ObservedObject var model: LedgerModel
    @ViewBuilder let content: () -> Content
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.guardianChildCoordinator) private var child
    @Environment(\.pantryVoicePrompt) private var pantryPrompt
    @State private var identity: CapturePrivateIdentity?
    @State private var workspaceID: UUID?

    var body: some View {
        let active = authorized()
        let retained = scenePhase != .background && pantryPrompt?.holdsPresentation() == true && currentOwner()
        Group {
            if active || retained {
                NavigationStack { content() }
                    .opacity(active ? 1 : 0).allowsHitTesting(active).accessibilityHidden(!active)
                    .environment(\.shoppingListAuthorization, authorized)
            } else { Text(captureText("Unlock your private workspace to review this source.")) }
        }.onAppear {
            if workspaceID == nil {
                workspaceID = model.sourceWorkspaceID
                identity = CapturePrivateIdentity.current(access: access, household: household)
            }
        }
    }

    private func authorized() -> Bool {
        scenePhase == .active && UIApplication.shared.applicationState == .active && currentOwner()
    }

    private func currentOwner() -> Bool {
        UIApplication.shared.isProtectedDataAvailable && model.ready && !model.hasPendingLedgerDeletion && workspaceID != nil && workspaceID == model.sourceWorkspaceID &&
            identity != nil && identity == CapturePrivateIdentity.current(access: access, household: household) &&
            household.projection?.grantId == nil && child?.presented != true
    }
}

/// Feedback belongs to the confirmed item. Its dated schedule ends after 120 ms
/// and cannot replay when the row is reused or the app returns to the foreground.
struct GroceryCheckCue {
    let lineID: UUID
    let began = Date()
}

struct GroceryCheckInset: View {
    let cue: GroceryCheckCue?
    let lineID: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scene
    var body: some View {
        if let cue, cue.lineID == lineID, !reduceMotion, scene == .active, Date().timeIntervalSince(cue.began) < 0.12 {
            let frames = (0...8).map { cue.began.addingTimeInterval(Double($0) * 0.015) }
            TimelineView(.explicit(frames)) { frame in
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.action, lineWidth: 2)
                    .opacity(max(0, min(1, 1 - frame.date.timeIntervalSince(cue.began) / 0.12)))
            }
            .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

private enum InStoreFocus: Hashable { case line(UUID), picked(UUID), subtotal }

struct InStoreShoppingView: View {
    private var dinnerPantry = ShoppingDinnerPantry()
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    let openSelectedList: (UUID) -> Void
    @Environment(\.shoppingListAuthorization) private var authorize
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var cue: GroceryCheckCue?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scene
    @EnvironmentObject private var photoAccess: WorkspaceAccess
    @EnvironmentObject private var photoHousehold: HouseholdModel
    @State private var packagePhotos: [UUID: PackageRowPhoto] = [:]
    @State private var loadedPhotoScope: PhotoScope?
    @State private var photoRefresh = UUID()
    private struct PhotoScope: Equatable {
        let owner: PackageRowPhoto.Owner
        let workspace: UUID
        let shop: UUID
        let generation: UUID
    }
    private struct PhotoRequest: Equatable {
        let scope: PhotoScope?
        let refresh: UUID
    }
    private var photoScope: PhotoScope? {
        guard scene == .active, authorize(), model.shop?.id == shopID, let workspace = model.sourceWorkspaceID,
              let identity = CapturePrivateIdentity.current(access: photoAccess, household: photoHousehold) else { return nil }
        return PhotoScope(owner: .init(identity), workspace: workspace, shop: shopID, generation: photoAccess.generation)
    }

    private struct PlaceSession: Equatable {
        let scope: InStorePlaceScope
        let accessGeneration, householdGeneration: UUID
    }
    private struct PlaceLoad: Equatable {
        let session: PlaceSession?
        let revision: UUID?
        let refresh: UUID
        let photoRequest: PhotoRequest
        let photoReady: Bool
    }
    @State private var placeSlot: InStorePlaceSlot?
    @State private var loadedPlaceSession: PlaceSession?
    @State private var placeRefresh = UUID()
    @State private var placeWrite: UUID?
    @State private var placeFailed = false
    @State private var unavailablePlace = false

    private var placeSession: PlaceSession? {
        guard let photoScope, let shop = model.shop, shop.id == shopID,
              let identity = CapturePrivateIdentity.current(access: photoAccess, household: photoHousehold) else { return nil }
        guard identity.subject == nil || photoHousehold.shoppingPlaceDeviceID != nil else { return nil }
        return PlaceSession(scope: InStorePlaceScope(identity: identity, workspace: photoScope.workspace, shop: shop,
                                                    enrollment: identity.subject == nil ? nil : photoHousehold.shoppingPlaceDeviceID),
                            accessGeneration: photoAccess.generation, householdGeneration: photoHousehold.generation)
    }

    private var placeLoad: PlaceLoad {
        PlaceLoad(session: placeSession, revision: model.shop?.revisionID, refresh: placeRefresh,
                  photoRequest: PhotoRequest(scope: photoScope, refresh: photoRefresh),
                  photoReady: loadedPhotoScope != nil && loadedPhotoScope == photoScope)
    }

    @State private var displayOwner = UUID()
    @State private var editingPrice: ShoppingLine?
    private typealias Focus = InStoreFocus
    private enum Destination: Hashable, Identifiable {
        case details(UUID), savedDetails(UUID, UUID), options, find, nextStore
        var id: Self { self }
    }
    @State private var destination: Destination?
    @State private var choosingList = false
    private struct UndoReview {
        let line: ShoppingLine
        let revision: UUID
    }
    @State private var undoReview: UndoReview?
    @State private var searching = false
    @State private var query = ""
    @State private var searchReturnTargets: [Focus] = []
    @State private var viewportAnchor: Focus?
    @FocusState private var editingSearch: Bool
    @SceneStorage("inStoreScrollRow") private var previousSavedRow = ""
    @SceneStorage private var savedRow: String
    @State private var trackingAisle = false
    @State private var completedDetailRow: UUID?
    @State private var scrollToReturn = false
    @AccessibilityFocusState private var focus: Focus?
    @State private var pendingFocus: Focus?

    init(model: LedgerModel, shopID: UUID, openSelectedList: @escaping (UUID) -> Void) {
        self.model = model
        self.shopID = shopID
        self.openSelectedList = openSelectedList
        _savedRow = SceneStorage(wrappedValue: "", "inStoreScrollRow-\(shopID)")
    }

    var body: some View {
        currentShopContent
            .navigationTitle(typeSize.isAccessibilitySize ? shoppingText("In store") : shoppingText("Shop in store"))
            .navigationBarTitleDisplayMode(typeSize.isAccessibilitySize ? .inline : .automatic)
            .toolbar {
                if model.shop?.id == shopID && authorize() {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        if searching {
                            Button(ledgerText("Cancel"), action: endSearch)
                                .accessibilityIdentifier("inStoreEndSearch")
                        } else {
                            Button { destination = .options } label: {
                                Label(ledgerText("List options"), systemImage: "ellipsis.circle")
                            }
                            .accessibilityIdentifier("inStoreTripOptions")
                            Button { destination = .find } label: {
                                Label(tripText("Add a find"), systemImage: "plus")
                            }
                            .accessibilityIdentifier("tripAddFind")
                            Button(action: beginSearch) {
                                Label(shelfText("Search this stop"), systemImage: "magnifyingglass")
                            }
                            .accessibilityIdentifier("inStoreSearch")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    TripFinishButton(model: model, shopID: shopID, inspect: { destination = .details($0) }, finish: { dismiss() })
                }
            }
            .task(id: PhotoRequest(scope: photoScope, refresh: photoRefresh)) {
                let scope = photoScope
                packagePhotos = [:]; loadedPhotoScope = nil
                guard let scope else { return }
                let target = CaptureTarget(workspaceID: scope.workspace, containerID: scope.shop, objectID: scope.shop,
                                           revision: 0, kind: .packageReference)
                guard let photos = try? await CaptureMediaStore.shared.packagePhotos(target: target, owner: scope.owner,
                    authorize: { photoScope == scope }), !Task.isCancelled, photoScope == scope else { return }
                packagePhotos = Dictionary(photos.map { ($0.target.objectID, $0) }, uniquingKeysWith: { first, _ in first })
                loadedPhotoScope = scope
            }
            .onReceive(NotificationCenter.default.publisher(for: PackageRowPhoto.changed)) { _ in
                packagePhotos = [:]; loadedPhotoScope = nil; photoRefresh = UUID()
            }
            .alert(savedPlaceText("This saved place is no longer available."), isPresented: $unavailablePlace) {
                Button(ledgerText("Done"), role: .cancel) {}
            }
            .task(id: placeLoad) { await loadPlace(placeLoad) }
            .task(id: placeSlot?.revision) {
                guard let place = placeSlot?.place else { return }
                let remaining = place.saved.addingTimeInterval(InStoreSavedPlace.lifetime).timeIntervalSinceNow
                if remaining > 0 {
                    do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                }
                placeRefresh = UUID()
            }
            .onReceive(NotificationCenter.default.publisher(for: CaptureMediaStore.savedPlaceChanged)) { notice in
                if notice.object as? UUID == model.sourceWorkspaceID { placeRefresh = UUID() }
            }
            .modifier(InStoreDisplayPreference(trip: shopID, owner: displayOwner, available: model.shop?.id == shopID && authorize()))
    }

    private var currentShopContent: some View {
        Group {
            if let shop = model.shop, shop.id == shopID {
                VStack(spacing: 0) {
                    ZStack {
                        // Keep the aisle list mounted while filtering so clearing search restores the actual viewport.
                        shoppingList(in: shop, filtering: false)
                            .ignoresSafeArea(.keyboard, edges: .bottom)
                            .opacity(searching ? 0 : 1).allowsHitTesting(!searching).accessibilityHidden(searching)
                        if searching { shoppingList(in: shop, filtering: true) }
                    }
                    if typeSize.isAccessibilitySize, !editingSearch, let last = shop.inStorePickedLines.first, last.canUndoInStore {
                        reachableUndo(last, in: shop)
                    }
                }
                    .sheet(item: $editingPrice) { line in
                        NavigationStack { InStorePriceEditor(model: model, shop: shop, line: line) }
                    }
                    .sheet(item: $destination, onDismiss: {
                        if let completedDetailRow {
                            returnToRow(completedDetailRow)
                            self.completedDetailRow = nil
                        }
                    }) { value in
                        NavigationStack {
                            destinationContent(value, in: shop)
                        }
                    }
            }
        }
    }

    private func shoppingList(in shop: ShoppingLedger, filtering: Bool) -> some View {
        let dinner = dinnerPantry.status(in: shop, ledger: model)
        let groups = model.workspace.listLayout.groups(shop: shop, excluding: dinner.covered)
        let matches = filtering ? searchMatches(in: shop) : nil
        func included(_ line: ShoppingLine) -> Bool {
            guard filtering else { return true }
            return line.eligibleForStop(named: shop.currentStop.name) && (matches == nil || matches?[line.id] != nil)
        }
        let matched = groups.flatMap(\.lines).filter(included)
        let visible = matched.filter { available($0, shop: shop) }
        let outstanding = matched.filter { shop.outcomeAtCurrentStop($0) != nil }
        let basket = shop.inStorePickedLines
        let picked = basket.filter(included)
        let exclusions = shop.listExclusions
        let packages = shop.itemPackages
        return ScrollViewReader { reader in
            JournalList {
                if model.error != nil || model.hasPendingSave { LedgerSaveStatus(model: model) }
                if !filtering {
                    DinnerPantryReviewSection(shopID: shop.id, reviews: dinner.pending)
                    listAndStop(shop)
                    savedPlaceEntry(in: shop)
                    TripDepartureSection(model: model, shop: shop)
                }
                ForEach(groups) { group in
                    let rows = group.lines.filter { available($0, shop: shop) && (matches == nil || matches?[$0.id] != nil) }
                    if !rows.isEmpty {
                        Section(group.aisle.isEmpty ? shoppingText("To pick") : group.aisle) {
                            ForEach(rows) { line in
                                outstandingRow(line, shop: shop, visible: visible, exclusions: exclusions[line.id],
                                               packages: packages[line.id] ?? [], hit: matches?[line.id])
                            }
                        }
                    }
                }
                if matches != nil && visible.isEmpty && outstanding.isEmpty && picked.isEmpty {
                    Text(shelfText("No matching groceries at this stop."))
                } else if matches == nil && visible.isEmpty {
                    Text(groups.allSatisfy { $0.lines.isEmpty } ? shoppingText("No items left to pick.") : tripText("Nothing else to pick at this stop."))
                }
                if !outstanding.isEmpty {
                    Section(tripText("Still needed")) {
                        ForEach(outstanding) { line in
                            stillNeededRow(line, in: shop, filtering: filtering, packages: packages[line.id] ?? [], hit: matches?[line.id])
                        }
                    }
                }
                if !picked.isEmpty {
                    Section(filtering ? shelfText("In your basket") : shoppingText("Picked items")) {
                        ForEach(picked) { line in
                            pickedRow(line, in: shop, filtering: filtering, packages: packages[line.id] ?? [], hit: matches?[line.id])
                        }
                    }
                }
                if !filtering {
                    Section {
                        Button { destination = .nextStore } label: { Label(tripText("Next store"), systemImage: "storefront") }
                            .accessibilityIdentifier("tripNextStore")
                    }.frame(minHeight: 44)
                    if typeSize.isAccessibilitySize {
                        Section { subtotalSummary(shop, last: basket.first).id(Focus.subtotal) }
                    }
                }
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .top, spacing: 0) { if filtering { searchField } }
            .coordinateSpace(name: "shoppingAisles")
            .onAppear {
                if !filtering, let id = restoredRow(), id != visible.first?.id {
                    if visible.contains(where: { $0.id == id }) || outstanding.contains(where: { $0.id == id }) {
                        reader.scrollTo(Focus.line(id), anchor: .top)
                    } else if basket.contains(where: { $0.id == id }) {
                        reader.scrollTo(Focus.picked(id), anchor: .top)
                    }
                }
                Task { @MainActor in await Task.yield(); trackingAisle = true }
            }
            .onPreferenceChange(TripVisibleRows.self) { rows in
                guard trackingAisle, !searching, scene == .active, authorize(),
                      let top = rows.filter({ $0.value.maxY > 0 }).min(by: { $0.value.minY < $1.value.minY })
                else { return }
                viewportAnchor = top.key
                switch top.key {
                case .line(let id), .picked(let id): remember(id)
                case .subtotal: break
                }
            }
            .disabled(model.saving)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !typeSize.isAccessibilitySize && (!filtering || !editingSearch) {
                    subtotalSummary(shop, last: basket.first)
                        .padding(.horizontal).padding(.vertical, 6).background(Theme.surface)
                        .overlay(alignment: .top) { Divider() }
                }
            }
            .onChange(of: pendingFocus) { _, target in
                guard let target, filtering == searching else { return }
                if UIAccessibility.isVoiceOverRunning || scrollToReturn {
                    switch target {
                    case .line, .picked:
                        // At large type the pinned aisle heading can cover a checkbox that List considers visible.
                        let centerRow = UIAccessibility.isVoiceOverRunning || (typeSize.isAccessibilitySize && scrollToReturn)
                        let anchor: UnitPoint? = centerRow ? .center : nil
                        reader.scrollTo(target, anchor: anchor)
                    case .subtotal:
                        if typeSize.isAccessibilitySize { reader.scrollTo(Focus.subtotal, anchor: .top) }
                    }
                }
                Task { @MainActor in
                    await Task.yield()
                    guard pendingFocus == target else { return }
                    focus = target
                    scrollToReturn = false
                    pendingFocus = nil
                }
            }
        }
    }

    private func currentPhoto(for id: UUID) -> PackageRowPhoto? {
        guard loadedPhotoScope != nil, loadedPhotoScope == photoScope, let photo = packagePhotos[id],
              photo.matchesCurrentGroceries(in: model.workspace) else { return nil }
        return photo
    }

    private func searchMatches(in shop: ShoppingLedger) -> [UUID: CurrentStopSearchHit]? {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard searching, !term.isEmpty else { return nil }
        let lines = shop.searchResults(term, department: { model.workspace.listLayout.department(for: $0, in: shop) })
        var matches = Dictionary(uniqueKeysWithValues: lines.map { ($0.line.id, CurrentStopSearchHit(fields: $0.evidence)) })
        for (id, photo) in packagePhotos where photo.cue.localizedStandardContains(term) {
            if currentPhoto(for: id) != nil {
                matches[id, default: CurrentStopSearchHit()].photoCue = true
            }
        }
        return matches
    }

    @ViewBuilder private var searchField: some View {
        if searching {
            HStack {
                TextField(shelfText("Search this stop"), text: $query)
                    .textFieldStyle(.roundedBorder).focused($editingSearch).submitLabel(.search)
                    .onSubmit { editingSearch = false }
                    .accessibilityIdentifier("inStoreSearchQuery")
                    .onAppear { editingSearch = true }
                    .onChange(of: query) { previous, current in
                        if !previous.isEmpty && current.isEmpty && searching { endSearch() }
                    }
                if !query.isEmpty {
                    Button(action: endSearch) {
                        Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(shelfText("Clear search and return to aisle"))
                    .accessibilityIdentifier("inStoreClearSearch")
                }
            }
            .padding(.horizontal).padding(.vertical, 4).background(.bar)
        }
    }

    private func aisleFocusOrder(in shop: ShoppingLedger) -> [Focus] {
        let covered = dinnerPantry.status(in: shop, ledger: model).covered
        let rows = model.workspace.listLayout.groups(shop: shop, excluding: covered).flatMap(\.lines)
        return rows.filter { available($0, shop: shop) }.map { .line($0.id) } +
            rows.filter { shop.outcomeAtCurrentStop($0) != nil }.map { .line($0.id) } +
            shop.inStorePickedLines.map { .picked($0.id) } + [.subtotal]
    }

    private func beginSearch() {
        guard let shop = model.shop, shop.id == shopID else { return }
        let order = aisleFocusOrder(in: shop)
        let anchor = (UIAccessibility.isVoiceOverRunning ? focus : nil) ?? viewportAnchor
        if UIAccessibility.isVoiceOverRunning, let anchor, let index = order.firstIndex(of: anchor) {
            // If the anchor itself is picked or removed during search, restore its closest surviving neighbor.
            let following = order[index...].filter { $0 != .subtotal }
            let preceding = order.prefix(index).reversed()
            searchReturnTargets = anchor == .subtotal ? [.subtotal] : following + preceding + [.subtotal]
        } else { searchReturnTargets = [] }
        searching = true
    }

    private func endSearch() {
        editingSearch = false
        searching = false
        query = ""
        if let shop = model.shop, shop.id == shopID {
            let remaining = Set(aisleFocusOrder(in: shop))
            if let target = searchReturnTargets.first(where: remaining.contains) {
                scrollToReturn = true
                pendingFocus = target
            }
        }
        searchReturnTargets = []
    }

    @ViewBuilder private func destinationContent(_ value: Destination, in shop: ShoppingLedger) -> some View {
        switch value {
        case let .details(id):
            itemDetails(id)
        case let .savedDetails(id, revision):
            if let slot = placeSlot, slot.revision == revision, let place = slot.place, place.line == id,
               resolvedPlace(place) != nil {
                itemDetails(id)
            } else {
                Text(savedPlaceText("This saved place is no longer available."))
                    .toolbar { closeSheet }
            }
        case .find:
            TripFindEntry(model: model, shop: shop, onSaved: { completedDetailRow = $0 }).toolbar { closeSheet }
        case .nextStore:
            TripNextStoreEntry(model: model, shopID: shopID).toolbar { closeSheet }
        case .options:
            List {
                NavigationLink(ledgerText("List order and aisles")) {
                    LedgerLayoutEditor(model: model, shop: shop)
                }
                NavigationLink(tripText("Preview list copy")) { TripHandoffEntry(model: model, shopID: shopID) }
                    .accessibilityIdentifier("tripShare.previewCopy")
                FamilyPermissionGuideLink(title: GuardianCopy.text("Child permissions")) { destination = nil }
                NavigationLink(pantryText("Buy this pack again")) { ShopPackLookupEntry(ledger: model, shopID: shopID) }
                PantryShelfPhotoLink()
                InStoreDisplayToggle(owner: displayOwner)
            }.workingSurface().navigationTitle(ledgerText("List options")).toolbar { closeSheet }
        }
    }

    private func itemDetails(_ id: UUID) -> some View {
        TripItemDetail(model: model, shopID: shopID, lineID: id, onSaved: { completedDetailRow = $0 },
                       placeActions: placeActions(for: id)) { shop, line in
            if authorize() {
                let hit = searching ? searchMatches(in: shop)?[line.id] : nil
                searchDetails(line, in: shop, hit: hit, showAisle: searching, fullText: true)
            }
        }
        .toolbar { closeSheet }
    }

    private func reviewedPlace(_ id: UUID, in session: PlaceSession) -> InStoreSavedPlace? {
        guard placeSession == session, loadedPhotoScope != nil, loadedPhotoScope == photoScope,
              let shop = model.shop, !dinnerPantry.status(in: shop, ledger: model).covered.contains(id) else { return nil }
        return InStoreSavedPlace.make(scope: session.scope, lineID: id, workspace: model.workspace, photo: currentPhoto(for: id))
    }

    private func resolvedPlace(_ place: InStoreSavedPlace) -> ShoppingLine? {
        guard let session = placeSession, loadedPlaceSession == session, place.isLive(at: .now),
              place.matches(reviewedPlace(place.line, in: session)) else { return nil }
        return model.shop?.lines.first { $0.id == place.line }
    }

    @ViewBuilder private func savedPlaceEntry(in shop: ShoppingLedger) -> some View {
        if let slot = placeSlot, let place = slot.place, let line = resolvedPlace(place), let session = placeSession {
            Button {
                Task { @MainActor in
                    do {
                        guard let owner = photoScope?.owner else { return }
                        let current = try await CaptureMediaStore.shared.savedPlace(in: session.scope, photoOwner: owner,
                            authorize: { placeSession == session && resolvedPlace(place) != nil })
                        guard current?.revision == slot.revision, resolvedPlace(place) != nil,
                              destination == nil, !searching else {
                            if placeSession == session { unavailablePlace = true }
                            placeRefresh = UUID()
                            return
                        }
                        completedDetailRow = line.id
                        destination = .savedDetails(line.id, slot.revision)
                    } catch {
                        if placeSession == session { unavailablePlace = true }
                        placeRefresh = UUID()
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Label(String(format: savedPlaceText("Return to %@"), locale: .current, line.name), systemImage: "bookmark")
                    let measure = TripMeasure(shop, line: line, packages: shop.itemPackages[line.id] ?? [])
                    if let amount = shop.tripAmountLabel(line, measure: measure) { Text(verbatim: amount).font(.subheadline) }
                    if let pack = measure?.packNote { Text(verbatim: pack).font(.subheadline) }
                    if !line.notes.isEmpty { Text(verbatim: line.notes).font(.subheadline) }
                    if let cue = currentPhoto(for: line.id)?.cue, !cue.isEmpty { Text(verbatim: cue).font(.subheadline) }
                    if let outcome = shop.outcomeAtCurrentStop(line) {
                        Text(tripText(outcome == .unavailable ? "Couldn’t find it at this stop" : "Left for next time"))
                    }
                }.frame(minHeight: 44).fixedSize(horizontal: false, vertical: true)
            }.accessibilityIdentifier("inStorePlace.return")
        }
    }

    private func placeActions(for id: UUID) -> InStorePlaceActions? {
        guard let session = placeSession, loadedPlaceSession == session,
              let candidate = reviewedPlace(id, in: session) else { return nil }
        let slot = placeSlot
        let marked = slot?.place?.line == id && slot?.place?.matches(candidate) == true
        return InStorePlaceActions(marked: marked, replacing: !marked && slot?.place != nil,
                                   busy: placeWrite != nil || model.saving || model.hasPendingSave, failed: placeFailed,
                                   save: { changePlace(to: candidate.atSaveTime(), expected: slot?.revision, in: session) },
                                   clear: { changePlace(to: nil, expected: slot?.revision, in: session) })
    }

    @MainActor private func changePlace(to value: InStoreSavedPlace?, expected: UUID?, in session: PlaceSession) {
        guard placeWrite == nil, loadedPlaceSession == session, placeSession == session, placeSlot?.revision == expected,
              !model.saving, !model.hasPendingSave else { return }
        let operation = UUID()
        placeWrite = operation
        placeFailed = false
        Task { @MainActor in
            defer { if placeWrite == operation { placeWrite = nil } }
            do {
                try await CaptureMediaStore.shared.updateSavedPlace(in: session.scope, expected: expected, place: value) {
                    guard placeSession == session, !model.saving, !model.hasPendingSave else { return false }
                    guard let value else { return true }
                    return value.matches(reviewedPlace(value.line, in: session))
                }
                if value == nil, case .savedDetails = destination { destination = nil }
            } catch { if placeSession == session { placeFailed = true } }
            placeRefresh = UUID()
        }
    }

    @MainActor private func loadPlace(_ request: PlaceLoad) async {
        if loadedPlaceSession != request.session { placeSlot = nil; loadedPlaceSession = nil; placeFailed = false }
        guard let session = request.session, request.photoReady else { return }
        do {
            let slot = try await CaptureMediaStore.shared.savedPlace(in: session.scope, authorize: { placeSession == session })
            guard !Task.isCancelled, placeLoad == request else { return }
            if let slot, let place = slot.place,
               !place.isLive(at: .now) || !place.matches(reviewedPlace(place.line, in: session)) {
                placeSlot = nil
                try await CaptureMediaStore.shared.updateSavedPlace(in: session.scope, expected: slot.revision, place: nil,
                                                                  authorize: { placeLoad == request })
                return
            }
            placeSlot = slot
            loadedPlaceSession = session
        } catch {
            if !Task.isCancelled && placeLoad == request { loadedPlaceSession = nil; placeSlot = nil }
        }
    }

    @ViewBuilder private func listAndStop(_ shop: ShoppingLedger) -> some View {
        let others = model.workspace.shops.filter { $0.id != shop.id }
        if !others.isEmpty {
            Section {
                Button { choosingList = true } label: {
                    HStack {
                        Text(tripFormat("Shopping list · %@", shop.title)).font(.headline)
                        Image(systemName: "chevron.down").imageScale(.small).accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityHint(tripText("Open another shopping list"))
                .accessibilityIdentifier("inStoreListPicker")
                .disabled(model.saving || model.hasPendingSave)
                .confirmationDialog(tripText("Open another shopping list"), isPresented: $choosingList, titleVisibility: .visible) {
                    ForEach(others, id: \.id) { item in
                        Button(item.title) {
                            Task {
                                await model.selectShop(item.id, authorize: {
                                    authorize() && model.shop?.id == shopID &&
                                        model.workspace.shops.contains { $0.id == item.id }
                                }, onSelected: { id in
                                    if authorize() { openSelectedList(id) }
                                })
                            }
                        }
                    }
                    Button(ledgerText("Cancel"), role: .cancel) {}
                }
                if !shop.currentStop.name.isEmpty, shop.currentStop.name != shop.title {
                    Label(shop.currentStop.name, systemImage: "storefront").font(.headline)
                }
            }
        } else if !shop.currentStop.name.isEmpty {
            Section { Label(shop.currentStop.name, systemImage: "storefront").font(.headline) }
        }
    }

    private var closeSheet: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(ledgerText("Done")) { destination = nil }
        }
    }

    private func available(_ line: ShoppingLine, shop: ShoppingLedger) -> Bool {
        shop.outcomeAtCurrentStop(line) == nil && line.eligibleForStop(named: shop.currentStop.name)
    }

    private func stillNeededRow(_ line: ShoppingLine, in shop: ShoppingLedger, filtering: Bool, packages: [BasketPackage], hit: CurrentStopSearchHit?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { destination = .details(line.id) } label: {
                VStack(alignment: .leading) {
                    nameSource(hit)
                    Text(line.name).font(.headline)
                    if filtering { searchDetails(line, in: shop, hit: hit) }
                    let measure = TripMeasure(shop, line: line, packages: packages)
                    if let quantity = shop.tripAmountLabel(line, measure: measure) { Text(quantity) }
                    Text(tripText(shop.isLeftForNextTrip(line) ? "Left for next time" : "Couldn’t find it at this stop"))
                        .foregroundStyle(Theme.secondary)
                }.frame(minHeight: 44)
            }.accessibilityFocused($focus, equals: .line(line.id))
            if line.tripUndo != nil {
                Button(tripFormat("Undo for %@", line.name)) { undo(line, in: shop) }.frame(minHeight: 44)
            }
        }.buttonStyle(.borderless).id(Focus.line(line.id))
            .background(TripRowPosition(row: .line(line.id)))
    }

    private func outstandingRow(_ line: ShoppingLine, shop: ShoppingLedger, visible: [ShoppingLine], exclusions: String?,
                                packages: [BasketPackage], hit: CurrentStopSearchHit?) -> some View {
        let measure = TripMeasure(shop, line: line, packages: packages)
        let amount = shop.tripAmountLabel(line, measure: measure)
        let department = model.workspace.listLayout.department(for: line, in: shop)
        let showDepartment = !department.isEmpty && model.workspace.listLayout.layout(for: shop).mode != .aisle
        let photo = currentPhoto(for: line.id)
        let noteCaption: CurrentStopSourceCaption = hit?.contains(.lineNote) == true ? .matchedNote : .note
        return HStack(alignment: .top, spacing: 8) {
            Button {
                let index = visible.firstIndex(where: { $0.id == line.id }) ?? 0
                let others = visible.filter { $0.id != line.id }
                let next = others.isEmpty ? nil : others[min(index, others.count - 1)].id
                changePick(line, in: shop, checked: true, next: next)
            } label: {
                Image(systemName: "square").font(.title3).foregroundStyle(Theme.controlEdge)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(ledgerFormat("Check %@", line.name))
            .accessibilityValue(rowSourceValue(line, department: showDepartment ? department : "",
                                               amount: amount, exclusions: exclusions, photo: photo, hit: hit))
            .accessibilityFocused($focus, equals: .line(line.id))
            .accessibilityIdentifier("inStoreCheck-\(line.id)")
            Button { destination = .details(line.id) } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        nameSource(hit)
                        GroceryNameAndAmount(name: line.name, amount: shop.groceryRowAmount(line, measure: measure))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel([line.name, amount].compactMap { $0 }.joined(separator: ", "))
                        if hit?.contains(.department) == true {
                            CurrentStopSourceText(caption: .department, literal: department)
                        } else if showDepartment {
                            Text(verbatim: department).font(.subheadline).foregroundStyle(Theme.secondary)
                        }
                        if let coupon = line.pinnedCoupon { InStoreCouponPickLabel(coupon: coupon, line: line) }
                        if !line.notes.isEmpty {
                            CurrentStopSourceText(caption: noteCaption, literal: line.notes)
                        }
                        originalSources(hit)
                        if let exclusions { Text(exclusions) }
                        TripRequestSummary(shop: shop, line: line)
                        if let photo {
                            Text(verbatim: CurrentStopSourceCaption.photoCue(for: photo, matched: hit?.photoCue == true).title).font(.caption).foregroundStyle(Theme.secondary)
                            PackagePhotoRowLabel(photo: photo)
                        }
                    }.foregroundStyle(Theme.ink)
                    Spacer(minLength: 4)
                    Image(systemName: "info.circle").accessibilityHidden(true)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.accessibilityHint(tripText("Shows dinner, pick part and store options."))
                .accessibilityIdentifier("tripDetails-\(line.id)")
        }.buttonStyle(.borderless).disabled(model.hasPendingSave)
        .background(TripRowPosition(row: .line(line.id)))
        .id(Focus.line(line.id))
    }

    private func remember(_ id: UUID) {
        guard let workspace = model.sourceWorkspaceID else { return }
        let scoped = [workspace, shopID, id].map(\.uuidString).joined(separator: "/")
        if savedRow != scoped { savedRow = scoped }
    }

    private func restoredRow() -> UUID? {
        let parts = (savedRow.isEmpty ? previousSavedRow : savedRow).split(separator: "/").map(String.init)
        guard authorize(), parts.count == 3, parts[0] == model.sourceWorkspaceID?.uuidString,
              parts[1] == shopID.uuidString else { return nil }
        return UUID(uuidString: parts[2])
    }

    private func returnToRow(_ id: UUID) {
        guard let shop = model.shop else { return }
        scrollToReturn = true
        guard let line = shop.lines.first(where: { $0.id == id && !$0.isTrashed && !$0.isHandled }),
              line.isChecked || shop.outcomeAtCurrentStop(line) != nil || available(line, shop: shop) else {
            let next = model.workspace.listLayout.groups(shop: shop).flatMap(\.lines).first { available($0, shop: shop) }
            pendingFocus = next.map { .line($0.id) } ?? .subtotal
            return
        }
        remember(id)
        pendingFocus = line.isChecked ? .picked(id) : .line(id)
    }

    private func rowSourceValue(_ line: ShoppingLine, department: String, amount: String? = nil,
                                exclusions: String? = nil, photo: PackageRowPhoto?, hit: CurrentStopSearchHit?) -> String {
        let note: CurrentStopSourceCaption = hit?.contains(.lineNote) == true ? .matchedNote : .note
        var words = [amount, hit?.contains(.name) == true ? CurrentStopSourceCaption.name.title : nil]
        if let field = hit?.fields.first(where: { $0.field == .department }) {
            words.append(CurrentStopSourceCaption.department.spoken(field.text))
        } else if !department.isEmpty {
            words.append(department)
        }
        if !line.notes.isEmpty { words.append(note.spoken(line.notes)) }
        let originals = hit?.originalFields ?? []
        for field in originals.prefix(CurrentStopSearchHit.rowEntryLimit) {
            let caption: CurrentStopSourceCaption = field.field == .originalEntry ? .entry : .entryNote
            words.append(caption.spoken(field.text))
        }
        if originals.count > CurrentStopSearchHit.rowEntryLimit { words.append(currentStopSourceText("More matching entries in Item details.")) }
        words.append(exclusions)
        if let photo { words.append(CurrentStopSourceCaption.photoCue(for: photo, matched: hit?.photoCue == true).spoken(photo.cue)) }
        return words.compactMap { $0 }.joined(separator: ", ")
    }

    @ViewBuilder private func nameSource(_ hit: CurrentStopSearchHit?) -> some View {
        if hit?.contains(.name) == true {
            Text(verbatim: CurrentStopSourceCaption.name.title).font(.caption).foregroundStyle(Theme.secondary)
        }
    }

    @ViewBuilder private func originalSources(_ hit: CurrentStopSearchHit?, fullText: Bool = false) -> some View {
        if let hit {
            let originals = hit.originalFields
            let count = fullText ? originals.count : CurrentStopSearchHit.rowEntryLimit
            ForEach(originals.prefix(count), id: \.self) { source in
                CurrentStopSourceText(caption: source.field == .originalEntry ? .entry : .entryNote,
                                      literal: source.text, fullText: fullText)
            }
            if originals.count > count {
                Text(verbatim: currentStopSourceText("More matching entries in Item details."))
                    .font(.subheadline).foregroundStyle(Theme.secondary)
            }
        }
    }

    @ViewBuilder private func searchDetails(_ line: ShoppingLine, in shop: ShoppingLedger, hit: CurrentStopSearchHit?, showAisle: Bool = true, fullText: Bool = false) -> some View {
        let aisle = model.workspace.listLayout.department(for: line, in: shop)
        if showAisle && !aisle.isEmpty {
            if hit?.contains(.department) == true {
                CurrentStopSourceText(caption: .department, literal: aisle, fullText: fullText)
            } else {
                Text(verbatim: aisle).foregroundStyle(Theme.secondary)
            }
        }
        if !line.notes.isEmpty {
            CurrentStopSourceText(caption: hit?.contains(.lineNote) == true ? .matchedNote : .note, literal: line.notes, fullText: fullText)
        }
        originalSources(hit, fullText: fullText)
        if let photo = currentPhoto(for: line.id) {
            CurrentStopSourceText(caption: .photoCue(for: photo, matched: hit?.photoCue == true), literal: photo.cue, fullText: fullText)
        }
    }

    private func pickedRow(_ line: ShoppingLine, in shop: ShoppingLedger, filtering: Bool, packages: [BasketPackage], hit: CurrentStopSearchHit?) -> some View {
        let undoLabel = shoppingFormat("Undo pick of %@", line.name)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                if line.tripUndo?.action == .pick { undo(line, in: shop) }
                else { changePick(line, in: shop, checked: false, next: line.id) }
            } label: {
                Image(systemName: "checkmark.square.fill").font(.title3)
                    .foregroundStyle(Theme.action)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(shoppingFormat("Uncheck %@", line.name))
            .accessibilityValue(filtering ? rowSourceValue(line, department: "", photo: currentPhoto(for: line.id), hit: hit) : "")
            .accessibilityIdentifier("inStoreUncheck-\(line.id)")
            .accessibilityFocused($focus, equals: .picked(line.id))
            .disabled(model.hasPendingSave)

            Button { editingPrice = line } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        nameSource(hit)
                        Text(line.name).font(.headline).foregroundStyle(Theme.ink)
                        if filtering { searchDetails(line, in: shop, hit: hit) }
                        TripRequestSummary(shop: shop, line: line)
                        if let pick = line.packagePick {
                            Text(pick.packages.shoppingLabel).foregroundStyle(Theme.secondary)
                        } else if let picked = try? shop.pickedQuantity(forLineID: line.id) {
                            let measure = TripMeasure(shop, line: line, packages: packages)
                            let label = measure.flatMap { measure in
                                (try? picked.converted(to: measure.need.unit)).map { measure.display($0) }
                            }
                            Text(label ?? ledgerQuantity(picked)).foregroundStyle(Theme.secondary)
                        }
                        if let coupon = line.pinnedCoupon { InStoreCouponPickLabel(coupon: coupon, line: line) }
                        Text(shop.priceForCurrentPick(lineID: line.id).map { pickedPriceLabels($0).joined(separator: " · ") }
                             ?? shoppingText("Price unknown · enter total"))
                            .foregroundStyle(Theme.secondary).monospacedDigit()
                    }
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Image(systemName: "pencil").font(.footnote).foregroundStyle(Theme.action)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityHint(shoppingText("Edit the price for the entire picked amount."))
            .accessibilityIdentifier("inStorePrice-\(line.id)")
            .accessibilityActions {
                if line.canUndoInStore { Button(undoLabel) { undo(line, in: shop) } }
            }
            Button { destination = .details(line.id) } label: {
                Image(systemName: "info.circle").frame(width: 44, height: 44)
            }.accessibilityLabel(ledgerFormat("Inspect %@", line.name))
        }
        .background(TripRowPosition(row: .picked(line.id)))
        .id(Focus.picked(line.id))
        .buttonStyle(.borderless)
        .overlay { GroceryCheckInset(cue: cue, lineID: line.id).allowsHitTesting(false) }
    }

    private func subtotalSummary(_ shop: ShoppingLedger, last: ShoppingLine?) -> some View {
        let subtotal = shop.pickedCartSubtotal
        return VStack(alignment: .leading, spacing: 5) {
            Text(pickedSubtotalText(subtotal)).font(.headline).monospacedDigit()
                .accessibilityFocused($focus, equals: .subtotal)
                .accessibilityIdentifier("inStoreSubtotal")
            InStoreBudgetSummary(shop: shop)
            if let last {
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 12))
                layout { lastPickActions(last, shop: shop) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .disabled(model.saving || model.hasPendingSave)
    }

    @ViewBuilder private func lastPickActions(_ last: ShoppingLine, shop: ShoppingLedger) -> some View {
        Button(shoppingText("Enter price")) { editingPrice = last }
            .frame(minHeight: 44)
            .accessibilityLabel(shoppingFormat("Enter price for %@", last.name))
            .accessibilityIdentifier("inStoreLastPrice")
        if last.canUndoInStore && !typeSize.isAccessibilitySize {
            lastPickUndo(last, shop: shop)
        }
    }

    private func reachableUndo(_ last: ShoppingLine, in shop: ShoppingLedger) -> some View {
        Button {
            undoReview = UndoReview(line: last, revision: shop.revisionID)
        } label: {
            Label(quickGroceryText("Undo"), systemImage: "arrow.uturn.backward")
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(undoLabel(for: last))
        .accessibilityIdentifier("inStoreReachableUndo")
        .disabled(model.saving || model.hasPendingSave)
        .background(.bar)
        .alert(undoReview.map { undoLabel(for: $0.line) } ?? quickGroceryText("Undo"),
               isPresented: Binding(get: { undoReview != nil }, set: { if !$0 { undoReview = nil } }),
               presenting: undoReview) { reviewed in
            Button(quickGroceryText("Undo")) {
                guard let current = model.shop, current.id == shopID, current.revisionID == reviewed.revision,
                      current.inStorePickedLines.first?.id == reviewed.line.id else { return }
                undo(reviewed.line, in: current)
            }.accessibilityIdentifier("inStoreConfirmUndo")
            Button(ledgerText("Cancel"), role: .cancel) {}
        }
    }

    private func undoLabel(for line: ShoppingLine) -> String {
        line.tripUndo?.action == .pick || line.tripUndo == nil
            ? shoppingFormat("Undo pick of %@", line.name) : tripFormat("Undo for %@", line.name)
    }

    private func lastPickUndo(_ line: ShoppingLine, shop: ShoppingLedger) -> some View {
        Button(undoLabel(for: line)) { undo(line, in: shop) }
            .frame(minHeight: 44).accessibilityIdentifier("inStoreUndo")
    }

    private func undo(_ line: ShoppingLine, in shop: ShoppingLedger) {
        Task {
            guard !model.hasPendingSave,
                  await model.editShop(key: "undo-trip-\(line.id)", shopID: shop.id, authorize: authorize, { current in
                    guard model.workspace.selectedShopID == shopID, current.revisionID == shop.revisionID else { throw LedgerError.stalePreview }
                    try current.undoInStore(lineID: line.id, expectedRevision: shop.revisionID)
                  }) else { return }
            cue = nil
            returnToRow(line.id)
        }
    }

    private func changePick(_ line: ShoppingLine, in shop: ShoppingLedger, checked: Bool, next: UUID?) {
        let originQuery = searching ? query : nil
        Task {
            guard !model.hasPendingSave, await model.change(key: "pick-\(line.id)", reviewedPantryBasis: nil, authorize: authorize, { workspace in
                guard workspace.selectedShopID == shopID, let index = workspace.shops.firstIndex(where: { $0.id == shopID }),
                      workspace.shops[index].revisionID == shop.revisionID,
                      workspace.shops[index].lines.contains(where: { $0.id == line.id && !$0.isHandled && !$0.isTrashed })
                else { throw LedgerError.stalePreview }
                try workspace.shops[index].setChecked(lineID: line.id, checked: checked)
                if checked { workspace.listLayout.recordAislePick(for: line.id, in: workspace.shops[index]) }
            }) else { return }
            cue = checked && !reduceMotion && scene == .active ? GroceryCheckCue(lineID: line.id) : nil
            guard originQuery == (searching ? query : nil) else { return }
            pendingFocus = next.map(Focus.line) ?? (searching && checked ? .picked(line.id) : .subtotal)
        }
    }
}


private struct TripVisibleRows: PreferenceKey {
    static let defaultValue: [InStoreFocus: CGRect] = [:]
    static func reduce(value: inout [InStoreFocus: CGRect], nextValue: () -> [InStoreFocus: CGRect]) {
        value.merge(nextValue()) { _, next in next }
    }
}

private struct TripRowPosition: View {
    let row: InStoreFocus
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: TripVisibleRows.self, value: [row: geometry.frame(in: .named("shoppingAisles"))])
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}
