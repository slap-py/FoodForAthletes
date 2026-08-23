import Foundation

/// A transient request. Photos are never written to the meal history or photo library.
struct MealAnalysisInput {
    let description: String
    let photoData: [Data]
    let identifiedFoods: [String]
    let capturedAt: Date
    let timeZoneIdentifier: String
    let allowsClarification: Bool
    let clarificationAnswers: [String: String]
    let clarificationRound: Int

    init(
        description: String,
        photoData: [Data],
        identifiedFoods: [String] = [],
        capturedAt: Date = .now,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        allowsClarification: Bool = false,
        clarificationAnswers: [String: String] = [:],
        clarificationRound: Int = 0
    ) {
        self.description = description
        self.photoData = Array(photoData.prefix(3))
        self.identifiedFoods = Array(identifiedFoods.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(12))
        self.capturedAt = capturedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.allowsClarification = allowsClarification
        self.clarificationAnswers = clarificationAnswers
        self.clarificationRound = min(2, max(0, clarificationRound))
    }
}

struct MealClarification: Equatable, Codable, Identifiable {
    struct Option: Equatable, Codable, Identifiable {
        let id: String
        let label: String
        let value: String
        let action: String
    }

    let id: String
    let prompt: String
    let detail: String
    let options: [Option]
}

enum MealAnalysisError: LocalizedError {
    case needsTextOrPhoto
    case noRecognizedFood
    case malformedServiceResponse

    var errorDescription: String? {
        switch self {
        case .needsTextOrPhoto:
            return "Add a description, a meal photo, or a nutrition-label photo to analyze a meal."
        case .noRecognizedFood:
            return "I couldn’t match foods from that description. Try naming the main foods and portions, or add the nutrition-label photo."
        case .malformedServiceResponse:
            return "The food analysis service returned an unreadable meal estimate. Please try again."
        }
    }
}

/// Coordinates service-backed analysis. Provider credentials never ship in the app.
struct MealAnalysisService {
    static let shared = MealAnalysisService()

    func analyze(_ input: MealAnalysisInput) async throws -> MealDraft {
        let trimmedDescription = input.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty || !input.photoData.isEmpty else {
            throw MealAnalysisError.needsTextOrPhoto
        }

        return try await DayplateService.shared.analyze(input)
    }

}
