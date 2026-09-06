//
//  Weapons.swift
//  SteelFront
//
//  The full weapon catalogue plus the simulation of firing, recoil, reload,
//  fire-mode switching and ammo economy. Pure logic: no rendering involved.
//

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Definitions

public enum FireMode: String, CaseIterable, Codable {
    case semi
    case burst
    case auto
}

public enum AmmoKind: String, CaseIterable, Codable {
    case light      // pistol / smg
    case rifle      // carbine / rifle / marksman
    case shell      // shotgun
    case heavy      // launcher ordnance
    case cell       // energy
}

public struct WeaponDefinition: Equatable {
    public let id: String
    public let displayName: String
    public let shortName: String
    public let ammo: AmmoKind
    public let damage: Float
    public let headshotMultiplier: Float
    /// Shots per second.
    public let fireRate: Float
    public let magazine: Int
    public let reserveMax: Int
    public let reloadSeconds: Float
    /// Hip fire cone, degrees (grows while moving).
    public let spreadDegrees: Float
    public let adsSpreadMultiplier: Float
    /// Recoil impulse, degrees of pitch per shot.
    public let recoilPitch: Float
    public let recoilYaw: Float
    public let recoveryRate: Float
    public let pellets: Int
    public let range: Float
    /// Muzzle velocity for projectile weapons, 0 = hitscan.
    public let projectileSpeed: Float
    /// Explosion radius for projectile weapons, 0 = no splash.
    public let blastRadius: Float
    public let blastDamage: Float
    public let zoomFOVDegrees: Float?
    public let supportsPenetration: Bool
    public let availableFireModes: [FireMode]
    public let burstCount: Int
    public let moveSpeedMultiplier: Float
    /// How much the aim punches upward on screen (visual kick).
    public let viewKick: Float

    public init(id: String, displayName: String, shortName: String, ammo: AmmoKind,
                damage: Float, headshotMultiplier: Float = 2.5, fireRate: Float,
                magazine: Int, reserveMax: Int, reloadSeconds: Float,
                spreadDegrees: Float, adsSpreadMultiplier: Float = 0.35,
                recoilPitch: Float, recoilYaw: Float = 0.6, recoveryRate: Float = 9,
                pellets: Int = 1, range: Float = 160, projectileSpeed: Float = 0,
                blastRadius: Float = 0, blastDamage: Float = 0,
                zoomFOVDegrees: Float? = nil, supportsPenetration: Bool = false,
                availableFireModes: [FireMode] = [.auto], burstCount: Int = 3,
                moveSpeedMultiplier: Float = 1, viewKick: Float = 1) {
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.ammo = ammo
        self.damage = damage
        self.headshotMultiplier = headshotMultiplier
        self.fireRate = fireRate
        self.magazine = magazine
        self.reserveMax = reserveMax
        self.reloadSeconds = reloadSeconds
        self.spreadDegrees = spreadDegrees
        self.adsSpreadMultiplier = adsSpreadMultiplier
        self.recoilPitch = recoilPitch
        self.recoilYaw = recoilYaw
        self.recoveryRate = recoveryRate
        self.pellets = pellets
        self.range = range
        self.projectileSpeed = projectileSpeed
        self.blastRadius = blastRadius
        self.blastDamage = blastDamage
        self.zoomFOVDegrees = zoomFOVDegrees
        self.supportsPenetration = supportsPenetration
        self.availableFireModes = availableFireModes
        self.burstCount = burstCount
        self.moveSpeedMultiplier = moveSpeedMultiplier
        self.viewKick = viewKick
    }
}

public enum WeaponCatalog {

    public static let sidearm = WeaponDefinition(
        id: "sidearm", displayName: "M9 Sidearm", shortName: "M9", ammo: .light,
        damage: 26, headshotMultiplier: 2.2, fireRate: 6.0, magazine: 15, reserveMax: 240,
        reloadSeconds: 1.15, spreadDegrees: 1.1, recoilPitch: 1.1, recoveryRate: 12,
        range: 90, availableFireModes: [.semi], moveSpeedMultiplier: 1.06, viewKick: 0.8)

