//
//  MetalTypes.swift
//  SteelFront
//
//  GPU data layouts: the packed vertex format, uniform byte offsets and the
//  small helpers that turn CPU meshes into Metal buffers.
//

import Foundation
import Metal
import simd

// MARK: - Vertex
//
// These are plain Float structs (alignment 4) so the Swift in-memory layout is
// exactly the packed layout the Metal vertex descriptor describes. No SIMD
// padding surprises.

/// 16 floats = 64 bytes. Indices must match Shaders.metal `VertexIn`.
struct Vertex {
    var px: Float; var py: Float; var pz: Float
    var nx: Float; var ny: Float; var nz: Float
    var u: Float;  var v: Float
    var tx: Float; var ty: Float; var tz: Float
    var ao: Float
    var limb: Float

    init(position: SIMD3<Float>, normal: SIMD3<Float>, uv: SIMD2<Float>,
         tint: SIMD3<Float>, ao: Float, limb: Float) {
        px = position.x; py = position.y; pz = position.z
        nx = normal.x; ny = normal.y; nz = normal.z
        u = uv.x; v = uv.y
        tx = tint.x; ty = tint.y; tz = tint.z
        self.ao = ao
        self.limb = limb
    }
}

/// 8 floats = 32 bytes. Indices must match Shaders.metal `FXVertexIn`.
struct FXVertex {
    var px: Float; var py: Float; var pz: Float
    var u: Float;  var v: Float
    var r: Float;  var g: Float; var b: Float; var a: Float

    init(position: SIMD3<Float>, uv: SIMD2<Float>, colour: SIMD4<Float>) {
        px = position.x; py = position.y; pz = position.z
        u = uv.x; v = uv.y
        r = colour.x; g = colour.y; b = colour.z; a = colour.w
    }
}

enum VertexLayout {
    static let stride = 64
    static let fxStride = 32

    static func sceneDescriptor() -> MTLVertexDescriptor {
        let d = MTLVertexDescriptor()
        d.attributes[0].format = .float3
        d.attributes[0].offset = 0
        d.attributes[0].bufferIndex = 0
        d.attributes[1].format = .float3
        d.attributes[1].offset = 12
        d.attributes[1].bufferIndex = 0
        d.attributes[2].format = .float2
        d.attributes[2].offset = 24
        d.attributes[2].bufferIndex = 0
        d.attributes[3].format = .float3
        d.attributes[3].offset = 32
        d.attributes[3].bufferIndex = 0
        d.attributes[4].format = .float
        d.attributes[4].offset = 44
        d.attributes[4].bufferIndex = 0
        d.attributes[5].format = .float
        d.attributes[5].offset = 48
        d.attributes[5].bufferIndex = 0
        d.layouts[0].stride = stride   // 64
        d.layouts[0].stepFunction = .perVertex
        return d
    }

    static func fxDescriptor() -> MTLVertexDescriptor {
        let d = MTLVertexDescriptor()
        d.attributes[0].format = .float3
        d.attributes[0].offset = 0
        d.attributes[0].bufferIndex = 0
        d.attributes[1].format = .float2
        d.attributes[1].offset = 12
        d.attributes[1].bufferIndex = 0
        d.attributes[2].format = .float4
        d.attributes[2].offset = 20
        d.attributes[2].bufferIndex = 0
        d.layouts[0].stride = fxStride   // 32
        d.layouts[0].stepFunction = .perVertex
        return d
    }
}

// MARK: - Uniform byte offsets (mirror of Shaders.metal)

enum FrameOffsets {
    static let viewProj = 0
    static let invViewProj = 64
    static let cameraPos = 128
    static let sunDir = 144
    static let sunColor = 160
    static let skyColor = 176
    static let fogParams = 192
    static let lightPos = [208, 224, 240, 256]
    static let lightCol = [272, 288, 304, 320]
    static let params = 336
    static let size = 352
}

enum DrawOffsets {
    static let model = 0
    static let tint = 64
    static let params = 80
    static let anim = 96
    static let extra = 112
    static let size = 128
}

// MARK: - Mesh

final class Mesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    var boundsMin = SIMD3<Float>(repeating: 0)
    var boundsMax = SIMD3<Float>(repeating: 0)

    init(vertexBuffer: MTLBuffer, indexBuffer: MTLBuffer, indexCount: Int) {
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = indexCount
    }

    func draw(_ encoder: MTLRenderCommandEncoder) {
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                      indexType: .uint32, indexBuffer: indexBuffer,
                                      indexBufferOffset: 0)
    }
}

// MARK: - Mesh building

final class MeshBuilder {
    private(set) var vertices: [Vertex] = []
    private(set) var indices: [UInt32] = []

    var vertexCount: Int { vertices.count }

    func reserve(vertices v: Int, indices i: Int) {
        vertices.reserveCapacity(vertices.count + v)
        indices.reserveCapacity(indices.count + i)
    }

    func add(vertex: Vertex) {
        vertices.append(vertex)
    }

