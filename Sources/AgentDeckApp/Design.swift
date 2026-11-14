import SwiftUI
import AppKit
import AgentDeckCore

// MARK: - Palette

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
    init(hex: UInt32) { self.init(light: hex, dark: hex) }
}

enum Deck {
    static let background = Color(light: 0xF2F4F6, dark: 0x101013)
    static let card = Color(light: 0xFFFFFF, dark: 0x1D1D23)
    static let raised = Color(light: 0xF9FAFB, dark: 0x26262E)
    static let text = Color(light: 0x191F28, dark: 0xF2F4F6)
    static let secondary = Color(light: 0x6B7684, dark: 0x9EA4AE)
    static let tertiary = Color(light: 0x8B95A1, dark: 0x7D838E)
    static let track = Color(light: 0xE5E8EB, dark: 0x33333D)
    static let divider = Color(light: 0xF2F4F6, dark: 0x2A2A32)
    static let accent = Color(light: 0x3182F6, dark: 0x4B93F7)
    static let accentSoft = Color(light: 0xE8F3FF, dark: 0x1B2C45)
    static let warning = Color(light: 0xFE9800, dark: 0xFFA733)
    static let warningSoft = Color(light: 0xFFF3E0, dark: 0x3A2A12)
    static let danger = Color(light: 0xF04452, dark: 0xFF5C69)
    static let dangerSoft = Color(light: 0xFFEEEE, dark: 0x3D1B1F)
    static let success = Color(light: 0x03B26C, dark: 0x2BC883)

    static func tint(for level: Double, stale: Bool = false) -> Color {
        if stale { return tertiary }
        return level >= 0.9 ? danger : level >= 0.7 ? warning : accent
    }
    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    static func money(_ value: Double, _ currency: String) -> String {
        value.formatted(.currency(code: currency.isEmpty ? "USD" : currency).precision(.fractionLength(2)))
    }
    static func resetText(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Window reset" }
        let hours = Int(seconds) / 3600, minutes = (Int(seconds) % 3600) / 60
        let relative = hours >= 48 ? "\(hours / 24)d \(hours % 24)h" : hours > 0 ? "\(hours)h \(minutes)m" : "\(max(1, minutes))m"
        return "Resets in \(relative)"
    }
}

// MARK: - Building blocks

struct DeckCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Deck.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct CardTitle: View {
    let text: String
    var trailing: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.system(size: 15, weight: .bold)).foregroundStyle(Deck.text)
            Spacer()
            if !trailing.isEmpty { Text(trailing).font(.system(size: 12, weight: .medium)).foregroundStyle(Deck.tertiary) }
        }
    }
}

struct UsageBar: View {
    let value: Double
    var tint: Color = Deck.accent
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Deck.track)
                Capsule().fill(tint).frame(width: max(value > 0 ? height : 0, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.35), value: value)
    }
}

struct Pill: View {
    let text: String
    var foreground: Color = Deck.secondary
    var background: Color = Deck.raised
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(foreground)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(background, in: Capsule())
    }
}

struct DeckButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    var kind: Kind = .primary
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(kind == .primary ? Color.white : kind == .secondary ? Deck.text : Deck.accent)
            .padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 6 : 9)
            .background(kind == .primary ? Deck.accent : kind == .secondary ? Deck.raised : Color.clear,
                        in: RoundedRectangle(cornerRadius: compact ? 9 : 11, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Deck.secondary)
                .frame(width: 30, height: 30).background(Deck.raised, in: Circle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

struct RefreshButton: View {
    let refreshing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: "arrow.clockwise").opacity(refreshing ? 0 : 1)
                if refreshing {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
            }
            .frame(width: 18, height: 18)
        }
        .disabled(refreshing)
        .help(refreshing ? "Refreshing providers…" : "Refresh all providers")
        .accessibilityLabel("Refresh all providers")
        .accessibilityValue(refreshing ? "Refreshing" : "Ready")
    }
}