    public static let smg = WeaponDefinition(
        id: "smg", displayName: "VX-9 SMG", shortName: "VX9", ammo: .light,
        damage: 17, fireRate: 13.0, magazine: 32, reserveMax: 320, reloadSeconds: 1.5,
        spreadDegrees: 2.6, adsSpreadMultiplier: 0.4, recoilPitch: 0.9, recoilYaw: 0.9,
        recoveryRate: 11, range: 70, availableFireModes: [.auto], moveSpeedMultiplier: 1.08,
        viewKick: 0.85)

    public static let shotgun = WeaponDefinition(
        id: "shotgun", displayName: "KSG-12 Breacher", shortName: "KSG", ammo: .shell,
        damage: 13, headshotMultiplier: 1.8, fireRate: 1.4, magazine: 6, reserveMax: 60,
        reloadSeconds: 2.3, spreadDegrees: 6.0, adsSpreadMultiplier: 0.65, recoilPitch: 5.5,
        recoilYaw: 1.6, recoveryRate: 5.5, pellets: 9, range: 34,
        availableFireModes: [.semi], moveSpeedMultiplier: 0.95, viewKick: 2.2)

    public static let rifle = WeaponDefinition(
        id: "rifle", displayName: "AR-15 Platform", shortName: "AR15", ammo: .rifle,
        damage: 32, fireRate: 10.5, magazine: 30, reserveMax: 300, reloadSeconds: 1.9,
        spreadDegrees: 2.0, adsSpreadMultiplier: 0.3, recoilPitch: 1.5, recoilYaw: 0.7,
        recoveryRate: 9, range: 130, zoomFOVDegrees: 55,
        availableFireModes: [.auto, .semi, .burst], moveSpeedMultiplier: 0.96, viewKick: 1.1)

    public static let marksman = WeaponDefinition(
        id: "marksman", displayName: "SR-98 Marksman", shortName: "SR98", ammo: .rifle,
        damage: 95, headshotMultiplier: 3.0, fireRate: 1.1, magazine: 5, reserveMax: 40,
        reloadSeconds: 2.6, spreadDegrees: 4.0, adsSpreadMultiplier: 0.05, recoilPitch: 6.0,
        recoilYaw: 1.0, recoveryRate: 4.5, range: 320, zoomFOVDegrees: 22,
        supportsPenetration: true, availableFireModes: [.semi], moveSpeedMultiplier: 0.88, viewKick: 2.4)

    public static let launcher = WeaponDefinition(
        id: "launcher", displayName: "M320 Grenade Launcher", shortName: "M320", ammo: .heavy,
        damage: 12, fireRate: 1.0, magazine: 1, reserveMax: 12, reloadSeconds: 2.1,
        spreadDegrees: 0.6, recoilPitch: 3.2, recoveryRate: 5, range: 120,
        projectileSpeed: 42, blastRadius: 7.0, blastDamage: 125,
        availableFireModes: [.semi], moveSpeedMultiplier: 0.9, viewKick: 1.8)

    public static let rpg = WeaponDefinition(
        id: "rpg", displayName: "AT-4 Rocket", shortName: "AT4", ammo: .heavy,
        damage: 20, fireRate: 0.7, magazine: 1, reserveMax: 8, reloadSeconds: 3.0,
        spreadDegrees: 0.4, recoilPitch: 7.0, recoveryRate: 3.5, range: 200,
        projectileSpeed: 55, blastRadius: 10.0, blastDamage: 190,
        availableFireModes: [.semi], moveSpeedMultiplier: 0.85, viewKick: 3.0)

    public static let railgun = WeaponDefinition(
        id: "railgun", displayName: "XR-7 Railgun", shortName: "XR7", ammo: .cell,
        damage: 150, headshotMultiplier: 2.0, fireRate: 0.9, magazine: 4, reserveMax: 24,
        reloadSeconds: 2.4, spreadDegrees: 0.05, recoilPitch: 4.0, recoveryRate: 6,
        range: 400, zoomFOVDegrees: 30, supportsPenetration: true,
        availableFireModes: [.semi], moveSpeedMultiplier: 0.9, viewKick: 1.6)

    /// Loadout order shown in the weapon wheel.
    public static let all: [WeaponDefinition] = [
        sidearm, smg, shotgun, rifle, marksman, launcher, rpg, railgun,
    ]

    public static func definition(for id: String) -> WeaponDefinition? {
        all.first { $0.id == id }
    }

