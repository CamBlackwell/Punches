# 11 — Settings UI

`View/setting_View.swift` is 1600 lines and holds four unrelated things: three shader-quality enums, the whole theme system (`ThemePreset`, `AppTheme`, `ThemeManager`), and the one screen that edits them. This document covers the screen and the quality tiers; the theme data model is in [10](10-theming-and-shaders.md) and the persistence keys in [12](12-persistence-and-keys.md).

---

## 1. How you get there

`SettingsView` is pushed onto the Songs tab's `NavigationStack` — there is no tab of its own.

| Step | Location |
|---|---|
| `@State private var showingSettings = false` | `View/content_view.swift:28` |
| `.navigationDestination(isPresented: $showingSettings) { SettingsView() }` | `View/content_view.swift:67-69` |
| Gear button in the overflow `Menu` | `View/content_view.swift:320-322` |

> **The gear is only in the overflow menu, and only on the Songs tab.** `View/content_view.swift:313-322` puts `Add Songs`, `Create Playlist` and `Settings` in the same `Menu`, which is itself conditional: the `else` branch at `:313` is reached when the multi-select toolbar is *not* active. So there is no way into Settings from the Playlists tab, from the player, or while a multi-selection is in progress.

---

## 2. Screen structure

`SettingsView` (`:1158`) is a `ZStack` — the live `AppBackground` (`:1165`) behind a `ScrollView` (`:1167`) with six sections in this order:

```swift
VStack(spacing: 24) {
    themePreview            // :1169
    themeSelectorsSection   // :1170
    waterShaderSection      // :1171
    tunnelShaderSection     // :1172
    fogShaderSection        // :1173
    smokeShaderSection      // :1174
}
.padding(.top, 20)
.padding(.bottom, 32)
```

`.navigationTitle("Settings")`, `.navigationBarTitleDisplayMode(.inline)` (`:1179-1180`).

The screen renders the real background behind itself, so every toggle flips the actual effect live while you watch. That is a genuinely good design decision and the reason there is no separate "preview" pane — the whole screen *is* the preview.

### 2.1 What is not on this screen

**There are no audio settings anywhere in Settings.** No volume, no pitch, no tempo, no loop, no crossfade, no output-routing, no session settings, no library or import settings, no diagnostics, no reset-to-defaults. All audio controls are inline in `AudioPlayerView`, and several of them (tempo, pitch) are non-functional — see [04](04-audio-pipeline.md).

The screen is a **theme and background-effects editor**, not a settings screen. It is titled "Settings" and reachable from a gear, which over-promises.

---

## 3. Theme preview (`:1186-1274`)

A rounded card (`cornerRadius: 16`, `backgroundColor.opacity(0.35)`, `textColor.opacity(0.08)` border) containing:

- Eight `previewSwatch` tiles in two rows of four — `Background`, `Text`, `Secondary`, `Accent` (`:1192-1197`) then `Tint`, `Sides`, `Mids`, `Play` (`:1198-1203`). Each is a 36pt-tall `RoundedRectangle` filled with the live colour, over a 9pt caption (`:1264-1274`).
- A badge row (`Label` in a `Capsule`) that appears only if at least one effect is enabled (`:1206`): Water, Fog, Tunnel, Smoke.

> **The Water badge colour is hardcoded.** `:1211` and `:1214` use `Color(hex: "#2dd4bf")` — a fixed teal that ignores the theme. Every other badge derives from the theme (`:1220`, `:1229`, `:1238`). On a light theme this badge is the one element that will not match. It should be `theme.waterColor`, which is itself fixed at `#2A7FAA` (`setting_View.swift:948`) — note the two hexes disagree, which is its own small bug.

The four `.animation(...)` modifiers at `:1258-1261` animate the badge row in and out.

---

## 4. Colour scheme (`:1278-1374`)

A `VStack` card with `backgroundColor.opacity(0.2)`, holding two controls.

### 4.1 Appearance — segmented picker

