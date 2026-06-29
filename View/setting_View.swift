import SwiftUI
import Combine

// MARK: - Theme Preset

struct ThemePreset {
    var background: Color
    var text: Color
    var secondaryText: Color
    var accent: Color
    var tint: Color
    var gonioSides: Color
    var gonioMids: Color
    var playButton: Color
    var useWaterShader: Bool
    var waterSpeed: Double
    var waterIntensity: Double

    static let empty = ThemePreset(
        background: .black,
        text: .white,
        secondaryText: .gray,
        accent: .blue,
        tint: .blue,
        gonioSides: .red,
        gonioMids: .purple,
        playButton: .white,
        useWaterShader: false,
        waterSpeed: 1.0,
        waterIntensity: 0.5
    )
}

// MARK: - Named Themes

enum AppTheme: String, CaseIterable, Identifiable {
    // Dark
    case minimalDark    = "Default"
    case atom           = "Atom"
    case ayu            = "Ayu"
    case catppuccin     = "Catppuccin"
    case dracula        = "Dracula"
    case eink           = "E-ink"
    case everforestDark = "Everforest"
    case flexoki        = "Flexoki"
    case gruvboxDark    = "Gruvbox"
    case macos          = "macOS"
    case nord           = "Nord"
    case rosePineDark   = "Rosé Pine"
    case sky            = "Sky"
    case solarizedDark  = "Solarized"
    case things         = "Things"
    case water          = "Water"

    // Light
    case minimalLight    = "Default (Light)"
    case atomLight       = "Atom (Light)"
    case ayuLight        = "Ayu (Light)"
    case catppuccinLight = "Catppuccin (Light)"
    case einkLight       = "E-ink (Light)"
    case everforestLight = "Everforest (Light)"
    case flexokiLight    = "Flexoki (Light)"
    case gruvboxLight    = "Gruvbox (Light)"
    case macosLight      = "macOS (Light)"
    case nordLight       = "Nord (Light)"
    case rosePineLight   = "Rosé Pine Dawn"
    case skyLight        = "Sky (Light)"
    case solarizedLight  = "Solarized (Light)"
    case thingsLight     = "Things (Light)"

    var id: String { rawValue }

    static var darkThemes: [AppTheme] {
        [.minimalDark, .atom, .ayu, .catppuccin, .dracula, .eink,
         .everforestDark, .flexoki, .gruvboxDark, .macos, .nord,
         .rosePineDark, .sky, .solarizedDark, .things, .water]
    }

    static var lightThemes: [AppTheme] {
        [.minimalLight, .atomLight, .ayuLight, .catppuccinLight, .einkLight,
         .everforestLight, .flexokiLight, .gruvboxLight, .macosLight, .nordLight,
         .rosePineLight, .skyLight, .solarizedLight, .thingsLight]
    }

    // MARK: Colour values for each theme

