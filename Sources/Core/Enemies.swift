//
//  Enemies.swift
//  SteelFront
//
//  Enemy roster plus their behaviour. Every enemy is simulated here in pure
//  logic; the renderer just draws whatever state this produces.
//

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

public enum EnemyKind: String, CaseIterable {
    case grunt
    case rusher
    case heavy
    case sniper
    case drone
    case brute
}

public struct EnemyDefinition {
    public let kind: EnemyKind
    public let displayName: String
    public let maxHealth: Float
    /// Walk speed in m/s.
    public let speed: Float
    public let damage: Float
    public let fireInterval: Float
    /// Rounds per burst.
    public let burstCount: Float
    /// Preferred engagement distance.
    public let preferredRange: Float
    public let attackRange: Float
    /// Accuracy: 0 = perfect, 1 = wild.
    public let inaccuracy: Float
    public let radius: Float
    public let height: Float
    public let eyeHeight: Float
    public let score: Int
    public let headRadius: Float
    public let flies: Bool
    public let explosiveOnDeath: Float
    /// How much incoming damage is absorbed (armour).
    public let armour: Float
    /// Seconds of telegraph before a sniper shot.
    public let telegraph: Float

    public init(kind: EnemyKind, displayName: String, maxHealth: Float, speed: Float,
                damage: Float, fireInterval: Float, burstCount: Float = 1,
                preferredRange: Float = 14, attackRange: Float = 45, inaccuracy: Float = 0.35,
                radius: Float = 0.45, height: Float = 1.8, eyeHeight: Float = 1.55,
                score: Int = 100, headRadius: Float = 0.24, flies: Bool = false,
                explosiveOnDeath: Float = 0, armour: Float = 0, telegraph: Float = 0) {
        self.kind = kind; self.displayName = displayName; self.maxHealth = maxHealth
        self.speed = speed; self.damage = damage; self.fireInterval = fireInterval
        self.burstCount = burstCount; self.preferredRange = preferredRange
        self.attackRange = attackRange; self.inaccuracy = inaccuracy
        self.radius = radius; self.height = height; self.eyeHeight = eyeHeight
        self.score = score; self.headRadius = headRadius; self.flies = flies
        self.explosiveOnDeath = explosiveOnDeath; self.armour = armour
        self.telegraph = telegraph
    }
}

public enum EnemyRoster {
    public static let grunt = EnemyDefinition(
        kind: .grunt, displayName: "Insurgent", maxHealth: 100, speed: 3.4, damage: 8,
        fireInterval: 1.5, burstCount: 3, preferredRange: 15, attackRange: 50,
        inaccuracy: 0.4, score: 100)

    public static let rusher = EnemyDefinition(
        kind: .rusher, displayName: "Blade Runner", maxHealth: 70, speed: 6.4, damage: 26,
        fireInterval: 0.9, preferredRange: 1.6, attackRange: 2.4, inaccuracy: 0,
        radius: 0.4, height: 1.75, score: 150)

    public static let heavy = EnemyDefinition(
        kind: .heavy, displayName: "Juggernaut", maxHealth: 340, speed: 2.3, damage: 12,
        fireInterval: 2.2, burstCount: 6, preferredRange: 12, attackRange: 40,
        inaccuracy: 0.45, radius: 0.62, height: 2.0, eyeHeight: 1.75, score: 400,
        headRadius: 0.26, armour: 0.3)

    public static let sniper = EnemyDefinition(
        kind: .sniper, displayName: "Marksman", maxHealth: 90, speed: 2.8, damage: 34,
        fireInterval: 3.2, preferredRange: 55, attackRange: 120, inaccuracy: 0.12,
        radius: 0.42, height: 1.8, score: 250, telegraph: 1.15)

    public static let drone = EnemyDefinition(
        kind: .drone, displayName: "Recon Drone", maxHealth: 55, speed: 5.6, damage: 7,
        fireInterval: 1.1, burstCount: 2, preferredRange: 12, attackRange: 45,
        inaccuracy: 0.5, radius: 0.42, height: 0.6, eyeHeight: 0.3, score: 175,
        headRadius: 0.3, flies: true, explosiveOnDeath: 3.2)

    public static let brute = EnemyDefinition(
        kind: .brute, displayName: "Siege Brute", maxHealth: 1500, speed: 2.0, damage: 45,
        fireInterval: 3.0, preferredRange: 20, attackRange: 60, inaccuracy: 0.3,
        radius: 0.9, height: 2.6, eyeHeight: 2.2, score: 2000, headRadius: 0.32,
        explosiveOnDeath: 8.0, armour: 0.4)

