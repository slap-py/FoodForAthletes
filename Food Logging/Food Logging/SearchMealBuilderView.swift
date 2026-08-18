import SwiftUI
import SwiftData

struct SearchMealBuilderView: View {
    private enum Step { case build, review }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @State private var step: Step = .build
    @State private var query = ""
    @State private var results: [CatalogFood] = []
    @State private var selections: [CatalogMealItem] = []
    @State private var title = "Meal"
    @State private var showsConnectivityMessage = false
    @State private var searchError: String?
    @State private var isSearching = false
    let onCompleted: () -> Void

    init(onCompleted: @escaping () -> Void = {}) { self.onCompleted = onCompleted }

    private var draft: MealDraft { DayplateCatalog.draft(items: selections, title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Meal" : title) }
    private var selectedCatalogVersion: String {
        let versions = Array(Set(selections.map(\.food.catalogVersion))).sorted()
        return versions.isEmpty ? DayplateCatalog.version : versions.joined(separator: " + ")
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .build: buildStep
                case .review: reviewStep
                }
            }
            .background(JournalTheme.paper.ignoresSafeArea())
            .navigationTitle(step == .build ? "Search foods" : "Review meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(step == .review ? "Back" : "Cancel") { step == .review ? (step = .build) : dismiss() }
                }
            }
        }
        .alert("Search needs a connection", isPresented: $showsConnectivityMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("New catalog searches need internet access. You can still repeat a recent meal from the method picker.")
        }
        .alert("Couldn’t search foods", isPresented: Binding(get: { searchError != nil }, set: { if !$0 { searchError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(searchError ?? "Please try again.")
        }
    }

    private var buildStep: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                TextField("Search common foods or brands", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(13).background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 14))
                    .overlay { RoundedRectangle(cornerRadius: 14).stroke(JournalTheme.ink.opacity(0.1)) }
                    .submitLabel(.search).onSubmit(performSearch)
                    .accessibilityHint("New searches require an internet connection")
                Button(isSearching ? "Searching…" : "Search foods", action: performSearch)
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, alignment: .trailing)
                    .disabled(isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !selections.isEmpty { mealSection }
                    if !results.isEmpty {
                        Text("RESULTS").font(.caption.bold()).tracking(1.2).foregroundStyle(JournalTheme.moss)
                        ForEach(results) { food in resultRow(food) }
                    } else if query.isEmpty && selections.isEmpty {
                        ContentUnavailableView("Find a food", systemImage: "fork.knife", description: Text("Search FatSecret first, with USDA FoodData Central supplemental results."))
                            .padding(.top, 46)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, selections.isEmpty ? 30 : 110)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom) {
            if !selections.isEmpty {
                Button("Review \(selections.count) item\(selections.count == 1 ? "" : "s") · \(Int(draft.calories)) kcal") { step = .review }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .frame(maxWidth: .infinity).padding(16).background(.ultraThinMaterial)
            }
        }
    }

    private var mealSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("THIS MEAL").font(.caption.bold()).tracking(1.2).foregroundStyle(JournalTheme.moss)
            ForEach($selections) { $item in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.food.canonicalName).font(.headline)
                            if let brand = item.food.brandName { Text(brand).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button(role: .destructive) { selections.removeAll { $0.id == item.id } } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Remove \(item.food.canonicalName)")
                    }
                    HStack {
                        Picker("Serving", selection: $item.servingIndex) {
                            ForEach(Array(item.food.servings.enumerated()), id: \.offset) { index, serving in Text(serving.label).tag(index) }
                        }
                        .pickerStyle(.menu)
                        Spacer()
                        Stepper(value: $item.quantity, in: 0.25...20, step: 0.25) {
                            Text("× \(item.quantity.formatted(.number.precision(.fractionLength(0...2))))").monospacedDigit()
                        }
                        .fixedSize()
                    }
                    Text("\(Int(item.nutrients.calories)) kcal · \(Int(item.nutrients.carbohydrates))g carbs · \(Int(item.nutrients.protein))g protein")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14).background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func resultRow(_ food: CatalogFood) -> some View {
        Button { add(food) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(food.canonicalName).font(.headline).foregroundStyle(JournalTheme.ink)
                    Text("\(food.sourceSummary) · \(food.servings[0].label)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(JournalTheme.moss)
            }
            .padding(14).background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Adds one \(food.servings[0].label) to this meal")
    }

    private var reviewStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(JournalTheme.moss)
                    Text("Calculated from \(selectedCatalogVersion)").font(.caption.weight(.semibold)).foregroundStyle(JournalTheme.moss)
                }
                TextField("Meal name", text: $title).font(.title.bold()).padding(14).background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 16))
                JournalCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(Date.now, format: .dateTime.hour().minute()).font(.caption.bold()).tracking(1).foregroundStyle(JournalTheme.moss)
                        HStack { nutrient("Carbs", draft.carbohydrates); nutrient("Protein", draft.protein) }
                        HStack { nutrient("Fat", draft.fat); nutrient("Fiber", draft.fiber) }
                        Divider()
                        LabeledContent("Energy", value: "\(Int(draft.calories)) kcal").font(.subheadline)
                    }
                }
                JournalCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Foods & portions").font(.headline)
                        ForEach(selections) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text(item.food.canonicalName); Spacer(); Text(item.displayPortion).foregroundStyle(.secondary) }
                                Text(item.food.sourceSummary).font(.caption2).foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    }
                }
                Button("Save meal", action: save).buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                    .accessibilityHint("Saves all selected foods as one meal at the current time")
            }
            .padding(18)
        }
    }

    private func nutrient(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label).font(.caption).foregroundStyle(.secondary); Text("\(Int(value)) g").font(.title3.bold()) }
            .frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    private func performSearch() {
        guard networkMonitor.isConnected else { showsConnectivityMessage = true; return }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }
        isSearching = true
        Task {
            defer { isSearching = false }
            do {
                results = try await DayplateService.shared.searchFoods(query: trimmedQuery)
            } catch {
                searchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func add(_ food: CatalogFood) {
        selections.append(CatalogMealItem(food: food))
        results.removeAll { $0.id == food.id }
    }

    private func save() {
        let current = draft
        let items = selections.map { selection in
            MealItem(canonicalName: selection.food.canonicalName, portion: selection.displayPortion, quantity: selection.quantity, catalogFoodID: selection.food.id, sourceRecordIDs: selection.food.provenance.map(\.sourceID), brandName: selection.food.brandName, sourceName: selection.food.provenance.map(\.source).joined(separator: ", "))
        }
        let meal = MealLog(title: current.title, descriptionText: "", calories: current.calories, carbohydrates: current.carbohydrates, protein: current.protein, fat: current.fat, fiber: current.fiber, calcium: current.calcium, iron: current.iron, magnesium: current.magnesium, potassium: current.potassium, sodium: current.sodium, vitaminD: current.vitaminD, assumptions: current.assumptions, loggingMethod: .search, catalogVersion: selectedCatalogVersion, items: items)
        modelContext.insert(meal)
        try? modelContext.save()
        onCompleted()
        dismiss()
    }
}
