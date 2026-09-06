//
//  EnemyMesher.swift
//  SteelFront
//
//  Procedural enemy models. Everything is built from boxes at a canonical
//  1.8 m scale with a `limb` index per vertex; the vertex shader then animates
//  a walk cycle, an aiming pose and a death topple, so a single static mesh
//  covers every animation the game needs.
//

import Foundation
import Metal
import simd

struct EnemyModel {
    let kind: EnemyKind
    let body: Mesh
    let kit: Mesh?
    let glow: Mesh?
    let scale: Float
    let bodyTint: SIMD4<Float>
}

/// Limb slots, must match the constants used in Shaders.metal.
enum Limb: Float {
    case root = 0
    case head = 1
    case upperArmLeft = 2
    case forearmLeft = 3
    case upperArmRight = 4
    case forearmRight = 5
    case thighLeft = 6
    case shinLeft = 7
    case thighRight = 8
    case shinRight = 9
    case weapon = 10
}

enum EnemyMesher {

    static func buildAll(device: MTLDevice) -> [EnemyKind: EnemyModel] {
        var out: [EnemyKind: EnemyModel] = [:]
        for kind in EnemyKind.allCases {
            if let model = build(kind: kind, device: device) {
                out[kind] = model
            }
        }
        return out
    }

    static func build(kind: EnemyKind, device: MTLDevice) -> EnemyModel? {
        if kind == .drone { return buildDrone(device: device) }

        let body = MeshBuilder()
        let kit = MeshBuilder()
        let glow = MeshBuilder()

        let proportions = proportions(for: kind)
        let w = proportions.width
        let bulk = proportions.bulk

        // --- Torso ------------------------------------------------------------
        body.addBox(min: SIMD3(-0.18 * w, 0.88, -0.13 * bulk), max: SIMD3(0.18 * w, 1.04, 0.13 * bulk),
                    uvScale: 0.5, limb: Limb.root.rawValue)
        body.addBox(min: SIMD3(-0.22 * w, 1.04, -0.14 * bulk), max: SIMD3(0.22 * w, 1.42, 0.14 * bulk),
                    uvScale: 0.45, limb: Limb.root.rawValue)
        body.addBox(min: SIMD3(-0.27 * w, 1.36, -0.12 * bulk), max: SIMD3(0.27 * w, 1.50, 0.12 * bulk),
                    uvScale: 0.5, limb: Limb.root.rawValue)

        // --- Head -------------------------------------------------------------
        body.addBox(min: SIMD3(-0.06, 1.50, -0.06), max: SIMD3(0.06, 1.56, 0.06),
                    uvScale: 1.2, tint: SIMD3(0.72, 0.58, 0.47), limb: Limb.head.rawValue)
        body.addBox(min: SIMD3(-0.11, 1.56, -0.12), max: SIMD3(0.11, 1.78, 0.12),
                    uvScale: 0.9, tint: SIMD3(0.72, 0.58, 0.47), limb: Limb.head.rawValue)
        // Jaw / balaclava.
        body.addBox(min: SIMD3(-0.10, 1.56, -0.05), max: SIMD3(0.10, 1.66, 0.125),
                    uvScale: 0.9, tint: SIMD3(0.35, 0.34, 0.32), limb: Limb.head.rawValue)
        kit.addBox(min: SIMD3(-0.135, 1.70, -0.145), max: SIMD3(0.135, 1.83, 0.145),
                   uvScale: 0.8, limb: Limb.head.rawValue)
        kit.addBox(min: SIMD3(-0.14, 1.70, -0.15), max: SIMD3(0.14, 1.74, 0.05),
                   uvScale: 0.8, limb: Limb.head.rawValue)   // brim

        // --- Arms -------------------------------------------------------------
        for side in [-1.0, 1.0] as [Float] {
            let upper = side < 0 ? Limb.upperArmLeft : Limb.upperArmRight
            let fore = side < 0 ? Limb.forearmLeft : Limb.forearmRight
            let x0 = side * 0.25 * w
            let x1 = side * 0.34 * w
            body.addBox(min: SIMD3(min(x0, x1), 1.20, -0.07), max: SIMD3(max(x0, x1), 1.44, 0.07),
                        uvScale: 0.7, limb: upper.rawValue)
            body.addBox(min: SIMD3(min(x0, x1) + side * 0.01, 0.96, -0.065),
                        max: SIMD3(max(x0, x1) - side * 0.01, 1.20, 0.065),
                        uvScale: 0.7, limb: fore.rawValue)
            // Gloves.
            kit.addBox(min: SIMD3(min(x0, x1) + side * 0.015, 0.87, -0.06),
                       max: SIMD3(max(x0, x1) - side * 0.015, 0.97, 0.06),
                       uvScale: 1.0, limb: fore.rawValue)
            // Shoulder armour.
            kit.addBox(min: SIMD3(min(x0, x1) - side * 0.02, 1.36, -0.10),
                       max: SIMD3(max(x0, x1) + side * 0.02, 1.48, 0.10),
                       uvScale: 0.9, limb: upper.rawValue)
        }

        // --- Legs -------------------------------------------------------------
        for side in [-1.0, 1.0] as [Float] {
            let thigh = side < 0 ? Limb.thighLeft : Limb.thighRight
            let shin = side < 0 ? Limb.shinLeft : Limb.shinRight
            let x0 = side * 0.10
            let x1 = side * 0.21
            body.addBox(min: SIMD3(min(x0, x1), 0.50, -0.11), max: SIMD3(max(x0, x1), 0.92, 0.11),
                        uvScale: 0.5, limb: thigh.rawValue)
            body.addBox(min: SIMD3(min(x0, x1) + side * 0.01, 0.10, -0.10),
                        max: SIMD3(max(x0, x1) - side * 0.01, 0.50, 0.10),
                        uvScale: 0.5, limb: shin.rawValue)
            // Boots.
            kit.addBox(min: SIMD3(min(x0, x1) - side * 0.02, 0.0, -0.13),
                       max: SIMD3(max(x0, x1) + side * 0.02, 0.16, 0.21),
                       uvScale: 0.9, limb: shin.rawValue)
            // Knee pad.
            kit.addBox(min: SIMD3(min(x0, x1), 0.44, 0.06), max: SIMD3(max(x0, x1), 0.56, 0.14),
                       uvScale: 1.0, limb: shin.rawValue)
        }

        // --- Load bearing kit ---------------------------------------------------
        kit.addBox(min: SIMD3(-0.24 * w, 1.10, -0.17 * bulk), max: SIMD3(0.24 * w, 1.40, 0.17 * bulk),
                   uvScale: 0.5, limb: Limb.root.rawValue)
        // Magazine pouches.
        for i in 0..<3 {
            let px = -0.16 + Float(i) * 0.16
            kit.addBox(min: SIMD3(px - 0.05, 1.12, 0.15), max: SIMD3(px + 0.05, 1.26, 0.21),
                       uvScale: 1.0, limb: Limb.root.rawValue)
        }
        // Backpack.
        kit.addBox(min: SIMD3(-0.16, 1.12, -0.26), max: SIMD3(0.16, 1.38, -0.16),
                   uvScale: 0.7, limb: Limb.root.rawValue)

        // --- Weapon ---------------------------------------------------------------
        addRifle(to: kit, scale: kind == .brute ? 1.5 : 1.0)

        // --- Optics / lights (emissive) ---------------------------------------------
        let glowTint = glowColour(for: kind)
        glow.addBox(min: SIMD3(-0.075, 1.66, 0.115), max: SIMD3(0.075, 1.70, 0.135),
                    uvScale: 2.0, tint: glowTint, limb: Limb.head.rawValue)

        guard let bodyMesh = body.makeMesh(device: device) else { return nil }
        return EnemyModel(kind: kind,
                          body: bodyMesh,
                          kit: kit.makeMesh(device: device),
                          glow: glow.makeMesh(device: device),
                          scale: scale(for: kind),
                          bodyTint: bodyTint(for: kind))
    }

