import SwiftUI

/// Resolve the current row by identity on every access. The placeholder contains no private row text.
/// Retained controls may read after removal; their writes cannot recreate or retarget a removed row.
func captureDraftBinding<Element: Identifiable>(_ placeholder: Element, in collection: Binding<[Element]>) -> Binding<Element> {
    let id = placeholder.id
    return Binding(get: {
        collection.wrappedValue.first { $0.id == id } ?? placeholder
    }, set: { updated, transaction in
        guard updated.id == id else { return }
        var current = collection.wrappedValue
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        current[index] = updated
        collection.transaction(transaction).wrappedValue = current
    })
}
