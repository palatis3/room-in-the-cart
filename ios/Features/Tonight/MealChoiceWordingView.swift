import HouseholdClient
import SwiftUI

@MainActor struct MealChoiceWordingLink: View {
  let refresh: () async -> Bool
  let makeSource: () throws -> MealChoiceSource
  @EnvironmentObject private var access: WorkspaceAccess
  @EnvironmentObject private var household: HouseholdModel
  @Environment(\.guardianChildCoordinator) private var child
  @Environment(\.scenePhase) private var scene
  @State private var opened: Session?
  @State private var starting = false
  private struct Session: Identifiable {
    let id = UUID()
    let identity: CapturePrivateIdentity
    let scope: ReceiptAssistanceScope
    let source: MealChoiceSource
  }
  private var identity: CapturePrivateIdentity? {
    guard scene == .active, UIApplication.shared.applicationState == .active,
      UIApplication.shared.isProtectedDataAvailable,
      child?.presented != true, !household.guardianChildOnly, household.projection?.grantId == nil,
      let identity = CapturePrivateIdentity.current(access: access, household: household),
      identity.subject != nil
    else { return nil }
    return identity
  }
  private var scope: ReceiptAssistanceScope? {
    guard let identity, let subject = identity.subject, let house = identity.householdID,
      let member = identity.memberID
    else { return nil }
    return .init(
      subject: subject, householdID: house, memberID: member, shopID: household.projection?.shopId)
  }
  var body: some View {
    if let identity, let scope, let service = household.service {
      Button(mealExplanationText("Choose a meal using my words")) {
        guard !starting else { return }
        starting = true
        Task { @MainActor in
          defer { starting = false }
          guard await refresh(), self.identity == identity, self.scope == scope,
            let source = try? makeSource(),
            source.isCurrent(), source.options.contains(where: \.shareable)
          else { return }
          opened = .init(identity: identity, scope: scope, source: source)
        }
      }.disabled(starting).accessibilityIdentifier("mealChoice.open")
        .sheet(item: $opened) { session in
          MealChoiceReviewView(
            source: session.source,
            authorized: { self.identity == session.identity && self.scope == session.scope },
            refresh: refresh,
            availability: {
              try await service.languageAssistanceAvailable(purpose: "meal-choice", scope: scope)
            },
            send: {
              try await service.languageSuggestion(
                purpose: "meal-choice", body: JSONEncoder().encode($0), scope: scope)
            })
        }
        .onChange(of: self.identity) { _, value in if opened?.identity != value { opened = nil } }
        .onChange(of: self.scope) { _, value in if opened?.scope != value { opened = nil } }
    }
  }
}

