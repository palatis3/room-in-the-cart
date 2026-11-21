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
        WorkingForm {
            Section {
                Text(helpText("In Shop, choose Add a grocery to start your private list. Pantry, Dinners and Records are also available without an account."))
            }
            Section(helpText("Using Room in the Cart")) {
                ForEach(HelpTopic.allCases) { topic in
                    NavigationLink { HelpArticleView(topic: topic) } label: {
                        Text(topic.title).fixedSize(horizontal: false, vertical: true)
                    }
                        .accessibilityIdentifier("help.topic." + topic.rawValue)
                }
                NavigationLink(helpText("Food storage guide")) { FoodKeeperLookupView() }
                    .accessibilityIdentifier("help.foodKeeper")
            }
            Section {
                NavigationLink(helpText("Privacy and data")) { HelpPrivacyView() }
                NavigationLink(helpText("Support")) { HelpSupportView() }
                NavigationLink(helpText("About Room in the Cart")) { AboutRoomInTheCartView() }
                    .accessibilityIdentifier("help.about")
                if let url = configuration.helpURL { Link(helpText("Online help"), destination: url) }
            }
        }.navigationTitle(helpText("Help"))
    }
}

enum HelpTopic: String, CaseIterable, Identifiable {
    case list, pantry, dinners, records, comparison, handoff, household, shortcuts, membership
    var id: String { rawValue }
    var navigationTitle: String {
        switch self {
        case .records: return helpText("Record recovery")
        case .membership: return mtr("Membership")
        default: return title
        }
    }
    var title: String {
        switch self {
        case .comparison: return helpText("Compare two packs")
        case .pantry: return helpText("Track food in Pantry")
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
    @EnvironmentObject private var household: HouseholdModel
    let topic: HelpTopic
    var body: some View {
        WorkingForm {
            switch topic {
            case .comparison:
                paragraph(helpText("Open Compare packs in Shop. Enter the amount you need, the usable amount in each pack and the price. If the package uses a different kind of unit, enter two equivalent amounts from its label or your own measurement, such as 120 grams of this flour for 1 cup. Without that information, leave the conversion blank."))
                paragraph(helpText("Review the whole packs needed, the usable food and the cost. An unknown usable amount or missing price stays unresolved. Save the comparison to reopen it in Records."))
                paragraph(helpText("A pack comparison covers that item only. To judge the whole pickup, review the shopping list and its checkout costs."))
            case .pantry:
                paragraph(helpText("Open Pantry to see the food you have and where you keep it. Add food by hand or review the lines from a receipt. Check each amount before saving."))
                paragraph(helpText("Choose a date to check food quality or look up a food in the offline storage guide. A reminder can ask you to open My Pantry."))
                NavigationLink(helpText("Food storage guide")) { FoodKeeperLookupView() }
            case .list:
                paragraph(helpText("In Shop, choose Add a grocery. Enter the item and any amount you know. You can also review pasted text and check possible duplicates before adding them."))
                paragraph(helpText("Set a spending cap and review the expected checkout with known fees, taxes and discounts. Missing prices remain visible. A payment hold and a posted charge are separate amounts."))
                paragraph(helpText("To compare stores, enter two quotes for the same needs. Include fees, extra travel cost and time, and check when each quote was observed. This is a manual comparison, not live retailer pricing."))
            case .dinners:
                paragraph(helpText("In Dinners, save a familiar meal with its portions, ingredients, source, exclusions and any known prep lead time. Review an idea before choosing it for this shop. Choosing an idea and assigning a night are separate steps."))
                paragraph(helpText("Before your first pickup, open Dinners, then Import and use recipes. Type a family recipe or choose a Recipe JSON-LD file from Files. Review and save it. Once you have a pickup, open the saved recipe from Dinner library to review its ingredients for that pickup."))
                paragraph(helpText("Use the meal week for guests, away nights and protected lunches. Preview a change before saving it. Editing this week does not rewrite your reusable dinner or rotation."))
                paragraph(helpText("Count pantry or freezer food only after confirming its usable quantity and matching it to the need. If food falls short, protect lunch reservations and review each affected dinner. Leave an unresolved need open until you choose a repair."))
            case .handoff:
                paragraph(helpText("Review the basket and prepare a dated retailer handoff in Shop. Copy or share that reviewed list, then place the order with your retailer. Copying or sharing does not place an order."))
                paragraph(helpText("Report placement separately. Record substitutions and the usable quantities that actually came home, then review meal shortages. Keep a pending credit pending until it posts; do not record a refund twice."))
                paragraph(helpText("Prepare a dated cook instruction showing portions, what to set aside and what remains unresolved. Choose the recipient language and review any private wording. Marking a copy sent and reporting acknowledgment are separate actions."))
            case .household:
                paragraph(helpText("You can shop on this iPhone without joining a household. Your existing private lists and dinners stay here when you join."))
                if household.configured {
                    paragraph(helpText("Open Household requests in Settings to see which requests you can send or review."))
                } else {
                    paragraph(ht("Household sign-in is unavailable"))
                }
                paragraph(helpText("A request is received only after the household confirms it. If the response is uncertain, retry the same request. A contributor sees their own request and outcome; household budgets stay private."))
                paragraph(helpText("Only the assigned shopper can commit a shared basket change. Another authorized adult can propose a change for review. A membership seat does not grant shopper authority or budget access."))
                paragraph(helpText("A current cook view is limited to one shop, selected fields and its expiry. Manage or revoke it through household controls. A dated static message remains a separate copy. Child enrollment requires the configured guardian consent process."))
            case .records:
                Section(helpText("On your old iPhone")) {
                    paragraph(helpText("In Records, open Recovery, exports and saved records. Choose your records and save the encrypted file. Keep the key separately."))
                }
                Section(helpText("On your new iPhone")) {
                    paragraph(helpText("Open recovery in Records. Choose the file, enter the key and review the dates before importing. Your records open as separate copies."))
                }
                Section(helpText("Sharing or deleting copies")) {
                    paragraph(helpText("For a readable copy, preview the records and any private details before you choose who gets it."))
                    paragraph(helpText("Before deleting, check which records are selected. Copies you already shared stay with their recipients. Account deletion is a separate choice in household settings."))
                }
            case .shortcuts:
                paragraph(helpText("Typed entry is always available. Camera, photo, barcode and speech capture create an editable preview. Review names, units, matches and amounts before saving; recognition is not a confirmed fact."))
                paragraph(helpText("Device shortcuts in Settings contains optional share, widget and reminder tools. Review incoming shared text before adding it. Widgets use a narrow view and hide private notes and money."))
                paragraph(helpText("Choose a specific reminder before allowing notifications. Check local time, quiet hours and expiry. Local reminders do not guarantee live household status while this iPhone is offline."))
            case .membership:
                Section(mtr("Included with Free")) {
                    paragraph(helpText("Use your private shopping list, plan dinners by hand, save one dinner to use again and export your records. You buy groceries from the retailer."))
                }
                Section(mtr("What Household adds")) {
                    paragraph(mtr("Plan repeat weeks and compare dinner combinations using your own prices. Up to two named adults can plan."))
                    MembershipHelpAccess()
                }
            }
        }.navigationTitle(topic.navigationTitle).navigationBarTitleDisplayMode(.inline)
    }
    private func paragraph(_ value: String) -> some View { Text(value).fixedSize(horizontal: false, vertical: true) }
}

private struct MembershipHelpAccess: View {
    @EnvironmentObject private var household: HouseholdModel
    @EnvironmentObject private var membership: MembershipCoordinator
    @Environment(\.guardianChildCoordinator) private var child

    var body: some View {
        if household.canOpenMembership && child?.presented != true {
            if let model = membership.model(for: household.membershipSession) {
                MembershipHelpControls(model: model)
            } else if !household.configured {
                Text(mtr("Your private lists and dinners work without an account. Household sign-in is unavailable on this iPhone."))
            } else if household.membershipSession == nil {
                Text(mtr("Select your household to check your planning access."))
            } else {
                Text(helpText("Open Household membership to check your current access."))
            }
            NavigationLink(tr("Household membership")) { MembershipEntryView(household: household) }
                .accessibilityIdentifier("help.openMembership")
        }
    }
}

private struct MembershipHelpControls: View {
    @ObservedObject var model: MembershipModel

    var body: some View {
        if model.displayedAnnualOffer != nil {
            Text(helpText("Open Household membership to see the App Store price and renewal period for this offer."))
        }
        if model.showsPurchaserControls {
            Text(helpText("Already paid? Open Household membership and choose Restore Purchases using the Apple account that bought it."))
        } else {
            Text(helpText("Open Household membership to refresh your planning access. The adult who bought the subscription manages it."))
        }
    }
}

struct HelpPrivacyView: View {
    @EnvironmentObject private var household: HouseholdModel
    private let configuration = HelpConfiguration.fromBundle()
    var body: some View {
        WorkingForm {
            Section(helpText("Your private workspace")) {
                Text(helpText("Your private lists, dinners, comparisons, capture reviews and pickup records stay on this iPhone. Joining a household keeps that work here."))
                Text(helpText("An export can include private notes and the names of people you shared with. Preview it before choosing a recipient."))
                Text(helpText("You can search the USDA FoodKeeper guide offline. In My Pantry, you can save a date to check food quality and choose a daily reminder. The reminder can appear on your Lock Screen. It asks you to open My Pantry and omits food names."))
                Text(helpText("Optional pickup feedback stays in your local pickup record. It is not sent to an analytics service. You can turn the prompt off in Settings and remove a saved response from its pickup."))
                Text(helpText("Optional household measurement is separate. With explicit consent, the service stores the response codes you review, the shop identity, eligible week and notice version, and can match membership status to study retention. Existing local feedback, grocery text, prices and member names are not sent. Manage or withdraw that consent in Settings."))
            }
            Section(helpText("Regional age checks")) {
                Text(helpText("If Apple requires an age range and the regional check is enabled, the app asks whether you’ll share it. The app uses the response on this iPhone to decide whether to open your workspace. It keeps the check result in memory and sends no age range to your household."))
            }
            Section(helpText("When you connect or share")) {
                Text(helpText("Account sign-in sends account information to the identity provider. Explicit household actions send the account, request, shop, budget or instruction fields needed for that action. The service checks the household, role and shop permissions."))
                Text(helpText("If you report household content, the service records your reason, which item and version you reported, your member ID and the sender’s ID when known. You can submit the report without sharing the wording, or choose up to 1,000 characters for the review team to read. Reports expire after the period the operator sets for review. Blocking a sender in your household sends no message text."))
                Text(helpText("If last calls are available, the shopper can set a cutoff that eligible adults see in the app. The service records your response and whether you mute the invitation. Requests after the cutoff go to the next trip."))
                Text(helpText("If you request a private review of your authority to delete a child’s account, the service uses the details you provide to verify your request. It keeps a case number, account or enrollment references, status and dates. You can check the case and its expiry in Guardian controls. A separate deletion receipt confirms when the account has been erased."))
                Text(helpText("The household service saves a shopper’s question with the contributor’s request. When you save shared instructions for a cook, it stores the wording and your member ID. If you mark the instructions as sent, it also saves the recipient you entered and the time."))
                Text(helpText("When you confirm a receipt for the household pantry, adults with pantry access can see the store, purchase date, any reference you enter, and each selected line’s original wording, food, quantities, storage location and price if entered. The original file stays on this iPhone."))
                Text(helpText("When you choose Read recipe for a web link, this iPhone requests the page directly from the recipe website. The site sees the page address you requested, including any query parameters, your IP address and an identifier for the app’s recipe reader. A site the link redirects you to receives the same kinds of information."))
                Text(helpText("When you save a recipe in Household Tonight, you send its ingredients, portions, selected pantry batches and any reviewed restrictions or package details to the household service. Adults with pantry access can see the recipe title and ingredients when the meal appears as a suggestion."))
                Text(helpText("When you share a reaction to a meal you shopped for, the household service saves it with your member ID. For up to 90 days, Household Tonight can use your latest reaction to that version of the recipe to break ties between dinner suggestions for you. To withdraw your reactions, open Household pantry and choose Review my shared meal feedback."))
                Text(helpText("If the household receipt save is unconfirmed, this iPhone keeps a protected copy of the reviewed details. Check the household pantry before retrying the same change. Clearing the retry leaves any receipt the household already saved in place."))
                Text(helpText("A cook link exposes only its granted fields. A static message or exported file is a separate copy under the recipient’s control. Review the destination and private fields before sharing."))
                Text(helpText("If Apple tells Room in the Cart that a guardian withdrew permission for an App Store download, the service saves a receipt to recognize repeated notices. The receipt contains the notice ID, the time Apple signed it and whether it came from the live or test App Store. It contains no age range, download ID or household account."))
                Text(helpText("Apple handles subscription payment credentials. The app and household service use transaction evidence to deliver and restore membership; they do not receive your payment card or bank account number."))
            }
            Section(helpText("Photos and speech")) {
                Text(helpText("Ordinary dictation and photo text recognition run on this iPhone. Your private evidence photos are saved in protected local storage. Apple may retrieve a selected iCloud photo. You can include reviewed photos in an encrypted recovery file."))
                Text(helpText("If product references are available, an adult can choose to share a description, brand, size or barcode with the named shopper. When photo sharing is enabled separately, the service receives only the crop you review, without location metadata. An authorized moderator reviews it before the shopper can see it. You can remove a shared reference. Access expires within seven days."))
                Text(helpText("When online assistance is available, an authorized adult can review and send a selected excerpt, a cropped image or a separate voice recording to OpenAI through Room in the Cart. Listen to the recording or inspect the crop before sending. You can keep using the local editor."))
                Text(helpText("The household service counts online assistance requests for your account to enforce the daily limit. It also keeps a code for each request to prevent processing it twice. The service can remove these records once they are more than 24 hours old."))
                Text(helpText("Looking up a barcode in Open Food Facts sends the barcode, app version and the app’s support email to that service. It also sees your IP address. Its privacy policy says it keeps visitor IP addresses and logs for three years for security, technical analysis and measuring popularity. You can enter the product name and package size yourself."))
                Text(helpText("For optional online language help, review what will go to OpenAI through Room in the Cart. Depending on the task, this can include your wording, possible matches, or selected meal titles and reasons. For a FoodKeeper match, you share the label wording and the names and IDs of the guide entries shown. You choose whether to use a suggestion."))
            }
            Section(helpText("Export and deletion")) {
                Text(helpText("Open Records, then Recovery, exports and saved records to preview an export, recover a file or review local deletion. Removing local work does not remove copies you already saved or sent."))
                Text(helpText("Household account deletion has its own scope and status. Review it in household controls. Signing out or leaving a household is separate from deleting an account, and deleting an account does not cancel an Apple subscription. Manage that subscription through Apple."))
                Text(helpText("Deleting your account erases the household receipt lines you submitted. To prevent the same lines from being imported again, the service keeps receipt identification codes and the positions of the erased lines. These records omit the printed wording."))
                NavigationLink(helpText("Open household and account controls")) { HouseholdSettingsView(model: household) }
            }
            Section(helpText("Policy and terms")) {
                if let name = configuration.operatorName {
                    LabeledContent(helpText("Operator"), value: name).accessibilityIdentifier("help.policy.operator")
                }
                Text(helpText("When Resend delivers a sign-in code, it processes the recipient’s email address and the message containing the code. If you email support, Cloudflare Email Routing forwards your address, message and any attachments to the operator’s Gmail inbox so the operator can respond."))
                Text(helpText("This guide describes the app’s data controls. The operator’s privacy policy and terms are separate pages."))
                if let url = configuration.privacyURL { Link(helpText("Privacy policy"), destination: url) }
                if let url = configuration.termsURL { Link(helpText("Terms of use"), destination: url) }
            }
        }.navigationTitle(helpText("Privacy and data"))
    }
}

struct HelpSupportView: View {
    @Environment(\.openURL) private var openURL
    @State private var emailUnavailable = false
    @State private var copiedAddress = false
    private let configuration = HelpConfiguration.fromBundle()
    private let diagnostics = SupportDiagnostics(systemVersion: UIDevice.current.systemVersion,
        language: Bundle.main.preferredLocalizations.first ?? "unknown")
    var body: some View {
        WorkingForm {
            Section(helpText("Get help")) {
                Text(helpText("Describe the steps, what you expected and what happened. Leave out grocery details, budgets, names, receipts, sign-in codes and invitation links."))
                if let url = configuration.supportEmailURL, let address = configuration.supportEmailAddress {
                    Button {
                        openURL(url) { opened in
                            emailUnavailable = !opened
                            copiedAddress = false
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(helpText("Email support"))
                            Text(address)
                        }.frame(minHeight: 44)
                    }.accessibilityIdentifier("help.support.email")
                    if emailUnavailable {
                        Text(helpText("Couldn’t open an email app. Copy the address to use in another app."))
                        Button {
                            UIPasteboard.general.string = address
                            copiedAddress = true
                        } label: {
                            Label(helpText(copiedAddress ? "Email address copied" : "Copy email address"),
                                  systemImage: copiedAddress ? "checkmark" : "doc.on.doc")
                                .frame(minHeight: 44)
                        }.accessibilityIdentifier("help.support.copyEmail")
                    } else {
                        Text(helpText("Choose your email app and review the message before sending. No message is sent automatically."))
                    }
                }
                if let url = configuration.supportURL { Link(helpText("Open support"), destination: url).accessibilityIdentifier("help.support.open") }
                else if configuration.supportEmailURL == nil { Text(helpText("Online support is unavailable. You can read the help articles here or share your support summary.")) }
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
        }.navigationTitle(helpText("Support"))
    }
}

private struct AboutRoomInTheCartView: View {
    @State private var replay: BrandCartMotion.Cue?
    @State private var showingCaption = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BrandCartMotion(cue: replay, kind: .aboutReplay)
                    .frame(width: 144, height: 144)
                    .accessibilityHidden(true)
                Text(verbatim: "Room in the Cart")
                    .font(.system(.largeTitle, design: .serif).weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text(helpText("Version") + " " + version)
                        .foregroundStyle(Theme.secondary)
                }
                if reduceMotion {
                    DisclosureGroup(helpText("View cart illustration"), isExpanded: $showingCaption) {
                        Text(helpText("A pale pear rests behind the rim of a plum cart with two wheels."))
                    }
                    .disclosureGroupStyle(LabeledFormDisclosureStyle(label: helpText("View cart illustration"), identifier: "about.viewIllustration"))
                } else {
                    Button { replay = .init() } label: {
                        Label(helpText("Replay the pear"), systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(PrimaryAction())
                    .accessibilityIdentifier("about.replay")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .workingSurface()
        .navigationTitle(helpText("About"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(ht("Done")) { dismiss() }.accessibilityIdentifier("about.done")
            }
        }
        .onChange(of: phase) { _, value in if value != .active { replay = nil } }
        .onChange(of: reduceMotion) { _, value in if value { replay = nil } }
        .onDisappear { replay = nil }
    }
}
