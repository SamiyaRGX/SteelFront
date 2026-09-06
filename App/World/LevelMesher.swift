//
//  LevelMesher.swift
//  SteelFront
//
//  Turns a map cell into static meshes (terrain, structures, scattered props)
//  plus the collision boxes that go with them. Meshes are grouped by material
//  so each draw call samples exactly one atlas tile. Cells are streamed in and
//  out forever, which is what makes the battlefield endless.
//

import Foundation
import Metal
import simd

struct ChunkKey: Hashable {
    let x: Int
    let z: Int
}

/// One mesh plus the atlas tile it samples.
struct ChunkMesh {
    let tile: Float
    let mesh: Mesh
}

final class Chunk {
    let key: ChunkKey
    var meshes: [ChunkMesh] = []
    var boxes: [Box] = []
    var center = SIMD3<Float>(repeating: 0)
    var triangleCount: Int { meshes.reduce(0) { $0 + $1.mesh.indexCount / 3 } }

    init(key: ChunkKey) {
        self.key = key
    }
}

/// Routes geometry into one MeshBuilder per material tile.
final class ChunkMesher {
    private var builders: [Int: MeshBuilder] = [:]
    private(set) var boxCount = 0

    func box(_ tile: MaterialTile, min lo: SIMD3<Float>, max hi: SIMD3<Float>,
             uvScale: Float = 0.28, tint: SIMD3<Float> = SIMD3<Float>(repeating: 1),
             faces: FaceMask = .all) {
        builder(for: tile).addBox(min: lo, max: hi, uvScale: uvScale, tint: tint, faces: faces)
        boxCount += 1
    }

    func vertex(_ tile: MaterialTile, _ vertex: Vertex) {
        builder(for: tile).add(vertex: vertex)
    }

    func triangle(_ tile: MaterialTile, _ a: UInt32, _ b: UInt32, _ c: UInt32) {
        builder(for: tile).addTriangle(a, b, c)
    }

    var vertexCount: Int { builders.values.reduce(0) { $0 + $1.vertexCount } }

    /// Vertex count of one material bucket, used to compute triangle indices.
    func vertexCount(for tile: MaterialTile) -> Int { builders[tile.rawValue]?.vertexCount ?? 0 }

    func makeMeshes(device: MTLDevice) -> [ChunkMesh] {
        var out: [ChunkMesh] = []
        for (tile, builder) in builders.sorted(by: { $0.key < $1.key }) {
            if let mesh = builder.makeMesh(device: device) {
                out.append(ChunkMesh(tile: Float(tile), mesh: mesh))
            }
        }
        return out
    }

    private func builder(for tile: MaterialTile) -> MeshBuilder {
        if let existing = builders[tile.rawValue] { return existing }
        let builder = MeshBuilder()
        builder.reserve(vertices: 1024, indices: 2048)
        builders[tile.rawValue] = builder
        return builder
    }
}

enum LevelMesher {

    static let groundSubdivisions = 8
    private static let propSalt: UInt64 = 0x9A37_C0DE

    /// Builds everything inside one cell.
    static func build(cellX: Int, cellZ: Int, generator: MapGenerator,
                      device: MTLDevice) -> Chunk {
        let chunk = Chunk(key: ChunkKey(x: cellX, z: cellZ))
        let cellSize = generator.cellSize
        let originX = Float(cellX) * cellSize
        let originZ = Float(cellZ) * cellSize
        chunk.center = SIMD3(originX + cellSize * 0.5, 0, originZ + cellSize * 0.5)

        let mesher = ChunkMesher()
        addTerrain(mesher: mesher, originX: originX, originZ: originZ, cellSize: cellSize)
        for structure in generator.structures(cellX: cellX, cellZ: cellZ) {
            addStructure(mesher: mesher, structure: structure, boxes: &chunk.boxes)
        }
        addProps(mesher: mesher, cellX: cellX, cellZ: cellZ, generator: generator,
                 boxes: &chunk.boxes)

        chunk.meshes = mesher.makeMeshes(device: device)
        return chunk
    }

    // MARK: - Terrain

