import CoreDomain
import SwiftUI

struct PackageDateChoices: View {
    @ObservedObject var model: PantryModel
    let lot: InventoryLot
    let access: PantryDigestAccess
    var code: CapturedBarcode? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var noLabel = false
    private var formula: Bool {
        let name = lot.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        return name.contains("formula") && ["infant", "baby", "bebe", "lactante", "leche"].contains(where: name.contains)
    }
    private var eligible: Bool {
        guard !formula, let reference = PantryFoodKeeperSelection.reference else { return false }
        let language: FoodKeeperLanguage = locale.language.languageCode?.identifier == "es" ? .spanish : .english
        return reference.search(lot.name, language: language).contains { product in
            FoodKeeperCondition.allCases.contains { $0.storage == lot.location.foodKeeperStorage && product.supportsDateWindow(for: $0) }
        }
    }
    var body: some View {
        WorkingForm {
            if access.canPresent(), model.snapshot?.lots.first(where: { $0.id == lot.id }) == lot {
                PantryBatchHeading(lot: lot)
                if !noLabel {
                    Section(pantryText("Is there a date on this package?")) {
                        if formula { Text(pantryText("For infant formula, follow the manufacturer’s use-by date.")) }
                        NavigationLink(pantryText("Read printed date")) {
                            PantryPackageDateEditor(model: model, lot: lot, access: access, store: PantryDigestStore.shared.packageDates, scannedCode: code)
                        }
                        if let code = code ?? lot.packageCode, code.gs1?.dates.isEmpty == false {
                            NavigationLink(pantryText("Review encoded date")) {
                                PantryPackageDateEditor(model: model, lot: lot, access: access, store: PantryDigestStore.shared.packageDates, scannedCode: code)
                            }
                        }
                        Button(pantryText("No visible date")) { noLabel = true }
                    }
                } else {
                    if formula {
                        Text(pantryText("For infant formula, follow the manufacturer’s use-by date."))
                    } else {
                        NavigationLink(pantryText(eligible ? "Estimate when to check" : "Food storage guide")) {
                            PantryLotStorageReference(model: model, lotID: lot.id, accessAllowed: access.authorized())
                        }
                    }
                    NavigationLink(pantryText("Choose my own check day")) { PantryDigestDayEditor(model: model, access: access, lot: lot) }
                }
                Button(pantryText("Skip")) { dismiss() }
            }
        }.disabled(!access.authorized()).privacySensitive().navigationTitle(pantryText("Add a date or reminder"))
    }
}
