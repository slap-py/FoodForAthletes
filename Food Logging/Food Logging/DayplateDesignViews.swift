import SwiftUI
import SwiftData

// Native SwiftUI implementation of the Dayplate.dc.html reference. These views
// intentionally keep the reference's compact hierarchy and warm journal styling
// while reading the real SwiftData journal.

struct DayplateTodayView: View {
    @Environment(\.locale) private var locale
    @Query(sort: \MealLog.timestamp) private var allMeals: [MealLog]
    @Query(sort: \WaterLog.timestamp) private var allWater: [WaterLog]
    @AppStorage("unitSystem") private var unitSystem = "us"
    @AppStorage("profileName") private var profileName = ""
    @AppStorage("profilePhotoPath") private var profilePhotoPath = ""
    @State private var nutrientsOpen = false
    let onOpenProfile: () -> Void

    private var meals: [MealLog] { allMeals.filter { Calendar.current.isDateInToday($0.timestamp) } }
    private var previousMeals: [MealLog] {
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now) else { return [] }
        return allMeals.filter { Calendar.current.isDate($0.timestamp, inSameDayAs: yesterday) }
    }
    private var water: [WaterLog] { allWater.filter { Calendar.current.isDateInToday($0.timestamp) } }
    private var entries: [DayplateTimelineEntry] {
        (meals.map(DayplateTimelineEntry.meal) + water.map(DayplateTimelineEntry.water))
            .sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    nutritionSummary
                    HStack(alignment: .firstTextBaseline) {
                        Text("THE DAY SO FAR")
                            .font(.caption.weight(.semibold)).tracking(1.4)
                            .foregroundStyle(JournalTheme.moss)
                        Spacer()
                        Text("\(entries.count) \(entries.count == 1 ? "entry" : "entries")")
                            .font(.caption.weight(.bold)).foregroundStyle(JournalTheme.ink.opacity(0.45))
                    }
                    timeline
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 138)
            }
            .background(JournalTheme.paper)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("TODAY")
                    .font(.caption.weight(.semibold)).tracking(1.8).foregroundStyle(JournalTheme.moss)
                Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: 33, weight: .bold, design: .default))
                    .tracking(-0.6)
                    .foregroundStyle(JournalTheme.ink)
            }
            Spacer(minLength: 4)
            Button(action: onOpenProfile) {
                ProfileAvatar(name: profileName, photoPath: profilePhotoPath, size: 46)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open profile")
            .padding(.top, 4)
        }
    }

    private var nutritionSummary: some View {
        let calories = meals.reduce(0) { $0 + $1.calories }
        let protein = meals.reduce(0) { $0 + $1.protein }
        let carbs = meals.reduce(0) { $0 + $1.carbohydrates }
        let fat = meals.reduce(0) { $0 + $1.fat }
        return JournalCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(calories.formatted(.number.precision(.fractionLength(0))))
                        .font(.system(size: 44, weight: .bold)).tracking(-1.2)
                    Text("kcal").font(.body.weight(.semibold)).foregroundStyle(JournalTheme.ink.opacity(0.55))
                }
                .padding(.bottom, 18)
                HStack(spacing: 12) {
                    DayplateMacro(label: "Protein", value: protein, previousValue: previousTotal(\.protein), color: JournalTheme.clay)
                    DayplateMacro(label: "Carbs", value: carbs, previousValue: previousTotal(\.carbohydrates), color: JournalTheme.oat)
                    DayplateMacro(label: "Fat", value: fat, previousValue: previousTotal(\.fat), color: JournalTheme.sage)
                }
                Button {
                    withAnimation(.snappy) { nutrientsOpen.toggle() }
                } label: {
                    HStack {
                        Text("Nutrient detail")
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(nutrientsOpen ? 180 : 0))
                            .font(.caption.bold()).foregroundStyle(JournalTheme.ink.opacity(0.45))
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(JournalTheme.moss)
                    .padding(.top, 13)
                    .padding(.bottom, nutrientsOpen ? 13 : 7)
                    .overlay(alignment: .top) { Divider().opacity(0.45) }
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
                if nutrientsOpen { nutrientGrid }
            }
        }
    }

    private var nutrientGrid: some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
            DayplateNutrientTile(label: "FIBER", value: total(\.fiber), unit: "g", color: JournalTheme.moss)
            DayplateNutrientTile(label: "SODIUM", value: total(\.sodium), unit: "mg", color: JournalTheme.clay)
            DayplateNutrientTile(label: "POTASSIUM", value: total(\.potassium), unit: "mg", color: JournalTheme.blue)
            DayplateNutrientTile(label: "MAGNESIUM", value: total(\.magnesium), unit: "mg", color: JournalTheme.oat)
            DayplateNutrientTile(label: "IRON", value: total(\.iron), unit: "mg", color: JournalTheme.clay)
            DayplateNutrientTile(label: "CALCIUM", value: total(\.calcium), unit: "mg", color: JournalTheme.blue)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder private var timeline: some View {
        if entries.isEmpty {
            Text("Meals and water will appear here in the order you log them.")
                .font(.subheadline).foregroundStyle(JournalTheme.ink.opacity(0.58))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            VStack(spacing: 9) {
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Text(entry.timestamp.formatted(.dateTime.hour().minute().locale(locale)))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(JournalTheme.ink.opacity(0.45))
                            .frame(width: 48, alignment: .trailing)
                            .padding(.top, 14)
                        Circle().fill(entry.isWater ? JournalTheme.blue : JournalTheme.moss)
                            .frame(width: 9, height: 9).padding(.top, 17)
                        switch entry {
                        case .meal(let meal):
                            NavigationLink { DayplateMealDetailView(meal: meal) } label: {
                                DayplateMealRow(meal: meal)
                            }
                            .buttonStyle(.plain)
                        case .water(let water):
                            HStack(spacing: 9) {
                                Image(systemName: "drop.fill")
                                Text(WaterDisplay.total(water.milliliters, unitSystem: unitSystem))
                            }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(JournalTheme.blue)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13).frame(height: 44)
                            .background(JournalTheme.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(JournalTheme.blue.opacity(0.20)))
                        }
                    }
                }
            }
            .overlay(alignment: .leading) {
                Rectangle().fill(JournalTheme.moss.opacity(0.22)).frame(width: 1.5)
                    .padding(.leading, 62).padding(.vertical, 20).allowsHitTesting(false)
            }
        }
    }

    private func total(_ keyPath: KeyPath<MealLog, Double>) -> Double {
        meals.reduce(0) { $0 + $1[keyPath: keyPath] }
    }

    private func previousTotal(_ keyPath: KeyPath<MealLog, Double>) -> Double? {
        guard !previousMeals.isEmpty else { return nil }
        return previousMeals.reduce(0) { $0 + $1[keyPath: keyPath] }
    }
}