    var preset: ThemePreset {
        switch self {

        // ── Dark themes ──────────────────────────────────────────────────────

        case .minimalDark:
            return ThemePreset(
                background:    Color(hex: "#1a1a1a"),
                text:          Color(hex: "#dadada"),
                secondaryText: Color(hex: "#888888"),
                accent:        Color(hex: "#7b6cd4"),
                tint:          Color(hex: "#7b6cd4"),
                gonioSides:    Color(hex: "#c9a8f5"),
                gonioMids:     Color(hex: "#7b6cd4"),
                playButton:    Color(hex: "#dadada"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .atom:
            return ThemePreset(
                background:    Color(hex: "#282c34"),
                text:          Color(hex: "#abb2bf"),
                secondaryText: Color(hex: "#5c6370"),
                accent:        Color(hex: "#61afef"),
                tint:          Color(hex: "#61afef"),
                gonioSides:    Color(hex: "#e06c75"),
                gonioMids:     Color(hex: "#c678dd"),
                playButton:    Color(hex: "#abb2bf"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .ayu:
            return ThemePreset(
                background:    Color(hex: "#0d1017"),
                text:          Color(hex: "#bfbdb6"),
                secondaryText: Color(hex: "#5c6773"),
                accent:        Color(hex: "#ffb454"),
                tint:          Color(hex: "#ffb454"),
                gonioSides:    Color(hex: "#f07178"),
                gonioMids:     Color(hex: "#d2a6ff"),
                playButton:    Color(hex: "#bfbdb6"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .catppuccin:
            return ThemePreset(
                background:    Color(hex: "#1e1e2e"),
                text:          Color(hex: "#cdd6f4"),
                secondaryText: Color(hex: "#6c7086"),
                accent:        Color(hex: "#cba6f7"),
                tint:          Color(hex: "#cba6f7"),
                gonioSides:    Color(hex: "#f38ba8"),
                gonioMids:     Color(hex: "#89b4fa"),
                playButton:    Color(hex: "#cdd6f4"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .dracula:
            return ThemePreset(
                background:    Color(hex: "#282a36"),
                text:          Color(hex: "#f8f8f2"),
                secondaryText: Color(hex: "#6272a4"),
                accent:        Color(hex: "#bd93f9"),
                tint:          Color(hex: "#bd93f9"),
                gonioSides:    Color(hex: "#ff79c6"),
                gonioMids:     Color(hex: "#8be9fd"),
                playButton:    Color(hex: "#f8f8f2"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .eink:
            return ThemePreset(
                background:    Color(hex: "#1c1c1c"),
                text:          Color(hex: "#e8e8e8"),
                secondaryText: Color(hex: "#888888"),
                accent:        Color(hex: "#aaaaaa"),
                tint:          Color(hex: "#aaaaaa"),
                gonioSides:    Color(hex: "#cccccc"),
                gonioMids:     Color(hex: "#888888"),
                playButton:    Color(hex: "#e8e8e8"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .everforestDark:
            return ThemePreset(
                background:    Color(hex: "#2d353b"),
                text:          Color(hex: "#d3c6aa"),
                secondaryText: Color(hex: "#7a8478"),
                accent:        Color(hex: "#a7c080"),
                tint:          Color(hex: "#a7c080"),
                gonioSides:    Color(hex: "#e67e80"),
                gonioMids:     Color(hex: "#83c092"),
                playButton:    Color(hex: "#d3c6aa"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .flexoki:
            return ThemePreset(
                background:    Color(hex: "#100f0f"),
                text:          Color(hex: "#cecdc3"),
                secondaryText: Color(hex: "#575653"),
                accent:        Color(hex: "#d0a215"),
                tint:          Color(hex: "#d0a215"),
                gonioSides:    Color(hex: "#af3029"),
                gonioMids:     Color(hex: "#8b7ec8"),
                playButton:    Color(hex: "#cecdc3"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .gruvboxDark:
            return ThemePreset(
                background:    Color(hex: "#282828"),
                text:          Color(hex: "#ebdbb2"),
                secondaryText: Color(hex: "#928374"),
                accent:        Color(hex: "#fabd2f"),
                tint:          Color(hex: "#fabd2f"),
                gonioSides:    Color(hex: "#fb4934"),
                gonioMids:     Color(hex: "#b8bb26"),
                playButton:    Color(hex: "#ebdbb2"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .macos:
            return ThemePreset(
                background:    Color(hex: "#1e1e1e"),
                text:          Color(hex: "#ffffff"),
                secondaryText: Color(hex: "#8e8e93"),
                accent:        Color(hex: "#0a84ff"),
                tint:          Color(hex: "#0a84ff"),
                gonioSides:    Color(hex: "#ff453a"),
                gonioMids:     Color(hex: "#30d158"),
                playButton:    Color(hex: "#ffffff"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .nord:
            return ThemePreset(
                background:    Color(hex: "#2e3440"),
                text:          Color(hex: "#eceff4"),
                secondaryText: Color(hex: "#4c566a"),
                accent:        Color(hex: "#88c0d0"),
                tint:          Color(hex: "#88c0d0"),
                gonioSides:    Color(hex: "#bf616a"),
                gonioMids:     Color(hex: "#b48ead"),
                playButton:    Color(hex: "#eceff4"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .rosePineDark:
            return ThemePreset(
                background:    Color(hex: "#191724"),
                text:          Color(hex: "#e0def4"),
                secondaryText: Color(hex: "#6e6a86"),
                accent:        Color(hex: "#c4a7e7"),
                tint:          Color(hex: "#c4a7e7"),
                gonioSides:    Color(hex: "#eb6f92"),
                gonioMids:     Color(hex: "#9ccfd8"),
                playButton:    Color(hex: "#e0def4"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .sky:
            return ThemePreset(
                background:    Color(hex: "#1b2433"),
                text:          Color(hex: "#cdd9e5"),
                secondaryText: Color(hex: "#545d68"),
                accent:        Color(hex: "#539bf5"),
                tint:          Color(hex: "#539bf5"),
                gonioSides:    Color(hex: "#e5534b"),
                gonioMids:     Color(hex: "#57ab5a"),
                playButton:    Color(hex: "#cdd9e5"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .solarizedDark:
            return ThemePreset(
                background:    Color(hex: "#002b36"),
                text:          Color(hex: "#839496"),
                secondaryText: Color(hex: "#586e75"),
                accent:        Color(hex: "#268bd2"),
                tint:          Color(hex: "#268bd2"),
                gonioSides:    Color(hex: "#dc322f"),
                gonioMids:     Color(hex: "#2aa198"),
                playButton:    Color(hex: "#839496"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .things:
            return ThemePreset(
                background:    Color(hex: "#1c1c1e"),
                text:          Color(hex: "#f2f2f7"),
                secondaryText: Color(hex: "#636366"),
                accent:        Color(hex: "#4f8ef7"),
                tint:          Color(hex: "#4f8ef7"),
                gonioSides:    Color(hex: "#ff6b6b"),
                gonioMids:     Color(hex: "#5ac8fa"),
                playButton:    Color(hex: "#f2f2f7"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .water:
            return ThemePreset(
                background:    Color(hex: "#020e1e"),
                text:          Color(hex: "#cceeff"),
                secondaryText: Color(hex: "#4d8fa8"),
                accent:        Color(hex: "#2dd4bf"),
                tint:          Color(hex: "#2dd4bf"),
                gonioSides:    Color(hex: "#67e8f9"),
                gonioMids:     Color(hex: "#0ea5e9"),
                playButton:    Color(hex: "#cceeff"),
                useWaterShader: true,
                waterSpeed:    1.0,
                waterIntensity: 0.8
            )

        // ── Light themes ─────────────────────────────────────────────────────

        case .minimalLight:
            return ThemePreset(
                background:    Color(hex: "#f5f5f5"),
                text:          Color(hex: "#1a1a1a"),
                secondaryText: Color(hex: "#888888"),
                accent:        Color(hex: "#7b6cd4"),
                tint:          Color(hex: "#7b6cd4"),
                gonioSides:    Color(hex: "#c9a8f5"),
                gonioMids:     Color(hex: "#7b6cd4"),
                playButton:    Color(hex: "#1a1a1a"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .atomLight:
            return ThemePreset(
                background:    Color(hex: "#fafafa"),
                text:          Color(hex: "#383a42"),
                secondaryText: Color(hex: "#a0a1a7"),
                accent:        Color(hex: "#4078f2"),
                tint:          Color(hex: "#4078f2"),
                gonioSides:    Color(hex: "#e45649"),
                gonioMids:     Color(hex: "#a626a4"),
                playButton:    Color(hex: "#383a42"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .ayuLight:
            return ThemePreset(
                background:    Color(hex: "#fafafa"),
                text:          Color(hex: "#5c6166"),
                secondaryText: Color(hex: "#abb0b6"),
                accent:        Color(hex: "#ff9940"),
                tint:          Color(hex: "#ff9940"),
                gonioSides:    Color(hex: "#f07171"),
                gonioMids:     Color(hex: "#a37acc"),
                playButton:    Color(hex: "#5c6166"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .catppuccinLight:
            return ThemePreset(
                background:    Color(hex: "#eff1f5"),
                text:          Color(hex: "#4c4f69"),
                secondaryText: Color(hex: "#9ca0b0"),
                accent:        Color(hex: "#8839ef"),
                tint:          Color(hex: "#8839ef"),
                gonioSides:    Color(hex: "#d20f39"),
                gonioMids:     Color(hex: "#1e66f5"),
                playButton:    Color(hex: "#4c4f69"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .einkLight:
            return ThemePreset(
                background:    Color(hex: "#f0f0f0"),
                text:          Color(hex: "#111111"),
                secondaryText: Color(hex: "#777777"),
                accent:        Color(hex: "#555555"),
                tint:          Color(hex: "#555555"),
                gonioSides:    Color(hex: "#333333"),
                gonioMids:     Color(hex: "#777777"),
                playButton:    Color(hex: "#111111"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .everforestLight:
            return ThemePreset(
                background:    Color(hex: "#fdf6e3"),
                text:          Color(hex: "#5c6a72"),
                secondaryText: Color(hex: "#a6b0a0"),
                accent:        Color(hex: "#8da101"),
                tint:          Color(hex: "#8da101"),
                gonioSides:    Color(hex: "#f85552"),
                gonioMids:     Color(hex: "#35a77c"),
                playButton:    Color(hex: "#5c6a72"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .flexokiLight:
            return ThemePreset(
                background:    Color(hex: "#fffcf0"),
                text:          Color(hex: "#100f0f"),
                secondaryText: Color(hex: "#b7b5ac"),
                accent:        Color(hex: "#ad8301"),
                tint:          Color(hex: "#ad8301"),
                gonioSides:    Color(hex: "#af3029"),
                gonioMids:     Color(hex: "#5e409d"),
                playButton:    Color(hex: "#100f0f"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .gruvboxLight:
            return ThemePreset(
                background:    Color(hex: "#fbf1c7"),
                text:          Color(hex: "#3c3836"),
                secondaryText: Color(hex: "#928374"),
                accent:        Color(hex: "#b57614"),
                tint:          Color(hex: "#b57614"),
                gonioSides:    Color(hex: "#9d0006"),
                gonioMids:     Color(hex: "#79740e"),
                playButton:    Color(hex: "#3c3836"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .macosLight:
            return ThemePreset(
                background:    Color(hex: "#f5f5f5"),
                text:          Color(hex: "#1c1c1e"),
                secondaryText: Color(hex: "#8e8e93"),
                accent:        Color(hex: "#007aff"),
                tint:          Color(hex: "#007aff"),
                gonioSides:    Color(hex: "#ff3b30"),
                gonioMids:     Color(hex: "#34c759"),
                playButton:    Color(hex: "#1c1c1e"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .nordLight:
            return ThemePreset(
                background:    Color(hex: "#eceff4"),
                text:          Color(hex: "#2e3440"),
                secondaryText: Color(hex: "#9099a8"),
                accent:        Color(hex: "#5e81ac"),
                tint:          Color(hex: "#5e81ac"),
                gonioSides:    Color(hex: "#bf616a"),
                gonioMids:     Color(hex: "#b48ead"),
                playButton:    Color(hex: "#2e3440"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .rosePineLight:
            return ThemePreset(
                background:    Color(hex: "#faf4ed"),
                text:          Color(hex: "#575279"),
                secondaryText: Color(hex: "#9893a5"),
                accent:        Color(hex: "#c84b4b"),
                tint:          Color(hex: "#c84b4b"),
                gonioSides:    Color(hex: "#d95555"),
                gonioMids:     Color(hex: "#56949f"),
                playButton:    Color(hex: "#575279"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .skyLight:
            return ThemePreset(
                background:    Color(hex: "#cdd9e5"),
                text:          Color(hex: "#1b2433"),
                secondaryText: Color(hex: "#768390"),
                accent:        Color(hex: "#0969da"),
                tint:          Color(hex: "#0969da"),
                gonioSides:    Color(hex: "#cf222e"),
                gonioMids:     Color(hex: "#1a7f37"),
                playButton:    Color(hex: "#1b2433"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .solarizedLight:
            return ThemePreset(
                background:    Color(hex: "#fdf6e3"),
                text:          Color(hex: "#657b83"),
                secondaryText: Color(hex: "#93a1a1"),
                accent:        Color(hex: "#268bd2"),
                tint:          Color(hex: "#268bd2"),
                gonioSides:    Color(hex: "#dc322f"),
                gonioMids:     Color(hex: "#2aa198"),
                playButton:    Color(hex: "#657b83"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )

        case .thingsLight:
            return ThemePreset(
                background:    Color(hex: "#f2f2f7"),
                text:          Color(hex: "#1c1c1e"),
                secondaryText: Color(hex: "#8e8e93"),
                accent:        Color(hex: "#4f8ef7"),
                tint:          Color(hex: "#4f8ef7"),
                gonioSides:    Color(hex: "#ff6b6b"),
                gonioMids:     Color(hex: "#5ac8fa"),
                playButton:    Color(hex: "#1c1c1e"),
                useWaterShader: false,
                waterSpeed: 1.0, waterIntensity: 0.5
            )
        }
    }
}

// MARK: - Hex colour helper

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Appearance Mode

enum AppearanceMode: String, CaseIterable {
    case light = "Light"
    case dark  = "Dark"
}

class ThemeManager: ObservableObject {
    // Default to Nord
    @Published var backgroundColor    = Color(hex: "#2e3440")
    @Published var textColor          = Color(hex: "#eceff4")
    @Published var accentColor        = Color(hex: "#4c566a")
    @Published var secondaryTextColor = Color(hex: "#88c0d0")
    @Published var tint               = Color(hex: "#88c0d0")
    @Published var gonioSidesColor    = Color(hex: "#bf616a")
    @Published var gonioMidsColor     = Color(hex: "#b48ead")
    @Published var playButtonColor    = Color(hex: "#eceff4")
    @Published var useWaterShader: Bool   = false
    // Fixed aqua blue — not user-configurable
    let waterColor: Color                 = Color(hex: "#2A7FAA")
    @Published var waterSpeed: Double     = 1.0
    @Published var waterIntensity: Double = 0.5
    @Published var appearanceMode: AppearanceMode = .dark
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var theme: ThemeManager

    // Local state mirrors ThemeManager so changes can be observed in the preview
    @State private var backgroundColor:    Color  = Color(hex: "#faf4ed")
    @State private var textColor:          Color  = Color(hex: "#575279")
    @State private var secondaryTextColor: Color  = Color(hex: "#9893a5")
    @State private var accentColor:        Color  = Color(hex: "#c84b4b")
    @State private var tintColor:          Color  = Color(hex: "#c84b4b")
    @State private var gonioSidesColor:    Color  = Color(hex: "#d95555")
    @State private var gonioMidsColor:     Color  = Color(hex: "#56949f")
    @State private var playButtonColor:    Color  = Color(hex: "#575279")
    @State private var useWaterShader:     Bool   = false
    @State private var waterSpeed:         Double = 1.0
    @State private var waterIntensity:     Double = 0.5

    @State private var selectedDarkTheme:  AppTheme = .minimalDark
    @State private var selectedLightTheme: AppTheme = .rosePineLight
    @State private var appearanceMode:     AppearanceMode = .light
    @State private var didInitialize = false

    var body: some View {
        ZStack {
            if useWaterShader {
                WaterShaderView()
            } else {
                backgroundColor.ignoresSafeArea()
            }

            ScrollView {
                VStack(spacing: 24) {
                    themePreview
                    themeSelectorsSection
                    waterShaderSection
                }
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !didInitialize else { return }
                loadFromTheme()
                didInitialize = true
            }
            // Propagate local state → ThemeManager
            .onChange(of: backgroundColor)    { _, v in theme.backgroundColor    = v }
            .onChange(of: textColor)          { _, v in theme.textColor          = v }
            .onChange(of: secondaryTextColor) { _, v in theme.secondaryTextColor = v }
            .onChange(of: accentColor)        { _, v in theme.accentColor        = v }
            .onChange(of: tintColor)          { _, v in theme.tint               = v }
            .onChange(of: gonioSidesColor)    { _, v in theme.gonioSidesColor    = v }
            .onChange(of: gonioMidsColor)     { _, v in theme.gonioMidsColor     = v }
            .onChange(of: playButtonColor)    { _, v in theme.playButtonColor    = v }
            .onChange(of: useWaterShader)     { _, v in theme.useWaterShader     = v }
            .onChange(of: waterSpeed)         { _, v in theme.waterSpeed         = v }
            .onChange(of: waterIntensity)     { _, v in theme.waterIntensity     = v }
            .onChange(of: appearanceMode)     { _, v in
                theme.appearanceMode = v
                applyActiveTheme()
            }
        }
    }

    // MARK: - Theme Preview

    private var themePreview: some View {
        VStack(spacing: 14) {
            Text("Preview")
                .font(.headline)
                .foregroundStyle(textColor)

            HStack(spacing: 12) {
                previewSwatch("Background",  backgroundColor)
                previewSwatch("Text",        textColor)
                previewSwatch("Secondary",   secondaryTextColor)
                previewSwatch("Accent",      accentColor)
            }
            HStack(spacing: 12) {
                previewSwatch("Tint",        tintColor)
                previewSwatch("Sides",       gonioSidesColor)
                previewSwatch("Mids",        gonioMidsColor)
                previewSwatch("Play",        playButtonColor)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(backgroundColor.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(textColor.opacity(0.08), lineWidth: 1)
                )
        )
        .padding(.horizontal)
    }

    private func previewSwatch(_ label: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color)
                .frame(height: 36)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(textColor.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Theme Selectors

    private var themeSelectorsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Colour Scheme")
                .font(.headline)
                .foregroundStyle(textColor)
                .padding(.horizontal)

            // Light / Dark toggle
            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance")
                    .font(.subheadline)
                    .foregroundStyle(textColor.opacity(0.7))
                    .padding(.horizontal)

                Picker("Appearance", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }

            // Show only the relevant dropdown
            VStack(spacing: 12) {
                if appearanceMode == .dark {
                    themeDropdown(
                        label: "Dark Theme",
                        selected: selectedDarkTheme,
                        options: AppTheme.darkThemes,
                        onSelect: { picked in
                            selectedDarkTheme = picked
                            applyTheme(picked)
                        }
                    )
                } else {
                    themeDropdown(
                        label: "Light Theme",
                        selected: selectedLightTheme,
                        options: AppTheme.lightThemes,
                        onSelect: { picked in
                            selectedLightTheme = picked
                            applyTheme(picked)
                        }
                    )
                }
            }
            .padding(.horizontal)
            .animation(.easeInOut(duration: 0.15), value: appearanceMode)
        }
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(backgroundColor.opacity(0.2))
        )
        .padding(.horizontal)
    }

    /// Whether dark colours should currently be active
    private var isUsingDark: Bool {
        appearanceMode == .dark
    }

    private func applyActiveTheme() {
        applyTheme(isUsingDark ? selectedDarkTheme : selectedLightTheme)
    }

    private func themeDropdown(
        label: String,
        selected: AppTheme,
        options: [AppTheme],
        onSelect: @escaping (AppTheme) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(textColor.opacity(0.7))

            Menu {
                ForEach(options) { option in
                    Button(option.rawValue) {
                        onSelect(option)
                    }
                }
            } label: {
                HStack {
                    // Swatch dot
                    Circle()
                        .fill(selected.preset.background)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle().strokeBorder(textColor.opacity(0.2), lineWidth: 1)
                        )

                    Text(selected.rawValue)
                        .font(.body)
                        .foregroundStyle(textColor)

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(textColor.opacity(0.5))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(backgroundColor.opacity(0.4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(textColor.opacity(0.12), lineWidth: 1)
                        )
                )
            }
        }
    }

    // MARK: - Water Shader Section

    private var waterShaderSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Water Effect")
                        .font(.headline)
                        .foregroundStyle(textColor)
                    Text("Uses the current background colour")
                        .font(.caption)
                        .foregroundStyle(textColor.opacity(0.5))
                }

                Spacer()

                Toggle("", isOn: $useWaterShader)
                    .tint(accentColor)
                    .labelsHidden()
            }

            if useWaterShader {
                VStack(spacing: 14) {
                    sliderRow(
                        label: "Speed",
                        value: $waterSpeed,
                        range: 0.1...3.0,
                        format: "%.1fx"
                    )
                    sliderRow(
                        label: "Intensity",
                        value: $waterIntensity,
                        range: 0.1...2.0,
                        format: "%.1f"
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(backgroundColor.opacity(0.2))
        )
        .padding(.horizontal)
        .animation(.easeInOut(duration: 0.2), value: useWaterShader)
    }

    private func sliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(textColor)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(textColor.opacity(0.6))
            }
            Slider(value: value, in: range)
                .tint(accentColor)
        }
    }

    // MARK: - Helpers

    private func loadFromTheme() {
        backgroundColor    = theme.backgroundColor
        textColor          = theme.textColor
        secondaryTextColor = theme.secondaryTextColor
        accentColor        = theme.accentColor
        tintColor          = theme.tint
        gonioSidesColor    = theme.gonioSidesColor
        gonioMidsColor     = theme.gonioMidsColor
        playButtonColor    = theme.playButtonColor
        useWaterShader     = theme.useWaterShader
        waterSpeed         = theme.waterSpeed
        waterIntensity     = theme.waterIntensity
        appearanceMode     = theme.appearanceMode
    }

    private func applyTheme(_ appTheme: AppTheme) {
        let p = appTheme.preset
        backgroundColor    = p.background
        textColor          = p.text
        secondaryTextColor = p.secondaryText
        accentColor        = p.accent
        tintColor          = p.tint
        gonioSidesColor    = p.gonioSides
        gonioMidsColor     = p.gonioMids
        playButtonColor    = p.playButton
        useWaterShader     = p.useWaterShader
        if p.useWaterShader {
            waterSpeed     = p.waterSpeed
            waterIntensity = p.waterIntensity
        }
    }
}
