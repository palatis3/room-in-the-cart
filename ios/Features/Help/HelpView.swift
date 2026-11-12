import SwiftUI
import UIKit

func helpText(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "Help") }

/// Place directly in the Settings Form. All articles remain available offline.
struct HelpSettingsSection: View {
    var body: some View {
        Section(helpText("Help and privacy")) {
            NavigationLink(helpText("Help")) { HelpCenterView() }.accessibilityIdentifier("settings.help")
            NavigationLink(helpText("Privacy and data")) { HelpPrivacyView() }.accessibilityIdentifier("settings.privacy")
            NavigationLink(helpText("Support")) { HelpSupportView() }.accessibilityIdentifier("settings.support")
        }
    }
}

struct HelpCenterView: View {
    private let configuration = HelpConfiguration.fromBundle()
    var body: some View {
        List {
            Section {
                Text(helpText("Start with a pack comparison. No account or connection is needed for your private shopping tools."))
            }
            Section(helpText("Using Room in the Cart")) {
                ForEach(HelpTopic.allCases) { topic in
                    NavigationLink { HelpArticleView(topic: topic) } label: { Text(topic.title) }
                        .accessibilityIdentifier("help.topic." + topic.rawValue)
                }
            }
            Section {
                NavigationLink(helpText("Privacy and data")) { HelpPrivacyView() }
                NavigationLink(helpText("Support")) { HelpSupportView() }
                if let url = configuration.helpURL { Link(helpText("Online help"), destination: url) }
            }
        }.workingSurface().navigationTitle(helpText("Help"))
    }
}

enum HelpTopic: String, CaseIterable, Identifiable {
    case comparison, list, dinners, handoff, household, records, shortcuts, membership
    var id: String { rawValue }
    var title: String {
        switch self {
        case .comparison: return helpText("Compare two packs")
        case .list: return helpText("Build a list and check the budget")
        case .dinners: return helpText("Plan dinners and protect lunches")
        case .handoff: return helpText("Hand off a pickup and record what arrived")
        case .household: return helpText("Requests, shared shops and cook views")
        case .records: return helpText("Export, recover and delete records")
        case .shortcuts: return helpText("Capture, reminders and device shortcuts")
        case .membership: return helpText("Free tools and Household membership")
        }
    }
}