```swift
Picker("Appearance", selection: $theme.appearanceMode) { … }
    .pickerStyle(.segmented)
    .onChange(of: theme.appearanceMode) { _, _ in theme.applyActiveTheme() }
```

`:1291-1300`, over `enum AppearanceMode { case light = "Light", case dark = "Dark" }` (`:844-847`).

### 4.2 Theme — custom dropdown

`themeDropdown(label:selected:options:onSelect:)` (`:1331-1374`) is a `Menu` whose label is a 14pt `Circle` filled with `selected.preset.background` plus the raw value and a `chevron.up.chevron.down` glyph. Options come from `AppTheme.darkThemes` (20 themes) or `AppTheme.lightThemes` (15) depending on the mode (`:1304-1318`), and selection calls `theme.apply($0)`.

The whole block animates on mode change (`:1321`).

> ### ⚠️ `appearanceMode` never reaches the SwiftUI environment
>
> `appearanceMode` is stored (`:1012-1013`), persisted (`theme.appearanceMode`), used to choose *which* preset list to show, and used by `applyActiveTheme()` to decide *which* theme to load (`:1141`). It is **never** applied as a colour scheme. Grepping the whole repository for `preferredColorScheme` returns exactly one hit — `View/audio_player_view.swift:31`, hardcoded `.dark`.
>
> Consequence: picking a light theme changes Punches' own colours but leaves every **system-drawn** control in the device's current appearance. On a device set to Dark, the user selects a light theme and gets light Punches surfaces with dark `Toggle`, `Slider`, `Menu` chrome, keyboard, and status bar. The fix is one line at the root of the app:
>
> ```swift
> .preferredColorScheme(theme.appearanceMode == .dark ? .dark : .light)
> ```
>
> applied alongside the `.environmentObject(theme)` in `silly_speed.swift`. See [14-known-issues.md](14-known-issues.md).

---

## 5. The four effect sections

All four share an identical shape: a header `HStack` with title + subtitle, a `Toggle` tinted with `theme.accentColor` and `labelsHidden()`, and an `if`-gated control group that transitions in with `.transition(.opacity.combined(with: .move(edge: .top)))`. The card wrapper and `.animation(.easeInOut(duration: 0.2), value:)` are the same in each.

| Section | Lines | Title / subtitle | Toggle | Gated controls |
|---|---|---|---|---|
| Water | `:1378-1426` | "Water Effect" / "Uses the current background colour" | `theme.useWaterShader` | Quality picker, Speed, Intensity |
| Tunnel | `:1430-1485` | "Tunnel Effect" / "Raymarched fractal tunnel" | `theme.useTunnelShader` | Quality picker, Speed, Intensity, **Grain** |
| Fog | `:1489-1520` | "Fog Effect" / "PS2-style depth fog with Bayer dithering" | `theme.useFogShader` | **Density only** |
| Smoke | `:1527-1576` | "Smoke Effect" / "Colormap-warp fBM background" | `theme.useSmokeShader` | Quality picker, Speed, Intensity, Grayscale |

### 5.1 Slider rows

Every slider goes through one helper, `sliderRow(label:value:range:format:)` (`:1580-1599`):

```swift
Slider(value: value, in: range)
    .tint(theme.accentColor)
```

with the label on the left and a `.monospacedDigit()` formatted read-out on the right (`:1587-1597`). Using monospaced digits is the right call — it stops the value jittering the layout as the digits change.

All ten slider ranges in the file:

| Control | Range | Format | Line |
|---|---|---|---|
| Water Speed | `0.1...3.0` | `%.1fx` | `:1409` |
| Water Intensity | `0.1...2.0` | `%.1f` | `:1410` |
| Tunnel Speed | `0.1...3.0` | `%.1fx` | `:1461` |
| Tunnel Intensity | `0.1...2.0` | `%.1f` | `:1462` |
| Tunnel Grain | `0.0...0.4` | `%.2f` | `:1463` |
| Fog Density | `0.1...2.0` | `%.1f` | `:1508` |
| Smoke Speed | `0.1...3.0` | `%.1fx` | `:1558` |
| Smoke Intensity | `0.0...1.0` | `%.1f` | `:1559` |
| Smoke Grayscale | `0.0...1.0` | `%.1f` | `:1560` |