    /// Weapons handed to the player as the run escalates (keyed by kill count).
    public static let unlockThresholds: [(id: String, kills: Int)] = [
        ("sidearm", 0),
        ("smg", 6),
        ("shotgun", 18),
        ("rifle", 35),
        ("launcher", 60),
        ("marksman", 95),
        ("railgun", 150),
        ("rpg", 220),
    ]
}

// MARK: - Live weapon state

public struct WeaponState {
    public let definition: WeaponDefinition
    public var magazineAmmo: Int
    public var reserveAmmo: Int
    public var reloadTimer: Float = 0
    public var cooldown: Float = 0
    public var fireMode: FireMode
    public var burstRemaining: Int = 0
    public var burstCooldown: Float = 0
    /// Accumulated recoil that has not recovered yet, in degrees.
    public var recoilPitch: Float = 0
    public var recoilYaw: Float = 0
    public var spreadGrowth: Float = 0
    /// 0..1, used for the view model kick animation.
    public var kick: Float = 0
    /// Local RNG so recoil yaw varies shot to shot (deterministic per run).
    public var rng = GameRandom(seed: 0x51A7_9C_3E)

    public var isReloading: Bool { reloadTimer > 0 }
    public var isReady: Bool { cooldown <= 0 && reloadTimer <= 0 && burstCooldown <= 0 }

    public init(definition: WeaponDefinition, startFull: Bool = true) {
        self.definition = definition
        self.magazineAmmo = startFull ? definition.magazine : 0
        self.reserveAmmo = startFull ? definition.reserveMax : 0
        self.fireMode = definition.availableFireModes.first ?? .semi
    }

    /// Current hip-fire cone in degrees, factoring movement and sustained fire.
    public func effectiveSpread(aiming: Bool, moving: Bool) -> Float {
        var spread = definition.spreadDegrees + spreadGrowth
        if moving { spread *= 1.55 }
        if aiming { spread *= definition.adsSpreadMultiplier }
        return spread
    }

    public mutating func tick(_ dt: Float) {
        cooldown = max(0, cooldown - dt)
        burstCooldown = max(0, burstCooldown - dt)
        kick = max(0, kick - dt * 7)
        spreadGrowth = max(0, spreadGrowth - dt * definition.recoveryRate * 0.22)

        let recovery = definition.recoveryRate * dt
        recoilPitch = approach(recoilPitch, 0, recovery)
        recoilYaw = approach(recoilYaw, 0, recovery * 0.8)

        if reloadTimer > 0 {
            reloadTimer -= dt
            if reloadTimer <= 0 {
                reloadTimer = 0
                finishReload()
            }
        }
    }

    private mutating func finishReload() {
        let need = definition.magazine - magazineAmmo
        let take = min(need, reserveAmmo)
        magazineAmmo += take
        reserveAmmo -= take
    }

    public var canReload: Bool {
        reloadTimer <= 0 && magazineAmmo < definition.magazine && reserveAmmo > 0
    }

    public mutating func startReload() {
        guard canReload else { return }
        reloadTimer = definition.reloadSeconds
    }

    public mutating func addReserve(_ amount: Int) {
        reserveAmmo = min(definition.reserveMax, reserveAmmo + amount)
    }

    public mutating func cycleFireMode() {
        let modes = definition.availableFireModes
        guard modes.count > 1 else { return }
        let index = modes.firstIndex(of: fireMode) ?? 0
        fireMode = modes[(index + 1) % modes.count]
    }

    /// Consume one trigger pull. Returns the number of pellets fired (0 = no shot).
    public mutating func fire(aiming: Bool, moving: Bool) -> Int {
        guard reloadTimer <= 0, cooldown <= 0, magazineAmmo > 0 else { return 0 }

        if fireMode == .burst {
            guard burstCooldown <= 0 else { return 0 }
            // The trigger pull itself fires round 1 of the burst.
            burstRemaining = max(0, definition.burstCount - 1)
            burstCooldown = 0.34
        }

        magazineAmmo -= 1
        cooldown = 1 / definition.fireRate
        spreadGrowth = min(spreadGrowth + 0.55, definition.spreadDegrees * 2.5)

        let kickAmount = definition.viewKick
        recoilPitch += definition.recoilPitch * kickAmount
        recoilYaw += definition.recoilYaw * kickAmount * rng.range(-1, 1)
        kick = min(1.4, kick + 0.9)
        if magazineAmmo == 0 { startReload() }
        return definition.pellets
    }

