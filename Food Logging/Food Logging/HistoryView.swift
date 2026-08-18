import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MealLog.timestamp, order: .reverse) private var meals: [MealLog]
    @Query(sort: \WaterLog.timestamp, order: .reverse) private var water: [WaterLog]
    @State private var mode = 0
    @State private var selectedDate = Calendar.current.startOfDay(for: .now)
    @State private var mealToEdit: MealLog?
    @State private var mealToDelete: MealLog?
    @State private var waterToEdit: WaterLog?
    @State private var waterToDelete: WaterLog?
    @AppStorage("unitSystem") private var unitSystem = "us"

    private var historyDays: [Date] {
        let today = Calendar.current.startOfDay(for: .now)
        return (0...365).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: today) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(eyebrow: "Look back", title: "History")
                    HStack(spacing: 6) {
                        modeButton("Day", mode: 0)
                        modeButton("Patterns", mode: 1)
                    }
                    .padding(5)
                    .background(JournalTheme.sage.opacity(0.28), in: Capsule())
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 10)

                if mode == 0 {
                    dayPage(for: selectedDate)
                        .id(selectedDate)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 24)
                                .onEnded { value in
                                    guard abs(value.translation.width) > abs(value.translation.height), abs(value.translation.width) > 50 else { return }
                                    moveHistoryDay(older: value.translation.width < 0)
                                }
                        )
                } else {
                    ScrollView { patternsView }
                }
            }
            .background(JournalTheme.paper)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $mealToEdit) { meal in
                MealTimeEditor(meal: meal)
            }
            .sheet(item: $waterToEdit) { waterLog in
                WaterEditor(water: waterLog, unitSystem: unitSystem)
            }
            .confirmationDialog(
                "Delete this meal?",
                isPresented: Binding(get: { mealToDelete != nil }, set: { if !$0 { mealToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete meal", role: .destructive) {
                    if let mealToDelete {
                        modelContext.delete(mealToDelete)
                        try? modelContext.save()
                    }
                    mealToDelete = nil
                }
                Button("Cancel", role: .cancel) { mealToDelete = nil }
            } message: {
                Text("This removes the meal and its foods from your history.")
            }
            .confirmationDialog(
                "Delete this water entry?",
                isPresented: Binding(get: { waterToDelete != nil }, set: { if !$0 { waterToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete water", role: .destructive) {
                    if let waterToDelete {
                        modelContext.delete(waterToDelete)
                        try? modelContext.save()
                    }
                    waterToDelete = nil
                }
                Button("Cancel", role: .cancel) { waterToDelete = nil }
            } message: {
                Text("This removes the water entry from your history.")
            }
        }
    }

    private func dayPage(for day: Date) -> some View {
        let dayMeals = meals.filter { Calendar.current.isDate($0.timestamp, inSameDayAs: day) }.sorted { $0.timestamp < $1.timestamp }
        let dayWater = water.filter { Calendar.current.isDate($0.timestamp, inSameDayAs: day) }.sorted { $0.timestamp < $1.timestamp }
        let entries = (dayMeals.map(HistoryJournalEntry.meal) + dayWater.map(HistoryJournalEntry.water)).sorted { $0.timestamp < $1.timestamp }

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(day, format: .dateTime.weekday(.wide).month(.wide).day())
                            .font(.title2.bold())
                        Text(Calendar.current.isDateInToday(day) ? "Today" : "Swipe to move between logged days")
                            .font(.caption)
                            .foregroundStyle(JournalTheme.ink.opacity(0.58))
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Button { moveHistoryDay(older: false) } label: {
                            Image(systemName: "chevron.left").frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(canMoveHistoryDay(older: false) ? JournalTheme.moss : JournalTheme.ink.opacity(0.25))
                        .disabled(!canMoveHistoryDay(older: false))
                        Button { moveHistoryDay(older: true) } label: {
                            Image(systemName: "chevron.right").frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(canMoveHistoryDay(older: true) ? JournalTheme.moss : JournalTheme.ink.opacity(0.25))
                        .disabled(!canMoveHistoryDay(older: true))
                    }
                }
                .padding(.bottom, 3)

                if entries.isEmpty {
                    JournalCard {
                        Text("No meals or water logged on this day.")
                            .foregroundStyle(JournalTheme.ink.opacity(0.62))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ForEach(entries) { entry in
                        switch entry {
                        case .meal(let meal):
                            MealCard(
                                meal: meal,
                                showsSupportingDetails: false,
                                onEdit: { mealToEdit = meal },
                                onDelete: { mealToDelete = meal }
                            )
                        case .water(let waterLog):
                            WaterJournalCard(
                                water: waterLog,
                                unitSystem: unitSystem,
                                onEdit: { waterToEdit = waterLog },
                                onDelete: { waterToDelete = waterLog }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
    }

    private var patternsView: some View {
        VStack(spacing: 14) {
            patternCard(icon: "sunrise.fill", title: "First meal time", value: averageFirstMeal, note: "Average across days with a logged meal")
            patternCard(icon: "arrow.left.and.right", title: "Meal spacing", value: averageSpacing, note: "A neutral view of time between meals")
            patternCard(icon: "chart.bar.xaxis", title: "Carbohydrate & protein", value: distributionSummary, note: "Distribution by logged time of day")
            patternCard(icon: "drop.fill", title: "Hydration history", value: hydrationAverage, note: "Average on days with water logs")
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 110)
    }

    private func modeButton(_ title: String, mode buttonMode: Int) -> some View {
        Button { mode = buttonMode } label: {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(JournalTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(mode == buttonMode ? JournalTheme.sage.opacity(0.75) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == buttonMode ? .isSelected : [])
    }

    private func patternCard(icon: String, title: String, value: String, note: String) -> some View {
        JournalCard {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).foregroundStyle(JournalTheme.moss).frame(width: 44, height: 44).background(JournalTheme.sage.opacity(0.28), in: Circle())
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
        let gaps = groups.values.flatMap { dayMeals -> [Double] in
            let sorted = dayMeals.sorted { $0.timestamp < $1.timestamp }
            return zip(sorted, sorted.dropFirst()).map { $0.1.timestamp.timeIntervalSince($0.0.timestamp) / 3600 }
        }
        guard !gaps.isEmpty else { return "Not enough entries yet" }
        return String(format: "%.1f hours", gaps.reduce(0, +) / Double(gaps.count))
    }

    private var distributionSummary: String {
        guard !meals.isEmpty else { return "Not enough entries yet" }
        return "\(Int(meals.reduce(0) { $0 + $1.carbohydrates })) g carbs · \(Int(meals.reduce(0) { $0 + $1.protein })) g protein"
    }

    private var hydrationAverage: String {
        let groups = Dictionary(grouping: water) { Calendar.current.startOfDay(for: $0.timestamp) }
        guard !groups.isEmpty else { return "Not enough entries yet" }
        let totals = groups.values.map { $0.reduce(0) { $0 + $1.milliliters } }
        return "\(WaterDisplay.amount(totals.reduce(0, +) / Double(totals.count), unitSystem: unitSystem)) per logged day"
    }

    private func canMoveHistoryDay(older: Bool) -> Bool {
        guard let index = historyDays.firstIndex(of: selectedDate) else { return false }
        return older ? index < historyDays.count - 1 : index > 0
    }

    private func moveHistoryDay(older: Bool) {
        guard let index = historyDays.firstIndex(of: selectedDate) else { return }
        let destinationIndex = older ? index + 1 : index - 1
        guard historyDays.indices.contains(destinationIndex) else { return }
        withAnimation(.snappy) { selectedDate = historyDays[destinationIndex] }
    }
}

private enum HistoryJournalEntry: Identifiable {
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

private struct MealTimeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let meal: MealLog
    @State private var time: Date

    init(meal: MealLog) {
        self.meal = meal
        _time = State(initialValue: meal.timestamp)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Meal") { Text(meal.title) }
                Section("When did you eat it?") {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                }
            }
            .navigationTitle("Edit meal time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let calendar = Calendar.current
                        let hour = calendar.component(.hour, from: time)
                        let minute = calendar.component(.minute, from: time)
                        meal.timestamp = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.startOfDay(for: meal.timestamp)) ?? meal.timestamp
                        try? modelContext.save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct WaterEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let water: WaterLog
    let unitSystem: String
    @State private var time: Date
    @State private var amount: Double

    init(water: WaterLog, unitSystem: String) {
        self.water = water
        self.unitSystem = unitSystem
        _time = State(initialValue: water.timestamp)
        _amount = State(initialValue: unitSystem == "us" ? water.milliliters / 29.5735 : water.milliliters)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Water") {
                    HStack {
                        Text("Amount")
                        Spacer()
                        TextField("Amount", value: $amount, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text(unitSystem == "us" ? "oz" : "mL")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("When did you drink it?") {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                }
            }
            .navigationTitle("Edit water")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let calendar = Calendar.current
                        let hour = calendar.component(.hour, from: time)
                        let minute = calendar.component(.minute, from: time)
                        water.timestamp = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.startOfDay(for: water.timestamp)) ?? water.timestamp
                        water.milliliters = max(0, unitSystem == "us" ? amount * 29.5735 : amount)
                        try? modelContext.save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