> **The labels are inconsistent.** "Speed" is formatted with a trailing `x` on all three effects, implying a multiplier; the values are passed straight to the shaders as `time` increments and are not literally multipliers. "Density" on the fog slider is bound to `fogIntensity`, which the shader uses as an intensity — the user-facing name and the property name disagree. Minor, but it is the kind of thing that makes a settings screen feel unfinished.

### 5.2 The "Low Power Mode" footnote

Three sections carry an identical caption — `:1414` (water), `:1467` (tunnel), `:1564` (smoke):

> *"Lower quality renders at a smaller resolution with a lighter raymarch budget — much easier on the GPU and battery. "Low" automatically applies when Low Power Mode is on."*

**This claim is true, but the UI does not reflect it.** The override lives in the rendering views, not in `ThemeManager`:

```swift
// View/ShaderEffects.swift:91-93, 234-236, 324-326
private var effectiveQuality: WaterQuality   { lowPowerModeEnabled ? .low : theme.waterQuality }
private var effectiveQuality: TunnelQuality  { lowPowerModeEnabled ? .low : theme.tunnelQuality }
private var effectiveQuality: SmokeQuality   { lowPowerModeEnabled ? .low : theme.smokeQuality }
```

Each view holds `@State private var lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled` (`ShaderEffects.swift:35`, `:166`, `:271`) and observes `.NSProcessInfoPowerStateDidChange` (`:83`, `:226`, `:316`).

So with Low Power Mode on, the segmented picker **still displays the user's stored choice** while the shader renders `.low`. A user on Balanced sees "Balanced" and gets Low. The setting is not overwritten and snaps back when LPM turns off, which is the correct implementation — the *disclosure* is what is wrong. The caption should say the tier is temporarily overridden, and ideally the picker should show the effective value.

> **Fog has neither a quality tier nor an LPM override.** `FogShaderView` is the only one of the four effect views with no `lowPowerModeEnabled` state, and the fog section correctly has no footnote. It also has no `resolutionScale`, so it always renders at full size.

### 5.3 Tunnel Grain