    public static func definition(_ kind: EnemyKind) -> EnemyDefinition {
        switch kind {
        case .grunt: return grunt
        case .rusher: return rusher
        case .heavy: return heavy
        case .sniper: return sniper
        case .drone: return drone
        case .brute: return brute
        }
    }
}

public enum EnemyAction: Equatable {
    /// Hitscan shot at the player.
    case shot(from: Vec3, spread: Float, damage: Float)
    /// Melee strike that already connected.
    case melee(damage: Float)
    /// Telegraph started (laser sight) so the HUD can warn the player.
    case telegraph
    /// Explosive death.
    case explode(position: Vec3, radius: Float, damage: Float)
    case died(position: Vec3, kind: EnemyKind, headshot: Bool)
}

public final class Enemy {
    public let id: Int
    public let definition: EnemyDefinition
    public var position: Vec3
    public var velocity = Vec3.zero
    public var health: Float
    public var yaw: Float = 0
    public var isDead = false
    public var deathTimer: Float = 0
    public var hitFlash: Float = 0
    public var spawnTimer: Float = 0.6
    public var fireTimer: Float
    public var telegraphTimer: Float = 0
    public var strafeDirection: Float = 1
    public var strafeTimer: Float = 0
    public var strafeFlipCount: Int = 0
    public var walkPhase: Float = 0
    public var hasLineOfSight = false
    public var distanceToPlayer: Float = 0
    public var lastKnownPlayerPosition = Vec3.zero
    /// 0..1 blend used by the renderer for the hit reaction.
    public var stagger: Float = 0
    /// Difficulty multiplier applied on spawn.
    public var powerScale: Float = 1

    public var kind: EnemyKind { definition.kind }
    public var eyePosition: Vec3 { position + Vec3(0, definition.eyeHeight, 0) }
    public var headCenter: Vec3 { position + Vec3(0, definition.height - definition.headRadius, 0) }
    public var healthFraction: Float { max(0, health) / (definition.maxHealth * powerScale) }
    public var isMelee: Bool { definition.kind == .rusher }

    public init(id: Int, definition: EnemyDefinition, position: Vec3, powerScale: Float = 1) {
        self.id = id
        self.definition = definition
        self.position = position
        self.health = definition.maxHealth * powerScale
        self.powerScale = powerScale
        self.fireTimer = definition.fireInterval * 0.6
        var spawnRNG = GameRandom(seed: UInt64(bitPattern: Int64(id)))
        self.walkPhase = spawnRNG.range(0, .pi * 2)
    }

    /// Applies damage. Returns (applied, killed, headshot).
    @discardableResult
    public func applyDamage(_ amount: Float, headshot: Bool) -> (applied: Float, killed: Bool) {
        guard !isDead else { return (0, false) }
        let armourReduction = 1 - definition.armour
        let headMultiplier: Float = headshot ? 2.0 : 1.0
        let applied = max(1, amount * armourReduction * headMultiplier)
        health -= applied
        hitFlash = 1
        stagger = min(1, stagger + 0.45)
        if health <= 0 {
            health = 0
            isDead = true
            deathTimer = 0
            return (applied, true)
        }
        return (applied, false)
    }

    public func tickTimers(_ dt: Float) {
        hitFlash = max(0, hitFlash - dt * 4)
        stagger = max(0, stagger - dt * 2.5)
        walkPhase += dt * (definition.speed * 1.6 + length(velocity) * 0.6)
        if isDead {
            deathTimer += dt
        } else {
            spawnTimer = max(0, spawnTimer - dt)
        }
    }
}

/// Stateless behaviour solver — keeps Enemy a plain data holder and makes the
/// AI easy to unit test.
public struct EnemyBrain {

    public struct Context {
        public var playerPosition: Vec3
        public var playerEye: Vec3
        public var world: CollisionWorld
        public var difficulty: Float
        public init(playerPosition: Vec3, playerEye: Vec3, world: CollisionWorld, difficulty: Float = 1) {
            self.playerPosition = playerPosition
            self.playerEye = playerEye
            self.world = world
            self.difficulty = difficulty
        }
    }

