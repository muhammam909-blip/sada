import SwiftUI

/// Look & feel options (Settings › Appearance).
enum ThemeKeys {
    static let accent = "accentHex"
    static let glass = "glassEnabled.v2"
    static let npBackground = "npBackground"
    static let lyricsSize = "lyricsSize"
    static let libraryStyle = "libraryStyle"
}

enum NowPlayingBackgroundStyle: String, CaseIterable, Identifiable {
    case animated = "Animated Colors"
    case blurred = "Blurred Artwork"
    case black = "Plain Black"
    var id: String { rawValue }
}

enum AccentPreset: String, CaseIterable, Identifiable {
    case pink = "FF2D55", red = "FF3B30", orange = "FF9500", yellow = "FFCC00", green = "34C759",
         mint = "00C7BE", teal = "30B0C7", blue = "0A84FF", indigo = "5E5CE6", purple = "BF5AF2"
    var id: String { rawValue }
    var color: Color { Color(hex: rawValue) }
}

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(max(0, min(1, r)) * 255), Int(max(0, min(1, g)) * 255), Int(max(0, min(1, b)) * 255))
    }
}

/// Uses Liquid Glass buttons when enabled, classic filled/bordered ones otherwise.
struct AdaptiveButtonStyle: ViewModifier {
    var prominent = false
    @AppStorage(ThemeKeys.glass) private var glass = false

    func body(content: Content) -> some View {
        if glass {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

/// Cards shrink slightly while pressed (Spotify / Anghami feel).
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Animated placeholder used while online content loads.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.25), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width * 1.6)
                }
                .clipped()
            }
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }

    func adaptiveButton(prominent: Bool = false) -> some View {
        modifier(AdaptiveButtonStyle(prominent: prominent))
    }
}