    // MARK: - Drone

    private static func buildDrone(device: MTLDevice) -> EnemyModel? {
        let body = MeshBuilder()
        let glow = MeshBuilder()

        body.addBox(min: SIMD3(-0.24, -0.09, -0.24), max: SIMD3(0.24, 0.09, 0.24),
                    uvScale: 1.2, tint: SIMD3(0.5, 0.52, 0.5))
        body.addBox(min: SIMD3(-0.10, -0.16, -0.10), max: SIMD3(0.10, -0.06, 0.10),
                    uvScale: 1.5, tint: SIMD3(0.3, 0.31, 0.3))
        // Arms and rotors.
        for sx in [-1.0, 1.0] as [Float] {
            for sz in [-1.0, 1.0] as [Float] {
                body.addBox(min: SIMD3(min(0, sx * 0.42), -0.02, min(0, sz * 0.42)),
                            max: SIMD3(max(0, sx * 0.42), 0.02, max(0, sz * 0.42)),
                            uvScale: 1.5, tint: SIMD3(0.35, 0.36, 0.35))
                body.addBox(min: SIMD3(sx * 0.42 - 0.16, 0.04, sz * 0.42 - 0.16),
                            max: SIMD3(sx * 0.42 + 0.16, 0.07, sz * 0.42 + 0.16),
                            uvScale: 1.0, tint: SIMD3(0.22, 0.22, 0.23))
                glow.addBox(min: SIMD3(sx * 0.42 - 0.04, -0.02, sz * 0.42 - 0.04),
                            max: SIMD3(sx * 0.42 + 0.04, 0.0, sz * 0.42 + 0.04),
                            uvScale: 2.0, tint: SIMD3(1.0, 0.25, 0.15))
            }
        }
        // Sensor eye.
        glow.addBox(min: SIMD3(-0.05, -0.12, 0.08), max: SIMD3(0.05, -0.04, 0.12),
                    uvScale: 2.0, tint: SIMD3(1.0, 0.3, 0.2))

        guard let bodyMesh = body.makeMesh(device: device) else { return nil }
        return EnemyModel(kind: .drone, body: bodyMesh, kit: nil,
                          glow: glow.makeMesh(device: device), scale: 1.0,
                          bodyTint: SIMD4(1, 1, 1, 1))
    }

