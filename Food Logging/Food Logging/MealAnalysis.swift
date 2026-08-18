import Foundation

/// A transient request. Neither image is written to SwiftData or the photo library.
struct MealAnalysisInput {
    let description: String
    let mealPhotoData: Data?
    let nutritionLabelPhotoData: Data?
    let capturedAt: Date
    let timeZoneIdentifier: String

    init(
        description: String, mealPhotoData: Data?, nutritionLabelPhotoData: Data?, capturedAt: Date = .now, timeZoneIdentifier: String = TimeZone.current.identifier
    ) {
        self.description = description
        self.mealPhotoData = mealPhotoData
        self.nutritionLabelPhotoData = nutritionLabelPhotoData
        self.capturedAt = capturedAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

enum MealAnalysisError: LocalizedError {
    case needsTextOrPhoto
    case directAnalysisKeysRequired
    case noRecognizedFood
    case malformedServiceResponse

    var errorDescription: String? {
        switch self {
        case .needsTextOrPhoto:
            return "Add a description, a meal photo, or a nutrition-label photo to analyze a meal."
        case .directAnalysisKeysRequired:
            return "Add your OpenAI and USDA FoodData Central API keys in Settings to analyze photos directly from this iPhone."
        case .noRecognizedFood:
            return "I couldn’t match foods from that description. Try naming the main foods and portions, or add the nutrition-label photo."
        case .malformedServiceResponse:
            return "The food analysis service returned an unreadable meal estimate. Please try again."
        }
    }
}

/// Coordinates direct, on-device-originated analysis. The iPhone sends inputs to
/// OpenAI and USDA itself; keys stay in this device's Keychain.
struct MealAnalysisService {
    static let shared = MealAnalysisService()

    func analyze(_ input: MealAnalysisInput) async throws -> MealDraft {
        let trimmedDescription = input.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty || input.mealPhotoData != nil || input.nutritionLabelPhotoData != nil else {
            throw MealAnalysisError.needsTextOrPhoto
        }

        if let openAIKey = APIKeyStore.value(for: .openAI),
           let foodDataKey = APIKeyStore.value(for: .foodDataCentral),
           !openAIKey.isEmpty, !foodDataKey.isEmpty {
            return try await DirectMealAnalysis(openAIKey: openAIKey, foodDataKey: foodDataKey).analyze(input)
        }
        throw MealAnalysisError.directAnalysisKeysRequired
    }
}