    /// Advances one enemy: steering, collision, animation timers and attacks.
    /// `neighbours` is used for crowd separation and may be empty.
    @discardableResult
    public static func update(_ enemy: Enemy, context: Context, dt: Float,
                              neighbours: [Enemy] = []) -> [EnemyAction] {
        var actions: [EnemyAction] = []
        let def = enemy.definition

        if enemy.isDead {
            enemy.velocity = Vec3.zero
            return actions
        }
        guard enemy.spawnTimer <= 0 else {
            enemy.velocity = Vec3.zero
            return actions
        }

        let toPlayer = context.playerPosition - enemy.position
        let flatDistance = distance2D(enemy.position, context.playerPosition)
        enemy.distanceToPlayer = flatDistance
        enemy.lastKnownPlayerPosition = context.playerPosition

        let eye = enemy.eyePosition
        let targetEye = context.playerEye
        enemy.hasLineOfSight = flatDistance < def.attackRange * 1.4 &&
            context.world.lineOfSight(from: eye, to: targetEye, clearance: 0.2)

        // Face the player (or the movement direction while searching).
        let faceTarget = enemy.hasLineOfSight ? toPlayer : enemy.velocity
        if horizontalLength(faceTarget) > 0.01 {
            let desired = atan2f(faceTarget.x, faceTarget.z)
            enemy.yaw = dampAngle(enemy.yaw, desired, 8, dt)
        }

        // --- Desired movement ---
        var move = Vec3.zero
        switch def.kind {
        case .rusher:
            let charge = normalize(Vec3(toPlayer.x, 0, toPlayer.z)) * def.speed
            // Bleed off speed at contact range so it swings instead of running past.
            move = flatDistance < def.attackRange * 1.3 ? charge * 0.12 : charge
        case .sniper:
            if enemy.hasLineOfSight {
                if flatDistance < def.preferredRange * 0.75 {
                    move = -normalize(Vec3(toPlayer.x, 0, toPlayer.z)) * def.speed
                } else if flatDistance > def.preferredRange {
                    move = normalize(Vec3(toPlayer.x, 0, toPlayer.z)) * def.speed * 0.7
                } else {
                    move = strafe(enemy: enemy, toPlayer: toPlayer, dt: dt) * def.speed * 0.6
                }
            } else {
                move = seekDirection(enemy: enemy, toPlayer: toPlayer, world: context.world) * def.speed
            }
        case .drone:
            let orbit = strafe(enemy: enemy, toPlayer: toPlayer, dt: dt)
            let approach = flatDistance > def.preferredRange
                ? normalize(Vec3(toPlayer.x, 0, toPlayer.z)) : Vec3.zero
            move = normalize(approach + orbit * 0.8) * def.speed
        case .brute, .heavy:
            if flatDistance > def.preferredRange {
                move = seekDirection(enemy: enemy, toPlayer: toPlayer, world: context.world) * def.speed
            } else {
                move = strafe(enemy: enemy, toPlayer: toPlayer, dt: dt) * def.speed * 0.5
            }
        case .grunt:
            if enemy.hasLineOfSight {
                if flatDistance > def.preferredRange * 1.2 {
                    move = normalize(Vec3(toPlayer.x, 0, toPlayer.z)) * def.speed
                } else if flatDistance < def.preferredRange * 0.6 {
                    move = -normalize(Vec3(toPlayer.x, 0, toPlayer.z)) * def.speed * 0.7
                } else {
                    move = strafe(enemy: enemy, toPlayer: toPlayer, dt: dt) * def.speed
                }
            } else {
                move = seekDirection(enemy: enemy, toPlayer: toPlayer, world: context.world) * def.speed
            }
        }

        // Separation from nearby allies keeps crowds from stacking into one blob.
        if !neighbours.isEmpty {
            var push = Vec3.zero
            for other in neighbours where other.id != enemy.id && !other.isDead {
                let delta = enemy.position - other.position
                let dist = distance2D(enemy.position, other.position)
                let minDist = (enemy.definition.radius + other.definition.radius) * 1.6
                if dist < minDist && dist > 0.001 {
                    push += normalize(Vec3(delta.x, 0, delta.z)) * (1 - dist / minDist)
                }
            }
            move += push * def.speed * 0.9
        }
        enemy.velocity = damp(enemy.velocity, move, def.flies ? 4 : 9, dt)
        integrate(enemy: enemy, context: context, dt: dt)

        // --- Attack ---
        enemy.fireTimer -= dt * context.difficulty
        if enemy.hasLineOfSight {
            switch def.kind {
            case .rusher:
                if flatDistance < def.attackRange {
                    if enemy.fireTimer <= 0 {
                        enemy.fireTimer = def.fireInterval
                        actions.append(.melee(damage: def.damage * enemy.powerScale))
                    }
                }
            case .sniper:
                if enemy.telegraphTimer > 0 {
                    enemy.telegraphTimer -= dt
                    if enemy.telegraphTimer <= 0 {
                        enemy.fireTimer = def.fireInterval
                        actions.append(.shot(from: eye,
                                             spread: def.inaccuracy * 0.4,
                                             damage: def.damage * enemy.powerScale))
                    }
                } else if enemy.fireTimer <= 0 && flatDistance < def.attackRange {
                    enemy.telegraphTimer = def.telegraph
                    actions.append(.telegraph)
                }
            default:
                if enemy.fireTimer <= 0 && flatDistance < def.attackRange {
                    enemy.fireTimer = def.fireInterval
                    let rounds = max(1, Int(def.burstCount))
                    for _ in 0..<rounds {
                        actions.append(.shot(from: eye,
                                             spread: def.inaccuracy,
                                             damage: def.damage * enemy.powerScale))
                    }
                }
            }
        } else {
            enemy.telegraphTimer = 0
        }
        return actions
    }