    // MARK: - Weapon held by enemies

    private static func addRifle(to builder: MeshBuilder, scale: Float) {
        let s = scale
        let origin = SIMD3<Float>(0.10, 1.24, 0.10)
        // Receiver.
        builder.addBox(min: origin + SIMD3(-0.05, -0.05, 0) * s,
                       max: origin + SIMD3(0.05, 0.05, 0.34) * s,
                       uvScale: 1.4, tint: SIMD3(0.32, 0.33, 0.34), limb: Limb.weapon.rawValue)
        // Barrel.
        builder.addBox(min: origin + SIMD3(-0.022, 0.0, 0.34) * s,
                       max: origin + SIMD3(0.022, 0.045, 0.62) * s,
                       uvScale: 1.6, tint: SIMD3(0.22, 0.22, 0.23), limb: Limb.weapon.rawValue)
        // Magazine.
        builder.addBox(min: origin + SIMD3(-0.035, -0.22, 0.10) * s,
                       max: origin + SIMD3(0.035, 0.0, 0.19) * s,
                       uvScale: 1.4, tint: SIMD3(0.26, 0.26, 0.27), limb: Limb.weapon.rawValue)
        // Stock.
        builder.addBox(min: origin + SIMD3(-0.04, -0.06, -0.22) * s,
                       max: origin + SIMD3(0.04, 0.04, 0.0) * s,
                       uvScale: 1.4, tint: SIMD3(0.28, 0.27, 0.25), limb: Limb.weapon.rawValue)
        // Sight.
        builder.addBox(min: origin + SIMD3(-0.025, 0.05, 0.14) * s,
                       max: origin + SIMD3(0.025, 0.11, 0.24) * s,
                       uvScale: 1.6, tint: SIMD3(0.18, 0.18, 0.19), limb: Limb.weapon.rawValue)
    }

    // MARK: - Per kind variation

    private struct Proportions { let width: Float; let bulk: Float }

    private static func proportions(for kind: EnemyKind) -> Proportions {
        switch kind {
        case .grunt: return Proportions(width: 1.0, bulk: 1.0)
        case .rusher: return Proportions(width: 0.88, bulk: 0.85)
        case .heavy: return Proportions(width: 1.25, bulk: 1.3)
        case .sniper: return Proportions(width: 0.92, bulk: 0.9)
        case .brute: return Proportions(width: 1.45, bulk: 1.5)
        case .drone: return Proportions(width: 1.0, bulk: 1.0)
        }
    }

    private static func scale(for kind: EnemyKind) -> Float {
        switch kind {
        case .grunt: return 1.0
        case .rusher: return 0.96
        case .heavy: return 1.12
        case .sniper: return 1.02
        case .brute: return 1.42
        case .drone: return 1.0
        }
    }

    private static func bodyTint(for kind: EnemyKind) -> SIMD4<Float> {
        switch kind {
        case .grunt: return SIMD4(0.78, 0.80, 0.68, 1)     // olive fatigues
        case .rusher: return SIMD4(0.52, 0.34, 0.30, 1)    // dusty red
        case .heavy: return SIMD4(0.46, 0.48, 0.42, 1)     // dark olive
        case .sniper: return SIMD4(0.84, 0.78, 0.62, 1)    // desert tan
        case .brute: return SIMD4(0.34, 0.32, 0.30, 1)     // charred grey
        case .drone: return SIMD4(1, 1, 1, 1)
        }
    }

    private static func glowColour(for kind: EnemyKind) -> SIMD3<Float> {
        switch kind {
        case .grunt: return SIMD3(1.0, 0.35, 0.18)
        case .rusher: return SIMD3(1.0, 0.15, 0.10)
        case .heavy: return SIMD3(1.0, 0.65, 0.15)
        case .sniper: return SIMD3(0.35, 1.0, 0.55)
        case .brute: return SIMD3(1.0, 0.20, 0.10)
        case .drone: return SIMD3(1.0, 0.30, 0.20)
        }
    }
}
