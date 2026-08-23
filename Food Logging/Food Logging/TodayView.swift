import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var healthStore: HealthKitStore
    @Query(sort: \MealLog.timestamp) private var allMeals: [MealLog]
    @Query(sort: \WaterLog.timestamp) private var allWater: [WaterLog]
    @AppStorage("unitSystem") private var unitSystem = "us"
    @State private var mealToReestimate: MealLog?
    let onLogMeal: () -> Void

    private var meals: [MealLog] { allMeals.filter { Calendar.current.isDateInToday($0.timestamp) } }
    private var todayWater: [WaterLog] { allWater.filter { Calendar.current.isDateInToday($0.timestamp) } }
    private var water: Double { allWater.filter { Calendar.current.isDateInToday($0.timestamp) }.reduce(0) { $0 + $1.milliliters } }
    private var journalEntries: [TodayJournalEntry] {
        (meals.map(TodayJournalEntry.meal) + todayWater.map(TodayJournalEntry.water))
            .sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 22) {
                    header
                    summary
                    MealRhythmView(meals: meals, water: todayWater, workouts: healthStore.snapshot.workouts)
                    mealJournal
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 110)
            }
            .background(JournalTheme.paper)
            .toolbar(.hidden, for: .navigationBar)
            .task { await healthStore.refreshToday() }
            .sheet(item: $mealToReestimate) { meal in
                MealReestimateView(meal: meal)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TODAY")
                        .font(.caption.weight(.semibold)).tracking(1.8)
                        .foregroundStyle(JournalTheme.moss)
                    Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.largeTitle.bold())
                        .foregroundStyle(JournalTheme.ink)
                }
                Spacer()
                Image("BrandMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
        }
        .padding(.top, 18)
    }

    private var summary: some View {
        let carbs = meals.reduce(0) { $0 + $1.carbohydrates }
        let protein = meals.reduce(0) { $0 + $1.protein }
        let fat = meals.reduce(0) { $0 + $1.fat }
        let calories = meals.reduce(0) { $0 + $1.calories }

        return NavigationLink {
            DailyShapeDetailView(meals: meals, waterMilliliters: water, unitSystem: unitSystem)
        } label: {
            JournalCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        Text("Daily shape")
                            .font(.caption.weight(.semibold))
                            .tracking(1.4)
                            .foregroundStyle(JournalTheme.moss)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(JournalTheme.ink.opacity(0.45))
                            .padding(.top, 9)
                    }
                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 18) {
                        MacroValue(label: "Calories", value: calories, color: JournalTheme.blue, unit: "kcal")
                        MacroValue(label: "Carbs", value: carbs, color: JournalTheme.oat)
                        MacroValue(label: "Protein", value: protein, color: JournalTheme.clay)
                        MacroValue(label: "Fat", value: fat, color: JournalTheme.sage)
                        WaterMacroValue(milliliters: water, unitSystem: unitSystem)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens daily nutrition details")
    }

    private var mealJournal: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(eyebrow: "Journal", title: journalEntries.isEmpty ? "No meals logged today" : "Meals by time")
            if journalEntries.isEmpty {
                JournalCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Your meals will appear here in the order you ate them.")
                            .foregroundStyle(JournalTheme.ink.opacity(0.65))
                        Button("Log a meal", action: onLogMeal)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(journalEntries) { entry in
                    switch entry {
                    case .meal(let meal):
                        MealCard(meal: meal, onEdit: { mealToReestimate = meal })
                    case .water(let waterLog): WaterJournalCard(water: waterLog, unitSystem: unitSystem)
                    }
                }
            }
        }
    }

}

private enum TodayJournalEntry: Identifiable {
    case meal(MealLog)
    case water(WaterLog)

    var id: String {
        switch self {
        case .meal(let meal): "meal-\(meal.id.uuidString)"
        case .water(let water): "water-\(water.id.uuidString)"
        }
    }

    var timestamp: Date {
        switch self {
        case .meal(let meal): meal.timestamp
        case .water(let water): water.timestamp
        }
    }
}

struct DailyShapeDetailView: View {
    let meals: [MealLog]
    let waterMilliliters: Double
    let unitSystem: String

