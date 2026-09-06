//
//  Player.swift
//  SteelFront
//
//  Player movement, damage, armour and the run-scoring state.
//

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

public struct PlayerConfig {
    public var walkSpeed: Float = 5.4
    public var sprintSpeed: Float = 8.6
    public var crouchSpeed: Float = 2.6
    public var acceleration: Float = 14
    public var airAcceleration: Float = 3
    public var jumpVelocity: Float = 6.2
    public var gravity: Float = 20
    public var capsuleRadius: Float = 0.42
    public var capsuleHeight: Float = 1.75
    public var eyeHeight: Float = 1.6
    public var crouchEyeHeight: Float = 1.05
    public var maxHealth: Float = 100
    public var maxArmour: Float = 100
    /// Fraction of damage absorbed by armour.
    public var armourAbsorb: Float = 0.6
    public var regenDelay: Float = 4.0
    public var regenPerSecond: Float = 14
    public var stepHeight: Float = 0.75

    public init() {}
}

public enum PlayerStance: String { case standing, crouched }

public final class Player {
    public var position: Vec3
    public var velocity = Vec3.zero
    public var yaw: Float = 0
    public var pitch: Float = 0
    public var health: Float
    public var armour: Float = 0
    public var grounded = false
    public var stance: PlayerStance = .standing
    public var sprinting = false
    public var aiming = false
    public var timeSinceDamage: Float = 100
    public var config: PlayerConfig
    /// Screen shake impulse, decays over time.
    public var shake: Float = 0
    /// 0..1 red damage vignette.
    public var damageFlash: Float = 0
    /// Direction (world) of the most recent hit, for the damage indicator.
    public var lastHitDirection: Vec3 = Vec3(1, 0, 0)
    public var headBob: Float = 0
    public var footstepTimer: Float = 0
    public var onFootstep: (() -> Void)?

    public var eyeHeight: Float {
        stance == .crouched ? config.crouchEyeHeight : config.eyeHeight
    }

    public var eyePosition: Vec3 { position + Vec3(0, eyeHeight, 0) }

    public var forward: Vec3 {
        Vec3(sinf(yaw) * cosf(pitch), sinf(pitch), cosf(yaw) * cosf(pitch))
    }

    public var forwardFlat: Vec3 { normalize(Vec3(sinf(yaw), 0, cosf(yaw))) }

    public var right: Vec3 { Vec3(cosf(yaw), 0, -sinf(yaw)) }

    public var healthFraction: Float { clamp(health / config.maxHealth, 0, 1) }
    public var armourFraction: Float { clamp(armour / config.maxArmour, 0, 1) }
    public var isAlive: Bool { health > 0 }

    public init(position: Vec3 = Vec3.zero, config: PlayerConfig = PlayerConfig()) {
        self.position = position
        self.config = config
        self.health = config.maxHealth
    }

    // MARK: - Movement

    /// `wish` is a unit-length XZ direction from the move stick, -1...1 magnitude.
    public func updateMovement(wish: Vec2, jumpPressed: Bool, world: CollisionWorld,
                               groundHeight: Float, dt: Float, speedMultiplier: Float = 1) {
        let crouching = stance == .crouched
        let baseSpeed = crouching ? config.crouchSpeed
            : (sprinting && length(wish) > 0.6 ? config.sprintSpeed : config.walkSpeed)
        let targetSpeed = baseSpeed * speedMultiplier

        let wishDir: Vec3
        if length(wish) > 0.001 {
            let f = forwardFlat
            let r = right
            let magnitude = min(1, length(wish))
            wishDir = normalize(f * wish.y + r * wish.x) * magnitude
        } else {
            wishDir = Vec3.zero
        }

        // --- Horizontal acceleration ---
        let accel = grounded ? config.acceleration : config.airAcceleration
        let targetVelocity = wishDir * targetSpeed
        velocity.x = damp(velocity.x, targetVelocity.x, accel, dt)
        velocity.z = damp(velocity.z, targetVelocity.z, accel, dt)

        // --- Ground detection (terrain + anything we can step onto) ---
        var support = groundHeight
        if let boxTop = world.supportHeight(center: position, radius: config.capsuleRadius,
                                            feetY: position.y, stepHeight: config.stepHeight) {
            support = max(support, boxTop)
        }
        if position.y <= support + 0.02 && velocity.y <= 0.01 {
            grounded = true
            position.y = support
            velocity.y = 0
        } else {
            grounded = false
        }

        // --- Jump / gravity / integrate ---
        if jumpPressed && grounded {
            velocity.y = config.jumpVelocity
            grounded = false
        }
        velocity.y -= config.gravity * dt
        position += velocity * dt

        // --- Collision: push out of walls, then re-snap to the floor ---
        world.resolveHorizontal(position: &position, radius: config.capsuleRadius,
                                height: eyeHeight + 0.15, feetY: position.y)
        var floor = Terrain.height(at: position.x, position.z)
        floor = max(floor, groundHeight)
        if let boxTop = world.supportHeight(center: position, radius: config.capsuleRadius,
                                            feetY: position.y, stepHeight: config.stepHeight) {
            floor = max(floor, boxTop)
        }
        if position.y <= floor + 0.001 {
            position.y = floor
            if velocity.y < 0 { velocity.y = 0 }
            grounded = true
        }

        // Head bob and footsteps.
        let horizontalSpeed = sqrtf(velocity.x * velocity.x + velocity.z * velocity.z)
        if grounded && horizontalSpeed > 0.6 {
            headBob += dt * horizontalSpeed * 1.5
            footstepTimer -= dt * horizontalSpeed
            if footstepTimer <= 0 {
                footstepTimer = 2.2
                onFootstep?()
            }
        } else {
            headBob = damp(headBob, 0, 6, dt)
        }

        shake = max(0, shake - dt * 3.2)
        damageFlash = max(0, damageFlash - dt * 1.6)
    }

    // MARK: - Damage

    public struct DamageOutcome {
        public var applied: Float = 0
        public var armourUsed: Float = 0
        public var died: Bool = false
    }

    @discardableResult
    public func takeDamage(_ amount: Float, from direction: Vec3) -> DamageOutcome {
        var outcome = DamageOutcome()
        guard isAlive, amount > 0 else { return outcome }

        var remaining = amount
        if armour > 0 {
            let absorbed = min(armour, amount * config.armourAbsorb)
            armour -= absorbed
            remaining -= absorbed
            outcome.armourUsed = absorbed
        }
        health -= remaining
        outcome.applied = amount
        timeSinceDamage = 0
        damageFlash = min(1, damageFlash + clamp(amount / 45, 0.15, 0.9))
        shake = min(1.4, shake + amount / 60)
        lastHitDirection = normalize(direction)
        if health <= 0 {
            health = 0
            outcome.died = true
        }
        return outcome
    }

    public func heal(_ amount: Float) { health = min(config.maxHealth, health + amount) }

    public func addArmour(_ amount: Float) { armour = min(config.maxArmour, armour + amount) }

    public func tickStatus(_ dt: Float) {
        timeSinceDamage += dt
        if timeSinceDamage > config.regenDelay && health < config.maxHealth {
            health = min(config.maxHealth, health + config.regenPerSecond * dt)
        }
    }
}
