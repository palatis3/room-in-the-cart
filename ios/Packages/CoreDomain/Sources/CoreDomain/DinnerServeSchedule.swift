import Foundation

/// Dishes run in parallel. Steps within a dish follow the cook's listed order.
public struct DinnerServeSchedule: Codable, Equatable, Sendable, Identifiable {
    public enum Equipment: String, Codable, CaseIterable, Sendable {
        case none, oven, burner, microwave
    }

    public struct Step: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public var instruction: String
        public var minutes: Int
        public var equipment: Equipment

        public init(id: UUID = UUID(), instruction: String = "", minutes: Int = 10, equipment: Equipment = .none) {
            self.id = id
            self.instruction = instruction
            self.minutes = minutes
            self.equipment = equipment
        }
    }

    public struct Dish: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public var name: String
        public var steps: [Step]

        public init(id: UUID = UUID(), name: String = "", steps: [Step] = [.init()]) {
            self.id = id
            self.name = name
            self.steps = steps
        }
    }

    public struct Slot: Equatable, Sendable, Identifiable {
        public var id: UUID { step.id }
        public let dish: String
        public let step: Step
        public let start: Date
        public let end: Date
    }

    public let id: UUID
    public let shopID: UUID
    public let occurrenceID: UUID
    public var dinnerDay: MealDay
    public var serveAt: Date
    public var availableMinutes: Int
    public var dishes: [Dish]

    public init(id: UUID = UUID(), shopID: UUID, occurrenceID: UUID, dinnerDay: MealDay,
                serveAt: Date, availableMinutes: Int = 90, dishes: [Dish]) {
        self.id = id
        self.shopID = shopID
        self.occurrenceID = occurrenceID
        self.dinnerDay = dinnerDay
        self.serveAt = serveAt
        self.availableMinutes = availableMinutes
        self.dishes = dishes
    }

    public var earliestStart: Date { serveAt.addingTimeInterval(-Double(availableMinutes) * 60) }

    public func pendingSteps(for meal: MealOccurrence, now: Date) -> [Slot] {
        guard meal.id == occurrenceID, !meal.isHidden, meal.removedAt == nil, meal.scheduledDay == dinnerDay,
              let slots = try? sequence() else { return [] }
        return slots.filter { $0.start > now }
    }

    public func sequence() throws -> [Slot] {
        try dinnerDay.validate()
        guard (1...1440).contains(availableMinutes), (1...12).contains(dishes.count),
              serveAt.timeIntervalSinceReferenceDate.isFinite,
              try MealDay(date: serveAt, timeZoneIdentifier: dinnerDay.timeZoneIdentifier) == dinnerDay,
              Set(dishes.map(\.id)).count == dishes.count else { throw DinnerPlanningError.invalid("serveTime") }
        var remaining = [Int]()
        var ids = Set<UUID>()
        for dish in dishes {
            guard !dish.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, dish.name.utf8.count <= 256,
                  (1...12).contains(dish.steps.count) else { throw DinnerPlanningError.invalid("dish") }
            for step in dish.steps {
                guard ids.insert(step.id).inserted, !step.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      step.instruction.utf8.count <= 512, (1...720).contains(step.minutes)
                else { throw DinnerPlanningError.invalid("prepStep") }
            }
            remaining.append(dish.steps.count)
        }
        var deadlines = Array(repeating: serveAt, count: dishes.count)
        var slots: [Slot] = []
        var booked: [Equipment: [Slot]] = [:]
        // Work back from the latest unfinished dish, breaking ties by input order.
        while let index = dishes.indices.filter({ remaining[$0] > 0 }).max(by: { deadlines[$0] < deadlines[$1] }) {
            remaining[index] -= 1
            let dish = dishes[index]
            let step = dish.steps[remaining[index]]
            let duration = Double(step.minutes) * 60
            var end = deadlines[index]
            if step.equipment != .none {
                for busy in booked[step.equipment, default: []].sorted(by: { $0.end > $1.end }) {
                    if busy.start < end && busy.end > end.addingTimeInterval(-duration) { end = busy.start }
                }
            }
            let slot = Slot(dish: dish.name, step: step, start: end.addingTimeInterval(-duration), end: end)
            if step.equipment != .none { booked[step.equipment, default: []].append(slot) }
            slots.append(slot)
            deadlines[index] = slot.start
        }
        return slots.sorted { ($0.start, $0.end, $0.id.uuidString) < ($1.start, $1.end, $1.id.uuidString) }
    }
}

/// Keep the legacy array encoding until a schedule is present. An older reader
/// rejects the versioned object before it can drop schedules in a later save.
public struct DinnerPrepRecords: Codable, Equatable, Sendable {
    public var tasks: [DinnerPrepTask]
    public var schedules: [DinnerServeSchedule]

    public init?(tasks: [DinnerPrepTask], schedules: [DinnerServeSchedule]) {
        guard !tasks.isEmpty || !schedules.isEmpty else { return nil }
        self.tasks = tasks
        self.schedules = schedules
    }

    private struct Versioned: Codable {
        let version: Int
        let tasks: [DinnerPrepTask]
        let schedules: [DinnerServeSchedule]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if (try? decoder.unkeyedContainer()) != nil {
            tasks = try container.decode([DinnerPrepTask].self)
            schedules = []
        } else {
            let records = try container.decode(Versioned.self)
            guard records.version == 2 else { throw DinnerPlanningError.invalid("prepVersion") }
            tasks = records.tasks
            schedules = records.schedules
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if schedules.isEmpty {
            try container.encode(tasks)
        } else {
            try container.encode(Versioned(version: 2, tasks: tasks, schedules: schedules))
        }
    }
}
