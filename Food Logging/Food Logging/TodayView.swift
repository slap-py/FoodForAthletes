import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var healthStore: HealthKitStore
    @Query(sort: \MealLog.timestamp) private var allMeals: [MealLog]
    @Query(sort: \WaterLog.timestamp) private var allWater: [WaterLog]
    @AppStorage("unitSystem") private var unitSystem = "us"
    @AppStorage("defaultWaterML") private var defaultWaterML = 240.0
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
            HStack {
                Label(waterLabel, systemImage: "drop.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(JournalTheme.blue)
                Spacer()
                Button("+ \(quickWaterLabel)") { addWater() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("Add \(quickWaterLabel) of water")
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
            DailyShapeDetailView(meals: meals)
        } label: {
            JournalCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        SectionTitle(eyebrow: "Daily shape", title: "Nutrition so far")
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
                    case .meal(let meal): MealCard(meal: meal)
                    case .water(let waterLog): WaterJournalCard(water: waterLog, unitSystem: unitSystem)
                    }
                }
            }
        }
    }

    private var waterLabel: String {
        WaterDisplay.total(water, unitSystem: unitSystem)
    }

    private var quickWaterLabel: String {
        WaterDisplay.amount(defaultWaterML, unitSystem: unitSystem)
    }

    private func addWater() {
        let now = Date.now
        let consolidationWindow: TimeInterval = 5 * 60
        if let latestWater = todayWater.max(by: { $0.timestamp < $1.timestamp }),
           now.timeIntervalSince(latestWater.timestamp) <= consolidationWindow {
            latestWater.milliliters += defaultWaterML
            latestWater.timestamp = now
        } else {
            modelContext.insert(WaterLog(timestamp: now, milliliters: defaultWaterML))
        }
        try? modelContext.save()
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

    private var calories: Double { meals.reduce(0) { $0 + $1.calories } }
    private var carbs: Double { meals.reduce(0) { $0 + $1.carbohydrates } }
    private var protein: Double { meals.reduce(0) { $0 + $1.protein } }
    private var fat: Double { meals.reduce(0) { $0 + $1.fat } }
    private var fiber: Double { meals.reduce(0) { $0 + $1.fiber } }
    private var hasMicronutrients: Bool {
        meals.contains { $0.sodium > 0 || $0.potassium > 0 || $0.calcium > 0 || $0.iron > 0 || $0.magnesium > 0 || $0.vitaminD > 0 }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                JournalCard {
                    VStack(alignment: .leading, spacing: 18) {
                        SectionTitle(eyebrow: "Daily shape", title: "Nutrition so far")
                        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 18) {
                            MacroValue(label: "Calories", value: calories, color: JournalTheme.blue, unit: "kcal")
                            MacroValue(label: "Carbs", value: carbs, color: JournalTheme.oat)
                            MacroValue(label: "Protein", value: protein, color: JournalTheme.clay)
                            MacroValue(label: "Fat", value: fat, color: JournalTheme.sage)
                        }
                    }
                }

                JournalCard {
                    VStack(alignment: .leading, spacing: 13) {
                        Text("More nutrition")
                            .font(.headline)
                        detailRow("Fiber", value: fiber, unit: "g")
                        if hasMicronutrients {
                            Divider()
                            detailRow("Sodium", value: total(\.sodium), unit: "mg")
                            detailRow("Potassium", value: total(\.potassium), unit: "mg")
                            detailRow("Calcium", value: total(\.calcium), unit: "mg")
                            detailRow("Iron", value: total(\.iron), unit: "mg")
                            detailRow("Magnesium", value: total(\.magnesium), unit: "mg")
                            detailRow("Vitamin D", value: total(\.vitaminD), unit: "mcg")
                        }
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

struct MealRhythmView: View {
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
                                .accessibilityLabel("Meal at \(meal.timestamp.formatted(date: .omitted, time: .shortened))")
                        }
                        ForEach(water) { waterLog in
                            Image(systemName: "drop.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(JournalTheme.blue)
                                .frame(width: 14, height: 14)
                                .background(JournalTheme.card, in: Circle())
                                .offset(x: markerPosition(for: waterLog.timestamp, width: proxy.size.width) - 7)
                                .accessibilityLabel("Water at \(waterLog.timestamp.formatted(date: .omitted, time: .shortened))")
                        }
                        ForEach(workouts) { workout in
                            Image(systemName: "figure.run")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(JournalTheme.clay)
                                .frame(width: 16, height: 16)
                                .background(JournalTheme.card, in: Circle())
                                .offset(x: markerPosition(for: workout.startDate, width: proxy.size.width) - 8)
                                .accessibilityLabel("\(workout.activityName) at \(workout.startDate.formatted(date: .omitted, time: .shortened))")
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
        .accessibilityLabel("Water, \(WaterDisplay.amount(water.milliliters, unitSystem: unitSystem)), at \(water.timestamp.formatted(date: .omitted, time: .shortened))")
    }
}

struct MealCard: View {
    let meal: MealLog
    var showsSupportingDetails = true
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    @State private var expanded = false

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
                        .accessibilityLabel("Edit time for \(meal.title)")
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
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Micronutrients").font(.subheadline.bold())
                            Text(micronutrientSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if showsSupportingDetails {
                        if let items = meal.items, !items.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Foods & portions").font(.subheadline.bold())
                                ForEach(items) { item in
                                    Text("\(item.canonicalName) · \(item.portion)")
                                        .font(.subheadline)
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

    private var micronutrientSummary: String {
        [
            meal.sodium > 0 ? "Sodium \(Int(meal.sodium.rounded())) mg" : nil,
            meal.potassium > 0 ? "Potassium \(Int(meal.potassium.rounded())) mg" : nil,
            meal.calcium > 0 ? "Calcium \(Int(meal.calcium.rounded())) mg" : nil,
            meal.iron > 0 ? "Iron \(Int(meal.iron.rounded())) mg" : nil,
            meal.magnesium > 0 ? "Magnesium \(Int(meal.magnesium.rounded())) mg" : nil,
            meal.vitaminD > 0 ? "Vitamin D \(Int(meal.vitaminD.rounded())) mcg" : nil
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}