    private var calories: Double { meals.reduce(0) { $0 + $1.calories } }
    private var carbs: Double { meals.reduce(0) { $0 + $1.carbohydrates } }
    private var protein: Double { meals.reduce(0) { $0 + $1.protein } }
    private var fat: Double { meals.reduce(0) { $0 + $1.fat } }
    private var fiber: Double { meals.reduce(0) { $0 + $1.fiber } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                JournalCard {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Daily shape")
                            .font(.caption.weight(.semibold))
                            .tracking(1.4)
                            .foregroundStyle(JournalTheme.moss)
                        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 18) {
                            MacroValue(label: "Calories", value: calories, color: JournalTheme.blue, unit: "kcal")
                            MacroValue(label: "Carbs", value: carbs, color: JournalTheme.oat)
                            MacroValue(label: "Protein", value: protein, color: JournalTheme.clay)
                            MacroValue(label: "Fat", value: fat, color: JournalTheme.sage)
                            WaterMacroValue(milliliters: waterMilliliters, unitSystem: unitSystem)
                        }
                    }
                }

                JournalCard {
                    VStack(alignment: .leading, spacing: 13) {
                        Text("More nutrition")
                            .font(.headline)
                        detailRow("Fiber", value: fiber, unit: "g")
                        Divider()
                        detailRow("Sodium", value: total(\.sodium), unit: "mg")
                        detailRow("Potassium", value: total(\.potassium), unit: "mg")
                        detailRow("Calcium", value: total(\.calcium), unit: "mg")
                        detailRow("Iron", value: total(\.iron), unit: "mg")
                        detailRow("Magnesium", value: total(\.magnesium), unit: "mg")
                        detailRow("Vitamin D", value: total(\.vitaminD), unit: "mcg")
                    }
                }

                if !meals.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(eyebrow: "Logged meals", title: "Energy by meal")
                        ForEach(meals.sorted { $0.timestamp < $1.timestamp }) { meal in
                            JournalCard {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(meal.timestamp, format: .dateTime.hour().minute())
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(JournalTheme.moss)
                                        Text(meal.title).font(.headline)
                                    }
                                    Spacer()
                                    Text("\(Int(meal.calories.rounded())) kcal")
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                        }
                    }
                }
            }
            .padding(18)
            .padding(.bottom, 30)
        }
        .background(JournalTheme.paper)
        .navigationTitle("Daily shape")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func total(_ keyPath: KeyPath<MealLog, Double>) -> Double {
        meals.reduce(0) { $0 + $1[keyPath: keyPath] }
    }

    private func detailRow(_ name: String, value: Double, unit: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text("\(Int(value.rounded())) \(unit)").fontWeight(.semibold)
        }
        .foregroundStyle(JournalTheme.ink.opacity(0.75))
    }
}

private struct WaterMacroValue: View {
    let milliliters: Double
    let unitSystem: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(JournalTheme.blue)
                    .frame(width: 4, height: 17)
                Text("Water")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(JournalTheme.ink.opacity(0.68))
            }
            Text(WaterDisplay.amount(milliliters, unitSystem: unitSystem))
                .font(.title2.weight(.bold))
                .foregroundStyle(JournalTheme.blue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Water, \(WaterDisplay.amount(milliliters, unitSystem: unitSystem))")
    }
}

struct MealRhythmView: View {
    @Environment(\.locale) private var locale
    let meals: [MealLog]
    let water: [WaterLog]
    var workouts: [HealthWorkout] = []

