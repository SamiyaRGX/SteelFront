//
//  Geometry.swift
//  SteelFront
//
//  Axis aligned boxes, capsule/swept collision and raycasting. This is the
//  physics layer used by the player, enemies, bullets and grenades.
//

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

public struct Box: Equatable {
    public var min: Vec3
    public var max: Vec3

    public init(min: Vec3, max: Vec3) {
        self.min = min
        self.max = max
    }

    public init(center: Vec3, half: Vec3) {
        self.min = center - half
        self.max = center + half
    }

    public var center: Vec3 { (min + max) * 0.5 }
    public var size: Vec3 { max - min }
    public var height: Float { max.y - min.y }
    public var top: Float { max.y }

    public func contains(_ p: Vec3) -> Bool {
        p.x >= min.x && p.x <= max.x && p.y >= min.y && p.y <= max.y && p.z >= min.z && p.z <= max.z
    }

    public func expanded(by r: Float) -> Box {
        Box(min: min - Vec3(repeating: r), max: max + Vec3(repeating: r))
    }

    /// Closest point on the box to `p`.
    public func closestPoint(to p: Vec3) -> Vec3 {
        Vec3(clamp(p.x, min.x, max.x), clamp(p.y, min.y, max.y), clamp(p.z, min.z, max.z))
    }
}

public struct RaycastHit: Equatable {
    public var point: Vec3
    public var normal: Vec3
    public var distance: Float
    /// Opaque surface blocks bullets; thin cover can be penetrated.
    public var penetrable: Bool

    public init(point: Vec3, normal: Vec3, distance: Float, penetrable: Bool = false) {
        self.point = point
        self.normal = normal
        self.distance = distance
        self.penetrable = penetrable
    }
}

/// Spatially hashed collection of boxes with query, resolution and raycasting.
public final class CollisionWorld {
    public let cellSize: Float
    private var buckets: [Int: [Box]] = [:]
    public private(set) var boxCount: Int = 0

    public init(cellSize: Float = 8) {
        self.cellSize = cellSize
    }

    public func clear() {
        buckets.removeAll(keepingCapacity: true)
        boxCount = 0
    }

    private func key(_ x: Int, _ z: Int) -> Int {
        // Pack two 24-bit coordinates into one Int.
        (x & 0xFFFFFF) | ((z & 0xFFFFFF) << 24)
    }

    public func insert(_ box: Box) {
        boxCount += 1
        let minX = Int(floorf(box.min.x / cellSize))
        let maxX = Int(floorf(box.max.x / cellSize))
        let minZ = Int(floorf(box.min.z / cellSize))
        let maxZ = Int(floorf(box.max.z / cellSize))
        for ix in minX...maxX {
            for iz in minZ...maxZ {
                buckets[key(ix, iz), default: []].append(box)
            }
        }
    }

    public func insert(_ boxes: [Box]) { boxes.forEach(insert) }

    /// Boxes whose AABB overlaps a horizontal disc of `radius` around `center`.
    public func query(center: Vec3, radius: Float, minY: Float = -1000, maxY: Float = 1000) -> [Box] {
        var out: [Box] = []
        out.reserveCapacity(16)
        let minX = Int(floorf((center.x - radius) / cellSize))
        let maxX = Int(floorf((center.x + radius) / cellSize))
        let minZ = Int(floorf((center.z - radius) / cellSize))
        let maxZ = Int(floorf((center.z + radius) / cellSize))
        for ix in minX...maxX {
            for iz in minZ...maxZ {
                guard let list = buckets[key(ix, iz)] else { continue }
                for box in list where box.max.y > minY && box.min.y < maxY {
                    if !out.contains(box) { out.append(box) }
                }
            }
        }
        return out
    }

    // MARK: - Character resolution

    public struct MoveResult {
        public var grounded: Bool = false
        public var groundY: Float = 0
        public var hitWall: Bool = false
    }

    /// Highest surface the capsule could stand on at this XZ position.
    /// Returns nil when there is nothing to stand on.
    public func supportHeight(center: Vec3, radius: Float, feetY: Float,
                              stepHeight: Float = 0.75) -> Float? {
        var best: Float?
        let probe = query(center: center, radius: radius * 0.98,
                          minY: feetY - stepHeight - 0.2, maxY: feetY + 2)
        for box in probe {
            guard center.x > box.min.x - radius * 0.5, center.x < box.max.x + radius * 0.5,
                  center.z > box.min.z - radius * 0.5, center.z < box.max.z + radius * 0.5 else { continue }
            if box.top > feetY + stepHeight + 0.001 { continue }   // too tall to step onto
            if box.top < feetY - stepHeight - 0.1 { continue }     // far below us
            if best == nil || box.top > best! { best = box.top }
        }
        return best
    }