private enum DayplateTimelineEntry: Identifiable {
    case meal(MealLog), water(WaterLog)
    var id: String { switch self { case .meal(let value): "m-\(value.id)"; case .water(let value): "w-\(value.id)" } }
    var timestamp: Date { switch self { case .meal(let value): value.timestamp; case .water(let value): value.timestamp } }
    var isWater: Bool { if case .water = self { true } else { false } }
}

private struct DayplateMacro: View {
    let label: String
    let value: Double
    var previousValue: Double?
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 16)
                Text(label).font(.subheadline).foregroundStyle(JournalTheme.ink.opacity(0.68)).lineLimit(1)
                if let previousValue, abs(value - previousValue) >= 0.5 {
                    Image(systemName: value > previousValue ? "arrow.up" : "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(value > previousValue ? JournalTheme.moss : JournalTheme.clay)
                }
            }
            Text("\(Int(value.rounded())) g").font(.title3.bold()).foregroundStyle(JournalTheme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DayplateNutrientTile: View {
    let label: String
    let value: Double
    let unit: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 10, weight: .bold)).tracking(1.1).foregroundStyle(JournalTheme.ink.opacity(0.55))
            Text("\(Int(value.rounded())) \(unit)").font(.headline.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 11).padding(.horizontal, 12)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 4).clipShape(Capsule()) }
    }
}