private struct HelpArticleView: View {
    let topic: HelpTopic
    var body: some View {
        List {
            switch topic {
            case .comparison:
                paragraph(helpText("Open Compare packs in Shop. Enter the amount you need, the usable amount in each pack and the price. If the package uses a different kind of unit, enter two equivalent amounts from its label or your own measurement, such as 120 grams of this flour for 1 cup. Without that information, leave the conversion blank."))
                paragraph(helpText("Review the whole packs needed, the usable food and the cost. An unknown usable amount or missing price stays unresolved. Save the comparison to reopen it in Records."))
                paragraph(helpText("A pack comparison covers that item only. To judge the whole pickup, review the shopping list and its checkout costs."))
            case .list:
                paragraph(helpText("In Shop, open your shopping list. Type items or review pasted text before adding it. Review possible duplicates; meal needs and everyday staples remain separate."))
                paragraph(helpText("Set a spending cap and review the expected checkout with known fees, taxes and discounts. Missing prices remain visible. A payment hold and a posted charge are separate amounts."))
                paragraph(helpText("To compare stores, enter two quotes for the same needs. Include fees, extra travel cost and time, and check when each quote was observed. This is a manual comparison, not live retailer pricing."))
            case .dinners:
                paragraph(helpText("In Dinners, save a familiar meal with its portions, ingredients, source, exclusions and any known prep lead time. Review an idea before choosing it for this shop. Choosing an idea and assigning a night are separate steps."))
                paragraph(helpText("In Dinner library, open Import and use recipes to type a family recipe or choose a Recipe JSON-LD file from Files. Review and save the recipe. When you want to shop for it, open the saved recipe and review the ingredients for that pickup."))
                paragraph(helpText("Use the meal week for guests, away nights and protected lunches. Preview a change before saving it. Editing this week does not rewrite your reusable dinner or rotation."))
                paragraph(helpText("Count pantry or freezer food only after confirming its usable quantity and matching it to the need. If food falls short, protect lunch reservations and review each affected dinner. Leave an unresolved need open until you choose a repair."))
            case .handoff:
                paragraph(helpText("Review the basket and prepare a dated retailer handoff in Shop. Copy or share that reviewed list, then place the order with your retailer. Copying or sharing does not place an order."))
                paragraph(helpText("Report placement separately. Record substitutions and the usable quantities that actually came home, then review meal shortages. Keep a pending credit pending until it posts; do not record a refund twice."))
                paragraph(helpText("Prepare a dated cook instruction showing portions, what to set aside and what remains unresolved. Choose the recipient language and review any private wording. Marking a copy sent and reporting acknowledgment are separate actions."))
            case .household:
                paragraph(helpText("Open Household requests in Settings to sign in or manage connected access. Signing in does not upload your existing private workspace. If sign-in is unavailable in this build, keep using the private tools."))
                paragraph(helpText("A request is received only after the household confirms it. If the response is uncertain, retry the same request. A contributor sees their own request and outcome; household budgets stay private."))
                paragraph(helpText("Only the assigned shopper can commit a shared basket change. Another authorized adult can propose a change for review. A membership seat does not grant shopper authority or budget access."))
                paragraph(helpText("A current cook view is limited to one shop, selected fields and its expiry. Manage or revoke it through household controls. A dated static message remains a separate copy. Child enrollment requires the configured guardian consent process."))
            case .records:
                paragraph(helpText("In Records, open Recovery, exports and saved records. Select readable records, then preview a helper copy, a readable owner export or a structured recovery file. Owner files can include private data. Choose where to save or share them."))
                paragraph(helpText("To recover a file, review its source, date, identity, revision and conflicts before importing. A recovery copy opens separately from newer work. A malformed or unsupported file must not replace your saved records."))
                paragraph(helpText("Deletion names its scope before confirmation. Deleting one record, recovered copies or the entire local ledger has different effects. Use undo only when it is offered. Account deletion is a separate household control; copies already exported or sent remain with their recipients."))
            case .shortcuts:
                paragraph(helpText("Typed entry is always available. Camera, photo, barcode and speech capture create an editable preview. Review names, units, matches and amounts before saving; recognition is not a confirmed fact."))
                paragraph(helpText("Device shortcuts in Settings contains optional share, widget and reminder tools. Review incoming shared text before adding it. Widgets use a narrow view and hide private notes and money."))
                paragraph(helpText("Choose a specific reminder before allowing notifications. Check local time, quiet hours and expiry. Local reminders do not guarantee live household status while this iPhone is offline."))
            case .membership:
                paragraph(helpText("Free covers an ordinary pickup, manual planning, one reusable dinner, saved records and exports. Household adds repeated planning tools for up to two named adults. Groceries are purchased from your retailer."))
                paragraph(helpText("Open Household membership in Settings for Apple’s actual localized offer, Restore Purchases and Manage Subscription. If the offer or account setup is unavailable, continue with Free."))
                paragraph(helpText("Restore with the original purchasing account and household. A pending or unverified purchase adds no paid access. If delivery is uncertain, retry delivery or restore rather than buying again. Ending membership preserves permitted Free work."))
            }
        }.workingSurface().navigationTitle(topic.title).navigationBarTitleDisplayMode(.inline)
    }
    private func paragraph(_ value: String) -> some View { Text(value).fixedSize(horizontal: false, vertical: true) }
}

