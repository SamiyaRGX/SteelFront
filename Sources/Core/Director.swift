//
//  Director.swift
//  SteelFront
//
//  The endless-run director. There are no levels: a continuously rising
//  "threat" value drives spawn rate, enemy composition and enemy power, so a
//  run only ever ends when the player does.
//

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

public struct DirectorConfig {
    public var threatPerSecond: Float = 0.55
    public var threatPerKill: Float = 1.35
    public var threatPerMetre: Float = 0.012
    public var maxThreat: Float = 100
    /// Enemies alive at once, scaled by threat.
    public var minAlive: Int = 3
    public var maxAlive: Int = 26
    /// Seconds between spawn attempts at threat 0 / max.
    public var spawnIntervalStart: Float = 2.4
    public var spawnIntervalEnd: Float = 0.35
    public var spawnRingMin: Float = 26
    public var spawnRingMax: Float = 48
    /// Kills between siege brute spawns (0 disables).
    public var bruteEveryKills: Int = 45

    public init() {}
}

public enum SpawnRequest {
    case enemy(EnemyKind, powerScale: Float)
}

public final class Director {
    public private(set) var threat: Float = 0
    public private(set) var kills: Int = 0
    public private(set) var elapsed: Float = 0
    public private(set) var distanceTravelled: Float = 0
    public private(set) var spawnTimer: Float = 1.0
    public private(set) var bruteCountdown: Int
    public var config: DirectorConfig

    /// Current difficulty multiplier applied to enemy stats and reaction speed.
    public var difficulty: Float { 1 + threat * 0.035 }

    /// 0..1 progress indicator shown on the HUD.
    public var threatFraction: Float { clamp(threat / config.maxThreat, 0, 1) }

    public var targetAlive: Int {
        let t = threatFraction
        return config.minAlive + Int(Float(config.maxAlive - config.minAlive) * (0.25 + 0.75 * t))
    }

    public var spawnInterval: Float {
        lerp(config.spawnIntervalStart, config.spawnIntervalEnd, powf(threatFraction, 0.85))
    }

    public init(config: DirectorConfig = DirectorConfig()) {
        self.config = config
        self.bruteCountdown = config.bruteEveryKills
    }

    public func registerKill() {
        kills += 1
        threat = min(config.maxThreat, threat + config.threatPerKill)
        bruteCountdown -= 1
    }

    public func registerMovement(_ metres: Float) {
        distanceTravelled += metres
        threat = min(config.maxThreat, threat + metres * config.threatPerMetre)
    }

    /// Advances the director and returns the enemies it wants spawned now.
    public func update(dt: Float, aliveCount: Int) -> [SpawnRequest] {
        elapsed += dt
        threat = min(config.maxThreat, threat + dt * config.threatPerSecond)
        spawnTimer -= dt

        var requests: [SpawnRequest] = []
        guard spawnTimer <= 0 else { return requests }
        spawnTimer = spawnInterval

        let deficit = targetAlive - aliveCount
        guard deficit > 0 else { return requests }

        // Ramp the batch size so late game feels like a swarm.
        let batch = min(deficit, 1 + Int(threatFraction * 4))
        for _ in 0..<batch {
            requests.append(.enemy(pickKind(), powerScale: powerScale()))
        }

        if config.bruteEveryKills > 0 && bruteCountdown <= 0 {
            bruteCountdown = config.bruteEveryKills
            requests.append(.enemy(.brute, powerScale: powerScale() * 1.25))
        }
        return requests
    }

    /// Composition shifts towards nastier units as the run escalates.
    public func pickKind(using rng: inout GameRandom) -> EnemyKind {
        let t = threatFraction
        // Weight table: grunt stays common forever, heavies/brutes arrive later.
        let gruntW: Float = max(0.12, 0.62 - t * 0.35)
        let rusherW: Float = 0.12 + t * 0.18
        let heavyW: Float = t < 0.12 ? 0 : (t - 0.12) * 0.55
        let sniperW: Float = t < 0.06 ? 0.03 : 0.08 + t * 0.12
        let droneW: Float = t < 0.1 ? 0.02 : 0.06 + t * 0.16
        let total = gruntW + rusherW + heavyW + sniperW + droneW
        var roll = rng.nextFloat() * total
        for (kind, weight) in [
            (EnemyKind.grunt, gruntW), (.rusher, rusherW), (.heavy, heavyW),
            (.sniper, sniperW), (.drone, droneW),
        ] {
            roll -= weight
            if roll <= 0 { return kind }
        }
        return .grunt
    }

    public func pickKind() -> EnemyKind {
        var rng = GameRandom(seed: UInt64(bitPattern: Int64(elapsed * 1000)) &* 0x9E37 &+ UInt64(kills))
        return pickKind(using: &rng)
    }

    /// Enemies get tougher the longer you survive.
    public func powerScale() -> Float {
        1 + threat * 0.028
    }

    /// Ring around the player to spawn on, biased away from the view cone.
    public func spawnPosition(around player: Vec3, rng: inout GameRandom,
                              avoidDirection: Vec3?) -> Vec3 {
        var angle = rng.range(0, .pi * 2)
        if let avoid = avoidDirection, length(avoid) > 0.01 {
            let avoidYaw = atan2f(avoid.x, avoid.z)
            var diff = angle - avoidYaw
            while diff > .pi { diff -= .pi * 2 }
            while diff < -.pi { diff += .pi * 2 }
            // Nudge spawns out of the player's direct line of sight.
            if absf(diff) < 0.7 { angle += (diff >= 0 ? 1 : -1) * rng.range(0.9, 1.8) }
        }
        let radius = rng.range(config.spawnRingMin, config.spawnRingMax)
        return Vec3(player.x + cosf(angle) * radius, 0, player.z + sinf(angle) * radius)
    }
}
