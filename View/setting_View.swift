import SwiftUI
import Combine

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
    var waterColor: Color
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
        waterColor: .blue,
        waterSpeed: 1.0,
        waterIntensity: 0.5
    )
}

class ThemeManager: ObservableObject {
    @Published var backgroundColor = Color(red: 0.15, green: 0.15, blue: 0.25)
    @Published var textColor = Color.white
    @Published var accentColor = Color.blue
    @Published var secondaryTextColor = Color.gray
    @Published var tint = Color.blue
    @Published var gonioSidesColor = Color.red
    @Published var gonioMidsColor = Color.purple
    @Published var playButtonColor = Color.white
    @Published var useWaterShader: Bool = false
    @Published var waterColor: Color = .blue
    @Published var waterSpeed: Double = 1.0
    @Published var waterIntensity: Double = 0.5
    
    @Published var customPresets: [ThemePreset] = [
        ThemePreset.empty,
        ThemePreset.empty,
        ThemePreset.empty
    ]
}

struct SettingsView: View {
    @EnvironmentObject var theme: ThemeManager
    
    @State private var backgroundColor: Color = Color.black
    @State private var textColor: Color = Color.white
    @State private var secondaryTextColor: Color = Color.gray
    @State private var accentColor: Color = Color.blue
    @State private var tintColor: Color = Color.blue
    @State private var gonioSidesColor: Color = Color.red
    @State private var gonioMidsColor: Color = Color.purple
    @State private var playButtonColor: Color = Color.white
    @State private var didInitializeFromTheme = false
    @State private var useWaterShader: Bool = false
    @State private var waterShaderColor: Color = Color.blue
    @State private var waterSpeed: Double = 1.0
    @State private var waterIntensity: Double = 0.5
    
    @State private var showingAssignDialog = false
    
    init() {}
    
    var body: some View {
        ZStack{
            theme.backgroundColor
                .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 20) {
                    themePreview
                    themePresetsSection
                    
                    VStack(spacing: 24) {
                        colorSection(
                            title: "Background",
                            controls: [
                                ColorControl(name: "Background Color", binding: $backgroundColor)
                            ]
                        )
                        
                        colorSection(
                            title: "Text Colors",
                            controls: [
                                ColorControl(name: "Primary Text", binding: $textColor),
                                ColorControl(name: "Secondary Text", binding: $secondaryTextColor)
                            ]
                        )
                        
                        colorSection(
                            title: "Accent Colors",
                            controls: [
                                ColorControl(name: "Accent Color", binding: $accentColor),
                                ColorControl(name: "Tint Color", binding: $tintColor),
                                ColorControl(name: "Play Button", binding: $playButtonColor)
                            ]
                        )
                        
                        colorSection(
                            title: "Gonio Colors",
                            controls: [
                                ColorControl(name: "Gonio Sides", binding: $gonioSidesColor),
                                ColorControl(name: "Gonio Mids", binding: $gonioMidsColor)
                            ]
                        )
                        
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Water Shader", isOn: $useWaterShader)
                                .foregroundStyle(textColor)
                                .tint(accentColor)

                            ColorPicker("Water Color", selection: $waterShaderColor)
                                .foregroundStyle(textColor)

                            Text("Speed: \(waterSpeed, specifier: "%.1f")x")
                                .foregroundStyle(textColor)
                            Slider(value: $waterSpeed, in: 0.1...3.0)
                                .tint(accentColor)

                            Text("Intensity: \(waterIntensity, specifier: "%.1f")")
                                .foregroundStyle(textColor)
                            Slider(value: $waterIntensity, in: 0.1...2.0)
                                .tint(accentColor)
                        }
                        .padding()
                        .background(backgroundColor.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                        
                        Button("Assign Current Theme to…") {
                            showingAssignDialog = true
                        }
                        .foregroundStyle(accentColor)
                        .confirmationDialog(
                            "Save Current Theme",
                            isPresented: $showingAssignDialog,
                            titleVisibility: .visible
                        ) {
                            Button("Custom Preset 1") { savePreset(0) }
                            Button("Custom Preset 2") { savePreset(1) }
                            Button("Custom Preset 3") { savePreset(2) }
                            Button("Cancel", role: .cancel) {}
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.top, 20)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if !didInitializeFromTheme {
                    loadFromTheme()
                    didInitializeFromTheme = true
                }
            }
            .onChange(of: backgroundColor) { _, v in theme.backgroundColor = v }
            .onChange(of: textColor) { _, v in theme.textColor = v }
            .onChange(of: secondaryTextColor) { _, v in theme.secondaryTextColor = v }
            .onChange(of: accentColor) { _, v in theme.accentColor = v }
            .onChange(of: tintColor) { _, v in theme.tint = v }
            .onChange(of: gonioSidesColor) { _, v in theme.gonioSidesColor = v }
            .onChange(of: gonioMidsColor) { _, v in theme.gonioMidsColor = v }
            .onChange(of: playButtonColor) { _, v in theme.playButtonColor = v }
            .onChange(of: useWaterShader) { _, v in theme.useWaterShader = v }
            .onChange(of: waterShaderColor) { _, v in theme.waterColor = v }
            .onChange(of: waterSpeed) { _, v in theme.waterSpeed = v }
            .onChange(of: waterIntensity) { _, v in theme.waterIntensity = v }
        }
    }
    