    func addTriangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        indices.append(a); indices.append(b); indices.append(c)
    }

    /// Axis aligned box with per-face UVs sized in world units so textures do
    /// not stretch, plus cheap baked ambient occlusion.
    func addBox(min lo: SIMD3<Float>, max hi: SIMD3<Float>, uvScale: Float = 0.25,
                tint: SIMD3<Float> = SIMD3<Float>(repeating: 1), limb: Float = 0,
                aoTop: Float = 1.0, aoSide: Float = 0.86, aoBottom: Float = 0.55,
                faces: FaceMask = .all) {
        let size = hi - lo
        let centre = (lo + hi) * 0.5
        let half = size * 0.5

        struct FaceDef {
            let normal: SIMD3<Float>
            let u: SIMD3<Float>
            let v: SIMD3<Float>
            let halfU: Float
            let halfV: Float
            let ao: Float
            let flag: FaceMask
        }

        // u and v are chosen so that cross(u, v) == normal, which gives
        // counter-clockwise winding seen from outside.
        let defs: [FaceDef] = [
            FaceDef(normal: SIMD3(0, 1, 0), u: SIMD3(0, 0, 1), v: SIMD3(1, 0, 0),
                    halfU: half.z, halfV: half.x, ao: aoTop, flag: .top),
            FaceDef(normal: SIMD3(0, -1, 0), u: SIMD3(1, 0, 0), v: SIMD3(0, 0, 1),
                    halfU: half.x, halfV: half.z, ao: aoBottom, flag: .bottom),
            FaceDef(normal: SIMD3(1, 0, 0), u: SIMD3(0, 1, 0), v: SIMD3(0, 0, 1),
                    halfU: half.y, halfV: half.z, ao: aoSide, flag: .posX),
            FaceDef(normal: SIMD3(-1, 0, 0), u: SIMD3(0, 0, 1), v: SIMD3(0, 1, 0),
                    halfU: half.z, halfV: half.y, ao: aoSide, flag: .negX),
            FaceDef(normal: SIMD3(0, 0, 1), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0),
                    halfU: half.x, halfV: half.y, ao: aoSide, flag: .posZ),
            FaceDef(normal: SIMD3(0, 0, -1), u: SIMD3(0, 1, 0), v: SIMD3(1, 0, 0),
                    halfU: half.y, halfV: half.x, ao: aoSide, flag: .negZ),
        ]

        let corners: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        for face in defs where faces.contains(face.flag) {
            let base = UInt32(vertices.count)
            let origin = centre + face.normal * dot(face.normal, half)
            for c in corners {
                let position = origin + face.u * (c.0 * face.halfU) + face.v * (c.1 * face.halfV)
                let uvU = (c.0 + 1) * face.halfU * uvScale
                let uvV = (c.1 + 1) * face.halfV * uvScale
                vertices.append(Vertex(position: position, normal: face.normal,
                                       uv: SIMD2(uvU, uvV), tint: tint, ao: face.ao, limb: limb))
            }
            addTriangle(base, base + 1, base + 2)
            addTriangle(base, base + 2, base + 3)
        }
    }

    /// Flat quad used for ground tiles, ramps and decals.
    func addQuad(origin: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                 uvScale: Float = 0.25, tint: SIMD3<Float> = SIMD3<Float>(repeating: 1),
                 ao: Float = 1, limb: Float = 0) {
        let normal = normalize(cross(right, up))
        let base = UInt32(vertices.count)
        let corners: [(Float, Float)] = [(0, 0), (1, 0), (1, 1), (0, 1)]
        for c in corners {
            let position = origin + right * c.0 + up * c.1
            let uvU = length(right) * c.0 * uvScale
            let uvV = length(up) * c.1 * uvScale
            vertices.append(Vertex(position: position, normal: normal, uv: SIMD2(uvU, uvV),
                                   tint: tint, ao: ao, limb: limb))
        }
        addTriangle(base, base + 1, base + 2)
        addTriangle(base, base + 2, base + 3)
    }

    func makeMesh(device: MTLDevice) -> Mesh? {
        guard !vertices.isEmpty, !indices.isEmpty else { return nil }
        guard let vb = device.makeBuffer(bytes: vertices,
                                         length: vertices.count * VertexLayout.stride,
                                         options: .storageModeShared),
              let ib = device.makeBuffer(bytes: indices,
                                         length: indices.count * MemoryLayout<UInt32>.stride,
                                         options: .storageModeShared) else { return nil }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in vertices {
            lo = SIMD3(min(lo.x, v.px), min(lo.y, v.py), min(lo.z, v.pz))
            hi = SIMD3(max(hi.x, v.px), max(hi.y, v.py), max(hi.z, v.pz))
        }
        let mesh = Mesh(vertexBuffer: vb, indexBuffer: ib, indexCount: indices.count)
        mesh.boundsMin = lo
        mesh.boundsMax = hi
        return mesh
    }
}

/// Which faces of a box to emit.
struct FaceMask: OptionSet {
    let rawValue: Int
    static let top = FaceMask(rawValue: 1 << 0)
    static let bottom = FaceMask(rawValue: 1 << 1)
    static let posX = FaceMask(rawValue: 1 << 2)
    static let negX = FaceMask(rawValue: 1 << 3)
    static let posZ = FaceMask(rawValue: 1 << 4)
    static let negZ = FaceMask(rawValue: 1 << 5)
    static let all = FaceMask(rawValue: 0b111111)
}

// MARK: - Draw description

struct SceneDraw {
    var mesh: Mesh
    var model: simd_float4x4 = matrix_identity_float4x4
    var tint = SIMD4<Float>(1, 1, 1, 1)
    /// x atlas tile, y uv scale, z ao strength, w emissive
    var params = SIMD4<Float>(0, 1, 1, 0)
    var anim = SIMD4<Float>(repeating: 0)
    var extra = SIMD4<Float>(0, 0, 1, 0)
}
