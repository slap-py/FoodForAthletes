import Foundation

enum DirectMealAnalysisError: LocalizedError {
    case missingKeys
    case malformedResponse
    case unrecognizedMeal

    var errorDescription: String? {
        switch self {
        case .missingKeys: return "Add your OpenAI and USDA FoodData Central API keys in Settings to analyze photos directly from this iPhone."
        case .malformedResponse: return "The AI returned an incomplete meal estimate. Please try again."
        case .unrecognizedMeal: return "The meal could not be matched to nutrition data. Try a clearer photo or add a short description."
        }
    }
}

struct DirectMealAnalysis {
    private let openAIKey: String
    private let foodDataKey: String

    init(openAIKey: String, foodDataKey: String) {
        self.openAIKey = openAIKey
        self.foodDataKey = foodDataKey
    }

    func analyze(_ input: MealAnalysisInput) async throws -> MealDraft {
        var requestInput: [Any] = [["role": "user", "content": visionContent(for: input)]]
        for _ in 0..<4 {
            let response = try await openAIResponse(input: requestInput)
            let output = response["output"] as? [[String: Any]] ?? []
            let calls = output.filter { ($0["type"] as? String) == "function_call" }
            if calls.isEmpty {
                guard let outputText = response["output_text"] as? String,
                      let data = outputText.data(using: .utf8) else { throw DirectMealAnalysisError.malformedResponse }
                let modelMeal = try JSONDecoder().decode(ModelMeal.self, from: data)
                return try await makeDraft(from: modelMeal)
            }

            requestInput.append(contentsOf: output)
            for call in calls {
                guard let callID = call["call_id"] as? String,
                      let arguments = call["arguments"] as? String,
                      let query = try? JSONDecoder().decode(CatalogQuery.self, from: Data(arguments.utf8)).query else { continue }
                let matches = try await searchCatalog(query)
                let encoded = try JSONEncoder().encode(matches)
                requestInput.append([
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": String(decoding: encoded, as: UTF8.self)
                ])
            }
        }
        throw DirectMealAnalysisError.malformedResponse
    }