    var body: some View {
        JournalCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(eyebrow: "Meal rhythm", title: "Your day in time")
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(JournalTheme.ink.opacity(0.1)).frame(height: 3)
                        ForEach(meals) { meal in
                            Circle()
                                .fill(JournalTheme.moss)
                                .frame(width: 13, height: 13)
                                .overlay(Circle().stroke(JournalTheme.card, lineWidth: 3))
                                .offset(x: markerPosition(for: meal.timestamp, width: proxy.size.width) - 6)
                                .accessibilityLabel("Meal at \(meal.timestamp.formatted(.dateTime.hour().minute().locale(locale)))")
                        }
                        ForEach(water) { waterLog in
                            Image(systemName: "drop.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(JournalTheme.blue)
                                .frame(width: 14, height: 14)
                                .background(JournalTheme.card, in: Circle())
                                .offset(x: markerPosition(for: waterLog.timestamp, width: proxy.size.width) - 7)
                                .accessibilityLabel("Water at \(waterLog.timestamp.formatted(.dateTime.hour().minute().locale(locale)))")
                        }
                        ForEach(workouts) { workout in
                            Image(systemName: "figure.run")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(JournalTheme.clay)
                                .frame(width: 16, height: 16)
                                .background(JournalTheme.card, in: Circle())
                                .offset(x: markerPosition(for: workout.startDate, width: proxy.size.width) - 8)
                                .accessibilityLabel("\(workout.activityName) at \(workout.startDate.formatted(.dateTime.hour().minute().locale(locale)))")
                        }
                    }
                }
                .frame(height: 16)
                HStack {
                    Text("6 AM")
                    Spacer()
                    if let gap = latestGap { Text(gap).foregroundStyle(JournalTheme.moss) }
                    Spacer()
                    Text("10 PM")
                }
                .font(.caption)
                .foregroundStyle(JournalTheme.ink.opacity(0.5))
            }
        }
    }

    private var latestGap: String? {
        guard meals.count >= 2 else {
            return meals.isEmpty ? (water.isEmpty && workouts.isEmpty ? "Meals, water & workouts appear by time" : "Activity appears by time") : nil
        }
        let sorted = meals.sorted { $0.timestamp < $1.timestamp }
        let hours = sorted.last!.timestamp.timeIntervalSince(sorted[sorted.count - 2].timestamp) / 3600
        return String(format: "%.1f h gap", hours)
    }

    private func markerPosition(for date: Date, width: CGFloat) -> CGFloat {
        let hour = Calendar.current.component(.hour, from: date)
        let minute = Calendar.current.component(.minute, from: date)
        let fraction = min(max((Double(hour) + Double(minute) / 60 - 6) / 16, 0), 1)
        return width * fraction
    }
}

struct WaterJournalCard: View {
    @Environment(\.locale) private var locale
    let water: WaterLog
    let unitSystem: String
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        JournalCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "drop.fill")
                    .foregroundStyle(JournalTheme.blue)
                    .frame(width: 32, height: 32)
                    .background(JournalTheme.blue.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    Text(water.timestamp, format: .dateTime.hour().minute())
                        .font(.caption.weight(.bold)).tracking(0.8)
                        .foregroundStyle(JournalTheme.moss)
                    Text("Water")
                        .font(.title3.bold())
                        .foregroundStyle(JournalTheme.ink)
                }
                Spacer()
                Text(WaterDisplay.amount(water.milliliters, unitSystem: unitSystem))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(JournalTheme.ink.opacity(0.66))
                if let onEdit {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.caption.weight(.bold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(JournalTheme.moss)
                    .background(JournalTheme.sage.opacity(0.28), in: Circle())
                    .accessibilityLabel("Edit water entry")
                }
                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption.weight(.bold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .background(.red.opacity(0.1), in: Circle())
                    .accessibilityLabel("Delete water entry")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Water, \(WaterDisplay.amount(water.milliliters, unitSystem: unitSystem)), at \(water.timestamp.formatted(.dateTime.hour().minute().locale(locale)))")
    }
}

struct MealCard: View {
    let meal: MealLog
    var showsSupportingDetails = true
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    @State private var expanded = false
    @AppStorage("unitSystem") private var unitSystem = "us"