private struct DayplateMealRow: View {
    let meal: MealLog
    var body: some View {
        HStack(spacing: 10) {
            Text(mealEmoji(meal.title)).font(.title3).frame(width: 36, height: 36).background(JournalTheme.sage.opacity(0.24), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(meal.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if meal.analysisStatus == .pending {
                    Label("Calculating nutrition…", systemImage: "clock")
                        .font(.caption2.weight(.semibold)).foregroundStyle(JournalTheme.moss)
                } else if meal.analysisStatus == .failed {
                    Label("Nutrition needs a retry", systemImage: "exclamationmark.circle")
                        .font(.caption2.weight(.semibold)).foregroundStyle(JournalTheme.clay)
                } else {
                    HStack(spacing: 6) {
                        Text("\(Int(meal.calories)) kcal").foregroundStyle(JournalTheme.blue)
                        Text("·")
                        Text("\(Int(meal.protein))p").foregroundStyle(JournalTheme.clay)
                        Text("·")
                        Text("\(Int(meal.carbohydrates))c").foregroundStyle(Color(red: 0.69, green: 0.54, blue: 0.24))
                        Text("·")
                        Text("\(Int(meal.fat))f").foregroundStyle(Color(red: 0.43, green: 0.55, blue: 0.35))
                    }.font(.caption2.bold()).lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(JournalTheme.ink.opacity(0.28))
        }
        .foregroundStyle(JournalTheme.ink).padding(11)
        .background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(JournalTheme.moss.opacity(0.12)))
    }
}

struct DayplateMealDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var offlineMealQueue: OfflineMealQueueStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    let meal: MealLog
    @State private var showsReestimate = false
    @AppStorage("unitSystem") private var unitSystem = "us"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(meal.timestamp, format: .dateTime.weekday(.short).month(.abbreviated).day().hour().minute())
                    .font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(JournalTheme.moss)
                HStack(alignment: .top, spacing: 10) {
                    Text(mealEmoji(meal.title)).font(.system(size: 30))
                    Text(meal.title).font(.system(size: 29, weight: .bold)).tracking(-0.6)
                }
                if meal.analysisStatus == .pending {
                    JournalCard {
                        Label("Calculating nutrition in the background", systemImage: "clock")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(JournalTheme.moss)
                    }
                } else if meal.analysisStatus == .failed {
                    JournalCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Nutrition could not be completed", systemImage: "exclamationmark.circle")
                                .font(.headline).foregroundStyle(JournalTheme.clay)
                            if let error = meal.analysisError { Text(error).font(.caption).foregroundStyle(.secondary) }
                            Button("Try again") {
                                offlineMealQueue.retry(meal: meal, in: modelContext)
                                Task { await offlineMealQueue.processPending(into: modelContext, networkAvailable: networkMonitor.isConnected) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else {
                    JournalCard {
                        VStack(alignment: .leading, spacing: 18) {
                            DayplateDetailMetric(label: "Calories", value: "\(Int(meal.calories)) kcal", color: JournalTheme.blue, large: true)
                            HStack {
                                DayplateDetailMetric(label: "Protein", value: "\(Int(meal.protein)) g", color: JournalTheme.clay)
                                DayplateDetailMetric(label: "Carbs", value: "\(Int(meal.carbohydrates)) g", color: JournalTheme.oat)
                                DayplateDetailMetric(label: "Fat", value: "\(Int(meal.fat)) g", color: JournalTheme.sage)
                            }
                        }
                    }
                    if let question = meal.clarificationSuggestions.first {
                        JournalCard {
                            VStack(alignment: .leading, spacing: 9) {
                                Text(question.prompt).font(.subheadline.weight(.semibold))
                                Text(question.detail).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Menu("Change") {
                                        ForEach(question.options.filter { $0.action == "answer" }) { option in
                                            Button(option.label) { answer(question, with: option) }
                                        }
                                    }
                                    .font(.caption.weight(.semibold))
                                    Spacer()
                                    Button("Not now") {
                                        meal.clarificationSuggestions = []
                                        try? modelContext.save()
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    JournalCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Foods & portions").font(.headline)
                            ForEach(meal.items ?? []) { item in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(item.canonicalName)
                                        Spacer()
                                        Text(PortionDisplay.text(item.portion, unitSystem: unitSystem)).foregroundStyle(.secondary)
                                    }.font(.subheadline)
                                    if let tier = item.sourceTier {
                                        Text(tier.shortLabel).font(.caption2).foregroundStyle(JournalTheme.ink.opacity(0.42))
                                    }
                                }
                                Divider().opacity(0.5)
                            }
                        }
                    }
                }
                if !meal.assumptions.isEmpty {
                    JournalCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("NOTES", systemImage: "line.3.horizontal")
                                .font(.caption.bold()).tracking(1.2).foregroundStyle(JournalTheme.moss)
                            Text(meal.assumptions).font(.subheadline).foregroundStyle(JournalTheme.ink.opacity(0.70))
                        }
                    }
                }
                if meal.analysisStatus == .resolved {
                    Button("Edit & re-estimate") { showsReestimate = true }
                    .font(.body.weight(.semibold)).foregroundStyle(JournalTheme.moss)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .overlay(Capsule().stroke(JournalTheme.moss.opacity(0.30)))
                }
            }
            .padding(18).padding(.bottom, 40)
        }
        .background(JournalTheme.paper).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsReestimate) { MealReestimateView(meal: meal) }
    }

    private func answer(_ question: MealClarification, with option: MealClarification.Option) {
        do {
            try offlineMealQueue.answer(option, questionID: question.id, for: meal, in: modelContext)
            Task { await offlineMealQueue.processPending(into: modelContext, networkAvailable: networkMonitor.isConnected) }
        } catch {
            meal.analysisStatus = .failed
            meal.analysisError = error.localizedDescription
            try? modelContext.save()
        }
    }
}