The Grain slider (`:1463`) is bound to `theme.tunnelGrainStrength` and feeds `ShaderLibrary.grainOverlay` — **a function that does not exist in any `.metal` file in the repository.** The control is fully wired and the shader is missing; see [10](10-theming-and-shaders.md#4-the-four-shader-effects) and [14-known-issues.md](14-known-issues.md).

### 5.4 Shader attribution

`:1474` shows the required MIT attribution, and the comment at `:1472-1473` states it is shown **regardless of whether the effect is enabled** — which is correct licence practice. It sits outside the `if theme.useTunnelShader` block, so it is always visible:

> Shader based on "RayMarching starting point" by Martijn Steinrucken (The Art of Code / BigWings), MIT License.

---

## 6. The quality tiers

Three enums, all `String, CaseIterable, Identifiable` with `low` / `balanced` / `high`. Each collapses several independent GPU levers behind one picker so the user makes one decision. Full per-tier values:

### `TunnelQuality` (`:12-57`)

| | `low` | `balanced` | `high` |
|---|---|---|---|
| `resolutionScale` (`:21`) | 0.35 | 0.55 | 0.8 |
| `maxSteps` (`:30`) | 75 | 130 | 200 |
| `foldIterations` (`:40`) | 5 | 7 | 9 |
| `frameInterval` (`:50`) | 1/24 s | 1/30 s | 1/60 s |

### `WaterQuality` (`:66-119`)

| | `low` | `balanced` | `high` |
|---|---|---|---|
| `resolutionScale` (`:74`) | 0.35 | 0.5 | 0.75 |
| `raymarchSteps` (`:83`) | 16 | 22 | 32 |
| `raymarchIterations` (`:92`) | 4 | 6 | 8 |
| `normalIterations` (`:103`) | 8 | 12 | 18 |
| `frameInterval` (`:112`) | 1/15 s | 1/24 s | 1/30 s |

### `SmokeQuality` (`:128-154`)

| | `low` | `balanced` | `high` |
|---|---|---|---|
| `resolutionScale` (`:137`) | 0.35 | 0.55 | 0.8 |
| `frameInterval` (`:147`) | 1/15 s | 1/24 s | 1/30 s |

Notes on the tier design:

- **`resolutionScale` is the dominant lever** and the file says so (`:19-20`, `:73-74`, `:135-136`): cost scales with pixel count. Low is 0.35 across all three, so the tiers are consistent.
- **`WaterQuality.normalIterations` is the most expensive per-pixel knob** — the comment at `:100-101` notes `normal()` is called 3× per pixel, nested inside the raymarch loop. Low drops it from 18 to 8, a 2.25× cut, on top of the resolution and step cuts.
- **Water and Tunnel are expensive; Smoke is cheap.** Smoke has only two levers because `ColormapWarp.metal` is a 2D fBM field, not a 3D raymarch. Its `frameInterval` tops out at 1/30 s, and it is drawn behind everything.
- **`high` water is still only 30 fps** (`:117`) while `high` tunnel is 60 (`:55`). Tunnel is animated more aggressively, so it gets the frame budget; water is ambient. That is a deliberate and defensible asymmetry.
- **The pickers are `.segmented`** in all three cases (`:1405`, `:1457`, `:1554`) bound to the `theme.*` property, so the tier is persisted immediately via its `didSet` — no apply button anywhere in the file.

---

## 7. Settings that do not exist

Worth listing explicitly, because their absence is easy to mistake for an oversight in this document rather than in the app:

- No **audio** section at all (§2.1).
- No **Reset to Defaults** — the only way back to stock is to pick a theme preset, which does not restore manually-tuned slider values.
- No **fog colour or fog speed** control. `fogColor` and `fogSpeed` are `@Published` and persisted (`ThemeKey.fogColor`, `ThemeKey.fogSpeed`) and every `ThemePreset` sets them, so they are reachable **only by selecting a preset** — never individually. The same applies to `tunnelColor`, which has no control either.
- No **water colour** control, and this one is deliberate: `ThemeManager.waterColor` is a non-`@Published` `let` fixed at `#2A7FAA` (`:947-948`), commented "not user-configurable". Because it is a `let`, no SwiftUI view observing `ThemeManager` can ever invalidate from it, and it is not persisted. The water section's subtitle "Uses the current background colour" (`:1385`) is therefore **wrong** — `AppBackground` draws `theme.backgroundColor` as a *separate* base layer (`ShaderEffects.swift:357`) and the water layer is filled and tinted with `theme.waterColor` (`ShaderEffects.swift:51`, `:56`). Changing the theme's background colour does not change the water at all.
- No **app icon**, **about**, **version**, or **licence** screen beyond the one-line tunnel credit.

> ### ⚠️ The four effect toggles are not independent, and the screen does not say so
>
> `AppBackground`'s own comment (`ShaderEffects.swift:346-349`) says it: *"Water, tunnel, and smoke are all full replacement backdrops rather than blend layers — enabling more than one together will simply show whichever is later in the ZStack on top, which is expected."*
>
> So of the three full-backdrop effects, **the user can only ever see the last one they enabled** — tunnel if water and tunnel are both on, smoke if any of tunnel/smoke is on with water. Only fog genuinely blends, because it is drawn on top of everything (`ShaderEffects.swift:377`).
>
> Settings presents four independent toggles with no warning, no mutual exclusion, and no indication that two of them are mutually exclusive by construction. A user who enables Water and then Tunnel loses Water entirely with no explanation. This is the most user-visible design flaw on the screen. The fix is either `RadioButton`-style exclusivity among water/tunnel/smoke, or making the later layers blend instead of replace.

---

## 8. Known issues in this screen

| Severity | Issue | Where |
|---|---|---|
| High | `appearanceMode` is never applied via `preferredColorScheme`; system controls keep the device appearance | §4.2 |
| High | `ShaderLibrary.grainOverlay` undefined, so the tunnel does not compile — the Grain slider is dead | §5.3 |
| High | Water / tunnel / smoke are full-replacement backdrops; enabling two shows only one, with no warning | §7 |
| Medium | Low Power Mode override is invisible; the picker shows the stored tier, not the effective one | §5.2 |
| Medium | Water section subtitle says "Uses the current background colour"; the shader uses the fixed `waterColor` | §7 |
| Medium | Only reachable from the Songs tab's overflow menu | §1 |
| Low | Water preview badge hardcodes `#2dd4bf`, which disagrees with `waterColor`'s `#2A7FAA` | §3 |
| Low | "Speed" formatted as `%.1fx` implies a multiplier it is not | §5.1 |
| Low | "Density" slider bound to `fogIntensity` | §5.1 |
| Low | `fogColor`, `fogSpeed`, `tunnelColor` are persisted and preset-driven but have no controls | §7 |
| Low | No reset-to-defaults path | §7 |

All are catalogued with remediation in [14-known-issues.md](14-known-issues.md).

---

## 9. Adding a new setting

There is no registration mechanism; a new setting is **six edits** across two files, and the compiler will not catch a missing one. The `ThemeManager` property is where the compiler does help — `@Published` plus `didSet` persistence is the pattern — but the *load* path and the *apply* path are separate and silent.

Using the fog block as the template:

1. Add the key: `ThemeKey` (`:851-887`).
2. Add the property with `didSet`: `ThemeManager` (`:952+`).
3. Load it in `init`: `ThemeManager` (`:1028+`).
4. Add it to `ThemePreset`: the struct (`:158-251`) and its `init` (`:193+`).
5. Set it in every one of the 35 `AppTheme` cases (`:253-828`) — or rely on the `init` defaults.
6. Add the control: one of the six `SettingsView` sections.

Miss steps 3 or 4 and the value **saves but never loads** or **loads but never applies**, with no diagnostic. The riskiest part is step 5: `AppTheme` has 35 cases and a missing entry silently falls back to the `init` default.

For a non-themed setting (something that should not vary per theme, like a quality tier the user picks once) the honest place for it is a new section on this screen with its own small `ObservableObject` — not `ThemeManager`, which is already 258 lines (`:903-1154`) and mixes concerns with three unrelated enums and the whole preset table.

### 9.1 `ThemeManager` landmarks

For navigation, the class spans `:903-1154` and its members are:

| Member | Line |
|---|---|
| `init()` — the entire load-from-`UserDefaults` pass | `:1024` |
| `apply(_ appTheme: AppTheme)` | `:1096` |
| `applyActiveTheme()` — `apply(appearanceMode == .dark ? selectedDarkTheme : selectedLightTheme)` | `:1140-1142` |
| `private func save(_ hex: String, for key: String)` — the shared colour-persistence helper used by all eight colour properties | `:1146` |

---

## See also

- [10 — Theming & Shaders](10-theming-and-shaders.md) — `ThemePreset`, `AppTheme`, `ThemeManager`, and the shader stack these controls drive
- [12 — Persistence & Keys](12-persistence-and-keys.md) — all 30 `theme.*` keys
- [07 — Meters & HUD](07-meters-and-hud.md) — the one control that *is* inline rather than in Settings
- [03 — Project Structure & Build](03-project-structure-and-build.md) — `setting_View.swift` is excluded from the target
- [14 — Known Issues](14-known-issues.md)