struct Banner: View {
    enum Tone { case info, warning, danger }
    let tone: Tone
    let symbol: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tone == .info ? Deck.accent : tone == .warning ? Deck.warning : Deck.danger)
        .padding(14)
        .background(tone == .info ? Deck.accentSoft : tone == .warning ? Deck.warningSoft : Deck.dangerSoft,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Provider icons

/// Fallback for providers without product artwork (self-hosted "Local models").
struct ProviderStyle {
    let colors: (UInt32, UInt32)
    let symbol: String?
    static func of(_ id: String) -> ProviderStyle {
        id == "local" ? .init(colors: (0x6B7684, 0x3F4651), symbol: "desktopcomputer") : .init(colors: (0x8B95A1, 0x4E5968), symbol: "cpu")
    }
}

/// Product artwork shipped in Resources/ProviderIcons (see THIRD_PARTY_NOTICES.md). Trademarks belong to
/// their owners and are used only to identify each provider.
enum ProviderArtwork {
    static let folder: URL? = {
        let exe = CurrentExecutable.url
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("ProviderIcons"),
                          exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/ProviderIcons"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/ProviderIcons")]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }()
    @MainActor private static var cache: [String: NSImage] = [:]
    @MainActor static func image(_ id: String, dark: Bool) -> NSImage? {
        let key = id + (dark ? "-dark" : "")
        if let hit = cache[key] { return hit }
        guard let folder else { return nil }
        let image = (dark ? NSImage(contentsOf: folder.appendingPathComponent("\(id)-dark.png")) : nil)
            ?? NSImage(contentsOf: folder.appendingPathComponent("\(id).png"))
        if let image { cache[key] = image }
        return image
    }
}

struct ProviderIcon: View {
    let id: String
    var size: CGFloat = 36
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack {
            if let image = ProviderArtwork.image(id, dark: scheme == .dark) {
                shape.fill(Color(light: 0xFFFFFF, dark: 0x2A2A32))
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .padding(size * 0.18)
                shape.strokeBorder(Color(light: 0xE5E8EB, dark: 0x3A3A44), lineWidth: 1)
            } else {
                let style = ProviderStyle.of(id)
                shape.fill(LinearGradient(colors: [Color(hex: style.colors.0), Color(hex: style.colors.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: style.symbol ?? "cpu").font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Menu bar status

enum DeckMenuStatus {
    case normal, warning, critical, stale

    var description: String {
        switch self {
        case .normal: return "Usage within limits"
        case .warning: return "Approaching a usage limit"
        case .critical: return "Usage limit nearly reached"
        case .stale: return "Previous usage data; refresh pending"
        }
    }

    var image: NSImage {
        switch self {
        case .normal: return DeckGlyph.image
        case .warning: return DeckGlyph.warning
        case .critical: return DeckGlyph.critical
        case .stale: return NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: description)!
        }
    }
}

// Normal status follows the menu bar appearance; alerts carry their own color.

enum DeckGlyph {
    static let image = makeImage()
    static let warning = makeImage(color: .systemOrange)
    static let critical = makeImage(color: .systemRed)

    private static func makeImage(color: NSColor? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            let ink = color ?? .black
            ink.setStroke(); ink.setFill()
            let back = NSBezierPath(roundedRect: NSRect(x: 5.5, y: 6.5, width: 11, height: 8), xRadius: 2, yRadius: 2)
            back.lineWidth = 1.4; back.stroke()
            let front = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 11, height: 9), xRadius: 2.2, yRadius: 2.2)
            front.fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let bar = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 4, width: 6, height: 1.8), xRadius: 0.9, yRadius: 0.9)
            bar.fill()
            let bar2 = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 6.8, width: 4, height: 1.8), xRadius: 0.9, yRadius: 0.9)
            bar2.fill()
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = "AgentDeck"
        return image
    }
}
