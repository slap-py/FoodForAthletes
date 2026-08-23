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
        case .server("route_not_found"):
            return "This app is connected to an older Dayplate service. Deploy the current catalog service, then try again."
        case .server("service_not_configured"):
            return "Voice transcription is not configured on the Dayplate service yet."
        case .server("analysis_timed_out"):
            return "Nutrition lookup took too long. Your meal is still saved, and you can try it again when you're ready."
        case .server("no_recognized_food"):
            return "No food could be identified from this entry. Add a food name or a clearer photo, then try again."
        case .server(let message) where message.hasPrefix("No trustworthy nutrition source found"):
            return "Nutrition facts couldn't be verified for one of the foods. Your meal is still saved; edit the description with a brand or product name and try again."
        case .server(let message) where message.hasPrefix("nutrition_verification_failed"):
            return "The nutrition sources disagreed about the serving size, so Dayplate did not save uncertain numbers. Your meal is still saved and can be retried."
        case .server(let message):
            return message.replacingOccurrences(of: "_", with: " ")
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

    func transcribe(audioData: Data, mimeType: String = "audio/m4a") async throws -> String {
        guard let baseURL else { throw DayplateServiceError.notConfigured }
        var request = URLRequest(url: baseURL.appending(path: "/v1/transcribe"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TranscriptionRequest(audioBase64: audioData.base64EncodedString(), mimeType: mimeType))
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        guard let result = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else { throw DayplateServiceError.invalidResponse }
        return result.text
    }

    func detectFoods(photoData: Data) async throws -> [String] {
        guard let baseURL else { throw DayplateServiceError.notConfigured }
        var request = URLRequest(url: baseURL.appending(path: "/v1/photo-foods"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PhotoFoodsRequest(photoBase64: photoData.base64EncodedString()))
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        guard let result = try? JSONDecoder().decode(PhotoFoodsResponse.self, from: data) else {
            throw DayplateServiceError.invalidResponse
        }
        return result.foods
    }

    func analyze(_ input: MealAnalysisInput) async throws -> MealDraft {
        guard let baseURL else { throw DayplateServiceError.notConfigured }
        var request = URLRequest(url: baseURL.appending(path: "/v1/meal-analysis"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RemoteMealRequest(input: input))
        // Analysis is idempotent. Give a transient gateway or provider failure
        // one bounded retry before the durable on-device queue takes over.
        let (data, response) = try await perform(request, timeout: 110, retryTimeouts: true, maxAttempts: 2)
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

    private func perform(
        _ originalRequest: URLRequest,
        timeout: TimeInterval = 60,
        retryTimeouts: Bool = true,
        maxAttempts: Int = 3
    ) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: attempt == 1 ? 300_000_000 : 900_000_000)
            }
            var request = originalRequest
            request.timeoutInterval = timeout
            do {
                let result = try await URLSession.shared.data(for: request)
                if let http = result.1 as? HTTPURLResponse,
                   http.statusCode == 429 || (500..<600).contains(http.statusCode) {
                    lastError = DayplateServiceError.server(
                        (try? JSONDecoder().decode(ServiceError.self, from: result.0).error)
                            ?? "The Dayplate service is temporarily unavailable."
                    )
                    continue
                }
                return result
            } catch {
                lastError = error
                guard let code = (error as? URLError)?.code else { throw error }
                let retryable: [URLError.Code] = retryTimeouts
                    ? [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed]
                    : [.networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed]
                guard retryable.contains(code) else {
                    throw error
                }
            }
        }
        throw lastError ?? DayplateServiceError.invalidResponse
    }
}

private struct ServiceError: Decodable { let error: String }

private struct RemoteMealRequest: Encodable {
    let description: String
    let photosBase64: [String]
    let identifiedFoods: [String]
    let capturedAt: String
    let timeZoneIdentifier: String
    let allowClarifications: Bool
    let clarificationAnswers: [String: String]
    let clarificationRound: Int

    init(input: MealAnalysisInput) {
        description = input.description
        photosBase64 = input.photoData.map { $0.base64EncodedString() }
        identifiedFoods = input.identifiedFoods
        capturedAt = ISO8601DateFormatter().string(from: input.capturedAt)
        timeZoneIdentifier = input.timeZoneIdentifier
        allowClarifications = input.allowsClarification
        clarificationAnswers = input.clarificationAnswers
        clarificationRound = input.clarificationRound
    }
}

private struct TranscriptionRequest: Encodable { let audioBase64: String; let mimeType: String }
private struct TranscriptionResponse: Decodable { let text: String }
private struct PhotoFoodsRequest: Encodable { let photoBase64: String }
private struct PhotoFoodsResponse: Decodable { let foods: [String] }
private struct RemoteMealDraft: Decodable {
    struct Food: Decodable {
        let name: String
        let portion: String
        let sourceName: String?
        let sourceTier: NutritionSourceTier?
    }
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
    let clarifications: [MealClarification]?
    let analysisVersion: String
    let catalogVersion: String

    var mealDraft: MealDraft {
        MealDraft(
            title: title,
            calories: calories,
            carbohydrates: carbohydrates,
            protein: protein,
            fat: fat,
            fiber: fiber,
            calcium: calcium,
            iron: iron,
            magnesium: magnesium,
            potassium: potassium,
            sodium: sodium,
            vitaminD: vitaminD,
            assumptions: assumptions,
            foods: foods.map { MealDraftFood(name: $0.name, portion: $0.portion, sourceName: $0.sourceName, sourceTier: $0.sourceTier) },
            clarifications: clarifications ?? [],
            analysisVersion: analysisVersion,
            catalogVersion: catalogVersion
        )
    }
}