    private static func addTerrain(mesher: ChunkMesher, originX: Float, originZ: Float,
                                   cellSize: Float) {
        let steps = groundSubdivisions
        let step = cellSize / Float(steps)

        // The dominant ground material for this cell; per-quad colour variation
        // comes from vertex tints so the whole cell stays one draw call.
        let macro = Noise.fbm(originX + cellSize * 0.5, originZ + cellSize * 0.5,
                              octaves: 2, baseScale: 0.006)
        let tile: MaterialTile = macro > 0.62 ? .gravelRoad
            : (Noise.value(originX, originZ, scale: 0.045) > 0.74 ? .rock : .sand)

        for iz in 0..<steps {
            for ix in 0..<steps {
                let x0 = originX + Float(ix) * step
                let z0 = originZ + Float(iz) * step
                let base = UInt32(mesher.vertexCount(for: tile))

                let corners: [(Float, Float)] = [(0, 0), (step, 0), (step, step), (0, step)]
                for c in corners {
                    let position = SIMD3(x0 + c.0, Terrain.height(at: x0 + c.0, z0 + c.1), z0 + c.1)
                    let variation = Noise.value(position.x, position.z, scale: 0.08)
                    var tint = SIMD3<Float>(1, 1, 1)
                    if tile == .sand {
                        tint = variation > 0.62 ? SIMD3(1.02, 0.98, 0.9)
                            : SIMD3(0.84, 0.87, 0.74)      // dry grass patches
                    } else if tile == .gravelRoad {
                        tint = SIMD3(repeating: 0.9 + variation * 0.2)
                    } else {
                        tint = SIMD3(repeating: 0.88 + variation * 0.24)
                    }
                    mesher.vertex(tile, Vertex(position: position,
                                               normal: Terrain.normal(at: position.x, position.z),
                                               uv: SIMD2(position.x, position.z) * 0.25,
                                               tint: tint, ao: 1, limb: 0))
                }
                // Counter-clockwise seen from above.
                mesher.triangle(tile, base, base + 2, base + 1)
                mesher.triangle(tile, base, base + 3, base + 2)
            }
        }
    }

    // MARK: - Structures

    private static func addStructure(mesher: ChunkMesher, structure: Structure,
                                     boxes: inout [Box]) {
        let tile = MaterialTile.surfaceTile[structure.surface] ?? .concrete
        let uvScale: Float = structure.surface == .sandbag ? 0.45 : 0.28
        for box in structure.boxes {
            boxes.append(box)
            mesher.box(tile, min: box.min, max: box.max, uvScale: uvScale)
        }
    }

    // MARK: - Scatter props

    private static func addProps(mesher: ChunkMesher, cellX: Int, cellZ: Int,
                                 generator: MapGenerator, boxes: inout [Box]) {
        var rng = Hash.rng(cellX, cellZ, propSalt)
        let cellSize = generator.cellSize
        let originX = Float(cellX) * cellSize
        let originZ = Float(cellZ) * cellSize

        for _ in 0..<rng.int(2, 7) {
            let px = originX + rng.range(1.5, cellSize - 1.5)
            let pz = originZ + rng.range(1.5, cellSize - 1.5)
            if sqrtf(px * px + pz * pz) < generator.spawnClearance { continue }
            let ground = Terrain.height(at: px, pz)

            switch rng.nextFloat() {
            case ..<0.30:
                addBarrel(mesher: mesher, at: SIMD3(px, ground, pz),
                          tint: rng.bool(0.4) ? SIMD3(0.55, 0.22, 0.16) : SIMD3(0.30, 0.34, 0.26),
                          boxes: &boxes)
            case ..<0.55:
                addCrateStack(mesher: mesher, at: SIMD3(px, ground, pz), rng: &rng, boxes: &boxes)
            case ..<0.75:
                addBarrier(mesher: mesher, at: SIMD3(px, ground, pz), along: rng.bool(), boxes: &boxes)
            case ..<0.90:
                addSandbagNest(mesher: mesher, at: SIMD3(px, ground, pz), rng: &rng, boxes: &boxes)
            default:
                addWreck(mesher: mesher, at: SIMD3(px, ground, pz), boxes: &boxes)
            }
        }
    }