struct HelpPrivacyView: View {
    @EnvironmentObject private var household: HouseholdModel
    private let configuration = HelpConfiguration.fromBundle()
    var body: some View {
        List {
            Section(helpText("Your private workspace")) {
                Text(helpText("Private comparisons, lists, dinners, capture reviews and pickup records are stored on this iPhone. Joining a household does not upload that existing work. An owner export can include private content and recipient history."))
                Text(helpText("Optional pickup feedback stays in your local pickup record. It is not sent to an analytics service. You can turn the prompt off in Settings and remove a saved response from its pickup."))
                Text(helpText("Optional household measurement is separate. With explicit consent, the service stores the response codes you review, the shop identity, eligible week and notice version, and can match membership status to study retention. Existing local feedback, grocery text, prices and member names are not sent. Manage or withdraw that consent in Settings."))
            }
            Section(helpText("When you connect or share")) {
                Text(helpText("Account sign-in sends account information to the identity provider. Explicit household actions send the account, request, shop, budget or instruction fields needed for that action. The service checks the household, role and shop permissions."))
                Text(helpText("A cook link exposes only its granted fields. A static message or exported file is a separate copy under the recipient’s control. Review the destination and private fields before sharing."))
                Text(helpText("Apple handles subscription payment credentials. The app and household service use transaction evidence to deliver and restore membership; they do not receive your payment card or bank account number."))
            }
            Section(helpText("Photos and speech")) {
                Text(helpText("The app’s capture tools process speech and images on this iPhone. Raw voice recordings are not retained or uploaded by the app. Saved evidence photos stay in protected local storage. Readable and helper exports exclude photos. An encrypted recovery file can include evidence photos only after you select and review them. Apple may download a photo you select from iCloud before delivering it to the app."))
            }
            Section(helpText("Export and deletion")) {
                Text(helpText("Open Records, then Recovery, exports and saved records to preview an export, recover a file or review local deletion. Removing local work does not remove copies you already saved or sent."))
                Text(helpText("Household account deletion has its own scope and status. Review it in household controls. Signing out or leaving a household is separate from deleting an account, and deleting an account does not cancel an Apple subscription. Manage that subscription through Apple."))
                NavigationLink(helpText("Open household and account controls")) { HouseholdSettingsView(model: household) }
            }
            Section(helpText("Policy and terms")) {
                if let name = configuration.operatorName {
                    LabeledContent(helpText("Operator"), value: name).accessibilityIdentifier("help.policy.operator")
                }
                Text(helpText("This guide describes the app’s data controls. The operator’s privacy policy and terms are separate pages."))
                if let url = configuration.privacyURL { Link(helpText("Privacy policy"), destination: url) }
                else { Text(helpText("The privacy policy link is unavailable in this build.")) }
                if let url = configuration.termsURL { Link(helpText("Terms of use"), destination: url) }
                else { Text(helpText("The terms link is unavailable in this build.")) }
            }
        }.workingSurface().navigationTitle(helpText("Privacy and data"))
    }
}

struct HelpSupportView: View {
    private let configuration = HelpConfiguration.fromBundle()
    private let diagnostics = SupportDiagnostics(systemVersion: UIDevice.current.systemVersion,
        language: Bundle.main.preferredLocalizations.first ?? "unknown")
    var body: some View {
        List {
            Section(helpText("Get help")) {
                Text(helpText("Describe the steps, what you expected and what happened. Leave out grocery details, budgets, names, receipts, sign-in codes and invitation links."))
                if let url = configuration.supportEmailURL, let address = configuration.supportEmailAddress {
                    Link(destination: url) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(helpText("Email support"))
                            Text(address)
                        }.frame(minHeight: 44)
                    }.accessibilityIdentifier("help.support.email")
                    Text(helpText("Choose your email app and review the message before sending. No message is sent automatically."))
                }
                if let url = configuration.supportURL { Link(helpText("Open support"), destination: url).accessibilityIdentifier("help.support.open") }
                else if configuration.supportEmailURL == nil { Text(helpText("An online support destination is unavailable in this build. Offline help and the support summary are still available.")) }
                NavigationLink(helpText("Read offline help")) { HelpCenterView() }
            }
            Section(helpText("Review support summary")) {
                Text(helpText("This summary contains only the app version, build, iOS version, interface language, build environment and whether service and membership configuration are present. It contains no groceries, money, account or device identifiers, credentials, logs or photos."))
                Text(diagnostics.text).font(.caption.monospaced()).textSelection(.enabled)
                    .accessibilityIdentifier("help.support.summary")
                ShareLink(item: diagnostics.text) { Label(helpText("Share support summary"), systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("help.support.share")
                Text(helpText("Nothing is sent automatically. Review the summary and choose its destination in the share sheet. A personal recovery file is a separate private export; support does not need it by default."))
            }
        }.workingSurface().navigationTitle(helpText("Support"))
    }
}
