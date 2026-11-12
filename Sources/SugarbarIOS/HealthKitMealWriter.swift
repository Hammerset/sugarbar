import HealthKit
import SugarbarCore

/// Mirrors each eaten Meal into Apple Health as dietary carbohydrate, plus fat, protein and energy when known, every
/// sample tagged with the Meal's id so edits and deletes can find them. The App Group store stays the source of truth;
/// a failed write never blocks the save.
struct HealthKitMealWriter {
    private let store = HKHealthStore()

    private static let types: [HKQuantityType] = [
        HKQuantityType(.dietaryCarbohydrates),
        HKQuantityType(.dietaryFatTotal),
        HKQuantityType(.dietaryProtein),
        HKQuantityType(.dietaryEnergyConsumed),
    ]

    func write(_ meal: Meal) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: Set(Self.types), read: [])
        let metadata = [HKMetadataKeyExternalUUID: meal.id.uuidString]
        let values: [(HKQuantityTypeIdentifier, HKUnit, Double?)] = [
            (.dietaryCarbohydrates, .gram(), meal.carbsGrams),
            (.dietaryFatTotal, .gram(), meal.fatGrams),
            (.dietaryProtein, .gram(), meal.proteinGrams),
            (.dietaryEnergyConsumed, .kilocalorie(), meal.energyKcal),
        ]
        let samples = values.compactMap { identifier, unit, value -> HKQuantitySample? in
            guard let value, value > 0 else { return nil }
            return HKQuantitySample(
                type: HKQuantityType(identifier),
                quantity: HKQuantity(unit: unit, doubleValue: value),
                start: meal.timestamp,
                end: meal.timestamp,
                metadata: metadata
            )
        }
        let carbs = samples.filter { $0.quantityType == HKQuantityType(.dietaryCarbohydrates) }
        try await store.save(carbs)
        // Fat, protein and energy are extras: a denied type must not undo the carbs.
        for sample in samples where !carbs.contains(sample) {
            try? await store.save(sample)
        }
    }

    /// HealthKit only lets an app delete samples it saved itself, so this never touches another app's entries.
    func delete(mealId: UUID) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: Set(Self.types), read: [])
        let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [mealId.uuidString])
        _ = try await store.deleteObjects(of: HKQuantityType(.dietaryCarbohydrates), predicate: predicate)
        for type in Self.types.dropFirst() {
            _ = try? await store.deleteObjects(of: type, predicate: predicate)
        }
    }
}
