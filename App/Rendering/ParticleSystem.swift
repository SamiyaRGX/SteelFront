//
//  ParticleSystem.swift
//  SteelFront
//
//  CPU simulated effects: sparks, dust, smoke, fire, shell casings, tracers,
//  blood and shockwave rings. Quads are rebuilt every frame into two dynamic
//  buffers (additive and alpha blended) so the whole effect layer costs two
//  draw calls.
//

import Foundation
import Metal
import simd

struct Particle {
    enum Kind {
        case spark, smoke, fire, dust, shell, blood, tracer, shockwave
    }

    var kind: Kind
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var life: Float
    var maxLife: Float
    var size: Float
    var endSize: Float
    var colour: SIMD4<Float>
    var endColour: SIMD4<Float>
    var gravity: Float
    var drag: Float
    var rotation: Float
    var spin: Float
    /// Tracers stretch along this vector instead of billboarding.
    var stretch: SIMD3<Float> = .zero
    var bounces: Int = 0
}

final class ParticleSystem {

    static let maxParticles = 1400

    private(set) var particles: [Particle] = []
    private var rng = GameRandom(seed: 0xF0_1234)

    var count: Int { particles.count }

    // MARK: - Emitters

    func impact(at position: SIMD3<Float>, normal: SIMD3<Float>, power: Float = 1) {
        let sparks = 5 + Int(power * 7)
        for _ in 0..<min(sparks, 16) {
            let spread = randomDirection(around: normal, spread: 0.85)
            add(Particle(kind: .spark, position: position + normal * 0.04,
                         velocity: spread * rng.range(5, 15) * power,
                         life: rng.range(0.12, 0.32), maxLife: 0.32,
                         size: rng.range(0.05, 0.11), endSize: 0.01,
                         colour: SIMD4(1.0, 0.82, 0.45, 1),
                         endColour: SIMD4(1.0, 0.35, 0.1, 0),
                         gravity: 16, drag: 1.6, rotation: 0, spin: 0, bounces: 0))
        }
        for _ in 0..<3 {
            add(Particle(kind: .dust, position: position + normal * 0.05,
                         velocity: randomDirection(around: normal, spread: 0.7) * rng.range(0.6, 2.0),
                         life: rng.range(0.5, 1.0), maxLife: 1.0,
                         size: rng.range(0.16, 0.30), endSize: rng.range(0.7, 1.2),
                         colour: SIMD4(0.62, 0.57, 0.47, 0.42),
                         endColour: SIMD4(0.62, 0.57, 0.47, 0),
                         gravity: -0.6, drag: 2.2, rotation: rng.range(0, .pi * 2),
                         spin: rng.range(-2, 2), bounces: 0))
        }
    }

    func muzzleFlash(at position: SIMD3<Float>, direction: SIMD3<Float>, scale: Float = 1) {
        add(Particle(kind: .fire, position: position,
                     velocity: direction * 2.2,
                     life: 0.06, maxLife: 0.06,
                     size: 0.34 * scale, endSize: 0.12 * scale,
                     colour: SIMD4(1.0, 0.92, 0.7, 1), endColour: SIMD4(1.0, 0.5, 0.15, 0),
                     gravity: 0, drag: 4, rotation: rng.range(0, .pi), spin: 0, bounces: 0))
        for _ in 0..<3 {
            add(Particle(kind: .smoke, position: position + direction * 0.1,
                         velocity: direction * rng.range(1.5, 3.5) + randomDirection(spread: 1) * 0.5,
                         life: rng.range(0.35, 0.7), maxLife: 0.7,
                         size: 0.12, endSize: 0.55,
                         colour: SIMD4(0.55, 0.53, 0.5, 0.30),
                         endColour: SIMD4(0.45, 0.44, 0.42, 0),
                         gravity: -1.2, drag: 2.6, rotation: rng.range(0, .pi * 2),
                         spin: rng.range(-1.5, 1.5), bounces: 0))
        }
    }

    func tracer(from origin: SIMD3<Float>, to target: SIMD3<Float>, colour: SIMD4<Float>) {
        let delta = target - origin
        let distance = length(delta)
        guard distance > 0.2 else { return }
        let direction = delta / distance
        // Keep tracers short so they read as streaks, not laser beams.
        let streakLength = min(distance, 7.0)
        let start = distance > streakLength ? target - direction * streakLength : origin
        add(Particle(kind: .tracer, position: (start + target) * 0.5,
                     velocity: .zero, life: 0.055, maxLife: 0.055,
                     size: 0.045, endSize: 0.02,
                     colour: colour, endColour: SIMD4(colour.x, colour.y, colour.z, 0),
                     gravity: 0, drag: 0, rotation: 0, spin: 0,
                     stretch: direction * streakLength, bounces: 0))
    }

