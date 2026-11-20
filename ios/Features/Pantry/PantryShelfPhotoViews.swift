import CoreDomain
import PhotosUI
import SwiftUI

func shelfPhotoText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "PantryShelfPhotos")
}

struct PantryShelfPhotoLink: View {
    var expectedOrigin: UUID? = nil
    @Environment(\.pantryDigestAccess) private var access
    @Environment(\.pantryDigestPermissionPrompt) private var prompt
    @Environment(\.pantryVoicePrompt) private var window
    @State private var previous: PantryDigestAccess?

    var body: some View {
        let current = access.flatMap { $0.authorized() ? $0 : nil }
        let retaining = window?.holdsPresentation() == true && previous?.scope == prompt?.scope
        Group {
            if let opened = current ?? (retaining ? previous : nil),
               expectedOrigin == nil || expectedOrigin == opened.scope.origin {
                NavigationLink {
                    ShelfPhotoAccessGate(opened: opened) {
                        PantryShelfLocations(access: opened, store: PantryDigestStore.shared.shelfPhotos)
                    }
                    .navigationTitle(shelfPhotoText("Shelf photos"))
                } label: {
                    Label(shelfPhotoText("Shelf photos"), systemImage: "photo.on.rectangle").frame(minHeight: 44)
                }
                .id(opened.scope.origin.uuidString + opened.scope.owner)
                .accessibilityIdentifier("shelfPhotos.open")
            }
        }
        .onChange(of: current?.scope, initial: true) { _, _ in
            if current != nil || !retaining { previous = current }
        }
    }
}

/// Retain the editor behind the app's existing privacy cover only while iOS asks this adult for camera access.
struct ShelfPhotoAccessGate<Content: View>: View {
    let opened: PantryDigestAccess
    @ViewBuilder let content: () -> Content
    @Environment(\.pantryDigestAccess) private var current
    @Environment(\.scenePhase) private var scene
    @Environment(\.pantryDigestPermissionPrompt) private var prompt
    @Environment(\.pantryVoicePrompt) private var window

    var body: some View {
        let active = scene == .active && current?.scope == opened.scope && opened.authorized()
        let retained = scene != .background && prompt?.scope == opened.scope && window?.holdsPresentation() == true
        Group {
            if UIApplication.shared.isProtectedDataAvailable && (active || retained) {
                content().opacity(active ? 1 : 0).allowsHitTesting(active).accessibilityHidden(!active)
            } else {
                Text(pantryText("Unlock the authorized private workspace to view pantry food."))
            }
        }.privacySensitive()
    }
}

private struct PantryShelfLocations: View {
    let access: PantryDigestAccess
    @ObservedObject var store: PantryShelfPhotoStore
    @State private var dates: [InventoryLocation: String] = [:]
    @State private var unreadable: Set<InventoryLocation> = []
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                ForEach(InventoryLocation.allCases, id: \.self) { location in
                    if unreadable.contains(location) {
                        VStack(alignment: .leading) {
                            Text(pantryLocationName(location))
                            Text(shelfPhotoText("Couldn’t open the saved photo.")).foregroundStyle(Theme.warning)
                        }
                    } else {
                        NavigationLink {
                            ShelfPhotoAccessGate(opened: access) {
                                PantryShelfLocationDetail(location: location, access: access, store: store)
                            }.navigationTitle(pantryLocationName(location))
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pantryLocationName(location)).font(.headline)
                                if let date = dates[location] {
                                    Text(date).foregroundStyle(Theme.secondary)
                                } else if loaded {
                                    Text(shelfPhotoText("No photo saved")).foregroundStyle(Theme.secondary)
                                }
                            }.frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("shelfPhotos.location." + location.rawValue)
                    }
                }
            } footer: {
                Text(shelfPhotoText("Keep one private photo per location on this iPhone. Check its date when you shop."))
            }
        }
        .workingSurface()
        .task(id: store.generation) {
            var next: [InventoryLocation: String] = [:]
            var failures: Set<InventoryLocation> = []
            for location in InventoryLocation.allCases {
                do { next[location] = try store.photo(at: location, access: access).map(shelfPhotoDateLabel) }
                catch { failures.insert(location) }
            }
            dates = next
            unreadable = failures
            loaded = true
        }
    }
}