    private static func addBarrel(mesher: ChunkMesher, at position: SIMD3<Float>,
                                  tint: SIMD3<Float>, boxes: inout [Box]) {
        let radius: Float = 0.38
        let height: Float = 1.05
        boxes.append(Box(min: SIMD3(position.x - radius, position.y - 0.05, position.z - radius),
                         max: SIMD3(position.x + radius, position.y + height, position.z + radius)))
        let segments = 10
        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * .pi * 2
            let a1 = Float(i + 1) / Float(segments) * .pi * 2
            let c0 = SIMD3(cosf(a0), 0, sinf(a0)) * radius
            let c1 = SIMD3(cosf(a1), 0, sinf(a1)) * radius
            let normal = normalize(SIMD3(cosf((a0 + a1) * 0.5), 0.12, sinf((a0 + a1) * 0.5)))
            let base = UInt32(mesher.vertexCount(for: .paintedSteel))
            mesher.vertex(.paintedSteel, Vertex(position: position + c0, normal: normal,
                                                uv: SIMD2(a0 * radius, 0), tint: tint, ao: 0.9, limb: 0))
            mesher.vertex(.paintedSteel, Vertex(position: position + c1, normal: normal,
                                                uv: SIMD2(a1 * radius, 0), tint: tint, ao: 0.9, limb: 0))
            mesher.vertex(.paintedSteel, Vertex(position: position + c1 + SIMD3(0, height, 0),
                                                normal: normal, uv: SIMD2(a1 * radius, height),
                                                tint: tint, ao: 0.95, limb: 0))
            mesher.vertex(.paintedSteel, Vertex(position: position + c0 + SIMD3(0, height, 0),
                                                normal: normal, uv: SIMD2(a0 * radius, height),
                                                tint: tint, ao: 0.95, limb: 0))
            mesher.triangle(.paintedSteel, base, base + 1, base + 2)
            mesher.triangle(.paintedSteel, base, base + 2, base + 3)
        }
        // Lid.
        let lidBase = UInt32(mesher.vertexCount(for: .paintedSteel))
        mesher.vertex(.paintedSteel, Vertex(position: position + SIMD3(0, height, 0),
                                            normal: SIMD3(0, 1, 0), uv: SIMD2(0.5, 0.5),
                                            tint: tint * 1.08, ao: 1, limb: 0))
        for i in 0..<segments {
            let a = Float(i) / Float(segments) * .pi * 2
            mesher.vertex(.paintedSteel,
                          Vertex(position: position + SIMD3(cosf(a), height, sinf(a)) * radius,
                                 normal: SIMD3(0, 1, 0), uv: SIMD2(0.5, 0.5),
                                 tint: tint * 1.08, ao: 1, limb: 0))
        }
        for i in 0..<segments {
            mesher.triangle(.paintedSteel, lidBase, lidBase + 1 + UInt32(i),
                            lidBase + 1 + UInt32((i + 1) % segments))
        }
    }

    private static func addCrateStack(mesher: ChunkMesher, at position: SIMD3<Float>,
                                      rng: inout GameRandom, boxes: inout [Box]) {
        let size = rng.range(0.7, 1.1)
        for i in 0..<rng.int(1, 2) {
            let y = position.y + Float(i) * size
            let box = Box(min: SIMD3(position.x - size * 0.5, y - 0.03, position.z - size * 0.5),
                          max: SIMD3(position.x + size * 0.5, y + size, position.z + size * 0.5))
            boxes.append(box)
            mesher.box(.crate, min: box.min, max: box.max, uvScale: 0.5,
                       tint: SIMD3(0.9, 0.88, 0.8))
        }
    }

    private static func addBarrier(mesher: ChunkMesher, at position: SIMD3<Float>,
                                   along: Bool, boxes: inout [Box]) {
        let length: Float = 2.9
        let half = SIMD3(along ? length * 0.5 : 0.35, 0.55, along ? 0.35 : length * 0.5)
        let box = Box(min: SIMD3(position.x, position.y - 0.1, position.z) - half,
                      max: SIMD3(position.x, position.y - 0.1, position.z) + half)
        boxes.append(box)
        mesher.box(.stainedConcrete, min: box.min, max: box.max, uvScale: 0.3,
                   tint: SIMD3(0.85, 0.85, 0.82))
    }

    private static func addSandbagNest(mesher: ChunkMesher, at position: SIMD3<Float>,
                                       rng: inout GameRandom, boxes: inout [Box]) {
        let radius: Float = 1.4
        let bags = 10
        let layers = rng.int(1, 2)
        for i in 0..<bags {
            let angle = Float(i) / Float(bags) * .pi * 2
            let bx = position.x + cosf(angle) * radius
            let bz = position.z + sinf(angle) * radius
            let bagGround = Terrain.height(at: bx, bz)
            for layer in 0..<layers {
                let y = bagGround + Float(layer) * 0.34
                let box = Box(min: SIMD3(bx - 0.34, y, bz - 0.24),
                              max: SIMD3(bx + 0.34, y + 0.32, bz + 0.24))
                boxes.append(box)
                mesher.box(.sandbag, min: box.min, max: box.max, uvScale: 0.6,
                           tint: SIMD3(0.95, 0.92, 0.85))
            }
        }
    }

    private static func addWreck(mesher: ChunkMesher, at position: SIMD3<Float>,
                                 boxes: inout [Box]) {
        let width: Float = 2.0
        let bodyLength: Float = 4.2
        let body = Box(min: SIMD3(position.x - width * 0.5, position.y - 0.1,
                                  position.z - bodyLength * 0.5),
                       max: SIMD3(position.x + width * 0.5, position.y + 1.1,
                                  position.z + bodyLength * 0.5))
        let cabin = Box(min: SIMD3(position.x - width * 0.42, position.y + 1.05, position.z - 0.6),
                        max: SIMD3(position.x + width * 0.42, position.y + 1.9, position.z + 1.2))
        boxes.append(body)
        boxes.append(cabin)
        mesher.box(.paintedSteel, min: body.min, max: body.max, uvScale: 0.22,
                   tint: SIMD3(0.35, 0.33, 0.30))
        mesher.box(.paintedSteel, min: cabin.min, max: cabin.max, uvScale: 0.3,
                   tint: SIMD3(0.25, 0.24, 0.22))
        // Wheels as squat boxes so the wreck reads as a vehicle.
        for sx in [-1.0, 1.0] as [Float] {
            for sz in [-1.4, 1.4] as [Float] {
                let wheel = Box(min: SIMD3(position.x + sx * (width * 0.5) - 0.12, position.y - 0.25,
                                           position.z + sz - 0.4),
                                max: SIMD3(position.x + sx * (width * 0.5) + 0.12, position.y + 0.45,
                                           position.z + sz + 0.4))
                boxes.append(wheel)
                mesher.box(.rubber, min: wheel.min, max: wheel.max, uvScale: 0.8)
            }
        }
    }
}
