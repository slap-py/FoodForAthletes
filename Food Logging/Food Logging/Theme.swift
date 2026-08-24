import SwiftUI
import UIKit

enum JournalTheme {
    private static func adaptive(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light })
    }

    // Shared cream-and-green palette. The dark surfaces are near-neutral warm
    // charcoals that keep only a trace of the green hue, and the dark accents are
    // desaturated toward olive so the theme reads calm rather than phosphor-green.
    static let paper = adaptive(UIColor(red: 0.965, green: 0.945, blue: 0.89, alpha: 1), UIColor(red: 0.068, green: 0.075, blue: 0.067, alpha: 1))
    static let card = adaptive(UIColor(red: 1.0, green: 0.99, blue: 0.96, alpha: 1), UIColor(red: 0.113, green: 0.122, blue: 0.111, alpha: 1))
    static let ink = adaptive(UIColor(red: 0.10, green: 0.18, blue: 0.12, alpha: 1), UIColor(red: 0.918, green: 0.922, blue: 0.902, alpha: 1))
    static let forest = adaptive(UIColor(red: 0.10, green: 0.31, blue: 0.18, alpha: 1), UIColor(red: 0.62, green: 0.70, blue: 0.60, alpha: 1))
    static let moss = adaptive(UIColor(red: 0.18, green: 0.35, blue: 0.23, alpha: 1), UIColor(red: 0.57, green: 0.65, blue: 0.55, alpha: 1))
    static let sage = adaptive(UIColor(red: 0.62, green: 0.72, blue: 0.54, alpha: 1), UIColor(red: 0.40, green: 0.44, blue: 0.37, alpha: 1))
    static let mint = adaptive(UIColor(red: 0.87, green: 0.92, blue: 0.84, alpha: 1), UIColor(red: 0.175, green: 0.190, blue: 0.170, alpha: 1))
    static let oat = Color(red: 0.84, green: 0.73, blue: 0.51)
    static let clay = Color(red: 0.69, green: 0.43, blue: 0.30)
    static let blue = Color(red: 0.35, green: 0.56, blue: 0.61)
}

enum PortionDisplay {
    static func text(_ raw: String, unitSystem: String) -> String {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*g\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).last,
              let amountRange = Range(match.range(at: 1), in: raw),
              let grams = Double(raw[amountRange]) else { return raw }

        let matchStart = Range(match.range, in: raw)?.lowerBound ?? raw.endIndex
        let beforeAmount = String(raw[..<matchStart])
        let label: String
        if let parenthesis = beforeAmount.firstIndex(of: "(") {
            label = String(beforeAmount[..<parenthesis]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            label = beforeAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let amount: String
        if unitSystem == "us" {
            amount = "\((grams / 28.3495).formatted(.number.precision(.fractionLength(0...1)))) oz"
        } else {
            amount = "\(Int(grams.rounded())) g"
        }
        return label.isEmpty ? amount : "\(label) (\(amount))"
    }
}

enum WaterDisplay {
    static func amount(_ milliliters: Double, unitSystem: String) -> String {
        guard unitSystem == "us" else {
            return "\(Int(milliliters.rounded())) mL"
        }

        return "\(Int((milliliters / 29.5735).rounded())) oz"
    }

    static func total(_ milliliters: Double, unitSystem: String) -> String {
        "\(amount(milliliters, unitSystem: unitSystem)) water"
    }
}

struct JournalCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(JournalTheme.moss.opacity(0.12), lineWidth: 1)
            }
    }
}

enum MealEmoji {
    static func symbol(for meal: MealLog) -> String {
        let itemNames = (meal.items ?? []).map(\.canonicalName)
        return symbol(for: ([meal.title, meal.descriptionText] + itemNames).joined(separator: " "))
    }

    static func symbol(for title: String) -> String {
        let value = title.lowercased()
        let mappings: [(String, String)] = [
            ("bacon", "🥓"), ("egg", "🍳"), ("pizza", "🍕"), ("burger", "🍔"),
            ("hamburger", "🍔"), ("fries", "🍟"), ("taco", "🌮"), ("burrito", "🌯"),
            ("steak", "🥩"), ("beef", "🥩"), ("chicken", "🍗"), ("turkey", "🍗"),
            ("sushi", "🍣"), ("salmon", "🍣"), ("tuna", "🍣"), ("fish", "🐟"),
            ("ramen", "🍜"), ("noodle", "🍜"), ("miso", "🍜"), ("pasta", "🍝"),
            ("spaghetti", "🍝"), ("rice", "🍚"), ("salad", "🥗"), ("bowl", "🥗"),
            ("sandwich", "🥪"), ("toast", "🥪"), ("hot dog", "🌭"), ("soup", "🥣"),
            ("oatmeal", "🥣"), ("cereal", "🥣"), ("yogurt", "🥣"), ("coffee", "☕"),
            ("latte", "☕"), ("tea", "🍵"), ("smoothie", "🥤"), ("banana", "🍌"),
            ("apple", "🍎"), ("strawber", "🍓"), ("berry", "🫐"), ("fruit", "🍇"),
            ("pop-tart", "🍫"), ("pop tart", "🍫"), ("chocolate", "🍫"), ("donut", "🍩"),
            ("doughnut", "🍩"), ("croissant", "🥐"), ("pastry", "🥐"), ("pancake", "🥞"),
            ("waffle", "🧇"), ("cookie", "🍪"), ("cake", "🍰"), ("ice cream", "🍨")
        ]
        return mappings.first(where: { value.contains($0.0) })?.1 ?? "🍽️"
    }
}

struct SectionTitle: View {
    let eyebrow: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(JournalTheme.moss)
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(JournalTheme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MacroValue: View {
    let label: String
    let value: Double
    let color: Color
    var unit: String = "g"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 4, height: 17)
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(JournalTheme.ink.opacity(0.68))
            }
            Text("\(Int(value.rounded())) \(unit)")
                .font(.title2.weight(.bold))
                .foregroundStyle(JournalTheme.ink)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(Int(value.rounded())) \(unit)")
    }
}