    /// Burst continuation — called by the weapon manager each frame.
    public mutating func tickBurst() -> Bool {
        guard fireMode == .burst, burstRemaining > 0 else { return false }
        guard cooldown <= 0, magazineAmmo > 0, reloadTimer <= 0 else { return false }
        burstRemaining -= 1
        magazineAmmo -= 1
        cooldown = 1 / definition.fireRate
        recoilPitch += definition.recoilPitch * definition.viewKick
        kick = min(1.4, kick + 0.9)
        if magazineAmmo == 0 { startReload() }
        return true
    }

    private func approach(_ value: Float, _ target: Float, _ step: Float) -> Float {
        if value > target { return max(target, value - step) }
        return min(target, value + step)
    }
}

// MARK: - Loadout

public final class WeaponManager {
    public internal(set) var slots: [String: WeaponState] = [:]
    public internal(set) var unlocked: [String] = []
    public private(set) var currentID: String
    public var kills: Int = 0 {
        didSet { checkUnlocks() }
    }
    public var onWeaponUnlocked: ((WeaponDefinition) -> Void)?
    public var onWeaponSwitched: ((WeaponDefinition) -> Void)?
    public var onReloadStarted: ((WeaponDefinition) -> Void)?
    public var onDryFire: (() -> Void)?

    public init() {
        currentID = WeaponCatalog.rifle.id
        kills = 0
        unlock(WeaponCatalog.sidearm, silent: true)
        unlock(WeaponCatalog.smg, silent: true)
        unlock(WeaponCatalog.rifle, silent: true)
        currentID = WeaponCatalog.rifle.id
    }

    public var current: WeaponState {
        get { slots[currentID]! }
        set { slots[currentID] = newValue }
    }

    public var currentDefinition: WeaponDefinition { current.definition }

    private func checkUnlocks() {
        for entry in WeaponCatalog.unlockThresholds where kills >= entry.kills {
            guard let def = WeaponCatalog.definition(for: entry.id) else { continue }
            if slots[def.id] == nil {
                unlock(def, silent: false)
            }
        }
    }

    /// Adds a weapon to the loadout (used by the kill unlocks and by pickups).
    public func unlock(_ def: WeaponDefinition, silent: Bool = false) {
        guard slots[def.id] == nil else { return }
        slots[def.id] = WeaponState(definition: def)
        unlocked.append(def.id)
        if !silent { onWeaponUnlocked?(def) }
    }

    @discardableResult
    public func select(_ id: String) -> Bool {
        guard slots[id] != nil, id != currentID else { return false }
        // Cancel a reload that will not complete.
        current.reloadTimer = 0
        currentID = id
        onWeaponSwitched?(currentDefinition)
        return true
    }

    @discardableResult
    public func cycle(_ direction: Int) -> Bool {
        guard unlocked.count > 1 else { return false }
        let index = unlocked.firstIndex(of: currentID) ?? 0
        let next = (index + direction + unlocked.count * 2) % unlocked.count
        return select(unlocked[next])
    }

    /// Advances timers. Returns how many burst rounds were emitted this frame
    /// (the caller spawns the matching hitscans/pellets).
    @discardableResult
    public func tick(_ dt: Float) -> Int {
        for key in slots.keys { slots[key]?.tick(dt) }
        guard current.fireMode == .burst, current.burstRemaining > 0 else { return 0 }
        return current.tickBurst() ? current.definition.pellets : 0
    }

    public func reload() {
        guard current.canReload else { return }
        current.startReload()
        onReloadStarted?(currentDefinition)
    }

    public func refillReserve(_ ammo: AmmoKind, amount: Int) {
        for key in slots.keys where slots[key]?.definition.ammo == ammo {
            slots[key]?.addReserve(amount)
        }
    }

    public func refillAll() {
        for key in slots.keys {
            guard var state = slots[key] else { continue }
            state.reserveAmmo = state.definition.reserveMax
            state.magazineAmmo = state.definition.magazine
            state.reloadTimer = 0
            slots[key] = state
        }
    }
}
