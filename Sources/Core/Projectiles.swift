//
//  Projectiles.swift
//  SteelFront
//
//  Rockets and grenades: gravity, bounce, proximity detonation and blast
//  damage with distance falloff.
//

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

public final class Projectile {
    public enum Kind { case rocket, grenade, enemyRocket }

    public let id: Int
    public let kind: Kind
    public var position: Vec3
    public var velocity: Vec3
    public var gravity: Float
    public var life: Float
    public var fuse: Float
    public var damage: Float
    public var blastRadius: Float
    public var proximityRadius: Float
    public var bouncesLeft: Int
    public var fromPlayer: Bool
    public var spin: Float = 0
    /// Trail emitter cadence handled by the renderer; this tracks age.
    public var age: Float = 0

    public init(id: Int, kind: Kind, position: Vec3, velocity: Vec3, gravity: Float,
                life: Float, fuse: Float, damage: Float, blastRadius: Float,
                proximityRadius: Float = 0, bouncesLeft: Int = 0, fromPlayer: Bool = true) {
        self.id = id; self.kind = kind; self.position = position; self.velocity = velocity
        self.gravity = gravity; self.life = life; self.fuse = fuse; self.damage = damage
        self.blastRadius = blastRadius; self.proximityRadius = proximityRadius
        self.bouncesLeft = bouncesLeft; self.fromPlayer = fromPlayer
    }

    public var speed: Float { length(velocity) }
    public var direction: Vec3 { normalize(velocity) }
}

public enum ProjectileEvent {
    case impact(position: Vec3, normal: Vec3, projectileID: Int)
    case explode(position: Vec3, radius: Float, damage: Float, fromPlayer: Bool, projectileID: Int)
}

public final class ProjectileSystem {
    public private(set) var projectiles: [Projectile] = []
    private var nextID = 1

    public var count: Int { projectiles.count }

    public func spawn(_ kind: Projectile.Kind, from origin: Vec3, direction: Vec3,
                      speed: Float, damage: Float, blastRadius: Float,
                      gravity: Float = 0, fuse: Float = 99, proximity: Float = 0,
                      bounces: Int = 0, fromPlayer: Bool = true) -> Projectile {
        let p = Projectile(id: nextID, kind: kind, position: origin,
                           velocity: normalize(direction) * speed, gravity: gravity,
                           life: 14, fuse: fuse, damage: damage, blastRadius: blastRadius,
                           proximityRadius: proximity, bouncesLeft: bounces, fromPlayer: fromPlayer)
        nextID += 1
        projectiles.append(p)
        return p
    }

    public func clear() { projectiles.removeAll() }

    public func update(dt: Float, world: CollisionWorld,
                       playerPosition: Vec3, enemies: [Enemy]) -> [ProjectileEvent] {
        var events: [ProjectileEvent] = []
        var survivors: [Projectile] = []
        survivors.reserveCapacity(projectiles.count)

        for p in projectiles {
            p.age += dt
            p.life -= dt
            p.fuse -= dt
            p.velocity.y -= p.gravity * dt
            p.spin += dt * 6

            // Sub-step so fast rockets do not tunnel through thin cover.
            let steps = max(1, min(6, Int(p.speed * dt / 0.6) + 1))
            let stepDT = dt / Float(steps)
            var consumed = false

            for _ in 0..<steps {
                let next = p.position + p.velocity * stepDT
                let delta = next - p.position
                let dist = length(delta)
                if dist > 0.0001 {
                    if let hit = world.raycast(origin: p.position, direction: delta / dist,
                                               maxDistance: dist) {
                        p.position = hit.point + hit.normal * 0.05
                        if p.kind == .grenade && p.bouncesLeft > 0 {
                            p.bouncesLeft -= 1
                            let reflected = p.velocity - hit.normal * 2 * dot(p.velocity, hit.normal)
                            p.velocity = reflected * 0.42
                            p.velocity.y = max(p.velocity.y, 1.2)
                            events.append(.impact(position: hit.point, normal: hit.normal,
                                                  projectileID: p.id))
                        } else {
                            events.append(.explode(position: p.position, radius: p.blastRadius,
                                                   damage: p.damage, fromPlayer: p.fromPlayer,
                                                   projectileID: p.id))
                            consumed = true
                        }
                        break
                    }
                }
                p.position = next

                // Ground contact.
                let ground = Terrain.height(at: p.position.x, p.position.z)
                if p.position.y < ground + 0.1 {
                    p.position.y = ground + 0.1
                    if p.kind == .grenade && p.bouncesLeft > 0 {
                        p.bouncesLeft -= 1
                        p.velocity = Vec3(p.velocity.x * 0.6, absf(p.velocity.y) * 0.45, p.velocity.z * 0.6)
                        events.append(.impact(position: p.position, normal: Vec3(0, 1, 0),
                                              projectileID: p.id))
                    } else {
                        events.append(.explode(position: p.position, radius: p.blastRadius,
                                               damage: p.damage, fromPlayer: p.fromPlayer,
                                               projectileID: p.id))
                        consumed = true
                    }
                    break
                }

                // Proximity detonation against enemies (rockets) or the player.
                if p.proximityRadius > 0 {
                    var near = false
                    if p.fromPlayer {
                        for e in enemies where !e.isDead {
                            if distance(e.position + Vec3(0, e.definition.height * 0.5, 0), p.position)
                                < p.proximityRadius + e.definition.radius {
                                near = true; break
                            }
                        }
                    } else if distance(playerPosition, p.position) < p.proximityRadius {
                        near = true
                    }
                    if near {
                        events.append(.explode(position: p.position, radius: p.blastRadius,
                                               damage: p.damage, fromPlayer: p.fromPlayer,
                                               projectileID: p.id))
                        consumed = true
                        break
                    }
                }
            }

            if consumed { continue }
            if p.life <= 0 || p.fuse <= 0 {
                events.append(.explode(position: p.position, radius: p.blastRadius,
                                       damage: p.damage, fromPlayer: p.fromPlayer,
                                       projectileID: p.id))
                continue
            }
            survivors.append(p)
        }
        projectiles = survivors
        return events
    }

    /// Blast damage with linear falloff, respecting line of sight so hiding
    /// behind a wall actually saves you.
    public static func blastDamage(center: Vec3, radius: Float, damage: Float,
                                   target: Vec3, world: CollisionWorld) -> Float {
        let delta = target - center
        let dist = length(delta)
        if dist > radius { return 0 }
        let falloff = 1 - (dist / radius)
        if dist > 0.5 {
            let dir = delta / dist
            if let hit = world.raycast(origin: center + dir * 0.3, direction: dir,
                                       maxDistance: dist) {
                if hit.distance < dist - 0.35 { return damage * falloff * 0.15 }
            }
        }
        return damage * falloff
    }
}
