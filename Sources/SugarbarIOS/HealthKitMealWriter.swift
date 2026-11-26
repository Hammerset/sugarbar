import HealthKit
import SugarbarCore

enum HealthAccess: Sendable, Equatable {
    case unavailable
    case notDetermined
    case denied
    case allowed
}

/// Mirrors each eaten Meal into Apple Health as dietary carbohydrate, plus fat, protein and energy when known, every
/// sample tagged with the Meal's id so edits and deletes can find them. The App Group store stays the source of truth;
/// a failed write never blocks the save.
struct HealthKitMealWriter {
    private let store = HKHealthStore()

    private static let carbs = HKQuantityType(.dietaryCarbohydrates)
    private static let fields: [(type: HKQuantityType, unit: HKUnit, amount: @Sendable (Meal) -> Double?)] = [
        (carbs, .gram(), { $0.carbsGrams }),
        (HKQuantityType(.dietaryFatTotal), .gram(), { $0.fatGrams }),
        (HKQuantityType(.dietaryProtein), .gram(), { $0.proteinGrams }),
        (HKQuantityType(.dietaryEnergyConsumed), .kilocalorie(), { $0.energyKcal }),
    ]
    static let shareTypes = Set(fields.map { $0.type as HKSampleType })

    /// Carbs decide it: fat, protein and energy are extras the owner may switch off on their own.
    var access: HealthAccess {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        switch store.authorizationStatus(for: Self.carbs) {
        case .sharingAuthorized: return .allowed
        case .sharingDenied: return .denied
        default: return .notDetermined
        }
    }

    /// Re-requesting whenever any type is undetermined is how iOS shows the sheet for a newly added type. The sheet
    /// can't appear while the app is in the background, so access can still come back undetermined.
    func authorize() async -> HealthAccess {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        if Self.shareTypes.contains(where: { store.authorizationStatus(for: $0) == .notDetermined }) {
            try? await store.requestAuthorization(toShare: Self.shareTypes, read: [])
        }
        return access
    }

    /// Call only once `authorize()` returned `.allowed`; types the owner switched off are skipped.
    func write(_ meal: Meal) async throws {
        let metadata = [HKMetadataKeyExternalUUID: meal.id.uuidString]
        let samples = Self.fields.compactMap { type, unit, amountOf -> HKQuantitySample? in
            guard isAllowed(type), let amount = amountOf(meal), amount > 0 else { return nil }
            return HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: amount),
                start: meal.timestamp,
                end: meal.timestamp,
                metadata: metadata
            )
        }
        let carbs = samples.filter { $0.quantityType == Self.carbs }
        try await store.save(carbs)
        for sample in samples where sample.quantityType != Self.carbs {
            try? await store.save(sample)
        }
    }

    /// HealthKit only lets an app delete samples it saved itself, so this never touches another app's entries.
    func delete(mealId: UUID) async throws {
        let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [mealId.uuidString])
        _ = try await store.deleteObjects(of: Self.carbs, predicate: predicate)
        for (type, _, _) in Self.fields where type != Self.carbs && isAllowed(type) {
            _ = try? await store.deleteObjects(of: type, predicate: predicate)
        }
    }

    private func isAllowed(_ type: HKQuantityType) -> Bool {
        store.authorizationStatus(for: type) == .sharingAuthorized
    }
}