private struct DayplateDetailMetric: View {
    let label: String, value: String
    let color: Color
    var large = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: large ? 16 : 14); Text(label).font(.subheadline).foregroundStyle(JournalTheme.ink.opacity(0.68)) }
            Text(value).font(large ? .system(size: 32, weight: .bold) : .headline.bold())
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DayplateHistoryView: View {
    @Query(sort: \MealLog.timestamp, order: .reverse) private var meals: [MealLog]
    @Binding var selectedDate: Date
    @State private var showsSearch = false
    private let calendar = Calendar.autoupdatingCurrent

    private var week: [Date] {
        let interval = calendar.dateInterval(of: .weekOfYear, for: selectedDate)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval?.start ?? selectedDate) }
    }
    private var recentDays: [Date] {
        let selected = calendar.startOfDay(for: selectedDate)
        return (0..<5).compactMap { calendar.date(byAdding: .day, value: -$0, to: selected) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        Text(selectedDate, format: .dateTime.month(.wide).year()).font(.system(size: 31, weight: .bold)).tracking(-0.6)
                        Spacer()
                        Button { showsSearch = true } label: { Image(systemName: "magnifyingglass").frame(width: 42, height: 42).background(JournalTheme.card, in: Circle()).overlay(Circle().stroke(JournalTheme.moss.opacity(0.18))) }
                            .buttonStyle(.plain).foregroundStyle(JournalTheme.moss).accessibilityLabel("Search meals")
                    }
                    HStack(spacing: 4) {
                        ForEach(week, id: \.self) { date in
                            Button { selectedDate = calendar.startOfDay(for: date) } label: {
                                VStack(spacing: 4) {
                                    Text(date, format: .dateTime.weekday(.narrow)).font(.caption2.weight(.semibold))
                                    Text(date, format: .dateTime.day()).font(.body.bold())
                                }
                                .foregroundStyle(calendar.isDate(date, inSameDayAs: selectedDate) ? .white : JournalTheme.ink)
                                .frame(maxWidth: .infinity).frame(height: 54)
                                .background(calendar.isDate(date, inSameDayAs: selectedDate) ? JournalTheme.moss : .clear, in: RoundedRectangle(cornerRadius: 14))
                            }.buttonStyle(.plain).disabled(date > Date.now)
                        }
                    }
                    DayplateHistoryDayCard(date: recentDays[0], meals: mealsFor(recentDays[0]), startsOpen: true)
                    Text("EARLIER THIS WEEK").font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(JournalTheme.moss).padding(.top, 8)
                    ForEach(recentDays.dropFirst(), id: \.self) { day in DayplateHistoryDayCard(date: day, meals: mealsFor(day)) }
                }
                .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 138)
            }
            .background(JournalTheme.paper).toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showsSearch) { DayplateHistorySearchView(meals: meals) }
        }
    }
    private func mealsFor(_ date: Date) -> [MealLog] { meals.filter { calendar.isDate($0.timestamp, inSameDayAs: date) }.sorted { $0.timestamp < $1.timestamp } }
}