private func shelfPhotoDateLabel(_ photo: PantryShelfPhoto) -> String {
    String(format: shelfPhotoText("Taken %@"), locale: .current, photo.dateLabel)
}

private struct PantryShelfLocationDetail: View {
    let location: InventoryLocation
    let access: PantryDigestAccess
    @ObservedObject var store: PantryShelfPhotoStore
    @State private var photo: PantryShelfPhoto?
    @State private var loaded = false
    @State private var failed = false
    @State private var editing = false
    @State private var expected: UUID?
    @State private var deleting: UUID?
    @State private var inspecting: UUID?
    @State private var status: String?

    var body: some View {
        List {
            if let photo, let image = UIImage(data: photo.jpeg) {
                Section {
                    Text(shelfPhotoDateLabel(photo)).font(.headline)
                    Button { inspecting = photo.id } label: {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                    .accessibilityLabel(shelfPhotoText("Inspect shelf photo"))
                    .accessibilityIdentifier("shelfPhotos.inspect")
                }
            } else if failed {
                Text(shelfPhotoText("Couldn’t open the saved photo."))
            } else if loaded {
                Text(shelfPhotoText("No photo saved"))
            }
            if loaded && !failed {
                Button {
                    expected = photo?.id
                    editing = true
                } label: {
                    Label(shelfPhotoText(photo == nil ? "Add shelf photo" : "Replace photo"), systemImage: "photo.badge.plus")
                        .frame(minHeight: 44)
                }.accessibilityIdentifier("shelfPhotos.edit")
                if let photo {
                    Button(role: .destructive) { deleting = photo.id } label: {
                        Label(shelfPhotoText("Delete photo"), systemImage: "trash").frame(minHeight: 44)
                    }.accessibilityIdentifier("shelfPhotos.delete")
                }
            }
            if let status { Text(status) }
        }
        .workingSurface()
        .task(id: store.generation) { refresh() }
        .sheet(isPresented: $editing) {
            NavigationStack {
                PantryShelfPhotoEditor(access: access, location: location, expected: expected) {
                    editing = false
                    report("Shelf photo saved.")
                }
            }
        }
        .sheet(isPresented: Binding(get: { inspecting != nil && inspecting == photo?.id }, set: { if !$0 { inspecting = nil } })) {
            if let photo, let image = UIImage(data: photo.jpeg), access.authorized() {
                NavigationStack {
                    ShelfPhotoInspector(image: image)
                        .accessibilityLabel(shelfPhotoText("Shelf photo"))
                        .navigationTitle(shelfPhotoDateLabel(photo)).navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button(pantryText("Done")) { inspecting = nil } }
                }.privacySensitive()
            }
        }
        .confirmationDialog(shelfPhotoText("Delete this shelf photo?"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { id in
                Button(shelfPhotoText("Delete photo"), role: .destructive) {
                    do {
                        try store.remove(id, at: location, access: access)
                        report("Shelf photo deleted.")
                    } catch { report("The photo changed or access ended. Reopen this location.") }
                }
            }
    }

    private func report(_ key: String) {
        status = shelfPhotoText(key)
        UIAccessibility.post(notification: .announcement, argument: status)
    }

    private func refresh() {
        do {
            photo = try store.photo(at: location, access: access)
            failed = false
        } catch {
            photo = nil
            failed = true
        }
        if inspecting != photo?.id { inspecting = nil }
        loaded = true
    }
}

/// Let the shopper inspect small packages using the native pinch and pan gestures.
private struct ShelfPhotoInspector: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        scroll.maximumZoomScale = 5
        scroll.delegate = context.coordinator
        context.coordinator.imageView = view
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) { context.coordinator.imageView?.image = image }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
