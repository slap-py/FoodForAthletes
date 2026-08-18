import SwiftUI
import SwiftData

struct LogFoodView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MealLog.timestamp, order: .reverse) private var meals: [MealLog]
    @State private var route: Route?

    private enum Route: Identifiable {
        case search, ai
        var id: Int { self == .search ? 0 : 1 }
    }

    private var repeats: [MealLog] {
        let hour = Calendar.current.component(.hour, from: .now)
        var seen = Set<String>()
        return meals.filter {
            abs(Calendar.current.component(.hour, from: $0.timestamp) - hour) <= 3 && seen.insert($0.title.lowercased()).inserted
        }.prefix(4).map { $0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("How would you like to log?").font(.largeTitle.bold()).foregroundStyle(JournalTheme.ink)
                        Text("Search is quick and calculated. AI is optional when a description or photo is easier.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }

                    methodButton(title: "Search foods", detail: "Build a meal from common foods and packaged brands", icon: "magnifyingglass", color: JournalTheme.moss) { route = .search }
                    methodButton(title: "AI estimate", detail: "Describe or photograph a meal, then review the estimate", icon: "sparkles", color: JournalTheme.clay) { route = .ai }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("REPEAT A MEAL").font(.caption.bold()).tracking(1.3).foregroundStyle(JournalTheme.moss)
                        if repeats.isEmpty {
                            Text("Meals you log will appear here around the same time of day.")
                                .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                        } else {
                            ForEach(repeats) { meal in
                                Button { repeatMeal(meal) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(meal.title).font(.headline).foregroundStyle(JournalTheme.ink)
                                            Text("\(Int(meal.calories)) kcal · \(meal.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.clockwise").foregroundStyle(JournalTheme.moss)
                                    }
                                    .padding(15).background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 16))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Repeat \(meal.title)")
                                .accessibilityHint("Creates a copy at the current time")
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(18).padding(.bottom, 24)
            }
            .background(JournalTheme.paper.ignoresSafeArea())
            .navigationTitle("Log food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .fullScreenCover(item: $route) { destination in
            switch destination {
            case .search: SearchMealBuilderView(onCompleted: { dismiss() })
            case .ai: MealCaptureView(onCompleted: { dismiss() })
            }
        }
    }

    private func methodButton(title: String, detail: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Image(systemName: icon).font(.title2.bold()).foregroundStyle(.white).frame(width: 48, height: 48).background(color, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.bold()).foregroundStyle(JournalTheme.ink)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(16).background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func repeatMeal(_ source: MealLog) {
        let items = (source.items ?? []).map { MealItem(canonicalName: $0.canonicalName, portion: $0.portion, quantity: $0.quantity, catalogFoodID: $0.catalogFoodID, sourceRecordIDs: $0.sourceRecordIDs, brandName: $0.brandName, sourceName: $0.sourceName) }
        let meal = MealLog(title: source.title, descriptionText: source.descriptionText, calories: source.calories, carbohydrates: source.carbohydrates, protein: source.protein, fat: source.fat, fiber: source.fiber, calcium: source.calcium, iron: source.iron, magnesium: source.magnesium, potassium: source.potassium, sodium: source.sodium, vitaminD: source.vitaminD, assumptions: source.assumptions, sourceMealID: source.id, loggingMethod: .repeatMeal, catalogVersion: source.catalogVersion, items: items)
        modelContext.insert(meal)
        try? modelContext.save()
        dismiss()
    }
}