    private func visionContent(for input: MealAnalysisInput) -> [Any] {
        var content: [Any] = [["type": "input_text", "text": "Meal description: \(input.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(none)" : input.description)\nCaptured at: \(ISO8601DateFormatter().string(from: input.capturedAt)) (\(input.timeZoneIdentifier))"]]
        if let photo = input.mealPhotoData {
            content.append(["type": "input_text", "text": "MEAL PHOTO — identify visible foods, preparation, and portions."])
            content.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(photo.base64EncodedString())", "detail": "high"])
        }
        if let label = input.nutritionLabelPhotoData {
            content.append(["type": "input_text", "text": "NUTRITION-LABEL PHOTO — visually read the Nutrition Facts panel accurately, including Calories."])
            content.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(label.base64EncodedString())", "detail": "original"])
        }
        return content
    }

    private func openAIResponse(input: [Any]) async throws -> [String: Any] {
        let body: [String: Any] = [
            "model": "gpt-5.6-terra",
            "reasoning": ["effort": "low"],
            "store": false,
            "instructions": Self.instructions,
            "tools": [Self.catalogTool],
            "input": input,
            "text": ["format": ["type": "json_schema", "name": "meal_analysis", "strict": true, "schema": Self.outputSchema]]
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return json
    }

    private func searchCatalog(_ query: String) async throws -> [CatalogMatch] {
        DayplateCatalog.search(query).prefix(8).compactMap { food in
            guard let sourceID = food.provenance.first?.sourceID, let fdcID = Int(sourceID) else { return nil }
            return CatalogMatch(fdcId: fdcID, name: food.canonicalName, category: food.sourceSummary)
        }
    }

    private func foodDetail(_ fdcID: Int) async throws -> FDCFood {
        let escaped = foodDataKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? foodDataKey
        let url = URL(string: "https://api.nal.usda.gov/fdc/v1/food/\(fdcID)?api_key=\(escaped)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(FDCFood.self, from: data)
    }

    private func makeDraft(from result: ModelMeal) async throws -> MealDraft {
        let items = result.items.filter { $0.grams > 0 && $0.grams <= 5_000 }.prefix(12)
        if let label = result.labelNutrition {
            let multiplier = min(max(label.servingMultiplier, 0.05), 20)
            let foods = try await itemNames(Array(items))
            return MealDraft(title: result.title, calories: label.calories * multiplier, carbohydrates: label.carbohydrates * multiplier, protein: label.protein * multiplier, fat: label.fat * multiplier, fiber: label.fiber * multiplier, calcium: label.calcium * multiplier, iron: label.iron * multiplier, magnesium: label.magnesium * multiplier, potassium: label.potassium * multiplier, sodium: label.sodium * multiplier, vitaminD: label.vitaminD * multiplier, assumptions: result.assumptions.joined(separator: " "), foods: foods, analysisVersion: "gpt-5.6-terra-direct-v1", catalogVersion: "OpenAI vision Nutrition Facts extraction")
        }
        guard !items.isEmpty else { throw DirectMealAnalysisError.unrecognizedMeal }
        let records = try await withThrowingTaskGroup(of: (RecognizedItem, FDCFood).self) { group in
            for item in items { group.addTask { (item, try await foodDetail(item.fdcId)) } }
            return try await group.reduce(into: [(RecognizedItem, FDCFood)]()) { $0.append($1) }
        }
        var total = NutrientSnapshot()
        for (item, food) in records { total.add(food.nutrients, scale: item.grams / 100) }
        guard total.hasMacros else { throw DirectMealAnalysisError.unrecognizedMeal }
        let foods = records.map { (name: $0.1.description ?? "USDA food", portion: $0.0.portion.isEmpty ? "\(Int($0.0.grams.rounded())) g" : $0.0.portion) }
        return MealDraft(title: result.title, calories: total.calories, carbohydrates: total.carbohydrates, protein: total.protein, fat: total.fat, fiber: total.fiber, calcium: total.calcium, iron: total.iron, magnesium: total.magnesium, potassium: total.potassium, sodium: total.sodium, vitaminD: total.vitaminD, assumptions: result.assumptions.joined(separator: " "), foods: foods, analysisVersion: "gpt-5.6-terra-direct-v1", catalogVersion: "USDA FoodData Central")
    }

    private func itemNames(_ items: [RecognizedItem]) async throws -> [(name: String, portion: String)] {
        try await withThrowingTaskGroup(of: (name: String, portion: String).self) { group in
            for item in items { group.addTask { let food = try await foodDetail(item.fdcId); return (food.description ?? "Nutrition-label food", item.portion.isEmpty ? "\(Int(item.grams.rounded())) g" : item.portion) } }
            return try await group.reduce(into: [(name: String, portion: String)]()) { $0.append($1) }
        }
    }

    private static let instructions = """
    Analyze one meal using the user's description plus the optional meal photograph and Nutrition Facts photograph. Use both supplied images as evidence for the same meal. The meal photo identifies foods, preparation, and portions. The nutrition-label photo is read visually by you; accurately copy every Nutrition Facts value, especially Calories.
    Call search_catalog for every food or common dish before choosing an fdcId. Never invent an fdcId. For labelNutrition, provide the label's values per listed serving and a servingMultiplier for the amount actually eaten. If no label photo exists, return labelNutrition as null. Do not calculate totals for non-label foods; the app calculates them from the selected USDA records.
    Set title to a concise, properly capitalized meal name, ideally no more than six words. Preserve a stated quantity for a single item (for example, "1 Uncrustable"). For a complete meal, name the meal naturally and briefly. Do not add labels such as "Meal:" or explanation to title.
    """

    private static let catalogTool: [String: Any] = ["type": "function", "name": "search_catalog", "description": "Search USDA FoodData Central for a food or common dish before selecting an fdcId.", "strict": true, "parameters": ["type": "object", "additionalProperties": false, "properties": ["query": ["type": "string"]], "required": ["query"]]]
    private static let outputSchema: [String: Any] = ["type": "object", "additionalProperties": false, "properties": ["title": ["type": "string"], "items": ["type": "array", "items": ["type": "object", "additionalProperties": false, "properties": ["fdcId": ["type": "integer"], "grams": ["type": "number"], "portion": ["type": "string"]], "required": ["fdcId", "grams", "portion"]]], "labelNutrition": ["type": ["object", "null"], "properties": ["servingMultiplier": ["type": "number"], "calories": ["type": "number"], "carbohydrates": ["type": "number"], "protein": ["type": "number"], "fat": ["type": "number"], "fiber": ["type": "number"], "calcium": ["type": "number"], "iron": ["type": "number"], "magnesium": ["type": "number"], "potassium": ["type": "number"], "sodium": ["type": "number"], "vitaminD": ["type": "number"]], "required": ["servingMultiplier", "calories", "carbohydrates", "protein", "fat", "fiber", "calcium", "iron", "magnesium", "potassium", "sodium", "vitaminD"], "additionalProperties": false], "assumptions": ["type": "array", "items": ["type": "string"]]], "required": ["title", "items", "labelNutrition", "assumptions"]]
}

private struct CatalogQuery: Decodable { let query: String }
private struct CatalogMatch: Codable { let fdcId: Int; let name: String; let category: String }
private struct FDCFood: Decodable {
    let description: String?
    let foodNutrients: [FDCNutrient]?
    var nutrients: NutrientSnapshot { NutrientSnapshot(foodNutrients ?? []) }
}
private struct FDCNutrient: Decodable { let amount: Double?; let value: Double?; let nutrient: NutrientName?; let nutrientName: String?; struct NutrientName: Decodable { let name: String?; let unitName: String? } }
private struct RecognizedItem: Decodable { let fdcId: Int; let grams: Double; let portion: String }
private struct LabelNutrition: Decodable { let servingMultiplier, calories, carbohydrates, protein, fat, fiber, calcium, iron, magnesium, potassium, sodium, vitaminD: Double }
private struct ModelMeal: Decodable { let title: String; let items: [RecognizedItem]; let labelNutrition: LabelNutrition?; let assumptions: [String] }

private struct NutrientSnapshot {
    var calories = 0.0, carbohydrates = 0.0, protein = 0.0, fat = 0.0, fiber = 0.0, calcium = 0.0, iron = 0.0, magnesium = 0.0, potassium = 0.0, sodium = 0.0, vitaminD = 0.0
    init() {}
    init(_ nutrients: [FDCNutrient]) {
        for nutrient in nutrients {
            let name = (nutrient.nutrient?.name ?? nutrient.nutrientName ?? "").lowercased()
            let value = nutrient.amount ?? nutrient.value ?? 0
            if name == "energy" { calories = nutrient.nutrient?.unitName == "kJ" ? value / 4.184 : value }
            if name == "carbohydrate, by difference" { carbohydrates = value }; if name == "protein" { protein = value }; if name == "total lipid (fat)" { fat = value }; if name == "fiber, total dietary" { fiber = value }
            if name == "calcium, ca" { calcium = value }; if name == "iron, fe" { iron = value }; if name == "magnesium, mg" { magnesium = value }; if name == "potassium, k" { potassium = value }; if name == "sodium, na" { sodium = value }; if name == "vitamin d (d2 + d3)" { vitaminD = value }
        }
    }
    var hasMacros: Bool { calories > 0 || carbohydrates > 0 || protein > 0 || fat > 0 }
    mutating func add(_ value: NutrientSnapshot, scale: Double) { calories += value.calories * scale; carbohydrates += value.carbohydrates * scale; protein += value.protein * scale; fat += value.fat * scale; fiber += value.fiber * scale; calcium += value.calcium * scale; iron += value.iron * scale; magnesium += value.magnesium * scale; potassium += value.potassium * scale; sodium += value.sodium * scale; vitaminD += value.vitaminD * scale }
}
