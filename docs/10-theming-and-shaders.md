# 10 — Theming & Shaders

> `ThemeManager` (30 `UserDefaults` keys, 35 named themes), the four SwiftUI `colorEffect` background shaders, and the three quality-tier enums that keep them off a GPU cliff.
> Companion: [11-settings-ui.md](11-settings-ui.md) (the Settings screen that edits all of this), [12-persistence-and-keys.md](12-persistence-and-keys.md) (all keys), [06-visualisation.md](06-visualisation.md) (the *other*, unrelated Metal stack).

---

## 1. Where things live

| Concern | File | Lines |
|---|---|---|
| `TunnelQuality` | `View/setting_View.swift` | `12-57` |
| `WaterQuality` | `View/setting_View.swift` | `66-119` |
| `SmokeQuality` | `View/setting_View.swift` | `128-154` |
| `ThemePreset` (+ `.empty`) | `View/setting_View.swift` | `158-249` |
| `AppTheme` (35 cases) | `View/setting_View.swift` | `253-826` |
| `Color(hex:)` | `View/setting_View.swift` | `830-840` |
| `AppearanceMode` | `View/setting_View.swift` | `844-847` |
| `ThemeKey` (30 keys) | `View/setting_View.swift` | `851-888` |
| `Color.hexString` | `View/setting_View.swift` | `891-899` |
| `ThemeManager` | `View/setting_View.swift` | `903-1154` |
| `SettingsView` | `View/setting_View.swift` | `1158-1600` |
| The 4 effect views + `AppBackground` | `View/ShaderEffects.swift` | `1-398` |
| MSL shaders | `View/{Water,TunnelShader,Fog,ColormapWarp}.metal` | 699 total |

`AppBackground()` has exactly one live call site: `View/content_view.swift:42`. The other two hits are a comment (`ShaderEffects.swift:350`) and a `#Preview` (`ShaderEffects.swift:396`).

---

## 2. `ThemeManager` — the contract

`final class ThemeManager: ObservableObject` (`:903`). It is an `@EnvironmentObject` injected at the app root, so **every** view that touches colours must declare `@EnvironmentObject var theme: ThemeManager` or it will crash at runtime on a missing environment object.

### 2.1 Every published property writes itself to `UserDefaults`

There is no explicit save call anywhere. Each of the 30 stored properties uses `didSet`:

```swift
// setting_View.swift:907-909
@Published var backgroundColor: Color {
    didSet { save(backgroundColor.hexString, for: ThemeKey.backgroundColor) }
}
```

- **Colours** go through `save(_:for:)` → `UserDefaults.standard.set(hex, forKey:)` (`:1146-1148`), where `hex` comes from `Color.hexString` (`:891-899`) — a `UIColor` round-trip producing `#rrggbb`, **alpha is dropped**.
- **Bools/Doubles/Enums** are written directly in their own `didSet` (`:934-945`, `:952-963`, `:969-979`, `:1000-1008`), with enums stored as `rawValue`.
- **`waterColor` is a `let`, not `@Published`** (`:947-948`): `let waterColor: Color = Color(hex: "#2A7FAA")`. It is deliberately not user-configurable and not persisted.

> **⚠️ `Color(hex:)` silently truncates on a 3-digit input.** `setting_View.swift:831-839` strips non-alphanumerics, scans the result as a single hex integer, then takes bits 16-23 / 8-15 / 0-7. A 3-digit shorthand like `#abc` scans to `0xabc` and becomes `r = 0x0, g = 0xa, b = 0xc` — i.e. near-black, not `#aabbcc`. All 35 presets use 6-digit form, so this is latent. There is also no failure path: if `scanHexInt64` finds no hex digits, `int` stays `0` and you get opaque black rather than the fallback.

> **⚠️ `hexString` drops alpha and quantises.** `Int(r * 255)` truncates rather than rounds, so each save/load round-trip through `UserDefaults` can shift a channel by up to 1/255. Harmless for the shipped presets, but it means a user-set custom colour drifts slightly on every relaunch.

### 2.2 `init` loads with Nord as the implicit default

`init()` (`:1024-1092`) is long and explicit — there is no generic decoding. Every value is `UserDefaults`-first, preset-second:

| Property | Load expression | Fallback |
|---|---|---|
| 8 colours | `Self.loadColor(ud, key:, default:)` (`:1150-1153`) | `AppTheme.nord.preset.*` |
| `useWaterShader` … `waterIntensity` | `ud.object(forKey:) as? Bool/Double ?? preset` | Nord (all `false`, `1.0`, `0.5`) |
| `waterQuality` | `ud.string(forKey:)` → `WaterQuality(rawValue:)` | `.balanced` |
| fog / tunnel / smoke blocks | same pattern | Nord (all shaders off) |
| `appearanceMode` | raw-value round-trip | `.dark` (`:1076`) |
| `selectedDarkTheme` | raw-value round-trip | `.nord` (`:1083`) |
| `selectedLightTheme` | raw-value round-trip | **`.rosePineLight`** (`:1090`) |

> **Gotcha:** the initial value is **Nord dark**, but the *stored* selection defaults to **Rosé Pine Dawn** for light mode. On first launch with `appearanceMode == .dark` you get Nord; flip to Light and you get Rosé Pine Dawn. That asymmetry is intentional (`rosePineLight`'s raw value is the one without a "(Light)" suffix) but reads like a bug the first time you see it.

> **Gotcha:** the `as? Bool` / `as? Double` pattern (`:1037-1039` etc.) returns `nil` — and therefore the preset — if the key is *absent* **or** stored with the wrong type. A number stored as `1` rather than `1.0` would silently reset. All writes use `Double`, so this is safe today.

### 2.3 `apply(_:)` — why shader params are conditional

```swift
// setting_View.swift:1106-1111
useWaterShader = p.useWaterShader
if p.useWaterShader {
    waterSpeed     = p.waterSpeed
    waterIntensity = p.waterIntensity
    waterQuality   = p.waterQuality
}
```

The pattern is identical for water (`:1107`), fog (`:1113`), tunnel (`:1119`) and smoke (`:1127`): **the on/off flag is always applied, but the per-effect parameters are only adopted when the effect is being switched on.**

Consequence: selecting a theme that does *not* use the tunnel while the tunnel is already on leaves your existing `tunnelSpeed` / `tunnelQuality` / `tunnelGrainStrength` untouched rather than resetting them. This is a deliberate "don't stomp the user's tuning" rule, and it is why the 4 shader parameter sets survive theme switching independently.

`apply` also records the selection (`:1133-1137`):

```swift
if AppTheme.darkThemes.contains(appTheme) { selectedDarkTheme  = appTheme }
else                                        { selectedLightTheme = appTheme }
```

Membership is tested against the two hardcoded arrays, so a theme missing from `darkThemes`/`lightThemes` is written to `selectedLightTheme` regardless of intent.

`applyActiveTheme()` (`:1140-1142`) is a one-liner: `apply(appearanceMode == .dark ? selectedDarkTheme : selectedLightTheme)`. This is what runs when the appearance mode changes.

---

## 3. `AppTheme` — 35 cases, 20 dark / 15 light

```swift
enum AppTheme: String, CaseIterable, Identifiable { ... }   // setting_View.swift:253
var id: String { rawValue }                                 // :293
```

The **raw value is the user-facing name** and is what is persisted. Because it doubles as the Settings display string, renaming a case's raw value silently orphans every existing user's stored selection (it will fail the `AppTheme(rawValue:)` round-trip and fall back to the default).

| Array | Count | Cases (`:295-305`) |
|---|---|---|
| `darkThemes` | **20** | `minimalDark, atom, ayu, catppuccin, dracula, eink, everforestDark, flexoki, gruvboxDark, macos, nord, rosePineDark, sky, solarizedDark, things, water, fog, mist, tunnel, tokyoNight` |
| `lightThemes` | **15** | `minimalLight, atomLight, ayuLight, catppuccinLight, einkLight, everforestLight, flexokiLight, gruvboxLight, macosLight, nordLight, rosePineLight, skyLight, solarizedLight, thingsLight, tokyoDay` |

> The 5 dark-only cases are `dracula`, `gruvboxDark`/`solarizedDark` are *not* dark-only, but `water`, `fog`, `mist` and `tunnel` are — they are shader-backed themes with no light counterpart, and `dracula` is simply unfinished. So: `water`, `fog`, `mist`, `tunnel` are shader themes; `dracula` has no light variant. Nothing enforces this: `AppTheme` has 35 cases and the two arrays cover exactly 35, so a new case **must** be added to one of the arrays or it will be invisible in Settings.

> **Naming asymmetry, deliberate:** `rosePineLight`'s raw value is `"Rosé Pine Dawn"` while every other light case ends in `"(Light)"`. `tokyoDay` vs `tokyoNight` is the same pattern. Do not "fix" these — the raw values are persisted strings.

### 3.1 `ThemePreset`

A flat struct of **26 stored properties** (`:158-190`): 8 colours, then 4 shader blocks.

| Block | Fields |
|---|---|
| colours | `background, text, secondaryText, accent, tint, gonioSides, gonioMids, playButton` |
| water | `useWaterShader, waterSpeed, waterIntensity, waterQuality` |
| fog | `useFogShader, fogColor, fogSpeed, fogIntensity` |
| tunnel | `useTunnelShader, tunnelColor, tunnelSpeed, tunnelIntensity, tunnelQuality, tunnelGrainStrength` |
| smoke | `useSmokeShader, smokeSpeed, smokeIntensity, smokeGrayscale, smokeQuality` |

`waterQuality` is the only non-optional field that has a default in the memberwise-ish `init` (`:198`); the rest of the fog/tunnel/smoke fields have `= default` values so that **existing `ThemePreset(...)` call sites keep compiling** when a new field is added (comment at `:191-192`). The shader defaults are `#b0c8e0` fog colour, `0.6` fog speed, `0.7` fog intensity, `#54a8ff` tunnel colour, `1.0` tunnel speed/intensity, `0.12` grain, `1.0` smoke speed/intensity, `0.0` grayscale (`:199-213`).

> **Gotcha:** `waterQuality` defaults to `.balanced` for *every* preset, so a theme that enables water without specifying a tier gets Balanced, not the tier the comment implies. And because the presets are hardcoded literals, the `.balanced` default at `:198` is only ever visible in themes that omit the argument — which is 34 of 35.

`ThemePreset.empty` (`:244-248`) is a plain black/white sentinel used for the pre-theme placeholder state; it is not reachable from `AppTheme.preset`.

### 3.2 The four shader-themed presets

Only 4 of the 35 themes enable a shader. These are the ones to check when debugging the background:

| Theme | Line | Enables | Values |
|---|---|---|---|
| **Water** | `:524-537` | water | speed `1.0`, intensity `0.8`, bg `#020e1e`, accent `#2dd4bf` |
| **Fog** | `:539-555` | fog | colour `#c8d8e8`, speed `0.55`, intensity `1.0`, bg `#0d0f12` |
| **Mist** | `:557-575` | water **and** fog | water `0.8`/`0.6`, fog `#80c8f0` `0.35`/`0.55`, bg `#020a14` |
| **Tunnel** | `:577-597` | tunnel | colour `#54a8ff`, speed `1.0`, intensity `1.0`, bg `#05070c` |

**No theme enables the smoke effect.** `useSmokeShader` is `false` in every preset, so smoke is reachable only by toggling it in Settings *after* selecting a theme — and selecting another theme afterwards will turn it back off, because `apply` unconditionally assigns `useSmokeShader = p.useSmokeShader` (`:1126`).

> **⚠️ Water's background colour is ignored.** `WaterShaderView` fills its `Rectangle` with `theme.waterColor` (`ShaderEffects.swift:51`), and `waterColor` is the hardcoded `let` `#2A7FAA` (`View/setting_View.swift:948`) — *not* `theme.backgroundColor` and not the Water theme's `#020e1e`. So selecting the Water theme gives you a mid-blue base that the raymarch tints, not the near-black background its palette implies. Fog (`:119`), tunnel (`:179`) and smoke (`:287`) all correctly fill with `theme.backgroundColor`; water is the odd one out.

> **⚠️ `Mist` renders water, not mist-first.** The comment at `:558` says "water caustics with a thin fog layer on top — underwater mist", and `AppBackground` does place fog last (on top). But water is a **full replacement backdrop**, not a blend layer — see §4.4. With both on you get fog over water, which matches the comment only by accident of ZStack order.

---

## 4. The four shader effects

### 4.1 The `colorEffect` contract

All four are SwiftUI `colorEffect`s, i.e. `[[ stitchable ]]` MSL functions invoked via the generated `ShaderLibrary` namespace. The signature shape is fixed by the framework:

```metal
[[ stitchable ]] half4 myEffect(
    float2 position,   // implicit — pixel position in the view
    half4  color,      // implicit — the pixel the view already has
    /* …explicit args in declared order… */
) -> half4
```

`position` and `color` are supplied by SwiftUI; the Swift call site omits them and passes only the explicit arguments **in declaration order**. Confirmed signatures:

| Effect | `.metal` | Explicit args (in order) |
|---|---|---|
| `waterEffect` | `View/Water.metal:206-215` | `time, size, tint, intensity, raymarchStepsF, raymarchIterationsF, normalIterationsF` (7) |
| `tunnelEffect` | `View/TunnelShader.metal:97-106` | `time, size, tintColor, speed, intensity, qualitySteps, qualityFolds` (7) |
| `fogEffect` | `View/Fog.metal:65-73` | `time, size, fogColor, intensity, speed` (5) |
| `colormapWarpEffect` | `View/ColormapWarp.metal:114-121` | `time, size, intensity, grayscale` (4) |

> **⚠️ `grainOverlay` does not exist — and it is not a compile error.** `ShaderEffects.swift:210-214` calls `ShaderLibrary.grainOverlay(.image(Image("BlueNoise64")), .float(...))` as a second `colorEffect` on the tunnel. **No `grainOverlay` function is defined in any `.metal` file in the repo** (verified: zero matches outside this call site). But `ShaderLibrary` is SwiftUI's own type and exposes `subscript(dynamicMember: String) -> ShaderFunction`, so the name is resolved by string at runtime against `default.metallib` and never type-checked. The build is green; the grain simply never appears. Confirmed by the symbol `SwiftUI.ShaderLibrary.subscript(dynamicMember:)` in the built `ShaderEffects.o`.
>
> **⚠️ `BlueNoise64` cannot resolve at runtime.** The header comment at `ShaderEffects.swift:157-159` says as much: *"requires 'BlueNoise64' to be added to Assets.xcassets"*. It was never added — `Assets.xcassets/` contains only `AccentColor.colorset`, `AppIcon.appiconset` and `Contents.json`. The PNG does exist as a loose file at `View/BlueNoise64.png`, but that is **not** sufficient: it is not in the asset catalogue, and although it *is* now a target member, a loose `.png` in a synchronized folder is not copied into the bundle by being listed in `membershipExceptions` — membership decides compilation, not resource copying (see [03](03-project-structure-and-build.md#5-target-membership-and-the-trap-in-it)). `Image("BlueNoise64")` at `:189` and `:211` therefore resolves to nothing.
>
> **⚠️ The tunnel's argument list is misaligned.** `ShaderEffects.swift:181-191` passes **8** explicit arguments, the last being `.image(Image("BlueNoise64"))`. `tunnelEffect` declares **9** (`float2 position, half4 color, float time, float2 size, half4 tintColor, float speed, float intensity, float qualitySteps, float qualityFolds` — `TunnelShader.metal:97-106`). Neither the count nor the types are checked at compile time for the same `dynamicMember` reason; the shader is bound positionally at runtime, so the arguments land on the wrong parameters and the tunnel renders wrong or not at all. The intent was clearly a `texture2d` parameter on the shader; `TunnelShader.metal` never got one — it has no `[[texture(n)]]` attribute anywhere.
>
> These three are all in the same ~30 lines. The tunnel effect is the one that does not compile. See [14-known-issues.md](14-known-issues.md#g1-missing-grainoverlay-shader-and-bluenoise64-asset).

> **Also note `.clipped()` is commented out on the tunnel** (`ShaderEffects.swift:204`) while the water and smoke views keep theirs (`:71`, `:304`). And the tunnel's `.blur(radius: 1.0)` line is **also** commented out (`:201`), which is deliberate — the grain overlay is re-applied after scaling to keep it crisp (`:205-208`), and without the grain overlay there is currently nothing to protect.

### 4.2 The performance pattern

Water, tunnel and smoke all share one structure (`ShaderEffects.swift:37-87`, `168-230`, `273-319`):

```swift
let quality = effectiveQuality                     // Low Power Mode can force .low
let scale   = quality.resolutionScale             // 0.35 / 0.5…0.8
let renderSize = CGSize(width: max(1, geo.size.width  * scale),
                        height: max(1, geo.size.height * scale))

Rectangle().fill(<opaque>)
    .colorEffect(ShaderLibrary.<effect>(…, .float2(renderSize), …))
    .frame(width: renderSize.width, height: renderSize.height)
    .drawingGroup(opaque: true)     // forces the low-res raster to actually happen
    .blur(radius: 1.0)              // hides the upscale's blocky edges
    .scaleEffect(1 / scale, anchor: .topLeading)
    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    .clipped()
    .ignoresSafeArea()
```

Five distinct cost levers, in order of impact:

1. **`resolutionScale`** — cost is linear in pixel count, so 0.35² ≈ 0.12× the pixels of full res.
2. **`.drawingGroup(opaque: true)`** — forces an offscreen raster at the reduced size. Without it SwiftUI may re-evaluate the colorEffect at the final size and the whole saving evaporates (`:19-20`, `:148-150`).
3. **`.blur(radius: 1.0)`** — in the *low-res* buffer's point space, so it auto-scales with the resolution drop (`:65-67`).
4. **`.scaleEffect(1 / scale)`** — the actual upscale.
5. **Step/iteration budgets** — passed in as uniforms, never `#define`d (`:151-152`).

**The fill must be opaque.** Called out four times in the file (`:48-50`, `:99-107`, `:284-286`): `colorEffect` recolours the pixel the view *already has*, so a transparent fill gives the shader `alpha = 0` and the effect renders invisible.

**Clocks.** Each view owns a `Timer.publish(every: quality.frameInterval, on: .main, in: .common)`, advances `time += quality.frameInterval * theme.<effect>Speed`, and is gated on `scenePhase == .active` (`:76-81`, `:219-224`, `:309-314`). Note the asymmetry: water and smoke **multiply** the interval by their speed (`:80`, `:313`) whereas the tunnel **does not** (`:223`) — the tunnel's speed is instead applied inside the shader as `time * speed` (`:110` of `TunnelShader.metal`).

**Low Power Mode.** `effectiveQuality` is `lowPowerModeEnabled ? .low : theme.<effect>Quality` (`:91-93`, `:234-236`, `:324-326`). `lowPowerModeEnabled` is refreshed by observing `NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)` (`:82-86`, `:225-229`, `:315-319`).

> **Gotcha:** these `Timer.publish(...).autoconnect()` objects are created inline in `body` (`:77`, `:220`, `:310`). Each `body` evaluation builds and tears down a new timer subscription. It works because the `@State` `time` survives, but it means the timer identity changes on every re-render — a classic source of dropped or doubled ticks if the body re-evaluates faster than the interval. Hoisting the publisher to a `private let` (as `AppBackground` does at `:357`) is the safer pattern.

> **Gotcha:** the timer is `on: .main, in: .common`, so it still fires (and is discarded by the `scenePhase` guard) while backgrounded. `time` does not advance, which is the intent, but the timer is not actually paused.

**Fog has none of this** (`:109-134`). It is comparatively cheap, takes `size` at full resolution, has no blur, no `drawingGroup`, no scale-up, and **no clock of its own** — `FogShaderView` receives an already-scaled `time: Double` from `AppBackground` (`:113`, `:383`). It is also the only effect that is **not** `fogSpeed`-multiplied twice: `AppBackground` passes `time * theme.fogSpeed` (`:383`) and the shader applies `speed` again (`:126`, `Fog.metal:71`) — i.e. **`fogSpeed` is squared**.

### 4.3 Quality tiers

Three enums, each `String, CaseIterable, Identifiable` with `id = rawValue` and `low`/`balanced`/`high` raw values `"Low"`/`"Balanced"`/`"High"`. Raw value is what is persisted.

**`TunnelQuality`** (`:12-57`)

| | `resolutionScale` | `maxSteps` | `foldIterations` | `frameInterval` |
|---|---|---|---|---|
| low | 0.35 | 75 | 5 | 1/24 |
| balanced | 0.55 | 130 | 7 | 1/30 |
| high | 0.8 | 200 | 9 | 1/60 |

**`WaterQuality`** (`:66-119`)

| | `resolutionScale` | `raymarchSteps` | `raymarchIterations` | `normalIterations` | `frameInterval` |
|---|---|---|---|---|---|
| low | 0.35 | 16 | 4 | 8 | 1/15 |
| balanced | 0.5 | 22 | 6 | 12 | 1/24 |
| high | 0.75 | 32 | 8 | 18 | 1/30 |

**`SmokeQuality`** (`:128-154`) — resolution and frame rate only:

| | `resolutionScale` | `frameInterval` |
|---|---|---|
| low | 0.35 | 1/15 |
| balanced | 0.55 | 1/24 |
| high | 0.8 | 1/30 |

Note the tier values are **not** monotonic across enums: water's balanced `resolutionScale` is `0.5` while tunnel's and smoke's are `0.55`, and water's high is `0.75` vs `0.8`. Tunnel is the only effect with a 1/60 (60 fps) high tier; water tops out at 1/30.

`normalIterations` is called out as the most expensive knob per shaded pixel because `normal()` is evaluated **3× per pixel** (`:100-101`) — the finite-difference derivative trick needs three height samples.

`frameInterval` is documented as intentional for all three: *"a slow ambient background doesn't need 60fps"* (`:48-49`, `:110-111`, `:145-146`).

### 4.4 `AppBackground` — layer order and the blend assumption

`AppBackground` (`:352-393`) is a 5-layer `ZStack`:

| # | Layer | Condition | Own clock? | Opacity |
|---|---|---|---|---|
| 1 | `theme.backgroundColor.ignoresSafeArea()` | always | — | opaque, zero GPU cost |
| 2 | `WaterShaderView()` | `theme.useWaterShader` | yes | **replacement** |
| 3 | `TunnelShaderView()` | `theme.useTunnelShader` | yes | **replacement** |
| 4 | `SmokeShaderView()` | `theme.useSmokeShader` | yes | **replacement** |
| 5 | `FogShaderView(time: time * theme.fogSpeed)` | `theme.useFogShader` | **no** — shared 60 Hz | **overlay** |

Its own timer runs at 60 Hz but only advances `time` when fog is on (`:357`, `:386-391`) — a micro-optimisation so the app isn't invalidating a view 60×/s for nothing when no fog is showing.

> **⚠️ Layers 2–4 are opaque full-screen fills, so "enabling more than one just stacks" is only half true.** The comment at `:345-347` is right that the later layer wins, but each of water/tunnel/smoke fills its `Rectangle` with an **opaque** colour and draws over the *entire* screen. So enabling water + tunnel gives you *only* the tunnel; the water raymarch is fully occluded and still burning GPU. There is no compositing — enabling two is pure waste. The `Mist` theme (water + fog) is the only multi-effect combination that actually shows both, because fog is the sole non-replacement layer.

> **⚠️ The tunnel's `time` is not speed-scaled in Swift, but the water's and smoke's are — and `AppBackground` scales fog twice.** See §4.2. If you add a fifth effect, follow the tunnel pattern (scale inside the shader) to avoid the double-multiply trap.

### 4.5 Shader credits — required in Settings

All three ports carry attribution, and the tunnel's is surfaced to the user:

| Effect | Source | License | Port notes |
|---|---|---|---|
| Water | afl_ext's raymarched water, Shadertoy, 2017–2024 (precision-hardened) | as upstream | `View/Water.metal:1-33` documents 5 changes: mouse camera removed; the original's dead centre-sample raymarch removed; iteration counts made uniforms; `mod()` reimplemented as `glslMod` for MSL sign semantics; global state threaded as parameters |
| Tunnel | "RayMarching starting point", Martijn Steinrucken (The Art of Code / BigWings), 2020 | **MIT** | `View/TunnelShader.metal:1-19`; camera texture replaced with a procedural sky gradient (SwiftUI colorEffects have no cubemap channel); speed/tint/intensity exposed as uniforms; hot loop runs in `half` for ~2× throughput |
| Smoke | trinketMage, 2019, <https://www.shadertoy.com/view/tdG3Rd> | as upstream | fBM colormap warp, surfaced in-app as **"Smoke"** — the Metal filename and the app's name deliberately differ (`ColormapWarp.metal` vs `useSmokeShader`) |
| Fog | original | — | A 4×4 Bayer-like threshold matrix (`:60-63`) plus fbm noise |

The tunnel hot loop uses `half` precision deliberately (`TunnelShader.metal:20-28`): *"Apple GPUs execute half-float math roughly 2x faster than float, and the visual result here — soft background art, usually viewed slightly blurred/upscaled anyway — does not benefit from float precision."* `int maxSteps = max(1, int(qualitySteps))` (`:109`) is the local truncation of the float uniform back to a loop bound.

---

## 5. Theme application timing

| Trigger | Action |
|---|---|
| App launch | `ThemeManager.init()` reads `UserDefaults`; nothing is written back on load |
| User picks a theme | `SettingsView.themeDropdown` → `theme.apply(theme)` → 20+ property assignments, each firing its own `didSet` → **20+ separate `UserDefaults.standard.set` calls in one runloop turn** |
| Appearance mode toggle | `theme.applyActiveTheme()` |
| Scene goes inactive | nothing; shader clocks pause via their `scenePhase` guards |

> **Gotcha:** `apply` writes `selectedDarkTheme`/`selectedLightTheme` *in addition to* the preset values, so picking a theme also persists the selection — but the *appearance mode* is never changed by `apply`. Selecting a light theme while in Dark mode applies the light palette immediately (`apply` is called with that theme) but leaves `appearanceMode == .dark` and `selectedDarkTheme` pointing at the old dark theme. Restarting the app returns you to the dark theme. See [11-settings-ui.md](11-settings-ui.md) for how the UI avoids this.

> **⚠️ `ThemeManager` is not `@MainActor`-isolated.** It is a plain `final class ObservableObject` with `didSet` writes to `UserDefaults` and no actor annotation, so Swift 6 strict-concurrency checking will flag the `@Published` mutation surface. See [13-concurrency-and-threading.md](13-concurrency-and-threading.md).

---

## 6. Adding a theme — checklist

1. Add the `case` to `AppTheme` (`:253-291`) with a **stable, unique** `rawValue` (it is the display name *and* the persisted key).
2. Add the case to `preset` (`:309-825`). Always pass all 8 colours. Pass the 3 base water fields (`useWaterShader`/`waterSpeed`/`waterIntensity`) as the other 33 presets do.
3. Add it to `darkThemes` (`:295-299`) or `lightThemes` (`:301-305`) — **otherwise it is invisible in Settings** even though `CaseIterable` sees it.
4. If it needs a new colour, add a `ThemeKey` (`:851-888`), a `@Published` property with `didSet` (`:907+`), an `init` load line (`:1028+`), and an `apply` assignment (`:1098+`). That's 4 edits; missing any one produces a colour that loads but never saves, or saves but never applies.
5. If it needs a new *effect*, that is 8+ edits: a `.metal` file, a `[[ stitchable ]]` function, a Swift view, an `AppBackground` layer, a `ThemeKey` set, a `ThemeManager` block, a `SettingsView` section, and a quality enum if it is expensive.

## 7. Change checklist

| If you change… | Re-verify |
|---|---|
| an `AppTheme` `rawValue` | every existing user's `theme.selectedDarkTheme` / `theme.selectedLightTheme` / stored colour values — the old string no longer round-trips and silently falls back |
| a `ThemePreset` field | `ThemePreset.init` default (`:193-213`), `ThemeManager.init` (`:1024-1092`), `apply` (`:1096-1138`) — 3 places |
| `ThemeKey` strings | they are the on-disk schema; a rename resets every user's setting |
| a `colorEffect` argument list | position in the Metal signature **and** the Swift call site must stay in lockstep — `grainOverlay` is what happens when they drift |
| `waterColor` | it is a `let`; making it configurable means adding a key, a `@Published`, an `init` line and an `apply` line, and it affects the Water theme's intended `#020e1e` base |
| `fogSpeed` | applied twice (`ShaderEffects.swift:126` + `:383`) — changing the shader's use of it changes the UI slider's apparent range quadratically |
| `resolutionScale` values | any value > 1.0 is a downscale of an upscale and will be blurry; 0.35 is the floor everywhere |
| `Color(hex:)` | 3-digit input and malformed input both produce near-black with no error |
