//
//  MapGenerator.swift
//  SteelFront
//
//  The endless battlefield. The world is an infinite grid of 24 m cells; each
//  cell deterministically yields a set of structures from its coordinates, so
//  chunks can be streamed in and out forever without ever storing the map.
//

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

public enum Surface: UInt8 {
    case ground
    case rock
    case concrete
    case metal
    case crate
    case sandbag
    case glass
    case flesh
}

/// Ground height field. Gentle rolling desert/urban terrain, flat enough to
/// fight on, varied enough to break up sightlines.
public enum Terrain {
    public static let amplitude: Float = 1.1

    public static func height(at x: Float, _ z: Float) -> Float {
        let base = Noise.fbm(x, z, octaves: 4, baseScale: 0.012) - 0.5
        let detail = Noise.value(x, z, scale: 0.11) - 0.5
        // Keep the immediate spawn bowl flat so the run starts clean.
        let distFromOrigin = sqrtf(x * x + z * z)
        let flatten = clamp(1 - (distFromOrigin - 12) / 26, 0, 1)
        return (base * amplitude + detail * 0.22) * (1 - flatten)
    }

    /// Surface normal from the height field (for lighting and decal placement).
    public static func normal(at x: Float, _ z: Float) -> Vec3 {
        let e: Float = 0.6
        let hL = height(at: x - e, z)
        let hR = height(at: x + e, z)
        let hD = height(at: x, z - e)
        let hU = height(at: x, z + e)
        return normalize(Vec3(hL - hR, 2 * e, hD - hU))
    }
}

public struct Structure: Equatable {
    public enum Kind: String { case building, container, pillars, lowWall, ruins, tower, crates }
    public var kind: Kind
    public var boxes: [Box]
    public var surface: Surface
    public var center: Vec3
    public var radius: Float

    public init(kind: Kind, boxes: [Box], surface: Surface, center: Vec3, radius: Float) {
        self.kind = kind; self.boxes = boxes; self.surface = surface
        self.center = center; self.radius = radius
    }
}

public final class MapGenerator {
    public let cellSize: Float
    public let worldSeed: UInt64

    /// Cells within this distance of the origin are kept clear for the spawn.
    public let spawnClearance: Float = 14

    public init(cellSize: Float = 24, worldSeed: UInt64 = 0x51EED) {
        self.cellSize = cellSize
        self.worldSeed = worldSeed
    }

    public func cellIndex(for position: Vec3) -> (Int, Int) {
        (Int(floorf(position.x / cellSize)), Int(floorf(position.z / cellSize)))
    }

    /// Deterministic structure list for a cell. Always returns something for
    /// cells inside the loaded radius (possibly an empty list).
    public func structures(cellX: Int, cellZ: Int) -> [Structure] {
        var rng = Hash.rng(cellX, cellZ, worldSeed ^ 0xBEEF_C0DE)
        let originX = (Float(cellX) + 0.5) * cellSize
        let originZ = (Float(cellZ) + 0.5) * cellSize

        // A handful of completely open cells keeps the map from feeling like
        // a solid maze and gives the player breathing room.
        let density = Noise.fbm(Float(cellX), Float(cellZ), octaves: 2, baseScale: 0.18)
        if density < 0.24 { return [] }

        let count = 1 + Int(density * 3.4) + rng.int(0, 1)
        var out: [Structure] = []
        out.reserveCapacity(count)

        var placed: [(Vec3, Float)] = []
        for _ in 0..<count {
            // Try a few positions that respect the cell bounds and spacing.
            var attempts = 0
            while attempts < 8 {
                attempts += 1
                let half = cellSize * 0.5
                let inset = half * 0.32
                let px = originX + rng.range(-inset, inset)
                let pz = originZ + rng.range(-inset, inset)

                if sqrtf(px * px + pz * pz) < spawnClearance { break }

                let kindRoll = rng.nextFloat()
                let kind: Structure.Kind
                switch kindRoll {
                case ..<0.26: kind = .building
                case ..<0.44: kind = .container
                case ..<0.58: kind = .pillars
                case ..<0.72: kind = .lowWall
                case ..<0.84: kind = .ruins
                case ..<0.93: kind = .crates
                default: kind = .tower
                }

                let w = rng.range(4.5, min(11, cellSize * 0.42))
                let d = rng.range(4.5, min(11, cellSize * 0.42))
                let h: Float = kind == .lowWall ? rng.range(1.0, 1.5) : rng.range(3.0, 6.5)
                let radius = max(w, d) * 0.6

                var overlap = false
                for (other, otherR) in placed where distance2D(Vec3(px, 0, pz), other) < radius + otherR + 2.5 {
                    overlap = true
                    break
                }
                if overlap { continue }

                let groundY = Terrain.height(at: px, pz)
                let center = Vec3(px, groundY, pz)
                let yaw = rng.range(0, .pi * 2)
                let structure = MapGenerator.build(kind: kind, center: center, width: w,
                                                   depth: d, height: h, yaw: yaw, rng: &rng)
                out.append(structure)
                placed.append((Vec3(px, 0, pz), radius))
                break
            }
        }
        return out
    }

