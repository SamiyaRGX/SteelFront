//
//  WeaponMesher.swift
//  SteelFront
//
//  First person weapon models. Each weapon gets a distinct silhouette built
//  from primitives, drawn in view space with its own near plane so it never
//  clips into level geometry.
//

import Foundation
import Metal
import simd

enum WeaponMesher {

    /// Builds the view model for a weapon id.
    static func build(id: String, device: MTLDevice) -> Mesh? {
        let builder = MeshBuilder()
        builder.reserve(vertices: 512, indices: 1024)

        let steel = SIMD3<Float>(0.30, 0.31, 0.33)
        let darkSteel = SIMD3<Float>(0.17, 0.175, 0.185)
        let polymer = SIMD3<Float>(0.13, 0.135, 0.14)
        let wood = SIMD3<Float>(0.36, 0.26, 0.17)
        let brass = SIMD3<Float>(0.62, 0.50, 0.24)

        switch id {
        case "sidearm":
            // Compact pistol: slide, frame, grip, short barrel.
            box(builder, lo: SIMD3(-0.035, 0.0, -0.05), hi: SIMD3(0.035, 0.075, 0.20), tint: darkSteel)
            box(builder, lo: SIMD3(-0.03, -0.02, -0.04), hi: SIMD3(0.03, 0.0, 0.17), tint: steel)
            box(builder, lo: SIMD3(-0.028, -0.14, -0.05), hi: SIMD3(0.028, -0.01, 0.03), tint: polymer)
            box(builder, lo: SIMD3(-0.014, 0.015, 0.20), hi: SIMD3(0.014, 0.045, 0.26), tint: darkSteel)
            box(builder, lo: SIMD3(-0.006, 0.078, 0.15), hi: SIMD3(0.006, 0.095, 0.19), tint: steel)

        case "smg":
            // Short barrel, long magazine, folding stock.
            box(builder, lo: SIMD3(-0.045, -0.02, -0.10), hi: SIMD3(0.045, 0.06, 0.22), tint: polymer)
            box(builder, lo: SIMD3(-0.02, 0.0, 0.22), hi: SIMD3(0.02, 0.035, 0.34), tint: darkSteel)
            box(builder, lo: SIMD3(-0.025, -0.20, 0.02), hi: SIMD3(0.025, -0.02, 0.09), tint: darkSteel)
            box(builder, lo: SIMD3(-0.03, -0.13, -0.09), hi: SIMD3(0.03, -0.02, -0.03), tint: polymer)
            box(builder, lo: SIMD3(-0.02, 0.0, -0.26), hi: SIMD3(0.02, 0.045, -0.10), tint: steel)
            box(builder, lo: SIMD3(-0.05, 0.06, 0.06), hi: SIMD3(0.05, 0.09, 0.12), tint: darkSteel)

        case "shotgun":
            // Pump action: long barrel, tubular magazine, wooden furniture.
            box(builder, lo: SIMD3(-0.04, -0.03, -0.18), hi: SIMD3(0.04, 0.05, 0.20), tint: steel)
            box(builder, lo: SIMD3(-0.026, 0.015, 0.20), hi: SIMD3(0.026, 0.055, 0.62), tint: darkSteel)
            box(builder, lo: SIMD3(-0.022, -0.03, 0.20), hi: SIMD3(0.022, 0.005, 0.58), tint: darkSteel)
            box(builder, lo: SIMD3(-0.032, -0.035, 0.24), hi: SIMD3(0.032, 0.02, 0.40), tint: wood)
            box(builder, lo: SIMD3(-0.035, -0.05, -0.36), hi: SIMD3(0.035, 0.045, -0.16), tint: wood)
            box(builder, lo: SIMD3(-0.028, -0.15, -0.10), hi: SIMD3(0.028, -0.03, -0.03), tint: wood)
            box(builder, lo: SIMD3(-0.012, 0.055, 0.10), hi: SIMD3(0.012, 0.075, 0.16), tint: brass)

        case "rifle":
            // Assault rifle: handguard, carry handle style optic, curved mag.
            box(builder, lo: SIMD3(-0.04, -0.03, -0.14), hi: SIMD3(0.04, 0.06, 0.20), tint: polymer)
            box(builder, lo: SIMD3(-0.032, -0.02, 0.20), hi: SIMD3(0.032, 0.045, 0.44), tint: polymer)
            box(builder, lo: SIMD3(-0.016, 0.005, 0.44), hi: SIMD3(0.016, 0.035, 0.58), tint: darkSteel)
            box(builder, lo: SIMD3(-0.024, -0.20, 0.02), hi: SIMD3(0.024, -0.03, 0.10), tint: polymer)
            box(builder, lo: SIMD3(-0.03, -0.13, -0.10), hi: SIMD3(0.03, -0.03, -0.04), tint: polymer)
            box(builder, lo: SIMD3(-0.025, -0.02, -0.34), hi: SIMD3(0.025, 0.05, -0.14), tint: polymer)
            box(builder, lo: SIMD3(-0.02, 0.06, -0.02), hi: SIMD3(0.02, 0.11, 0.12), tint: darkSteel)
            box(builder, lo: SIMD3(-0.008, 0.11, 0.0), hi: SIMD3(0.008, 0.125, 0.10), tint: steel)
            box(builder, lo: SIMD3(-0.045, -0.02, 0.22), hi: SIMD3(0.045, 0.03, 0.40), tint: darkSteel)

        case "marksman":
            // Long barrel marksman rifle with a large scope and bipod.
            box(builder, lo: SIMD3(-0.035, -0.03, -0.16), hi: SIMD3(0.035, 0.055, 0.16), tint: polymer)
            box(builder, lo: SIMD3(-0.018, 0.005, 0.16), hi: SIMD3(0.018, 0.04, 0.72), tint: darkSteel)
            box(builder, lo: SIMD3(-0.028, 0.045, 0.60), hi: SIMD3(0.028, 0.075, 0.70), tint: darkSteel)
            box(builder, lo: SIMD3(-0.026, -0.18, 0.0), hi: SIMD3(0.026, -0.03, 0.08), tint: polymer)
            box(builder, lo: SIMD3(-0.03, -0.12, -0.10), hi: SIMD3(0.03, -0.03, -0.04), tint: polymer)
            box(builder, lo: SIMD3(-0.028, -0.03, -0.42), hi: SIMD3(0.028, 0.05, -0.16), tint: polymer)
            // Scope: tube plus bells.
            box(builder, lo: SIMD3(-0.026, 0.075, -0.06), hi: SIMD3(0.026, 0.13, 0.22), tint: darkSteel)
            box(builder, lo: SIMD3(-0.032, 0.07, 0.20), hi: SIMD3(0.032, 0.135, 0.26), tint: darkSteel)
            box(builder, lo: SIMD3(-0.03, 0.072, -0.10), hi: SIMD3(0.03, 0.133, -0.05), tint: darkSteel)
            // Bipod folded under the handguard.
            box(builder, lo: SIMD3(-0.05, -0.06, 0.30), hi: SIMD3(0.05, -0.03, 0.44), tint: steel)

        case "launcher":
            // Under-barrel style grenade launcher with a drum.
            box(builder, lo: SIMD3(-0.05, -0.05, -0.14), hi: SIMD3(0.05, 0.05, 0.16), tint: polymer)
            cylinder(builder, from: SIMD3(0, 0.0, 0.16), to: SIMD3(0, 0.0, 0.42), radius: 0.055,
                     tint: darkSteel)
            cylinder(builder, from: SIMD3(0, -0.09, 0.02), to: SIMD3(0, -0.09, 0.06), radius: 0.075,
                     tint: steel)
            box(builder, lo: SIMD3(-0.03, -0.16, -0.10), hi: SIMD3(0.03, -0.05, -0.03), tint: polymer)
            box(builder, lo: SIMD3(-0.02, 0.05, 0.02), hi: SIMD3(0.02, 0.09, 0.10), tint: darkSteel)

        case "rpg":
            // Big tube, warhead out front, grip and sight underneath.
            cylinder(builder, from: SIMD3(0, 0.0, -0.30), to: SIMD3(0, 0.0, 0.42), radius: 0.075,
                     tint: SIMD3(0.24, 0.27, 0.22))
            cylinder(builder, from: SIMD3(0, 0.0, 0.42), to: SIMD3(0, 0.0, 0.62), radius: 0.055,
                     tint: darkSteel)
            box(builder, lo: SIMD3(-0.05, 0.05, 0.50), hi: SIMD3(0.05, 0.13, 0.62), tint: SIMD3(0.45, 0.25, 0.18))
            box(builder, lo: SIMD3(-0.03, -0.18, -0.04), hi: SIMD3(0.03, -0.07, 0.03), tint: polymer)
            box(builder, lo: SIMD3(-0.03, -0.16, 0.16), hi: SIMD3(0.03, -0.07, 0.22), tint: polymer)
            box(builder, lo: SIMD3(-0.012, 0.075, 0.06), hi: SIMD3(0.012, 0.13, 0.20), tint: darkSteel)

        case "railgun":
            // Energy weapon: two rails, a capacitor block and a glowing core.
            box(builder, lo: SIMD3(-0.05, -0.05, -0.20), hi: SIMD3(0.05, 0.06, 0.14), tint: SIMD3(0.20, 0.22, 0.24))
            box(builder, lo: SIMD3(-0.055, 0.0, 0.14), hi: SIMD3(-0.02, 0.05, 0.62), tint: steel)
            box(builder, lo: SIMD3(0.02, 0.0, 0.14), hi: SIMD3(0.055, 0.05, 0.62), tint: steel)
            box(builder, lo: SIMD3(-0.018, 0.008, 0.14), hi: SIMD3(0.018, 0.042, 0.60),
                tint: SIMD3(0.35, 0.85, 1.0))
            box(builder, lo: SIMD3(-0.06, -0.10, -0.10), hi: SIMD3(0.06, 0.0, 0.06),
                tint: SIMD3(0.22, 0.24, 0.26))
            box(builder, lo: SIMD3(-0.03, -0.17, -0.14), hi: SIMD3(0.03, -0.05, -0.06), tint: polymer)
            box(builder, lo: SIMD3(-0.025, -0.02, -0.34), hi: SIMD3(0.025, 0.05, -0.20), tint: polymer)
            box(builder, lo: SIMD3(-0.03, 0.06, -0.06), hi: SIMD3(0.03, 0.11, 0.10), tint: darkSteel)

        default:
            box(builder, lo: SIMD3(-0.04, -0.03, -0.14), hi: SIMD3(0.04, 0.06, 0.30), tint: steel)
        }
        return builder.makeMesh(device: device)
    }

