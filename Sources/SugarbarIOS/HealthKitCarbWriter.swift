import HealthKit
import SugarbarCore

/// Mirrors each logged meal into Apple Health as a dietary-carbohydrate sample, tagged with the Meal's id so
/// edits and deletes can find it. The App Group store stays the source of truth; a failed write never blocks the save.
struct HealthKitCarbWriter {
    private let store = HKHealthStore()

    func write(_ meal: Meal) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let type = HKQuantityType(.dietaryCarbohydrates)
        try await store.requestAuthorization(toShare: [type], read: [])
        let sample = HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: .gram(), doubleValue: meal.carbsGrams),
            start: meal.timestamp,
            end: meal.timestamp,
            metadata: [HKMetadataKeyExternalUUID: meal.id.uuidString]
        )
        try await store.save(sample)
    }

    /// HealthKit only lets an app delete samples it saved itself, so this never touches another app's carbs.
    func delete(mealId: UUID) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let type = HKQuantityType(.dietaryCarbohydrates)
        try await store.requestAuthorization(toShare: [type], read: [])
        let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [mealId.uuidString])
        _ = try await store.deleteObjects(of: type, predicate: predicate)
    }
}