    /// Applies velocity to position, resolves collisions and keeps enemies on
    /// the ground (or hovering, for drones).
    private static func integrate(enemy: Enemy, context: Context, dt: Float) {
        let def = enemy.definition
        enemy.position += enemy.velocity * dt

        let ground = Terrain.height(at: enemy.position.x, enemy.position.z)
        if def.flies {
            let hover = ground + 3.4 + sinf(enemy.walkPhase * 0.7) * 0.5
            enemy.position.y = damp(enemy.position.y, hover, 2.5, dt)
        } else {
            if enemy.position.y < ground { enemy.position.y = ground }
            _ = context.world.move(position: &enemy.position, radius: def.radius,
                                   height: def.height, stepHeight: 0.65)
            let floor = Terrain.height(at: enemy.position.x, enemy.position.z)
            if enemy.position.y < floor { enemy.position.y = floor }
        }
    }

    /// Sidestepping movement so enemies orbit instead of standing still.
    private static func strafe(enemy: Enemy, toPlayer: Vec3, dt: Float) -> Vec3 {
        enemy.strafeTimer -= dt
        if enemy.strafeTimer <= 0 {
            var rng = GameRandom(seed: UInt64(bitPattern: Int64(enemy.id))
                &+ UInt64(enemy.walkPhase.bitPattern & 0xFFFF) &+ UInt64(enemy.strafeFlipCount))
            enemy.strafeFlipCount += 1
            enemy.strafeTimer = rng.range(0.7, 1.9)
            enemy.strafeDirection *= -1
        }
        let forward = normalize(Vec3(toPlayer.x, 0, toPlayer.z))
        return Vec3(-forward.z, 0, forward.x) * enemy.strafeDirection
    }

    /// Probe three directions and pick the first that is not blocked; this is
    /// cheap obstacle avoidance that works well enough in open arenas.
    private static func seekDirection(enemy: Enemy, toPlayer: Vec3, world: CollisionWorld) -> Vec3 {
        let direct = normalize(Vec3(toPlayer.x, 0, toPlayer.z))
        let origin = enemy.eyePosition
        let probeLength: Float = 3.0
        let candidates: [Vec3] = [
            direct,
            rotateY(direct, 0.6), rotateY(direct, -0.6),
            rotateY(direct, 1.2), rotateY(direct, -1.2),
        ]
        for candidate in candidates {
            let hit = world.raycast(origin: origin, direction: candidate, maxDistance: probeLength)
            if hit == nil || hit!.distance > probeLength * 0.9 {
                return candidate
            }
        }
        return rotateY(direct, .pi * 0.5)
    }

    public static func rotateY(_ v: Vec3, _ radians: Float) -> Vec3 {
        let c = cosf(radians), s = sinf(radians)
        return Vec3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)
    }
}

/// Shortest-path angle interpolation.
public func dampAngle(_ current: Float, _ target: Float, _ rate: Float, _ dt: Float) -> Float {
    var diff = target - current
    while diff > .pi { diff -= .pi * 2 }
    while diff < -.pi { diff += .pi * 2 }
    return current + diff * (1 - exp(-rate * dt))
}
