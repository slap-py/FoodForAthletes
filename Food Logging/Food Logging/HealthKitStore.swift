import Combine
import Foundation
import HealthKit

/// The small, in-memory HealthKit snapshot used by the Today experience.
/// HealthKit remains the source of truth; this app only reads today's workouts
/// and active energy and never writes health data.
struct HealthDaySnapshot: Equatable {
    var workouts: [HealthWorkout] = []
    var activeEnergyBurned: Double = 0
    var updatedAt: Date?
}

struct HealthWorkout: Identifiable, Equatable {
    let id: UUID
    let startDate: Date
    let endDate: Date
    let activityName: String

    nonisolated init(workout: HKWorkout) {
        id = workout.uuid
        startDate = workout.startDate
        endDate = workout.endDate
        activityName = Self.name(for: workout.workoutActivityType)
    }

    nonisolated private static func name(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: "Run"
        case .walking: "Walk"
        case .cycling: "Ride"
        case .swimming: "Swim"
        case .yoga: "Yoga"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "Strength workout"
        case .highIntensityIntervalTraining: "HIIT workout"
        case .hiking: "Hike"
        default: "Workout"
        }
    }
}

enum HealthConnectionState: Equatable {
    case unavailable
    case notRequested
    case loading
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .unavailable: "Unavailable on this device"
        case .notRequested: "Not connected"
        case .loading: "Connecting…"
        case .connected: "Connected"
        case .failed: "Couldn’t connect"
        }
    }
}

@MainActor
final class HealthKitStore: ObservableObject {
    @Published private(set) var snapshot = HealthDaySnapshot()
    @Published private(set) var connectionState: HealthConnectionState
    @Published private(set) var dataRefreshError: String?

    private let healthStore = HKHealthStore()
    private let authorizationRequestedKey = "healthKitAuthorizationRequested"

    init() {
        if !HKHealthStore.isHealthDataAvailable() {
            connectionState = .unavailable
        } else if UserDefaults.standard.bool(forKey: authorizationRequestedKey) {
            connectionState = .connected
        } else {
            connectionState = .notRequested
        }
    }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            connectionState = .unavailable
            return
        }

        connectionState = .loading
        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
            // HealthKit intentionally does not disclose individual read grants.
            // Save that the request was made and let a refresh reveal available data.
            UserDefaults.standard.set(true, forKey: authorizationRequestedKey)
            connectionState = .connected
            await refreshToday()
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    func refreshToday() async {
        guard HKHealthStore.isHealthDataAvailable(),
              UserDefaults.standard.bool(forKey: authorizationRequestedKey) else { return }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let end = Date.now

        do {
            async let workouts = fetchWorkouts(from: start, to: end)
            async let activeEnergy = fetchActiveEnergy(from: start, to: end)
            snapshot = HealthDaySnapshot(
                workouts: try await workouts,
                activeEnergyBurned: try await activeEnergy,
                updatedAt: .now
            )
            connectionState = .connected
            dataRefreshError = nil
        } catch {
            // A HealthKit read can fail because a specific data type is unavailable
            // or declined. That is not a failed authorization connection.
            dataRefreshError = error.localizedDescription
        }
    }

    private var readTypes: Set<HKObjectType> {
        guard let activeEnergy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) else {
            return [HKObjectType.workoutType()]
        }
        return [HKObjectType.workoutType(), activeEnergy]
    }

    private func fetchWorkouts(from start: Date, to end: Date) async throws -> [HealthWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKWorkout] ?? []).map(HealthWorkout.init))
                }
            }
            healthStore.execute(query)
        }
    }

    private func fetchActiveEnergy(from start: Date, to end: Date) async throws -> Double {
        guard let type = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) else { return 0 }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0)
                }
            }
            healthStore.execute(query)
        }
    }
}
