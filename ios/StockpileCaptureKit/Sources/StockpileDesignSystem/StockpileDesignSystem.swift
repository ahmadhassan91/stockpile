import SwiftUI

public enum StockpileDesignSystemNamespace {}

public struct StockpileColorValue: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

public enum StockpilePalette {
    public static let canvas = StockpileColorValue(red: 0.97, green: 0.95, blue: 0.92)
    public static let surface = StockpileColorValue(red: 1.0, green: 1.0, blue: 1.0)
    public static let elevatedSurface = StockpileColorValue(red: 0.95, green: 0.92, blue: 0.89)
    public static let ink = StockpileColorValue(red: 0.12, green: 0.13, blue: 0.15)
    public static let mutedInk = StockpileColorValue(red: 0.41, green: 0.48, blue: 0.51)
    public static let accent = StockpileColorValue(red: 0.49, green: 0.19, blue: 0.21)
    public static let success = StockpileColorValue(red: 0.37, green: 0.44, blue: 0.47)
    public static let caution = StockpileColorValue(red: 0.64, green: 0.48, blue: 0.18)
    public static let critical = StockpileColorValue(red: 0.44, green: 0.18, blue: 0.20)
    public static let border = StockpileColorValue(red: 0.87, green: 0.83, blue: 0.79)
}

public enum StockpileSpacing {
    public static let xxxSmall: CGFloat = 4
    public static let xxSmall: CGFloat = 6
    public static let xSmall: CGFloat = 8
    public static let small: CGFloat = 12
    public static let medium: CGFloat = 16
    public static let large: CGFloat = 24
    public static let xLarge: CGFloat = 32
    public static let xxLarge: CGFloat = 40
    public static let xxxLarge: CGFloat = 48
}

public enum StockpileCornerRadius {
    public static let badge: CGFloat = 999
    public static let button: CGFloat = 18
    public static let card: CGFloat = 24
}

public struct StockpileTypeToken: Equatable, Sendable {
    public let size: CGFloat
    public let weight: Font.Weight

    public init(size: CGFloat, weight: Font.Weight) {
        self.size = size
        self.weight = weight
    }

    public var font: Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

public enum StockpileTypography {
    public static let hero = StockpileTypeToken(size: 34, weight: .bold)
    public static let metric = StockpileTypeToken(size: 44, weight: .bold)
    public static let sectionTitle = StockpileTypeToken(size: 22, weight: .semibold)
    public static let body = StockpileTypeToken(size: 17, weight: .regular)
    public static let callout = StockpileTypeToken(size: 15, weight: .medium)
    public static let caption = StockpileTypeToken(size: 13, weight: .medium)
}

public struct StockpileStatusTheme: Equatable, Sendable {
    public let accent: StockpileColorValue
    public let background: StockpileColorValue
    public let foreground: StockpileColorValue
}

public enum StockpileStatusTone: CaseIterable, Sendable {
    case info
    case success
    case caution
    case critical

    public var theme: StockpileStatusTheme {
        switch self {
        case .info:
            return StockpileStatusTheme(
                accent: StockpilePalette.accent,
                background: StockpileColorValue(red: 0.95, green: 0.91, blue: 0.90),
                foreground: StockpilePalette.ink
            )
        case .success:
            return StockpileStatusTheme(
                accent: StockpilePalette.success,
                background: StockpileColorValue(red: 0.90, green: 0.93, blue: 0.93),
                foreground: StockpilePalette.ink
            )
        case .caution:
            return StockpileStatusTheme(
                accent: StockpilePalette.caution,
                background: StockpileColorValue(red: 0.97, green: 0.93, blue: 0.86),
                foreground: StockpilePalette.ink
            )
        case .critical:
            return StockpileStatusTheme(
                accent: StockpilePalette.critical,
                background: StockpileColorValue(red: 0.95, green: 0.89, blue: 0.89),
                foreground: StockpilePalette.ink
            )
        }
    }
}

public struct StockpileButtonTokens: Equatable, Sendable {
    public let background: StockpileColorValue
    public let foreground: StockpileColorValue
    public let minimumHeight: CGFloat
    public let cornerRadius: CGFloat
}

public enum StockpileButtonRole: Sendable {
    case primary
    case secondary

    public var tokens: StockpileButtonTokens {
        switch self {
        case .primary:
            return StockpileButtonTokens(
                background: StockpilePalette.accent,
                foreground: StockpilePalette.surface,
                minimumHeight: 56,
                cornerRadius: StockpileCornerRadius.button
            )
        case .secondary:
            return StockpileButtonTokens(
                background: StockpileColorValue(red: 0.95, green: 0.92, blue: 0.89),
                foreground: StockpilePalette.ink,
                minimumHeight: 56,
                cornerRadius: StockpileCornerRadius.button
            )
        }
    }
}

public struct StockpileShadowTokens: Equatable, Sendable {
    public let color: StockpileColorValue
    public let radius: CGFloat
    public let y: CGFloat
    public let opacity: Double
}

public struct StockpileCardTokens: Equatable, Sendable {
    public let background: StockpileColorValue
    public let border: StockpileColorValue
    public let cornerRadius: CGFloat
    public let shadow: StockpileShadowTokens
}

public enum StockpileCardAppearance: Sendable {
    case elevated
    case outlined