    /// Pushes a capsule out of any solid it overlaps horizontally.
    /// Returns true when a wall was touched (used for footstep/impact sounds).
    @discardableResult
    public func resolveHorizontal(position: inout Vec3, radius: Float, height: Float,
                                  feetY: Float) -> Bool {
        var hitWall = false
        let nearby = query(center: position, radius: radius + 0.1,
                           minY: feetY + 0.06, maxY: feetY + height)
        for box in nearby {
            let cx = clamp(position.x, box.min.x, box.max.x)
            let cz = clamp(position.z, box.min.z, box.max.z)
            var dx = position.x - cx
            var dz = position.z - cz
            let distSq = dx * dx + dz * dz

            if distSq > radius * radius { continue }
            hitWall = true
            if distSq > 1e-8 {
                let dist = sqrtf(distSq)
                let push = radius - dist
                dx /= dist; dz /= dist
                position.x += dx * push
                position.z += dz * push
            } else {
                // Centre is inside the box: eject along the shallowest axis.
                let left = position.x - box.min.x
                let right = box.max.x - position.x
                let front = position.z - box.min.z
                let back = box.max.z - position.z
                let m = min(left, right, front, back)
                if m == left { position.x = box.min.x - radius }
                else if m == right { position.x = box.max.x + radius }
                else if m == front { position.z = box.min.z - radius }
                else { position.z = box.max.z + radius }
            }
        }
        return hitWall
    }

    /// Convenience wrapper: horizontal resolve + vertical snap in one call.
    @discardableResult
    public func move(position: inout Vec3, radius: Float, height: Float,
                     stepHeight: Float = 0.75) -> MoveResult {
        var result = MoveResult()
        let feet = position.y
        // Step up first: otherwise the horizontal pass would shove us out of a
        // low crate we are meant to be standing on.
        if let support = supportHeight(center: position, radius: radius, feetY: feet,
                                       stepHeight: stepHeight), support > feet + 0.001 {
            position.y = support
            result.grounded = true
            result.groundY = support
        }
        result.hitWall = resolveHorizontal(position: &position, radius: radius,
                                           height: height, feetY: position.y)
        return result
    }

    // MARK: - Raycasting

    /// Slab test ray vs box. Returns entry distance, or nil.
    public static func rayBox(origin: Vec3, direction: Vec3, box: Box) -> (Float, Float)? {
        var tmin: Float = -Float.greatestFiniteMagnitude
        var tmax: Float = Float.greatestFiniteMagnitude
        let o = [origin.x, origin.y, origin.z]
        let d = [direction.x, direction.y, direction.z]
        let lo = [box.min.x, box.min.y, box.min.z]
        let hi = [box.max.x, box.max.y, box.max.z]
        for i in 0..<3 {
            if absf(d[i]) < 1e-7 {
                if o[i] < lo[i] || o[i] > hi[i] { return nil }
            } else {
                let inv = 1 / d[i]
                var t1 = (lo[i] - o[i]) * inv
                var t2 = (hi[i] - o[i]) * inv
                if t1 > t2 { swap(&t1, &t2) }
                tmin = max(tmin, t1)
                tmax = min(tmax, t2)
                if tmin > tmax { return nil }
            }
        }
        if tmax < 0 { return nil }
        return (max(0, tmin), tmax)
    }

    private static func axisNormal(origin: Vec3, direction: Vec3, box: Box, t: Float) -> Vec3 {
        let p = origin + direction * t
        let eps: Float = 0.002
        if absf(p.x - box.min.x) < eps { return Vec3(-1, 0, 0) }
        if absf(p.x - box.max.x) < eps { return Vec3(1, 0, 0) }
        if absf(p.y - box.min.y) < eps { return Vec3(0, -1, 0) }
        if absf(p.y - box.max.y) < eps { return Vec3(0, 1, 0) }
        if absf(p.z - box.min.z) < eps { return Vec3(0, 0, -1) }
        if absf(p.z - box.max.z) < eps { return Vec3(0, 0, 1) }
        return Vec3(0, 1, 0)
    }

