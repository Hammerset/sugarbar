import HealthKit
import SugarbarCore

/// Mirrors each logged meal into Apple Health as a dietary-carbohydrate sample. The App Group store
/// stays the source of truth; a failed write never blocks the meal from being saved.
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
}
