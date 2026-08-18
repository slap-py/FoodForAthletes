import SwiftUI

enum JournalTheme {
    // Shared cream-and-green palette, derived from the app mark.
    static let paper = Color(red: 0.965, green: 0.945, blue: 0.89)
    static let card = Color(red: 1.0, green: 0.99, blue: 0.96)
    static let ink = Color(red: 0.10, green: 0.18, blue: 0.12)
    static let forest = Color(red: 0.10, green: 0.31, blue: 0.18)
    static let moss = Color(red: 0.18, green: 0.35, blue: 0.23)
    static let sage = Color(red: 0.62, green: 0.72, blue: 0.54)
    static let mint = Color(red: 0.87, green: 0.92, blue: 0.84)
    static let oat = Color(red: 0.84, green: 0.73, blue: 0.51)
    static let clay = Color(red: 0.69, green: 0.43, blue: 0.30)
    static let blue = Color(red: 0.35, green: 0.56, blue: 0.61)
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
            .padding(16)
            .background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(JournalTheme.moss.opacity(0.12), lineWidth: 1)
            }
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