    func explosion(at position: SIMD3<Float>, radius: Float) {
        add(Particle(kind: .shockwave, position: position, velocity: .zero,
                     life: 0.42, maxLife: 0.42, size: radius * 0.3, endSize: radius * 2.4,
                     colour: SIMD4(1.0, 0.85, 0.6, 0.85), endColour: SIMD4(1.0, 0.5, 0.2, 0),
                     gravity: 0, drag: 0, rotation: 0, spin: 0, bounces: 0))
        for _ in 0..<14 {
            let direction = randomDirection(spread: 1)
            add(Particle(kind: .fire, position: position + direction * 0.2,
                         velocity: direction * rng.range(3, 11),
                         life: rng.range(0.22, 0.55), maxLife: 0.55,
                         size: rng.range(0.5, 1.3), endSize: rng.range(0.2, 0.5),
                         colour: SIMD4(1.0, 0.75, 0.30, 1),
                         endColour: SIMD4(0.85, 0.22, 0.05, 0),
                         gravity: 3, drag: 3.2, rotation: rng.range(0, .pi * 2),
                         spin: rng.range(-3, 3), bounces: 0))
        }
        for _ in 0..<12 {
            let direction = randomDirection(spread: 1)
            add(Particle(kind: .smoke, position: position + direction * 0.4,
                         velocity: direction * rng.range(1.5, 5) + SIMD3(0, 2.2, 0),
                         life: rng.range(1.2, 2.4), maxLife: 2.4,
                         size: rng.range(0.9, 1.8), endSize: rng.range(3.2, 5.5),
                         colour: SIMD4(0.24, 0.22, 0.20, 0.55),
                         endColour: SIMD4(0.32, 0.30, 0.28, 0),
                         gravity: -1.1, drag: 1.4, rotation: rng.range(0, .pi * 2),
                         spin: rng.range(-1.2, 1.2), bounces: 0))
        }
        for _ in 0..<10 {
            let direction = randomDirection(spread: 1)
            add(Particle(kind: .spark, position: position,
                         velocity: direction * rng.range(9, 24),
                         life: rng.range(0.4, 0.9), maxLife: 0.9,
                         size: rng.range(0.06, 0.14), endSize: 0.02,
                         colour: SIMD4(1.0, 0.7, 0.3, 1), endColour: SIMD4(1.0, 0.2, 0.05, 0),
                         gravity: 18, drag: 0.7, rotation: 0, spin: 0, bounces: 1))
        }
    }

    func blood(at position: SIMD3<Float>, direction: SIMD3<Float>) {
        for _ in 0..<7 {
            add(Particle(kind: .blood, position: position,
                         velocity: randomDirection(around: direction, spread: 0.8) * rng.range(1.5, 5),
                         life: rng.range(0.3, 0.7), maxLife: 0.7,
                         size: rng.range(0.05, 0.13), endSize: 0.02,
                         colour: SIMD4(0.55, 0.04, 0.04, 0.9),
                         endColour: SIMD4(0.30, 0.02, 0.02, 0),
                         gravity: 12, drag: 1.0, rotation: 0, spin: 0, bounces: 0))
        }
    }

    func shellCasing(at position: SIMD3<Float>, right: SIMD3<Float>) {
        add(Particle(kind: .shell, position: position,
                     velocity: right * rng.range(1.6, 2.8) + SIMD3(0, rng.range(1.6, 2.4), 0),
                     life: 1.6, maxLife: 1.6, size: 0.05, endSize: 0.05,
                     colour: SIMD4(0.78, 0.62, 0.28, 1), endColour: SIMD4(0.78, 0.62, 0.28, 0),
                     gravity: 14, drag: 0.2, rotation: rng.range(0, .pi),
                     spin: rng.range(-12, 12), bounces: 2))
    }

    func landingDust(at position: SIMD3<Float>, strength: Float) {
        for _ in 0..<Int(4 + strength * 6) {
            let direction = randomDirection(spread: 1)
            add(Particle(kind: .dust, position: position + SIMD3(0, 0.05, 0),
                         velocity: SIMD3(direction.x, 0.4, direction.z) * rng.range(0.8, 2.4),
                         life: rng.range(0.4, 0.9), maxLife: 0.9,
                         size: 0.2, endSize: 0.8,
                         colour: SIMD4(0.60, 0.55, 0.45, 0.35),
                         endColour: SIMD4(0.60, 0.55, 0.45, 0),
                         gravity: -0.4, drag: 2.4, rotation: rng.range(0, .pi * 2),
                         spin: rng.range(-2, 2), bounces: 0))
        }
    }

    // MARK: - Simulation