    /// Ray march across the hash grid. `maxDistance` caps the march.
    public func raycast(origin: Vec3, direction: Vec3, maxDistance: Float) -> RaycastHit? {
        let dir = normalize(direction)
        guard length(dir) > 0.5 else { return nil }

        var best: RaycastHit?
        var bestT = maxDistance

        // Walk the grid cells the ray passes through.
        var cellX = Int(floorf(origin.x / cellSize))
        var cellZ = Int(floorf(origin.z / cellSize))
        let stepX = dir.x > 0 ? 1 : -1
        let stepZ = dir.z > 0 ? 1 : -1
        let tDeltaX = absf(dir.x) < 1e-6 ? Float.greatestFiniteMagnitude : absf(cellSize / dir.x)
        let tDeltaZ = absf(dir.z) < 1e-6 ? Float.greatestFiniteMagnitude : absf(cellSize / dir.z)
        let boundaryX = dir.x > 0 ? Float(cellX + 1) * cellSize : Float(cellX) * cellSize
        let boundaryZ = dir.z > 0 ? Float(cellZ + 1) * cellSize : Float(cellZ) * cellSize
        var tMaxX = absf(dir.x) < 1e-6 ? Float.greatestFiniteMagnitude : (boundaryX - origin.x) / dir.x
        var tMaxZ = absf(dir.z) < 1e-6 ? Float.greatestFiniteMagnitude : (boundaryZ - origin.z) / dir.z

        var travelled: Float = 0
        var guardCount = 0
        while travelled <= bestT && guardCount < 512 {
            guardCount += 1
            if let list = buckets[key(cellX, cellZ)] {
                for box in list {
                    guard let (t0, _) = CollisionWorld.rayBox(origin: origin, direction: dir, box: box) else { continue }
                    if t0 < bestT {
                        bestT = t0
                        best = RaycastHit(point: origin + dir * t0,
                                          normal: CollisionWorld.axisNormal(origin: origin, direction: dir, box: box, t: t0),
                                          distance: t0,
                                          penetrable: box.height < 1.1)
                    }
                }
            }
            if tMaxX < tMaxZ {
                cellX += stepX
                travelled = tMaxX
                tMaxX += tDeltaX
            } else {
                cellZ += stepZ
                travelled = tMaxZ
                tMaxZ += tDeltaZ
            }
        }
        return best
    }

    /// Ray vs sphere. Returns the entry distance, or nil.
    public static func raySphere(origin: Vec3, direction: Vec3, center: Vec3,
                                 radius: Float) -> Float? {
        let delta = origin - center
        let b = dot(delta, direction)
        let c = dot(delta, delta) - radius * radius
        if c > 0 && b > 0 { return nil }
        let discriminant = b * b - c
        if discriminant < 0 { return nil }
        let t = -b - sqrtf(discriminant)
        return t < 0 ? 0 : t
    }

    /// Ray vs capsule (segment + radius). Returns the entry distance, or nil.
    /// Used for enemy body hitboxes.
    public static func raySegment(origin: Vec3, direction: Vec3, a: Vec3, b: Vec3,
                                  radius: Float) -> Float? {
        let d1 = direction
        let d2 = b - a
        let r = origin - a
        let A = dot(d1, d1)
        let E = dot(d2, d2)
        guard A > 1e-8 else { return nil }
        let C = dot(d1, r)

        var s: Float
        var t: Float
        if E < 1e-8 {
            // Degenerate capsule: treat as a sphere.
            return raySphere(origin: origin, direction: direction, center: a, radius: radius)
        }
        let B = dot(d1, d2)
        let F = dot(d2, r)
        let denominator = A * E - B * B
        s = absf(denominator) > 1e-8 ? max(0, (B * F - C * E) / denominator) : 0
        t = (B * s + F) / E
        if t < 0 {
            t = 0
            s = max(0, -C / A)
        } else if t > 1 {
            t = 1
            s = max(0, (B - C) / A)
        }

        let closestOnRay = origin + d1 * s
        let closestOnSegment = a + d2 * t
        let separation = closestOnRay - closestOnSegment
        let separationSq = dot(separation, separation)
        if separationSq > radius * radius { return nil }
        let entry = s - sqrtf(max(0, radius * radius - separationSq))
        return entry < 0 ? 0 : entry
    }

    public func lineOfSight(from: Vec3, to: Vec3, clearance: Float = 0.15) -> Bool {
        let delta = to - from
        let dist = length(delta)
        guard dist > 0.01 else { return true }
        let dir = delta / dist
        guard let hit = raycast(origin: from, direction: dir, maxDistance: dist) else { return true }
        return hit.distance >= dist - clearance
    }
}