    private func loadFromTheme() {
        backgroundColor = theme.backgroundColor
        textColor = theme.textColor
        secondaryTextColor = theme.secondaryTextColor
        accentColor = theme.accentColor
        tintColor = theme.tint
        gonioSidesColor = theme.gonioSidesColor
        gonioMidsColor = theme.gonioMidsColor
        playButtonColor = theme.playButtonColor
        useWaterShader = theme.useWaterShader
        waterShaderColor = theme.waterColor
        waterSpeed = theme.waterSpeed
        waterIntensity = theme.waterIntensity
    }
    
    private var themePreview: some View {
        VStack(spacing: 14) {
            Text("Theme Preview")
                .font(.headline)
                .foregroundStyle(textColor)
            
            previewRow("Background", backgroundColor)
            previewRow("Primary Text", textColor)
            previewRow("Secondary Text", secondaryTextColor)
            previewRow("Accent", accentColor)
            previewRow("Tint", tintColor)
            previewRow("Gonio Sides", gonioSidesColor)
            previewRow("Gonio Mids", gonioMidsColor)
            previewRow("Play Button", playButtonColor)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(backgroundColor)
        )
        .padding(.horizontal)
    }
    
    private func previewRow(_ name: String, _ color: Color) -> some View {
        HStack {
            Text(name)
                .font(.subheadline)
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Circle()
                .fill(color)
                .frame(width: 22, height: 22)
        }
    }
    
