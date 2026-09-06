# SteelFront — endless first-person shooter (Metal, pure Swift)

A single-player, **endless** FPS written in Swift + Metal, targeting iPhone and
iPad. There are no levels: an always-escalating *threat* director keeps spawning
enemies forever, and the battlefield is generated procedurally as far as you run.
Every texture, sound, enemy and weapon model is generated **at runtime** — no
binary art assets, nothing to license.

Built and packaged as an **unsigned IPA** by GitHub Actions, ready to sideload.

---

## What's in the box

- **Graphics (Metal):** procedural sky with drifting clouds and a sun disc,
  HDR bloom + ACES tonemap, film grain, chromatic aberration, vignette,
  dynamic point lights (muzzle flashes, explosions), distance fog,
  4× MSAA, and animated enemies (walk cycle, aim pose, death topple) done in
  the vertex shader.
- **Endless world:** infinite streamed chunks of cover — buildings, containers,
  watch towers, sandbag nests, wrecks, barrels — all deterministic per cell.
- **8 weapons** across the categories you asked for: sidearm, SMG, pump shotgun,
  assault rifle (auto/semi/burst), marksman rifle (penetration + scope),
  grenade launcher, rocket launcher, railgun. Weapons unlock as the run escalates.
- **6 enemy types:** grunt, rusher (melee), heavy, sniper (telegraphed laser),
  recon drone, and a periodic siege brute miniboss. AI uses line-of-sight,
  cover and simple obstacle avoidance.
- **Gameplay loop:** kills raise a combo multiplier and the director's threat;
  threat scales enemy mix, density, health and damage. Pickups (health, armour,
  ammo) keep you going. Best score persists between runs.
- **Controls:** dual touch sticks (left = move, right = look), fire / ADS /
  jump / reload / sprint / weapon / fire-mode buttons, weapon quick slots,
  optional gyroscope aim, full military HUD (compass, kill feed, threat meter,
  damage direction, hit markers).

---

## Build the unsigned IPA on GitHub Actions

1. Push this folder to a repo and make sure the default branch is `main`/`master`.
2. The workflow `.github/workflows/build.yml` runs automatically on every push
   (and manually via **Run workflow**).
3. On `macos-14` it runs the logic tests, then `xcodegen generate`, then
   `xcodebuild archive` with `CODE_SIGNING_ALLOWED=NO`, and zips the app into
   **`SteelFront-unsigned.ipa`**.
4. Download it from **Actions → Build SteelFront → Artifacts**.

The IPA carries **no signature and no provisioning profile** by design.

---

## Sideloading (re-sign with your own account)

Any standard re-signing tool works, e.g.:

- **Sideloadly** — drop the `.ipa` in, sign with your Apple ID, install over USB.
- **AltStore** — same, via the AltStore companion.
- **esign / TrollStore** — for devices that support on-device signing.

Free developer accounts last **7 days**; re-install then. A paid account lasts a
year. Because the build is unsigned, the tool injects your own signing identity —
nothing in the repo depends on my certificate.

### Building locally in Xcode (optional)

```bash
brew install xcodegen
xcodegen generate      # recreates SteelFront.xcodeproj
open SteelFront.xcodeproj
# Xcode → select your Team under Signing & Capabilities, then Run on device.
```

---

## Project layout

```
App/                 UI, Metal renderer, shaders, game controller, input, audio
  Rendering/         Shaders.metal, MetalRenderer, meshers, textures, particles
Sources/Core/        Platform-agnostic game logic (no Metal/UIKit) — unit tested
Tests/CoreTests/     SwiftPM tests for the logic (run with `swift test`)
project.yml          XcodeGen spec (the .xcodeproj is generated, not committed)
.github/workflows/   CI: logic tests + unsigned IPA
```

The game logic (weapons, enemy AI, collision, director, projectiles) lives in
`Sources/Core` with no Apple framework dependencies, so it is fully unit-tested
on any machine with `swift test`, while the iOS app layers rendering and input
on top.

---

## Tuning

Everything is data. Look at:

- `Sources/Core/Weapons.swift` — the weapon catalogue and unlock thresholds.
- `Sources/Core/Director.swift` — threat curve, spawn cadence, composition.
- `Sources/Core/Enemies.swift` — enemy stats and behaviour.
- `App/Rendering/Shaders.metal` — sky, fog, bloom, tonemap.
