import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MealLog.timestamp) private var allMeals: [MealLog]
    @Query(sort: \WaterLog.timestamp) private var allWater: [WaterLog]
    @AppStorage("unitSystem") private var unitSystem = "us"
    @AppStorage("defaultWaterML") private var defaultWaterML = 240.0
    let onLogMeal: () -> Void

    private var meals: [MealLog] { allMeals.filter { Calendar.current.isDateInToday($0.timestamp) } }
    private var todayWater: [WaterLog] { allWater.filter { Calendar.current.isDateInToday($0.timestamp) } }
    private var water: Double { allWater.filter { Calendar.current.isDateInToday($0.timestamp) }.reduce(0) { $0 + $1.milliliters } }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 22) {
                    header
                    summary
                    MealRhythmView(meals: meals, water: todayWater)
                    mealJournal
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 110)
            }
            .background(JournalTheme.paper)
            .toolbar(.hidden, for: .navigationBar)
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
                Image(systemName: "leaf.fill")
                    .font(.title2)
                    .foregroundStyle(JournalTheme.moss)
                    .frame(width: 24, height: 24)
                    .offset(x: 1)
                    .padding(12)
                    .background(JournalTheme.sage.opacity(0.32), in: Circle())
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
        let fiber = meals.reduce(0) { $0 + $1.fiber }
        let calories = meals.reduce(0) { $0 + $1.calories }

        return JournalCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionTitle(eyebrow: "Daily shape", title: "Nutrition so far")
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 18) {
                    MacroValue(label: "Carbohydrate", value: carbs, color: JournalTheme.oat)
                    MacroValue(label: "Protein", value: protein, color: JournalTheme.clay)
                    MacroValue(label: "Fat", value: fat, color: JournalTheme.sage)
                    MacroValue(label: "Fiber", value: fiber, color: JournalTheme.blue)
                }
                DisclosureGroup("Calories & details") {
                    HStack {
                        Text("Estimated energy")
                        Spacer()
                        Text("\(Int(calories.rounded())) kcal").fontWeight(.semibold)
                    }
                    .padding(.top, 10)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(JournalTheme.ink.opacity(0.72))
            }
        }
    }

    private var mealJournal: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(eyebrow: "Journal", title: meals.isEmpty ? "No meals logged today" : "Meals by time")
            if meals.isEmpty {
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
                ForEach(meals) { meal in
                    MealCard(meal: meal)
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
        modelContext.insert(WaterLog(milliliters: defaultWaterML))
        try? modelContext.save()
    }
}

struct MealRhythmView: View {
    let meals: [MealLog]
    let water: [WaterLog]

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
            return meals.isEmpty ? (water.isEmpty ? "Meals & water appear by time" : "Water appears by time") : nil
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

struct MealCard: View {
    let meal: MealLog
    @State private var expanded = false

    var body: some View {
        JournalCard {
            VStack(alignment: .leading, spacing: 13) {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(meal.timestamp, format: .dateTime.hour().minute())
                                .font(.caption.weight(.bold)).tracking(0.8)
                                .foregroundStyle(JournalTheme.moss)
                            Text(meal.title)
                                .font(.title3.bold())
                                .foregroundStyle(JournalTheme.ink)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .foregroundStyle(JournalTheme.ink.opacity(0.45))
                    }
                }
                .buttonStyle(.plain)
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

    private func detail(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text("\(Int(value)) g").font(.subheadline.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(Int(value)) grams")
    }
}