private struct DayplateHistoryDayCard: View {
    let date: Date, meals: [MealLog]
    @State private var open: Bool
    init(date: Date, meals: [MealLog], startsOpen: Bool = false) { self.date = date; self.meals = meals; _open = State(initialValue: startsOpen) }
    private var calories: Double { meals.reduce(0) { $0 + $1.calories } }
    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(date, format: .dateTime.weekday(.wide).month(.abbreviated).day()).font(.subheadline.weight(.semibold))
                        HStack(spacing: 7) {
                            Text("\(Int(calories)) kcal").foregroundStyle(JournalTheme.blue)
                            Text("·")
                            Text("\(Int(meals.reduce(0) { $0 + $1.protein })) g protein").foregroundStyle(JournalTheme.clay)
                            Text("·")
                            Text("\(Int(meals.reduce(0) { $0 + $1.carbohydrates })) g carbs").foregroundStyle(Color(red: 0.69, green: 0.54, blue: 0.24))
                        }.font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0)).font(.caption.bold()).foregroundStyle(JournalTheme.ink.opacity(0.4))
                }.foregroundStyle(JournalTheme.ink).padding(14)
            }.buttonStyle(.plain)
            if open {
                if meals.isEmpty { Text("No meals logged").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(14).overlay(alignment: .top) { Divider() } }
                ForEach(meals) { meal in
                    NavigationLink { DayplateMealDetailView(meal: meal) } label: {
                        HStack(spacing: 10) {
                            Text(meal.timestamp, format: .dateTime.hour().minute()).font(.caption2.weight(.semibold)).foregroundStyle(JournalTheme.ink.opacity(0.45)).frame(width: 58, alignment: .leading)
                            Text(mealEmoji(meal.title)); Text(meal.title).font(.subheadline).lineLimit(1); Spacer(); Text("\(Int(meal.calories)) kcal").font(.caption.weight(.semibold)).foregroundStyle(JournalTheme.blue)
                        }.foregroundStyle(JournalTheme.ink).padding(.horizontal, 14).padding(.vertical, 10).overlay(alignment: .top) { Divider().padding(.leading, 14) }
                    }.buttonStyle(.plain)
                }
            }
        }.background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 18).stroke(JournalTheme.moss.opacity(0.12)))
    }
}

