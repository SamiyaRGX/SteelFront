//
//  WorldStreamer.swift
//  SteelFront
//
//  Streams map cells around the player. Cells entering the radius are meshed a
//  few per frame (so streaming never causes a visible hitch) and cells leaving
//  it are released. The collision world is rebuilt whenever the loaded set
//  changes, which only happens when the player crosses a cell boundary.
//

import Foundation
import Metal

final class WorldStreamer {

    let generator: MapGenerator
    let device: MTLDevice

    /// Radius in cells. 4 => a 9x9 grid (216 m across) around the player.
    var radius: Int = 4
    /// Maximum cells meshed per frame while catching up.
    var buildBudgetPerFrame = 2

    private(set) var chunks: [ChunkKey: Chunk] = [:]
    let collision = CollisionWorld(cellSize: 8)
    private var pending: [ChunkKey] = []
    private var lastCenter = ChunkKey(x: Int.max, z: Int.max)
    private(set) var rebuildCount = 0
    private(set) var triangleCount: Int = 0

    init(generator: MapGenerator, device: MTLDevice) {
        self.generator = generator
        self.device = device
    }

    var loadedCount: Int { chunks.count }

    /// Loads everything in range synchronously. Call once behind the loading
    /// screen so the first frame is never empty.
    func prime(around position: SIMD3<Float>) {
        let (cx, cz) = generator.cellIndex(for: position)
        lastCenter = ChunkKey(x: cx, z: cz)
        for iz in -radius...radius {
            for ix in -radius...radius {
                let key = ChunkKey(x: cx + ix, z: cz + iz)
                if chunks[key] == nil {
                    let chunk = LevelMesher.build(cellX: key.x, cellZ: key.z,
                                                  generator: generator, device: device)
                    chunks[key] = chunk
                }
            }
        }
        rebuildCollision()
    }

    /// Per-frame update. Returns true when new geometry became visible.
    @discardableResult
    func update(around position: SIMD3<Float>) -> Bool {
        let (cx, cz) = generator.cellIndex(for: position)
        let center = ChunkKey(x: cx, z: cz)
        var changed = false

        if center != lastCenter {
            lastCenter = center
            // Queue newly visible cells, nearest first.
            var wanted = Set<ChunkKey>()
            for iz in -radius...radius {
                for ix in -radius...radius {
                    wanted.insert(ChunkKey(x: cx + ix, z: cz + iz))
                }
            }
            for key in wanted where chunks[key] == nil {
                if !pending.contains(key) { pending.append(key) }
            }
            pending.sort { keyDistance($0, center) < keyDistance($1, center) }

            // Drop cells that fell out of range (one extra ring of hysteresis).
            let keepRadius = radius + 1
            for key in Array(chunks.keys) {
                if abs(key.x - cx) > keepRadius || abs(key.z - cz) > keepRadius {
                    chunks.removeValue(forKey: key)
                    changed = true
                }
            }
            if changed { rebuildCollision() }
        }

        var built = 0
        while built < buildBudgetPerFrame, !pending.isEmpty {
            let key = pending.removeFirst()
            guard chunks[key] == nil else { continue }
            let chunk = LevelMesher.build(cellX: key.x, cellZ: key.z,
                                          generator: generator, device: device)
            chunks[key] = chunk
            collision.insert(chunk.boxes)
            built += 1
            changed = true
        }
        if built > 0 {
            rebuildCount += 1
            recomputeTriangleCount()
        }
        return changed
    }

    /// Nearest loaded chunk centre, used for spawn placement.
    func isInsideLoadedArea(_ position: SIMD3<Float>) -> Bool {
        let (cx, cz) = generator.cellIndex(for: position)
        return chunks[ChunkKey(x: cx, z: cz)] != nil
    }

    func groundHeight(at position: SIMD3<Float>) -> Float {
        Terrain.height(at: position.x, position.z)
    }

    private func rebuildCollision() {
        collision.clear()
        var triangles = 0
        for chunk in chunks.values {
            collision.insert(chunk.boxes)
            triangles += chunk.triangleCount
        }
        triangleCount = triangles
    }

    private func recomputeTriangleCount() {
        triangleCount = chunks.values.reduce(0) { $0 + $1.triangleCount }
    }

    private func keyDistance(_ a: ChunkKey, _ b: ChunkKey) -> Int {
        let dx = a.x - b.x
        let dz = a.z - b.z
        return dx * dx + dz * dz
    }
}