    private func colorSection(title: String, controls: [ColorControl]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(textColor)
            
            VStack(spacing: 16) {
                ForEach(controls) { control in
                    ColorPicker(control.name, selection: control.binding)
                }
            }
        }
        .padding()
        .background(backgroundColor.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private var themePresetsSection: some View {
        VStack(spacing: 12) {
            Text("Theme Presets")
                .font(.headline)
                .foregroundStyle(textColor)
                .padding(.top, 10)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    presetButton("Default") { applyDefaultTheme() }
                    presetButton("Red") { applyRedTheme() }
                    presetButton("Blue") { applyBlueTheme() }
                    presetButton("Grey") { applyGreyTheme() }
                    presetButton("Brown") { applyBrownTheme() }
                    presetButton("Green") { applyGreenTheme() }
                    presetButton("Water") { applyWaterTheme() }
                    presetButton("Purple") { applyPurpleTheme() }
                    presetButton("Yellow") { applyYellowTheme() }
                    presetButton("Pink") { applyPinkTheme() }
                    presetButton("Orange") { applyOrangeTheme() }
                    presetButton("Teal") { applyTealTheme() }
                    presetButton("Midnight") { applyMidnightTheme() }
                    presetButton("Light") { applyLightTheme() }
                    presetButton("Neon") { applyNeonTheme() }
                    
                    presetButton("Custom 1") { loadPreset(0) }
                    presetButton("Custom 2") { loadPreset(1) }
                    presetButton("Custom 3") { loadPreset(2) }
                }
                .padding(.horizontal)
            }
        }
    }
    
    private func presetButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(tintColor.opacity(0.15))
                .foregroundStyle(accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
    
    private func savePreset(_ index: Int) {
        theme.customPresets[index] = ThemePreset(
            background: backgroundColor,
            text: textColor,
            secondaryText: secondaryTextColor,
            accent: accentColor,
            tint: tintColor,
            gonioSides: gonioSidesColor,
            gonioMids: gonioMidsColor,
            playButton: playButtonColor,
            useWaterShader: useWaterShader,
            waterColor: waterShaderColor,
            waterSpeed: waterSpeed,
            waterIntensity: waterIntensity
        )
    }
    
    private func loadPreset(_ index: Int) {
        let p = theme.customPresets[index]
        backgroundColor = p.background
        textColor = p.text
        secondaryTextColor = p.secondaryText
        accentColor = p.accent
        tintColor = p.tint
        gonioSidesColor = p.gonioSides
        gonioMidsColor = p.gonioMids
        playButtonColor = p.playButton
        useWaterShader = p.useWaterShader
        waterShaderColor = p.waterColor
        waterSpeed = p.waterSpeed
        waterIntensity = p.waterIntensity
    }
    
    private func applyDefaultTheme() {
        backgroundColor = Color(red: 0.15, green: 0.15, blue: 0.25)
        textColor = .white
        secondaryTextColor = .gray
        accentColor = .blue
        tintColor = .blue
        gonioSidesColor = .red
        gonioMidsColor = .purple
        playButtonColor = .white
    }
    
    private func applyRedTheme() {
        backgroundColor = Color(red: 0.2, green: 0, blue: 0)
        textColor = .white
        secondaryTextColor = .gray
        accentColor = .red
        tintColor = .red
        gonioSidesColor = .pink
        gonioMidsColor = .red
        playButtonColor = .white
    }
    
    private func applyBlueTheme() {
        backgroundColor = Color(red: 0.05, green: 0.1, blue: 0.22)
        textColor = .white
        secondaryTextColor = .cyan.opacity(0.8)
        accentColor = .blue
        tintColor = .blue
        gonioSidesColor = .cyan
        gonioMidsColor = .blue
        playButtonColor = .white
    }
    
    private func applyGreyTheme() {
        backgroundColor = Color(.darkGray)
        textColor = .white
        secondaryTextColor = .gray
        accentColor = .white
        tintColor = .gray
        gonioSidesColor = .gray
        gonioMidsColor = .white
        playButtonColor = .black
    }
    
    private func applyBrownTheme() {
        backgroundColor = Color(red: 0.25, green: 0.15, blue: 0.1)
        textColor = Color(red: 0.9, green: 0.85, blue: 0.8)
        secondaryTextColor = .brown
        accentColor = .orange
        tintColor = .orange
        gonioSidesColor = .brown
        gonioMidsColor = .orange
        playButtonColor = .white
    }
    
    private func applyGreenTheme() {
        backgroundColor = Color(red: 0.05, green: 0.20, blue: 0.12)
        textColor = .white
        secondaryTextColor = .green.opacity(0.7)
        accentColor = .green
        tintColor = .green
        gonioSidesColor = .mint
        gonioMidsColor = .green
        playButtonColor = .white
    }
    
    private func applyPurpleTheme() {
        backgroundColor = Color(red: 0.12, green: 0.05, blue: 0.18)
        textColor = .white
        secondaryTextColor = .purple.opacity(0.7)
        accentColor = .purple
        tintColor = .purple
        gonioSidesColor = .pink
        gonioMidsColor = .purple
        playButtonColor = .white
    }
    
    private func applyWaterTheme() {
        backgroundColor = Color(red: 0.02, green: 0.08, blue: 0.18)
        textColor = .white
        secondaryTextColor = .cyan.opacity(0.7)
        accentColor = .cyan
        tintColor = .cyan
        gonioSidesColor = .blue
        gonioMidsColor = .cyan
        playButtonColor = .white
        useWaterShader = true
        waterShaderColor = .blue
        waterSpeed = 1.0
        waterIntensity = 0.8
    }
    
    private func applyYellowTheme() {
        backgroundColor = Color(red: 0.20, green: 0.20, blue: 0.05)
        textColor = .white
        secondaryTextColor = .yellow.opacity(0.7)
        accentColor = .yellow
        tintColor = .yellow
        gonioSidesColor = .yellow.opacity(0.8)
        gonioMidsColor = .orange
        playButtonColor = .white
    }
    
    private func applyPinkTheme() {
        backgroundColor = Color(red: 0.25, green: 0.05, blue: 0.15)
        textColor = .white
        secondaryTextColor = .pink.opacity(0.7)
        accentColor = .pink
        tintColor = .pink
        gonioSidesColor = .pink
        gonioMidsColor = .red
        playButtonColor = .white
    }
    
    private func applyOrangeTheme() {
        backgroundColor = Color(red: 0.20, green: 0.10, blue: 0)
        textColor = .white
        secondaryTextColor = .orange.opacity(0.7)
        accentColor = .orange
        tintColor = .orange
        gonioSidesColor = .yellow
        gonioMidsColor = .orange
        playButtonColor = .white
    }
    
    private func applyTealTheme() {
        backgroundColor = Color(red: 0.04, green: 0.18, blue: 0.20)
        textColor = .white
        secondaryTextColor = .teal.opacity(0.7)
        accentColor = .teal
        tintColor = .teal
        gonioSidesColor = .cyan
        gonioMidsColor = .teal
        playButtonColor = .white
    }
    
    private func applyMidnightTheme() {
        backgroundColor = .black
        textColor = .white
        secondaryTextColor = .gray
        accentColor = .white
        tintColor = .white
        gonioSidesColor = .gray
        gonioMidsColor = .white
        playButtonColor = .black
    }
    
    private func applyLightTheme() {
        backgroundColor = .white
        textColor = .black
        secondaryTextColor = .gray
        accentColor = .blue
        tintColor = .blue
        gonioSidesColor = .gray
        gonioMidsColor = .blue
        playButtonColor = .white
    }
    
    private func applyNeonTheme() {
        backgroundColor = .black
        textColor = .green
        secondaryTextColor = .yellow
        accentColor = .pink
        tintColor = .pink
        gonioSidesColor = .yellow
        gonioMidsColor = .green
        playButtonColor = .white
    }
}

struct ColorControl: Identifiable {
    let id: String
    let name: String
    let binding: Binding<Color>

    init(name: String, binding: Binding<Color>) {
        self.id = name
        self.name = name
        self.binding = binding
    }
}
