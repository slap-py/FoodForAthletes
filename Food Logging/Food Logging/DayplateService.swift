import Foundation

enum DayplateServiceError: LocalizedError {
    case notConfigured
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This build is missing its Dayplate service URL. Configure DAYPLATE_SERVICE_URL before distributing the app."
        case .invalidResponse:
            return "The Dayplate service returned an unreadable response. Please try again."
        case .server(let message):
            return message
        }
    }
}

struct DayplateService {
    static let shared = DayplateService()

    private var baseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "DayplateServiceURL") as? String,
              !value.isEmpty, !value.contains("$("), let url = URL(string: value) else { return nil }
        return url
    }

    func searchFoods(query: String) async throws -> [CatalogFood] {
        guard let baseURL else { throw DayplateServiceError.notConfigured }
        var components = URLComponents(url: baseURL.appending(path: "/v1/foods/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validate(response, data: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let result = try? decoder.decode(FoodSearchResponse.self, from: data) else { throw DayplateServiceError.invalidResponse }
        return result.foods
    }

    func analyze(_ input: MealAnalysisInput) async throws -> MealDraft {
        guard let baseURL else { throw DayplateServiceError.notConfigured }
        var request = URLRequest(url: baseURL.appending(path: "/v1/meal-analysis"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RemoteMealRequest(input: input))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        guard let result = try? JSONDecoder().decode(RemoteMealDraft.self, from: data) else { throw DayplateServiceError.invalidResponse }
        return result.mealDraft
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw DayplateServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ServiceError.self, from: data).error) ?? "The Dayplate service could not complete the request."
            throw DayplateServiceError.server(message)
        }
    }
}

private struct FoodSearchResponse: Decodable { let foods: [CatalogFood] }
private struct ServiceError: Decodable { let error: String }

private struct RemoteMealRequest: Encodable {
    let description: String
    let mealPhotoBase64: String?
    let nutritionLabelPhotoBase64: String?
    let capturedAt: String
    let timeZoneIdentifier: String

    init(input: MealAnalysisInput) {
        description = input.description
        mealPhotoBase64 = input.mealPhotoData?.base64EncodedString()
        nutritionLabelPhotoBase64 = input.nutritionLabelPhotoData?.base64EncodedString()
        capturedAt = ISO8601DateFormatter().string(from: input.capturedAt)
        timeZoneIdentifier = input.timeZoneIdentifier
    }
}

private struct RemoteMealDraft: Decodable {
    struct Food: Decodable { let name: String; let portion: String }
    let title: String
    let calories: Double
    let carbohydrates: Double
    let protein: Double
    let fat: Double
    let fiber: Double
    let calcium: Double
    let iron: Double
    let magnesium: Double
    let potassium: Double
    let sodium: Double
    let vitaminD: Double
    let assumptions: String
    let foods: [Food]
    let analysisVersion: String
    let catalogVersion: String

    var mealDraft: MealDraft {
        MealDraft(title: title, calories: calories, carbohydrates: carbohydrates, protein: protein, fat: fat, fiber: fiber, calcium: calcium, iron: iron, magnesium: magnesium, potassium: potassium, sodium: sodium, vitaminD: vitaminD, assumptions: assumptions, foods: foods.map { ($0.name, $0.portion) }, analysisVersion: analysisVersion, catalogVersion: catalogVersion)
    }
}