    // MARK: - Structure builders

    private static func build(kind: Structure.Kind, center: Vec3, width w: Float, depth d: Float,
                              height h: Float, yaw: Float, rng: inout GameRandom) -> Structure {
        switch kind {
        case .building:
            return enclosedBuilding(center: center, w: w, d: d, h: h, yaw: yaw, rng: &rng)
        case .container:
            let boxes = [Box(min: Vec3(center.x - w * 0.5, center.y - 0.4, center.z - d * 0.5),
                             max: Vec3(center.x + w * 0.5, center.y + h - 0.4, center.z + d * 0.5))]
            return Structure(kind: .container, boxes: boxes, surface: .metal, center: center,
                             radius: max(w, d) * 0.6)
        case .pillars:
            var boxes: [Box] = []
            let count = rng.int(2, 4)
            let spread = min(w, d) * 0.5
            for i in 0..<count {
                let angle = Float(i) / Float(count) * .pi * 2 + yaw
                let px = center.x + cosf(angle) * spread
                let pz = center.z + sinf(angle) * spread
                let base = Terrain.height(at: px, pz)
                boxes.append(Box(min: Vec3(px - 0.55, base - 0.6, pz - 0.55),
                                 max: Vec3(px + 0.55, base + h, pz + 0.55)))
            }
            return Structure(kind: .pillars, boxes: boxes, surface: .concrete, center: center,
                             radius: spread + 1)
        case .lowWall:
            // Built from short axis aligned segments so an angled wall still
            // collides exactly where it is drawn.
            let segments = max(2, Int(w / 1.7))
            let segLen = w / Float(segments)
            let dirX = cosf(yaw), dirZ = sinf(yaw)
            var boxes: [Box] = []
            for i in 0..<segments {
                let t = (Float(i) + 0.5) / Float(segments) - 0.5
                let px = center.x + dirX * t * w
                let pz = center.z + dirZ * t * w
                let base = Terrain.height(at: px, pz)
                let halfAlong = segLen * 0.5 + 0.06
                let halfAcross: Float = 0.45
                let ex = absf(dirX) * halfAlong + absf(dirZ) * halfAcross
                let ez = absf(dirZ) * halfAlong + absf(dirX) * halfAcross
                boxes.append(Box(min: Vec3(px - ex, base - 0.4, pz - ez),
                                 max: Vec3(px + ex, base + h, pz + ez)))
            }
            return Structure(kind: .lowWall, boxes: boxes, surface: .sandbag, center: center,
                             radius: w * 0.55)
        case .ruins:
            var boxes: [Box] = []
            // Two or three broken wall fragments at odd angles.
            for _ in 0..<rng.int(2, 3) {
                let off = rng.range(-w * 0.3, w * 0.3)
                let fragYaw = yaw + rng.range(-0.9, 0.9)
                let fh = h * rng.range(0.4, 0.9)
                let px = center.x + cosf(fragYaw + .pi / 2) * off
                let pz = center.z + sinf(fragYaw + .pi / 2) * off
                let base = Terrain.height(at: px, pz)
                let fl = w * rng.range(0.25, 0.5)
                let dx = cosf(fragYaw), dz = sinf(fragYaw)
                let ex = absf(dx) * fl * 0.5 + absf(dz) * 0.4
                let ez = absf(dz) * fl * 0.5 + absf(dx) * 0.4
                boxes.append(Box(min: Vec3(px - ex, base - 0.4, pz - ez),
                                 max: Vec3(px + ex, base + fh, pz + ez)))
            }
            return Structure(kind: .ruins, boxes: boxes, surface: .concrete, center: center,
                             radius: w * 0.6)
        case .crates:
            var boxes: [Box] = []
            for _ in 0..<rng.int(2, 4) {
                let px = center.x + rng.range(-w * 0.4, w * 0.4)
                let pz = center.z + rng.range(-d * 0.4, d * 0.4)
                let size = rng.range(0.9, 1.5)
                let base = Terrain.height(at: px, pz)
                boxes.append(Box(min: Vec3(px - size * 0.5, base - 0.2, pz - size * 0.5),
                                 max: Vec3(px + size * 0.5, base + size - 0.2, pz + size * 0.5)))
            }
            return Structure(kind: .crates, boxes: boxes, surface: .crate, center: center,
                             radius: max(w, d) * 0.5)
        case .tower:
            var boxes: [Box] = []
            let legSpread = min(w, d) * 0.45
            let deckY = center.y + h
            for sx in [-1.0, 1.0] as [Float] {
                for sz in [-1.0, 1.0] as [Float] {
                    let px = center.x + cosf(yaw) * legSpread * sx - sinf(yaw) * legSpread * sz
                    let pz = center.z + sinf(yaw) * legSpread * sx + cosf(yaw) * legSpread * sz
                    let base = Terrain.height(at: px, pz)
                    boxes.append(Box(min: Vec3(px - 0.35, base - 0.6, pz - 0.35),
                                     max: Vec3(px + 0.35, deckY, pz + 0.35)))
                }
            }
            // Deck with a gap the player jumps up to from a crate.
            boxes.append(Box(min: Vec3(center.x - legSpread, deckY, center.z - legSpread),
                             max: Vec3(center.x + legSpread, deckY + 0.35, center.z + legSpread)))
            return Structure(kind: .tower, boxes: boxes, surface: .metal, center: center,
                             radius: legSpread + 1.2)
        }
    }