private struct DayplateHistorySearchView: View {
    @Environment(\.dismiss) private var dismiss
    let meals: [MealLog]
    @State private var query = ""
    private var results: [MealLog] { query.isEmpty ? [] : meals.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.descriptionText.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Ask about your history").font(.title2.bold())
                    TextField("When did I last eat salmon?", text: $query).padding(14).background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(JournalTheme.moss.opacity(0.2)))
                    if !query.isEmpty { Text(results.isEmpty ? "No matching meals yet." : "Found \(results.count) matching \(results.count == 1 ? "meal" : "meals").").font(.subheadline).foregroundStyle(JournalTheme.ink.opacity(0.65)) }
                    ForEach(results) { meal in DayplateMealRow(meal: meal) }
                }.padding(18)
            }.background(JournalTheme.paper).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct DayplateInsightsView: View {
    @Environment(\.locale) private var locale
    @Query(sort: \MealLog.timestamp) private var meals: [MealLog]
    @AppStorage("insightsWindow") private var insightsWindow = "rolling"
    @State private var selectedBar: Int?
    private let calendar = Calendar.autoupdatingCurrent
    private var days: [Date] {
        if insightsWindow == "week", let start = calendar.dateInterval(of: .weekOfYear, for: .now)?.start {
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        }
        return (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: calendar.startOfDay(for: .now)) }
    }
    private var dailyMeals: [[MealLog]] { days.map { day in meals.filter { calendar.isDate($0.timestamp, inSameDayAs: day) } } }
    private var logged: [[MealLog]] { dailyMeals.filter { !$0.isEmpty } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Insights").font(.system(size: 31, weight: .bold)).tracking(-0.6)
                    Text(windowLabel).font(.subheadline).foregroundStyle(JournalTheme.ink.opacity(0.55))
                }
                JournalCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("DAILY AVERAGE").font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(JournalTheme.moss)
                        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 18) {
                            DayplateInsightMetric("Calories", average(\.calories), "kcal", JournalTheme.blue)
                            DayplateInsightMetric("Protein", average(\.protein), "g", JournalTheme.clay)
                            DayplateInsightMetric("Carbs", average(\.carbohydrates), "g", JournalTheme.oat)
                            DayplateInsightMetric("Fat", average(\.fat), "g", JournalTheme.sage)
                        }
                        Divider().opacity(0.55)
                        HStack(spacing: 10) {
                            DayplateMiniMetric(label: "FIBER", unit: "g", value: average(\.fiber), color: JournalTheme.moss)
                            DayplateMiniMetric(label: "SODIUM", unit: "mg", value: average(\.sodium), color: JournalTheme.clay)
                            DayplateMiniMetric(label: "CALCIUM", unit: "mg", value: average(\.calcium), color: JournalTheme.blue)
                        }
                    }
                }
                JournalCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("CALORIES BY DAY").font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(JournalTheme.moss)
                        Text(barCallout)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selectedBar == nil ? JournalTheme.ink.opacity(0.38) : JournalTheme.blue)
                            .frame(minHeight: 18)
                        GeometryReader { proxy in
                            HStack(alignment: .bottom, spacing: 7) {
                                ForEach(Array(zip(days.indices, days)), id: \.0) { index, day in
                                    let calories = dailyMeals[index].reduce(0) { $0 + $1.calories }
                                    Button { selectedBar = selectedBar == index ? nil : index } label: {
                                        VStack(spacing: 6) {
                                            Spacer(minLength: 0)
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(selectedBar == index ? JournalTheme.moss : (calories == 0 ? JournalTheme.moss.opacity(0.15) : JournalTheme.blue))
                                                .frame(height: max(4, proxy.size.height * 0.78 * CGFloat(calories / max(maxCalories, 1))))
                                            Text(day, format: .dateTime.weekday(.narrow))
                                                .font(.caption2.weight(selectedBar == index ? .bold : .regular))
                                                .foregroundStyle(selectedBar == index ? JournalTheme.moss : JournalTheme.ink.opacity(0.55))
                                        }.frame(maxWidth: .infinity)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.frame(height: 170)
                    }
                }
                JournalCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("MACROS BY DAY").font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(JournalTheme.moss)
                        HStack(spacing: 0) {
                            Text("").frame(width: 22)
                            ForEach(days, id: \.self) { day in
                                Text(day, format: .dateTime.weekday(.narrow))
                                    .font(.caption2.bold()).foregroundStyle(calendar.isDateInToday(day) ? JournalTheme.moss : JournalTheme.ink.opacity(0.45))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        DayplateMacroTableRow(label: "P", color: JournalTheme.clay, values: dailyMeals.map { $0.reduce(0) { $0 + $1.protein } })
                        DayplateMacroTableRow(label: "C", color: Color(red: 0.69, green: 0.54, blue: 0.24), values: dailyMeals.map { $0.reduce(0) { $0 + $1.carbohydrates } })
                        DayplateMacroTableRow(label: "F", color: Color(red: 0.43, green: 0.55, blue: 0.35), values: dailyMeals.map { $0.reduce(0) { $0 + $1.fat } })
                    }
                }
                JournalCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MOST LOGGED THIS PERIOD").font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(JournalTheme.moss).padding(.bottom, 6)
                        if topFoods.isEmpty {
                            Text("Foods will appear as you build your history.").font(.subheadline).foregroundStyle(JournalTheme.ink.opacity(0.55)).padding(.vertical, 8)
                        } else {
                            ForEach(topFoods, id: \.name) { food in
                                HStack(spacing: 12) {
                                    Text(mealEmoji(food.name)).frame(width: 28)
                                    Text(food.name).font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text("\(food.count)×").font(.subheadline.weight(.semibold)).foregroundStyle(JournalTheme.ink.opacity(0.5))
                                }.padding(.vertical, 9)
                                if food.name != topFoods.last?.name { Divider().opacity(0.45) }
                            }
                        }
                    }
                }
            }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 138)
        }.background(JournalTheme.paper)
    }
    private var maxCalories: Double { dailyMeals.map { $0.reduce(0) { $0 + $1.calories } }.max() ?? 1 }
    private func average(_ keyPath: KeyPath<MealLog, Double>) -> Double { guard !logged.isEmpty else { return 0 }; return logged.map { $0.reduce(0) { $0 + $1[keyPath: keyPath] } }.reduce(0, +) / Double(logged.count) }
    private var windowLabel: String {
        insightsWindow == "week" ? "This week · Mon – Sun" : "Rolling 7 day period · \(days.first?.formatted(.dateTime.month(.abbreviated).day().locale(locale)) ?? "") – \(days.last?.formatted(.dateTime.day().locale(locale)) ?? "")"
    }
    private var barCallout: String {
        guard let selectedBar else { return "Tap a bar for that day's total" }
        let dayMeals = dailyMeals[selectedBar]
        let label = days[selectedBar].formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(locale))
        return dayMeals.isEmpty ? "\(label) · nothing logged yet" : "\(label) · \(Int(dayMeals.reduce(0) { $0 + $1.calories })) kcal"
    }
    private var topFoods: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for meal in logged.flatMap({ $0 }) {
            let names = (meal.items ?? []).isEmpty ? [meal.title] : (meal.items ?? []).map(\.canonicalName)
            names.forEach { counts[$0, default: 0] += 1 }
        }
        let rows: [(name: String, count: Int)] = counts.map { (name: $0.key, count: $0.value) }
        let sorted = rows.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.name < rhs.name : lhs.count > rhs.count
        }
        return Array(sorted.prefix(5))
    }
}