    // MARK: - Primitives

    private static func box(_ builder: MeshBuilder, lo: SIMD3<Float>, hi: SIMD3<Float>,
                            tint: SIMD3<Float>) {
        builder.addBox(min: lo, max: hi, uvScale: 2.2, tint: tint)
    }

    /// Cylinder along an arbitrary axis, capped at both ends.
    private static func cylinder(_ builder: MeshBuilder, from: SIMD3<Float>, to: SIMD3<Float>,
                                 radius: Float, tint: SIMD3<Float>, segments: Int = 10) {
        let axis = to - from
        let height = length(axis)
        guard height > 0.0001 else { return }
        let direction = axis / height

        // Build an orthonormal basis around the axis.
        var helper = SIMD3<Float>(0, 1, 0)
        if absf(dot(direction, helper)) > 0.9 { helper = SIMD3(1, 0, 0) }
        let u = normalize(cross(direction, helper))
        let v = cross(direction, u)

        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * .pi * 2
            let a1 = Float(i + 1) / Float(segments) * .pi * 2
            let ring0 = u * cosf(a0) + v * sinf(a0)
            let ring1 = u * cosf(a1) + v * sinf(a1)
            let normal = normalize((ring0 + ring1) * 0.5)
            let base = UInt32(builder.vertexCount)
            builder.add(vertex: Vertex(position: from + ring0 * radius, normal: normal,
                                       uv: SIMD2(a0 * radius, 0), tint: tint, ao: 0.9, limb: 0))
            builder.add(vertex: Vertex(position: from + ring1 * radius, normal: normal,
                                       uv: SIMD2(a1 * radius, 0), tint: tint, ao: 0.9, limb: 0))
            builder.add(vertex: Vertex(position: to + ring1 * radius, normal: normal,
                                       uv: SIMD2(a1 * radius, height), tint: tint, ao: 0.95, limb: 0))
            builder.add(vertex: Vertex(position: to + ring0 * radius, normal: normal,
                                       uv: SIMD2(a0 * radius, height), tint: tint, ao: 0.95, limb: 0))
            builder.addTriangle(base, base + 1, base + 2)
            builder.addTriangle(base, base + 2, base + 3)
        }

        // Caps.
        for (centre, sign) in [(from, -1.0), (to, 1.0)] as [(SIMD3<Float>, Float)] {
            let capBase = UInt32(builder.vertexCount)
            let normal = direction * sign
            builder.add(vertex: Vertex(position: centre, normal: normal, uv: SIMD2(0.5, 0.5),
                                       tint: tint * 1.05, ao: 1, limb: 0))
            for i in 0..<segments {
                let a = Float(i) / Float(segments) * .pi * 2
                let ring = u * cosf(a) + v * sinf(a)
                builder.add(vertex: Vertex(position: centre + ring * radius, normal: normal,
                                           uv: SIMD2(0.5, 0.5), tint: tint * 1.05, ao: 1, limb: 0))
            }
            for i in 0..<segments {
                let next = (i + 1) % segments
                if sign > 0 {
                    builder.addTriangle(capBase, capBase + 1 + UInt32(i), capBase + 1 + UInt32(next))
                } else {
                    builder.addTriangle(capBase, capBase + 1 + UInt32(next), capBase + 1 + UInt32(i))
                }
            }
        }
    }
}
