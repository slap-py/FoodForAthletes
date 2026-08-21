import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MealLog.timestamp, order: .reverse) private var meals: [MealLog]
    @Query(sort: \WaterLog.timestamp, order: .reverse) private var water: [WaterLog]
    @State private var mode = 0
    @State private var selectedDate = Calendar.current.startOfDay(for: .now)
    @State private var displayedMonth = Calendar.current.startOfDay(for: .now)
    @State private var mealToEdit: MealLog?
    @State private var mealToDelete: MealLog?
    @State private var waterToEdit: WaterLog?
    @State private var waterToDelete: WaterLog?
    @AppStorage("unitSystem") private var unitSystem = "us"
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let calendar = Calendar.autoupdatingCurrent

    private var summaries: [Date: HistoryDaySummary] {
        HistoryDaySummary.grouped(meals: meals, water: water, calendar: calendar)
    }

    private var earliestHistoryDay: Date {
        summaries.keys.min() ?? calendar.startOfDay(for: .now)
    }

    private var currentMonth: Date {
        calendar.dateInterval(of: .month, for: .now)?.start ?? calendar.startOfDay(for: .now)
    }

    private var firstHistoryMonth: Date {
        calendar.dateInterval(of: .month, for: earliestHistoryDay)?.start ?? earliestHistoryDay
    }

    private var selectedWeek: [Date] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: selectedDate) else { return [selectedDate] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(eyebrow: "Look back", title: "History")
                    HStack(spacing: 6) {
                        modeButton("Overview", mode: 0)
                        modeButton("Patterns", mode: 1)
                    }
                    .padding(5)
                    .background(JournalTheme.sage.opacity(0.28), in: Capsule())
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 10)

                if mode == 0 {
                    overviewPage
                } else {
                    ScrollView { patternsView }
                }
            }
            .background(JournalTheme.paper)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: HistoryDayRoute.self) { route in
                dayPage(for: route.date)
                    .toolbar(.visible, for: .navigationBar)
            }
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

    private var overviewPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                calendarSection
                weekSection
                periodAverageSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
    }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { moveMonth(by: -1) } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canMoveMonth(by: -1) ? JournalTheme.moss : JournalTheme.ink.opacity(0.25))
                .disabled(!canMoveMonth(by: -1))

                Spacer()
                Text(displayedMonth, format: .dateTime.month(.wide).year())
                    .font(.title3.bold())
                Spacer()

                Button { moveMonth(by: 1) } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canMoveMonth(by: 1) ? JournalTheme.moss : JournalTheme.ink.opacity(0.25))
                .disabled(!canMoveMonth(by: 1))
            }

            HStack {
                Text("Choose a day to update the week below.")
                    .font(.caption)
                    .foregroundStyle(JournalTheme.ink.opacity(0.62))
                Spacer()
                Button("Today") {
                    selectedDate = calendar.startOfDay(for: .now)
                    displayedMonth = currentMonth
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(JournalTheme.moss)
            }

            WeekdayHeader(calendar: calendar)
            MonthCalendarGrid(
                month: displayedMonth,
                selectedDate: selectedDate,
                summaries: summaries,
                calendar: calendar,
                onSelect: selectDay
            )
        }
    }

    private var weekSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Week at a glance")
                        .font(.headline)
                    Text(weekRangeLabel)
                        .font(.caption)
                        .foregroundStyle(JournalTheme.ink.opacity(0.62))
                }
                Spacer()
                HStack(spacing: 0) {
                    Button { moveWeek(by: -1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                        .buttonStyle(.plain)
                        .foregroundStyle(JournalTheme.moss)
                    Button { moveWeek(by: 1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
                        .buttonStyle(.plain)
                        .foregroundStyle(canMoveWeekForward ? JournalTheme.moss : JournalTheme.ink.opacity(0.25))
                        .disabled(!canMoveWeekForward)
                }
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    ForEach(selectedWeek, id: \.self) { date in
                        NavigationLink(value: HistoryDayRoute(date: date)) {
                            HistoryWeekDayCard(summary: summaries[date] ?? HistoryDaySummary(date: date), compact: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(selectedWeek, id: \.self) { date in
                            NavigationLink(value: HistoryDayRoute(date: date)) {
                                HistoryWeekDayCard(summary: summaries[date] ?? HistoryDaySummary(date: date), compact: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var periodAverageSection: some View {
        let weekSummaries = selectedWeek.compactMap { summaries[$0] }.filter(\.hasMeals)
        let monthSummaries = summaries.values.filter { calendar.isDate($0.date, equalTo: displayedMonth, toGranularity: .month) && $0.hasMeals }

        return VStack(spacing: 12) {
            periodAverageCard(title: "Week average", summaries: weekSummaries)
            periodAverageCard(title: "Monthly average", summaries: monthSummaries)
        }
    }

    private func periodAverageCard(title: String, summaries: [HistoryDaySummary]) -> some View {
        JournalCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.headline)
                if summaries.isEmpty {
                    Text("No meal days logged in this period.")
                        .font(.subheadline)
                        .foregroundStyle(JournalTheme.ink.opacity(0.62))
                } else {
                    HStack(spacing: 16) {
                        HistoryAverageValue(label: "Calories", value: summaries.map(\.calories).average, unit: "kcal")
                        HistoryAverageValue(label: "Carbs", value: summaries.map(\.carbohydrates).average, unit: "g")
                        HistoryAverageValue(label: "Protein", value: summaries.map(\.protein).average, unit: "g")
                    }
                    Text("Average across \(summaries.count) \(summaries.count == 1 ? "day" : "days") with meals")
                        .font(.caption)
                        .foregroundStyle(JournalTheme.ink.opacity(0.62))
                }
            }
        }
    }

    private func dayPage(for day: Date) -> some View {
        let summary = summaries[day] ?? HistoryDaySummary(date: day)
        let dayMeals = summary.meals.sorted { $0.timestamp < $1.timestamp }
        let dayWater = summary.water.sorted { $0.timestamp < $1.timestamp }
        let entries = (dayMeals.map(HistoryJournalEntry.meal) + dayWater.map(HistoryJournalEntry.water)).sorted { $0.timestamp < $1.timestamp }

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(day, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.title2.bold())
                    if calendar.isDateInToday(day) {
                        Text("Today")
                            .font(.caption)
                            .foregroundStyle(JournalTheme.ink.opacity(0.58))
                    }
                }

                HistoryDayNutritionCard(summary: summary, unitSystem: unitSystem)

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
        .navigationTitle("Day")
        .navigationBarTitleDisplayMode(.inline)
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

    private var weekRangeLabel: String {
        guard let first = selectedWeek.first, let last = selectedWeek.last else { return "" }
        return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private var canMoveWeekForward: Bool {
        guard let next = calendar.date(byAdding: .day, value: 7, to: selectedDate) else { return false }
        return next <= calendar.startOfDay(for: .now)
    }

    private func selectDay(_ date: Date) {
        guard date <= calendar.startOfDay(for: .now) else { return }
        selectedDate = calendar.startOfDay(for: date)
    }

    private func canMoveMonth(by offset: Int) -> Bool {
        guard let candidate = calendar.date(byAdding: .month, value: offset, to: displayedMonth) else { return false }
        return candidate >= firstHistoryMonth && candidate <= currentMonth
    }

    private func moveMonth(by offset: Int) {
        guard canMoveMonth(by: offset), let destination = calendar.date(byAdding: .month, value: offset, to: displayedMonth) else { return }
        displayedMonth = destination
        selectedDate = dayMatchingSelection(in: destination)
    }

    private func moveWeek(by offset: Int) {
        guard offset < 0 || canMoveWeekForward,
              let destination = calendar.date(byAdding: .day, value: offset * 7, to: selectedDate),
              destination >= earliestHistoryDay,
              destination <= calendar.startOfDay(for: .now) else { return }
        selectedDate = calendar.startOfDay(for: destination)
        displayedMonth = calendar.dateInterval(of: .month, for: selectedDate)?.start ?? displayedMonth
    }

    private func dayMatchingSelection(in month: Date) -> Date {
        let selectedDay = calendar.component(.day, from: selectedDate)
        let daysInMonth = calendar.range(of: .day, in: .month, for: month)?.count ?? selectedDay
        let candidate = calendar.date(byAdding: .day, value: min(selectedDay, daysInMonth) - 1, to: month) ?? month
        return min(candidate, calendar.startOfDay(for: .now))
    }
}

struct HistoryDaySummary: Identifiable {
    let date: Date
    let meals: [MealLog]
    let water: [WaterLog]

    init(date: Date, meals: [MealLog] = [], water: [WaterLog] = []) {
        self.date = date
        self.meals = meals
        self.water = water
    }

    var id: Date { date }
    var hasMeals: Bool { !meals.isEmpty }
    var hasEntries: Bool { !meals.isEmpty || !water.isEmpty }
    var mealCount: Int { meals.count }
    var calories: Double { meals.reduce(0) { $0 + $1.calories } }
    var carbohydrates: Double { meals.reduce(0) { $0 + $1.carbohydrates } }
    var protein: Double { meals.reduce(0) { $0 + $1.protein } }
    var waterMilliliters: Double { water.reduce(0) { $0 + $1.milliliters } }
    var firstMeal: Date? { meals.min(by: { $0.timestamp < $1.timestamp })?.timestamp }

    static func grouped(meals: [MealLog], water: [WaterLog], calendar: Calendar = .autoupdatingCurrent) -> [Date: HistoryDaySummary] {
        let mealGroups = Dictionary(grouping: meals) { calendar.startOfDay(for: $0.timestamp) }
        let waterGroups = Dictionary(grouping: water) { calendar.startOfDay(for: $0.timestamp) }
        let dates = Set(mealGroups.keys).union(waterGroups.keys)

        return Dictionary(uniqueKeysWithValues: dates.map { date in
            (date, HistoryDaySummary(date: date, meals: mealGroups[date] ?? [], water: waterGroups[date] ?? []))
        })
    }
}

private struct HistoryDayRoute: Hashable {
    let date: Date
}

private struct WeekdayHeader: View {
    let calendar: Calendar

    private var symbols: [String] {
        let base = calendar.veryShortStandaloneWeekdaySymbols
        let start = max(0, calendar.firstWeekday - 1)
        return Array(base[start...]) + Array(base[..<start])
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(symbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(JournalTheme.ink.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(symbol)
            }
        }
    }
}

private struct MonthCalendarGrid: View {
    let month: Date
    let selectedDate: Date
    let summaries: [Date: HistoryDaySummary]
    let calendar: Calendar
    let onSelect: (Date) -> Void

    private var days: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month),
              let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) else { return [] }
        let leadingCount = (calendar.component(.weekday, from: firstDay) - calendar.firstWeekday + 7) % 7
        let monthDays = range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: firstDay) }
        let trailingCount = (7 - ((leadingCount + monthDays.count) % 7)) % 7
        return Array(repeating: nil, count: leadingCount) + monthDays + Array(repeating: nil, count: trailingCount)
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 5) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                if let date {
                    let summary = summaries[date] ?? HistoryDaySummary(date: date)
                    Button { onSelect(date) } label: {
                        VStack(spacing: 3) {
                            Text("\(calendar.component(.day, from: date))")
                                .font(.subheadline.weight(calendar.isDate(date, inSameDayAs: selectedDate) ? .bold : .regular))
                            Circle()
                                .fill(summary.hasEntries ? JournalTheme.moss : .clear)
                                .frame(width: 5, height: 5)
                        }
                        .foregroundStyle(date <= calendar.startOfDay(for: .now) ? JournalTheme.ink : JournalTheme.ink.opacity(0.25))
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(calendar.isDate(date, inSameDayAs: selectedDate) ? JournalTheme.sage.opacity(0.38) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(date > calendar.startOfDay(for: .now))
                    .accessibilityLabel(accessibilityLabel(for: summary))
                    .accessibilityAddTraits(calendar.isDate(date, inSameDayAs: selectedDate) ? .isSelected : [])
                } else {
                    Color.clear
                        .frame(minHeight: 42)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func accessibilityLabel(for summary: HistoryDaySummary) -> String {
        var label = summary.date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        if summary.hasMeals {
            label += ", \(summary.mealCount) meal\(summary.mealCount == 1 ? "" : "s"), \(Int(summary.calories.rounded())) calories, \(Int(summary.carbohydrates.rounded())) grams carbs, \(Int(summary.protein.rounded())) grams protein"
        } else if summary.hasEntries {
            label += ", water logged, no meals"
        } else {
            label += ", no meals or water logged"
        }
        return label
    }
}

private struct HistoryWeekDayCard: View {
    let summary: HistoryDaySummary
    let compact: Bool

    var body: some View {
        JournalCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(summary.date, format: .dateTime.weekday(.short))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(JournalTheme.moss)
                    Spacer()
                    Text(summary.date, format: .dateTime.day())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(JournalTheme.ink.opacity(0.6))
                }

                if summary.hasMeals {
                    nutritionValue("Calories", value: summary.calories, unit: "kcal")
                    nutritionValue("Carbs", value: summary.carbohydrates, unit: "g")
                    nutritionValue("Protein", value: summary.protein, unit: "g")
                    Text("\(summary.mealCount) meal\(summary.mealCount == 1 ? "" : "s")\(firstMealLabel)")
                        .font(.caption2)
                        .foregroundStyle(JournalTheme.ink.opacity(0.62))
                } else if summary.hasEntries {
                    Label("Water only", systemImage: "drop.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(JournalTheme.blue)
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                } else {
                    Text("No meals logged")
                        .font(.caption)
                        .foregroundStyle(JournalTheme.ink.opacity(0.58))
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                }
            }
            .frame(width: compact ? 138 : nil, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var firstMealLabel: String {
        guard let firstMeal = summary.firstMeal else { return "" }
        return " · first \(firstMeal.formatted(date: .omitted, time: .shortened))"
    }

    private func nutritionValue(_ label: String, value: Double, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(JournalTheme.ink.opacity(0.62))
            Spacer(minLength: 4)
            Text("\(Int(value.rounded())) \(unit)")
                .font(.caption.weight(.bold))
                .foregroundStyle(JournalTheme.ink)
        }
    }
}

private struct HistoryDayNutritionCard: View {
    let summary: HistoryDaySummary
    let unitSystem: String

    var body: some View {
        JournalCard {
            if summary.hasMeals {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Daily nutrition")
                        .font(.headline)
                    HStack(spacing: 14) {
                        HistoryAverageValue(label: "Calories", value: summary.calories, unit: "kcal")
                        HistoryAverageValue(label: "Carbs", value: summary.carbohydrates, unit: "g")
                        HistoryAverageValue(label: "Protein", value: summary.protein, unit: "g")
                    }
                    dayNote
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.hasEntries ? "No meals logged" : "No meals or water logged")
                        .font(.headline)
                    if summary.hasEntries {
                        Text("Water: \(WaterDisplay.total(summary.waterMilliliters, unitSystem: unitSystem))")
                            .font(.subheadline)
                            .foregroundStyle(JournalTheme.blue)
                    }
                }
            }
        }
    }

    @ViewBuilder private var dayNote: some View {
        HStack(spacing: 5) {
            Text("\(summary.mealCount) meal\(summary.mealCount == 1 ? "" : "s")")
            if let firstMeal = summary.firstMeal {
                Text("· First at \(firstMeal.formatted(date: .omitted, time: .shortened))")
            }
            if summary.waterMilliliters > 0 {
                Text("· \(WaterDisplay.total(summary.waterMilliliters, unitSystem: unitSystem)) water")
            }
        }
        .font(.caption)
        .foregroundStyle(JournalTheme.ink.opacity(0.62))
    }
}

private struct HistoryAverageValue: View {
    let label: String
    let value: Double
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(JournalTheme.ink.opacity(0.62))
            Text("\(Int(value.rounded()))")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(JournalTheme.ink)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(JournalTheme.ink.opacity(0.58))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(Int(value.rounded())) \(unit)")
    }
}

private extension Array where Element == Double {
    var average: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
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