    /// Building with four walls and a doorway on a random side. Buildings are
    /// aligned to the world grid (as in a real street plan) which keeps the
    /// collision AABB identical to what gets drawn.
    private static func enclosedBuilding(center: Vec3, w: Float, d: Float, h: Float,
                                         yaw: Float, rng: inout GameRandom) -> Structure {
        let thickness: Float = 0.5
        let doorWidth: Float = 2.2
        let doorSide = rng.int(0, 3)
        var boxes: [Box] = []

        // North / south walls run along X, east / west along Z.
        for side in 0..<4 {
            let alongX = side < 2
            let sign: Float = side == 0 || side == 2 ? -1 : 1
            let length = alongX ? w : d
            let halfLen = length * 0.5
            let offset = (alongX ? d : w) * 0.5 * sign

            if side == doorSide {
                let gap = doorWidth * 0.5
                let segment = (halfLen - gap)
                if segment > 0.4 {
                    for s in [-1.0, 1.0] as [Float] {
                        let cx = alongX ? center.x + s * (gap + segment * 0.5) : center.x + offset
                        let cz = alongX ? center.z + offset : center.z + s * (gap + segment * 0.5)
                        let half = alongX ? Vec3(segment * 0.5, h * 0.5, thickness * 0.5)
                                          : Vec3(thickness * 0.5, h * 0.5, segment * 0.5)
                        let base = Terrain.height(at: cx, cz)
                        boxes.append(Box(min: Vec3(cx, base + h * 0.5 - 0.4, cz) - half,
                                         max: Vec3(cx, base + h * 0.5 - 0.4, cz) + half))
                    }
                }
                // Lintel above the door.
                let lintelH: Float = 0.9
                let cx = alongX ? center.x : center.x + offset
                let cz = alongX ? center.z + offset : center.z
                let half = alongX ? Vec3(doorWidth * 0.5, lintelH * 0.5, thickness * 0.5)
                                  : Vec3(thickness * 0.5, lintelH * 0.5, doorWidth * 0.5)
                let base = Terrain.height(at: cx, cz)
                boxes.append(Box(min: Vec3(cx, base + h - lintelH * 0.5 - 0.4, cz) - half,
                                 max: Vec3(cx, base + h - lintelH * 0.5 - 0.4, cz) + half))
            } else {
                let cx = alongX ? center.x : center.x + offset
                let cz = alongX ? center.z + offset : center.z
                let half = alongX ? Vec3(halfLen, h * 0.5, thickness * 0.5)
                                  : Vec3(thickness * 0.5, h * 0.5, halfLen)
                let base = Terrain.height(at: cx, cz)
                boxes.append(Box(min: Vec3(cx, base + h * 0.5 - 0.4, cz) - half,
                                 max: Vec3(cx, base + h * 0.5 - 0.4, cz) + half))
            }
        }
        return Structure(kind: .building, boxes: boxes, surface: .concrete, center: center,
                         radius: max(w, d) * 0.7)
    }

    /// Axis aligned bounding box of a rotated box (cheap and conservative).
    public static func orientedBox(center: Vec3, half: Vec3, yaw: Float) -> Box {
        if absf(yaw) < 0.001 {
            return Box(min: center - half, max: center + half)
        }
        let c = absf(cosf(yaw)), s = absf(sinf(yaw))
        let ex = half.x * c + half.z * s
        let ez = half.x * s + half.z * c
        return Box(min: Vec3(center.x - ex, center.y - half.y, center.z - ez),
                   max: Vec3(center.x + ex, center.y + half.y, center.z + ez))
    }
}