@MainActor struct MealChoiceReviewView: View {
  let source: MealChoiceSource
  let authorized: () -> Bool
  let refresh: () async -> Bool
  let availability: () async throws -> Bool
  let send: (MealChoiceWording.Payload) async throws -> MealChoiceWording.Reply
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @Environment(\.scenePhase) private var scene
  @State private var available: Bool?
  @State private var words = ""
  @State private var selected = Set<UUID>()
  @State private var result: MealChoiceWording.Option?
  @State private var task: Task<Void, Never>?
  @State private var token = UUID()
  @State private var busy = false
  @State private var message: String?
  private var cleaned: String { words.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var canSend: Bool {
    ReceiptLineAssistanceRequest.accepts(cleaned) && !selected.isEmpty && selected.count <= 8
  }
  private var active: Bool { scene == .active && authorized() }
  var body: some View {
    NavigationStack {
      Form {
        if active {
          if !source.isCurrent() {
            if busy {
              ProgressView()
            } else {
              Text(
                mealExplanationText(
                  "These choices have changed. Return to the current meal review."))
            }
          } else if available == true {
            Section(mealExplanationText("Words and titles to send to OpenAI")) {
              Text(
                mealExplanationText(
                  "Type what you want and select up to eight titles. Only your words, language and these titles with temporary references will be shared. Omit personal details."
                ))
              TextField(mealExplanationText("What would you like?"), text: $words).submitLabel(
                .done
              )
              .accessibilityIdentifier("mealChoice.words")
              ForEach(source.options.filter(\.shareable)) { option in
                Toggle(
                  option.title,
                  isOn: Binding(
                    get: { selected.contains(option.id) },
                    set: { checked in
                      if checked { selected.insert(option.id) } else { selected.remove(option.id) }
                    })
                ).disabled(!selected.contains(option.id) && selected.count >= 8)
                  .accessibilityIdentifier("mealChoice.title." + option.id.uuidString)
              }
              Button(mealExplanationText("Send these words and titles")) { request() }
                .disabled(!canSend || result != nil).accessibilityIdentifier("mealChoice.send")
            }.disabled(busy)
            if let result {
              Section(mealExplanationText("Suggested meal to review")) {
                Text(verbatim: result.title).accessibilityIdentifier("mealChoice.proposed")
                Text(
                  mealExplanationText(
                    "Review this choice with the current local quantities, holds and prices."))
                Button(mealExplanationText("Review this choice")) { adopt(result) }
                  .disabled(busy).accessibilityIdentifier("mealChoice.use")
              }
            }
            if busy { ProgressView() }
            if let message { Text(message) }
          } else if available == false {
            Text(
              mealExplanationText(
                "Online meal selection is unavailable. Choose directly in the meal list."))
          } else {
            ProgressView()
          }
        }
      }.navigationTitle(mealExplanationText("Choose from reviewed meals"))
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(mealExplanationText("Close")) {
              clear()
              dismiss()
            }
          }
        }
    }.privacySensitive()
      .task {
        guard active else { return }
        let ok = (try? await availability()) == true
        if !Task.isCancelled && active { available = ok }
      }
      .onChange(of: words) { _, _ in clear() }.onChange(of: selected) { _, _ in clear() }
      .onChange(of: active) { _, ok in
        if !ok {
          clear()
          dismiss()
        }
      }.onDisappear { clear() }
  }

  private func clear() {
    task?.cancel()
    task = nil
    token = UUID()
    busy = false
    result = nil
    message = nil
  }
  private func valid(_ operation: UUID) -> Bool {
    token == operation && !Task.isCancelled && active
  }
  private func current(_ operation: UUID) async -> Bool {
    guard valid(operation), await refresh(), valid(operation), source.isCurrent() else {
      return false
    }
    return true
  }
  private func request() {
    guard active, !busy, available == true, canSend,
      let review = try? MealChoiceWording(
        words: cleaned, locale: locale.language.languageCode?.identifier == "es" ? "es" : "en",
        eligible: source.options, selected: selected)
    else { return }
    clear()
    let operation = token
    busy = true
    task = Task { @MainActor in
      defer { if operation == token { busy = false } }
      do {
        guard await current(operation) else { throw ClientError.accessEnded }
        let reply = try await send(review.payload)
        guard await current(operation) else { throw ClientError.accessEnded }
        result = try review.resolve(reply)
        if result == nil {
          message = mealExplanationText("No title matched your wording. You can choose directly.")
        }
      } catch {
        if valid(operation) {
          result = nil
          message = mealExplanationText(
            "This suggestion could not be verified. Review the current meal choices.")
        }
      }
    }
  }
  private func adopt(_ option: MealChoiceWording.Option) {
    guard active, !busy, result == option else { return }
    let operation = token
    busy = true
    task = Task { @MainActor in
      defer { if operation == token { busy = false } }
      do {
        guard await current(operation), result == option else { throw ClientError.accessEnded }
        try source.select(option.id)
        dismiss()
      } catch {
        if valid(operation) {
          result = nil
          message = mealExplanationText(
            "This suggestion could not be verified. Review the current meal choices.")
        }
      }
    }
  }
}