    public var tokens: StockpileCardTokens {
        switch self {
        case .elevated:
            return StockpileCardTokens(
                background: StockpilePalette.surface,
                border: StockpilePalette.border,
                cornerRadius: StockpileCornerRadius.card,
                shadow: StockpileShadowTokens(
                    color: StockpilePalette.ink,
                    radius: 16,
                    y: 8,
                    opacity: 0.10
                )
            )
        case .outlined:
            return StockpileCardTokens(
                background: StockpilePalette.canvas,
                border: StockpilePalette.border,
                cornerRadius: StockpileCornerRadius.card,
                shadow: StockpileShadowTokens(
                    color: StockpilePalette.ink,
                    radius: 0,
                    y: 0,
                    opacity: 0
                )
            )
        }
    }
}

public struct StockpileCard<Content: View>: View {
    private let appearance: StockpileCardAppearance
    private let content: Content

    public init(
        appearance: StockpileCardAppearance = .elevated,
        @ViewBuilder content: () -> Content
    ) {
        self.appearance = appearance
        self.content = content()
    }

    public var body: some View {
        let tokens = appearance.tokens

        return content
            .padding(StockpileSpacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tokens.background.color, in: RoundedRectangle(cornerRadius: tokens.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: tokens.cornerRadius)
                    .stroke(tokens.border.color, lineWidth: 1)
            )
            .shadow(
                color: tokens.shadow.color.color.opacity(tokens.shadow.opacity),
                radius: tokens.shadow.radius,
                y: tokens.shadow.y
            )
    }
}

public struct StockpileBadge: View {
    private let label: String
    private let tone: StockpileStatusTone

    public init(_ label: String, tone: StockpileStatusTone) {
        self.label = label
        self.tone = tone
    }

    public var body: some View {
        let theme = tone.theme

        return HStack(spacing: StockpileSpacing.xxSmall) {
            Circle()
                .fill(theme.accent.color)
                .frame(width: 8, height: 8)

            Text(label)
                .font(StockpileTypography.caption.font)
                .foregroundStyle(theme.foreground.color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, StockpileSpacing.small)
        .padding(.vertical, StockpileSpacing.xSmall)
        .background(theme.background.color, in: Capsule())
    }
}

public struct StockpileActionButtonStyle: ButtonStyle {
    private let role: StockpileButtonRole

    public init(role: StockpileButtonRole) {
        self.role = role
    }

    public func makeBody(configuration: Configuration) -> some View {
        let tokens = role.tokens

        return configuration.label
            .font(StockpileTypography.callout.font.weight(.semibold))
            .foregroundStyle(tokens.foreground.color)
            .frame(maxWidth: .infinity)
            .frame(minHeight: tokens.minimumHeight)
            .background(tokens.background.color.opacity(configuration.isPressed ? 0.90 : 1), in: RoundedRectangle(cornerRadius: tokens.cornerRadius))
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

public struct StockpileMetricCard: View {
    private let label: String
    private let value: String
    private let note: String?

    public init(label: String, value: String, note: String? = nil) {
        self.label = label
        self.value = value
        self.note = note
    }

    public var body: some View {
        StockpileCard {
            VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                Text(label.uppercased())
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)

                Text(value)
                    .font(StockpileTypography.metric.font)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(StockpilePalette.ink.color)

                if let note {
                    Text(note)
                        .font(StockpileTypography.callout.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                }
            }
        }
    }
}

public struct StockpileGuidanceBanner: View {
    private let title: String
    private let message: String
    private let tone: StockpileStatusTone

    public init(title: String, message: String, tone: StockpileStatusTone) {
        self.title = title
        self.message = message
        self.tone = tone
    }

    public var body: some View {
        let theme = tone.theme

        return HStack(alignment: .top, spacing: StockpileSpacing.medium) {
            Circle()
                .fill(theme.accent.color)
                .frame(width: 10, height: 10)
                .padding(.top, StockpileSpacing.xxSmall)

            VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                Text(title)
                    .font(StockpileTypography.callout.font.weight(.semibold))
                    .foregroundStyle(theme.foreground.color)

                Text(message)
                    .font(StockpileTypography.body.font)
                    .foregroundStyle(theme.foreground.color.opacity(0.82))
            }
        }
        .padding(StockpileSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background.color, in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card))
    }
}

public struct StockpileFieldScreenModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .padding(StockpileSpacing.large)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(StockpilePalette.canvas.color.ignoresSafeArea())
    }
}

public extension View {
    func stockpileFieldScreen() -> some View {
        modifier(StockpileFieldScreenModifier())
    }
}
