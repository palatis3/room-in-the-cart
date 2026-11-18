import CoreDomain
import Foundation
import HouseholdClient

/// Titles and a single note leave the device. UUIDs sent for candidates exist only for this request.
struct MealChoiceWording {
  struct Option: Identifiable, Equatable {
    let id: UUID
    let title: String
    var shareable: Bool {
      !title.isEmpty && title == title.trimmingCharacters(in: .whitespacesAndNewlines)
        && title.utf16.count <= 200 && title.utf8.count <= 512
        && title.rangeOfCharacter(from: .controlCharacters) == nil
    }
  }
  struct Payload: Encodable, Sendable {
    struct Candidate: Encodable, Sendable {
      let id: UUID
      let title: String
    }
    let version: Int
    let requestID: UUID
    let issuedAt: Int64
    let consent: Bool
    let locale: String
    let sourceLines: [LanguageSourceLine]
    let candidates: [Candidate]
  }
  struct Reply: Decodable, Sendable {
    let version: Int
    let requestID: UUID
    let candidateID: UUID?
    private enum CodingKeys: String, CodingKey { case version, requestID, candidateID }
    private struct Field: CodingKey {
      let stringValue: String
      init?(stringValue: String) { self.stringValue = stringValue }
      var intValue: Int? { nil }
      init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
      let names = try decoder.container(keyedBy: Field.self).allKeys.map(\.stringValue)
      guard Set(names) == ["version", "requestID", "candidateID"] else {
        throw ClientError.invalidResponse
      }
      let values = try decoder.container(keyedBy: CodingKeys.self)
      version = try values.decode(Int.self, forKey: .version)
      requestID = try values.decode(UUID.self, forKey: .requestID)
      guard values.contains(.candidateID) else { throw ClientError.invalidResponse }
      candidateID = try values.decodeIfPresent(UUID.self, forKey: .candidateID)
    }
  }
  let payload: Payload
  private let local: [UUID: Option]

  init(words: String, locale: String, eligible: [Option], selected: Set<UUID>) throws {
    let input = try LanguageAssistanceRequest(
      consentingTo: [.init(id: UUID(), text: words)], locale: locale)
    let chosen = eligible.filter { selected.contains($0.id) }
    guard (1...8).contains(chosen.count), chosen.count == selected.count,
      Set(chosen.map(\.id)) == selected, chosen.allSatisfy(\.shareable)
    else { throw ClientError.invalidResponse }
    let candidates = chosen.map { Payload.Candidate(id: UUID(), title: $0.title) }
    local = Dictionary(uniqueKeysWithValues: zip(candidates.map(\.id), chosen))
    payload = .init(
      version: input.version, requestID: input.requestID, issuedAt: input.issuedAt,
      consent: input.consent,
      locale: input.locale, sourceLines: input.sourceLines, candidates: candidates)
  }

  func resolve(_ reply: Reply) throws -> Option? {
    guard reply.version == 1, reply.requestID == payload.requestID else {
      throw ClientError.invalidResponse
    }
    guard let id = reply.candidateID else { return nil }
    guard let value = local[id] else { throw ClientError.invalidResponse }
    return value
  }
}

@MainActor struct MealChoiceSource {
  let options: [MealChoiceWording.Option]
  let isCurrent: () -> Bool
  let select: (UUID) throws -> Void
}

extension MealChoiceSource {
  static func tonight(
    _ model: TonightMealModel, ledgerID: UUID, following: Bool,
    authorized: @escaping () -> Bool, choose: @escaping (PantryMealMatcher.Review) -> Void
  ) throws -> Self {
    let snapshot = try TonightExplanationModel.Snapshot(model: model, ledgerID: ledgerID)
    let first = model.firstRecipeID
    let batch = model.batch
    func options() -> [PantryMealMatcher.Review] {
      (following ? model.followingMeals : model.suggestions).filter {
        TonightMealModel.canChoose($0) && (batch == nil || $0.batchUse?.lotID == batch?.lotID)
      }
    }
    let offered = options()
    func valid() -> Bool {
      authorized() && model.firstRecipeID == first && model.batch == batch
        && snapshot.isCurrent(in: model) && options() == offered
    }
    return .init(
      options: offered.map { .init(id: $0.id, title: $0.recipe.title) }, isCurrent: valid
    ) { id in
      guard valid(), let choice = offered.first(where: { $0.id == id }) else {
        throw TonightMealModel.Failure.stale
      }
      choose(choice)
    }
  }

  static func swap(
    _ model: DinnerFeatureModel, pickup: PickupModel, occurrence: UUID, group: UUID?,
    displayed: [DinnerSwapOption], authorized: @escaping () -> Bool,
    choose: @escaping (UUID) -> Void
  ) throws -> Self {
    let initial = try model.swapOptions(occurrenceID: occurrence, groupID: group, pickup: pickup)
    let journey = pickup.journey
    let eligible = initial.filter(\.canChoose)
    guard authorized(), initial == displayed, !eligible.isEmpty else {
      throw DinnerPlanningError.stalePreview
    }
    func valid() -> Bool {
      authorized() && pickup.journey == journey
        && (try? model.swapOptions(occurrenceID: occurrence, groupID: group, pickup: pickup))
          == initial
    }
    return .init(options: eligible.map { .init(id: $0.id, title: $0.title) }, isCurrent: valid) {
      id in
      guard valid(), eligible.contains(where: { $0.id == id }) else {
        throw DinnerPlanningError.stalePreview
      }
      choose(id)
    }
  }
}