private struct DayplateMiniMetric: View {
    let label: String, unit: String
    let value: Double, color: Color
    var body: some View {
        VStack(spacing: 4) {
            Text(label).font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(JournalTheme.ink.opacity(0.5))
            Text("\(Int(value.rounded())) \(unit)").font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity).padding(.vertical, 10).background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DayplateMacroTableRow: View {
    let label: String, color: Color
    let values: [Double]
    var body: some View {
        HStack(spacing: 0) {
            Text(label).font(.caption.bold()).foregroundStyle(color).frame(width: 22, alignment: .leading)
            ForEach(values.indices, id: \.self) { index in
                VStack(spacing: 2) {
                    Text(values[index] == 0 ? "—" : "\(Int(values[index].rounded()))")
                        .font(.caption2.weight(.semibold)).foregroundStyle(values[index] == 0 ? JournalTheme.ink.opacity(0.25) : color)
                    if index > 0, values[index] > 0, values[index - 1] > 0, abs(values[index] - values[index - 1]) >= 0.5 {
                        Image(systemName: values[index] > values[index - 1] ? "arrow.up" : "arrow.down")
                            .font(.system(size: 7, weight: .bold)).foregroundStyle(values[index] > values[index - 1] ? JournalTheme.moss : JournalTheme.clay)
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 5)
            }
        }.overlay(alignment: .top) { Divider().opacity(0.45) }
    }
}

private struct DayplateInsightMetric: View {
    let label: String, unit: String
    let value: Double, color: Color
    init(_ label: String, _ value: Double, _ unit: String, _ color: Color) { self.label = label; self.value = value; self.unit = unit; self.color = color }
    var body: some View { VStack(alignment: .leading, spacing: 7) { HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 16); Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(JournalTheme.ink.opacity(0.60)) }; Text("\(Int(value.rounded())) \(unit)").font(.title2.bold()) }.frame(maxWidth: .infinity, alignment: .leading) }
}

private func mealEmoji(_ title: String) -> String {
    let value = title.lowercased()
    if value.contains("coffee") || value.contains("latte") { return "☕" }
    if value.contains("salmon") || value.contains("noodle") || value.contains("miso") { return "🍜" }
    if value.contains("salad") || value.contains("bowl") { return "🥗" }
    if value.contains("sandwich") || value.contains("toast") { return "🥪" }
    if value.contains("banana") || value.contains("fruit") { return "🍌" }
    if value.contains("egg") { return "🍳" }
    return "🍽️"
}
