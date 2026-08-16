import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \MealLog.timestamp, order: .reverse) private var meals: [MealLog]
    @Query(sort: \WaterLog.timestamp, order: .reverse) private var water: [WaterLog]
    @State private var mode = 0
    @State private var selectedDate = Date.now
    @AppStorage("unitSystem") private var unitSystem = "us"

    private var selectedMeals: [MealLog] {
        meals.filter { Calendar.current.isDate($0.timestamp, inSameDayAs: selectedDate) }.reversed()
    }

    private var selectedWater: [WaterLog] {
        water.filter { Calendar.current.isDate($0.timestamp, inSameDayAs: selectedDate) }.reversed()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(eyebrow: "Look back", title: "History")
                        HStack(spacing: 6) {
                            modeButton("Day", mode: 0)
                            modeButton("Patterns", mode: 1)
                        }
                        .padding(5)
                        .background(JournalTheme.sage.opacity(0.28), in: Capsule())
                    }
                    .padding(.top, 18)

                    if mode == 0 { dayView } else { patternsView }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 110)
            }
            .background(JournalTheme.paper)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var dayView: some View {
        VStack(spacing: 16) {
            JournalCard {
                HStack {
                    Text("Selected day")
                        .font(.headline)
                        .foregroundStyle(JournalTheme.ink)
                    Spacer()
                    DatePicker("Selected day", selection: $selectedDate, in: ...Date.now, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .foregroundStyle(JournalTheme.ink)
                        .tint(JournalTheme.moss)
                }
            }
            if selectedMeals.isEmpty && selectedWater.isEmpty {
                JournalCard {
                    Text("No meals or water logged on this day.")
                        .foregroundStyle(JournalTheme.ink.opacity(0.62))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                MealRhythmView(meals: selectedMeals, water: selectedWater)
                ForEach(selectedMeals) { MealCard(meal: $0) }
            }
        }
    }

    private var patternsView: some View {
        VStack(spacing: 14) {
            patternCard(
                icon: "sunrise.fill",
                title: "First meal time",
                value: averageFirstMeal,
                note: "Average across days with a logged meal"
            )
            patternCard(
                icon: "arrow.left.and.right",
                title: "Meal spacing",
                value: averageSpacing,
                note: "A neutral view of time between meals"
            )
            patternCard(
                icon: "chart.bar.xaxis",
                title: "Carbohydrate & protein",
                value: distributionSummary,
                note: "Distribution by logged time of day"
            )
            patternCard(
                icon: "drop.fill",
                title: "Hydration history",
                value: hydrationAverage,
                note: "Average on days with water logs"
            )
        }
    }

    private func modeButton(_ title: String, mode buttonMode: Int) -> some View {
        Button {
            mode = buttonMode
        } label: {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(JournalTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(
                    mode == buttonMode ? JournalTheme.sage.opacity(0.75) : .clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == buttonMode ? .isSelected : [])
    }

    private func patternCard(icon: String, title: String, value: String, note: String) -> some View {
        JournalCard {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(JournalTheme.moss)
                    .frame(width: 44, height: 44)
                    .background(JournalTheme.sage.opacity(0.28), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(value).font(.title3.bold()).foregroundStyle(JournalTheme.moss)
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var averageFirstMeal: String {
        let groups = Dictionary(grouping: meals) { Calendar.current.startOfDay(for: $0.timestamp) }
        let firsts = groups.values.compactMap { $0.min(by: { $0.timestamp < $1.timestamp })?.timestamp }
        guard !firsts.isEmpty else { return "Not enough entries yet" }
        let minutes = firsts.map { Calendar.current.component(.hour, from: $0) * 60 + Calendar.current.component(.minute, from: $0) }
        let average = minutes.reduce(0, +) / minutes.count
        var components = DateComponents(); components.hour = average / 60; components.minute = average % 60
        return Calendar.current.date(from: components)?.formatted(date: .omitted, time: .shortened) ?? "—"
    }

    private var averageSpacing: String {
        let groups = Dictionary(grouping: meals) { Calendar.current.startOfDay(for: $0.timestamp) }
        var gaps: [Double] = []
        for dayMeals in groups.values {
            let sorted = dayMeals.sorted { $0.timestamp < $1.timestamp }
            for pair in zip(sorted, sorted.dropFirst()) {
                gaps.append(pair.1.timestamp.timeIntervalSince(pair.0.timestamp) / 3600)
            }
        }
        guard !gaps.isEmpty else { return "Not enough entries yet" }
        return String(format: "%.1f hours", gaps.reduce(0, +) / Double(gaps.count))
    }

    private var distributionSummary: String {
        guard !meals.isEmpty else { return "Not enough entries yet" }
        let carbs = meals.reduce(0) { $0 + $1.carbohydrates }
        let protein = meals.reduce(0) { $0 + $1.protein }
        return "\(Int(carbs)) g carbs · \(Int(protein)) g protein"
    }

    private var hydrationAverage: String {
        let groups = Dictionary(grouping: water) { Calendar.current.startOfDay(for: $0.timestamp) }
        guard !groups.isEmpty else { return "Not enough entries yet" }
        let totals = groups.values.map { $0.reduce(0) { $0 + $1.milliliters } }
        return "\(WaterDisplay.amount(totals.reduce(0, +) / Double(totals.count), unitSystem: unitSystem)) per logged day"
    }
}