    var body: some View {
        JournalCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top) {
                    Button {
                        withAnimation(.snappy) { expanded.toggle() }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(meal.timestamp, format: .dateTime.hour().minute())
                                .font(.caption.weight(.bold)).tracking(0.8)
                                .foregroundStyle(JournalTheme.moss)
                            Text(meal.title)
                                .font(.title3.bold())
                                .foregroundStyle(JournalTheme.ink)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    if let onEdit {
                        Button(action: onEdit) {
                            Image(systemName: "pencil")
                                .font(.caption.weight(.bold))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(JournalTheme.moss)
                        .background(JournalTheme.sage.opacity(0.28), in: Circle())
                        .accessibilityLabel("Edit \(meal.title)")
                    }
                    if let onDelete {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                                .font(.caption.weight(.bold))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .background(.red.opacity(0.1), in: Circle())
                        .accessibilityLabel("Delete \(meal.title)")
                    }
                    Button {
                        withAnimation(.snappy) { expanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .foregroundStyle(JournalTheme.ink.opacity(0.45))
                            .frame(width: 28, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Collapse \(meal.title)" : "Expand \(meal.title)")
                }
                HStack(spacing: 18) {
                    Label("\(Int(meal.carbohydrates)) g carbs", systemImage: "circle.fill")
                        .symbolRenderingMode(.palette).foregroundStyle(JournalTheme.oat)
                    Text("\(Int(meal.calories)) kcal")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(JournalTheme.ink.opacity(0.66))

                if expanded {
                    Divider()
                    HStack {
                        detail("Protein", meal.protein)
                        detail("Fat", meal.fat)
                        detail("Fiber", meal.fiber)
                    }
                    if meal.sodium > 0 || meal.potassium > 0 || meal.calcium > 0 || meal.iron > 0 || meal.magnesium > 0 || meal.vitaminD > 0 {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Micronutrients").font(.subheadline.bold())
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                                ForEach(micronutrients) { nutrient in
                                    micronutrient(nutrient)
                                }
                            }
                        }
                        .padding(12)
                        .background(JournalTheme.sage.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    if showsSupportingDetails {
                        if let items = meal.items, !items.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                            Text("Ingredients & portions").font(.subheadline.bold())
                            ForEach(items) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(item.canonicalName) · \(PortionDisplay.text(item.portion, unitSystem: unitSystem))").font(.subheadline)
                                    if let source = item.sourceName { Text(source).font(.caption).foregroundStyle(.secondary) }
                                }
                                }
                            }
                        }
                        if !meal.assumptions.isEmpty {
                            Text(meal.assumptions)
                                .font(.caption)
                                .foregroundStyle(JournalTheme.ink.opacity(0.55))
                        }
                    }
                }
            }
        }
    }

    private func detail(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text("\(Int(value)) g").font(.subheadline.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(Int(value)) grams")
    }

    private var micronutrients: [Micronutrient] {
        [
            Micronutrient(label: "Sodium", value: meal.sodium, unit: "mg", icon: "drop.fill"),
            Micronutrient(label: "Potassium", value: meal.potassium, unit: "mg", icon: "bolt.fill"),
            Micronutrient(label: "Calcium", value: meal.calcium, unit: "mg", icon: "circle.grid.cross.fill"),
            Micronutrient(label: "Iron", value: meal.iron, unit: "mg", icon: "shield.fill"),
            Micronutrient(label: "Magnesium", value: meal.magnesium, unit: "mg", icon: "sparkles"),
            Micronutrient(label: "Vitamin D", value: meal.vitaminD, unit: "mcg", icon: "sun.max.fill")
        ].filter { $0.value > 0 }
    }

    private func micronutrient(_ nutrient: Micronutrient) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: nutrient.icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(JournalTheme.moss)
            Text(nutrient.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(JournalTheme.ink.opacity(0.65))
                .lineLimit(1)
            Text("\(Int(nutrient.value.rounded())) \(nutrient.unit)")
                .font(.caption.weight(.bold))
                .foregroundStyle(JournalTheme.ink)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 73, alignment: .leading)
        .padding(8)
        .background(JournalTheme.card.opacity(0.75), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private struct Micronutrient: Identifiable {
        let label: String
        let value: Double
        let unit: String
        let icon: String
        var id: String { label }
    }
}

struct MealReestimateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @AppStorage("unitSystem") private var unitSystem = "us"
    let meal: MealLog
    @State private var descriptionText: String
    @State private var timestamp: Date
    @State private var draft: MealDraft?
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    @FocusState private var descriptionFocused: Bool

    init(meal: MealLog) {
        self.meal = meal
        _descriptionText = State(initialValue: meal.descriptionText)
        _timestamp = State(initialValue: meal.timestamp)
    }

    private var canAnalyze: Bool {
        !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAnalyzing
    }

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    review(draft)
                } else {
                    editor
                }
            }
            .background(JournalTheme.paper.ignoresSafeArea())
            .navigationTitle(draft == nil ? "Edit meal" : "Review update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { descriptionFocused = false }
                }
            }
        }
        .alert("Couldn’t re-estimate this meal", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                JournalCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Refine the original description", systemImage: "sparkles")
                            .font(.headline)
                            .foregroundStyle(JournalTheme.moss)
                        Text("Update what you ate, then get a fresh estimate before replacing this saved meal. The original photo is not needed.")
                            .font(.subheadline)
                            .foregroundStyle(JournalTheme.ink.opacity(0.68))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("What did you eat?").font(.headline)
                    TextField("Describe the meal", text: $descriptionText, axis: .vertical)
                        .focused($descriptionFocused)
                        .lineLimit(4...8)
                        .padding(14)
                        .background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(JournalTheme.ink.opacity(0.09))
                        }
                }

                JournalCard {
                    DatePicker("When did you eat it?", selection: $timestamp, displayedComponents: [.date, .hourAndMinute])
                        .tint(JournalTheme.moss)
                }

                Button(action: reestimate) {
                    HStack {
                        if isAnalyzing { ProgressView().tint(.white) }
                        Text(isAnalyzing ? "Re-estimating…" : "Re-estimate meal")
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canAnalyze)
            }
            .padding(18)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func review(_ draft: MealDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                JournalCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(timestamp, format: .dateTime.weekday(.short).month(.abbreviated).day().hour().minute())
                            .font(.caption.bold())
                            .tracking(1)
                            .foregroundStyle(JournalTheme.moss)
                        Text(draft.title)
                            .font(.title.bold())
                            .foregroundStyle(JournalTheme.ink)
                        HStack(spacing: 14) {
                            MacroValue(label: "Calories", value: draft.calories, color: JournalTheme.blue, unit: "kcal")
                            MacroValue(label: "Carbs", value: draft.carbohydrates, color: JournalTheme.oat)
                            MacroValue(label: "Protein", value: draft.protein, color: JournalTheme.clay)
                        }
                    }
                }

                JournalCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Foods & portions").font(.headline)
                        ForEach(Array(draft.foods.enumerated()), id: \.offset) { _, food in
                            HStack(alignment: .firstTextBaseline) {
                                Text(food.name)
                                Spacer()
                                Text(PortionDisplay.text(food.portion, unitSystem: unitSystem))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    }
                }

                Button("Edit description") {
                    self.draft = nil
                    descriptionFocused = true
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

                Button("Update saved meal") { updateMeal(with: draft) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
            .padding(18)
            .padding(.bottom, 28)
        }
    }

    private func reestimate() {
        guard canAnalyze else { return }
        guard networkMonitor.isConnected else {
            errorMessage = "Connect to the internet to re-estimate this saved meal."
            return
        }
        descriptionFocused = false
        isAnalyzing = true
        Task {
            defer { isAnalyzing = false }
            do {
                draft = try await MealAnalysisService.shared.analyze(
                    MealAnalysisInput(description: descriptionText, photoData: [])
                )
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func updateMeal(with draft: MealDraft) {
        (meal.items ?? []).forEach(modelContext.delete)
        let items = draft.foods.map {
            MealItem(canonicalName: $0.name, portion: $0.portion, sourceName: $0.sourceName, sourceTier: $0.sourceTier)
        }
        items.forEach { $0.meal = meal }
        meal.items = items
        meal.timestamp = timestamp
        meal.title = draft.title
        meal.descriptionText = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        meal.calories = draft.calories
        meal.carbohydrates = draft.carbohydrates
        meal.protein = draft.protein
        meal.fat = draft.fat
        meal.fiber = draft.fiber
        meal.calcium = draft.calcium
        meal.iron = draft.iron
        meal.magnesium = draft.magnesium
        meal.potassium = draft.potassium
        meal.sodium = draft.sodium
        meal.vitaminD = draft.vitaminD
        meal.assumptions = draft.assumptions
        meal.loggingMethod = .ai
        meal.catalogVersion = draft.catalogVersion
        try? modelContext.save()
        dismiss()
    }
}