    func update(dt: Float) {
        guard !particles.isEmpty else { return }
        var survivors: [Particle] = []
        survivors.reserveCapacity(particles.count)
        for var p in particles {
            p.life -= dt
            if p.life <= 0 { continue }
            p.velocity.y -= p.gravity * dt
            let damping = max(0, 1 - p.drag * dt)
            p.velocity *= damping
            p.position += p.velocity * dt
            p.rotation += p.spin * dt

            // Simple ground bounce for shells and heavy sparks.
            if p.bounces > 0 {
                let ground = Terrain.height(at: p.position.x, p.position.z) + 0.03
                if p.position.y < ground {
                    p.position.y = ground
                    p.velocity.y = absf(p.velocity.y) * 0.4
                    p.velocity.x *= 0.6
                    p.velocity.z *= 0.6
                    p.bounces -= 1
                }
            }
            survivors.append(p)
        }
        particles = survivors
    }

    func clear() { particles.removeAll() }

    private func add(_ particle: Particle) {
        if particles.count >= ParticleSystem.maxParticles {
            particles.removeFirst(particles.count / 4)
        }
        particles.append(particle)
    }

    private func randomDirection(spread: Float) -> SIMD3<Float> {
        let a = rng.range(0, .pi * 2)
        let b = rng.range(-spread, spread)
        return SIMD3(cosf(a) * cosf(b), sinf(b), sinf(a) * cosf(b))
    }

    private func randomDirection(around axis: SIMD3<Float>, spread: Float) -> SIMD3<Float> {
        let base = length(axis) > 0.01 ? axis : SIMD3(0, 1, 0)
        var helper = SIMD3<Float>(0, 1, 0)
        if absf(dot(base, helper)) > 0.9 { helper = SIMD3(1, 0, 0) }
        let u = normalize(cross(base, helper))
        let v = cross(base, u)
        let angle = rng.range(0, .pi * 2)
        let tilt = rng.range(0, spread)
        return normalize(base + (u * cosf(angle) + v * sinf(angle)) * tilt)
    }

    // MARK: - Geometry

    struct Batch {
        var additive: MTLBuffer?
        var additiveCount: Int = 0
        var alpha: MTLBuffer?
        var alphaCount: Int = 0
    }

    /// Builds camera facing quads for every live particle.
    func makeBatch(device: MTLDevice, right: SIMD3<Float>, up: SIMD3<Float>,
                   eye: SIMD3<Float>) -> Batch {
        var additive: [FXVertex] = []
        var alpha: [FXVertex] = []
        additive.reserveCapacity(particles.count * 4)
        alpha.reserveCapacity(particles.count * 4)

        for p in particles {
            let t = 1 - clamp(p.life / max(p.maxLife, 0.0001), 0, 1)
            let size = lerp(p.size, p.endSize, t)
            let colour = SIMD4(lerp(p.colour.x, p.endColour.x, t),
                               lerp(p.colour.y, p.endColour.y, t),
                               lerp(p.colour.z, p.endColour.z, t),
                               lerp(p.colour.w, p.endColour.w, t))
            guard colour.w > 0.004, size > 0.001 else { continue }

            // Billboard basis. Tracers stretch along their flight direction
            // instead of facing the camera.
            let axisU: SIMD3<Float>
            let axisV: SIMD3<Float>
            if p.kind == .tracer, length(p.stretch) > 0.01 {
                let direction = normalize(p.stretch)
                let side = normalize(cross(direction, normalize(eye - p.position)))
                axisU = direction * (length(p.stretch) * 0.5)
                axisV = side * size
            } else {
                let c = cosf(p.rotation)
                let sn = sinf(p.rotation)
                axisU = (right * c + up * sn) * size
                axisV = (-right * sn + up * c) * size
            }

            // Sprite sheet: blob occupies v in [0, 0.5], ring in [0.5, 1].
            let vBase: Float = p.kind == .shockwave ? 0.5 : 0.0
            let corners: [(SIMD3<Float>, SIMD2<Float>)] = [
                (p.position - axisU - axisV, SIMD2(0, vBase)),
                (p.position + axisU - axisV, SIMD2(1, vBase)),
                (p.position + axisU + axisV, SIMD2(1, vBase + 0.5)),
                (p.position - axisU + axisV, SIMD2(0, vBase + 0.5)),
            ]

            let isAdditive = (p.kind == .spark || p.kind == .fire || p.kind == .tracer
                              || p.kind == .shockwave)
            for corner in corners {
                let vertex = FXVertex(position: corner.0, uv: corner.1, colour: colour)
                if isAdditive { additive.append(vertex) } else { alpha.append(vertex) }
            }
        }

        var batch = Batch()
        if !additive.isEmpty,
           let buffer = device.makeBuffer(bytes: additive,
                                          length: additive.count * VertexLayout.fxStride,
                                          options: .storageModeShared) {
            batch.additive = buffer
            batch.additiveCount = additive.count
        }
        if !alpha.isEmpty,
           let buffer = device.makeBuffer(bytes: alpha,
                                          length: alpha.count * VertexLayout.fxStride,
                                          options: .storageModeShared) {
            batch.alpha = buffer
            batch.alphaCount = alpha.count
        }
        return batch
    }
}
