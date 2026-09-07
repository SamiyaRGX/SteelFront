//
//  TextureFactory.swift
//  SteelFront
//
//  Every texture in the game is generated procedurally at launch: a 4x4
//  material atlas (albedo in RGB, roughness in A), a particle sprite sheet and
//  a UI noise mask. No image assets to ship, nothing to license, and the whole
//  look can be re-tuned from code.
//

import Foundation
import Metal
import simd

enum MaterialTile: Int {
    case sand = 0
    case concrete = 1
    case corrugatedMetal = 2
    case crate = 3
    case sandbag = 4
    case rock = 5
    case paintedSteel = 6
    case grate = 7
    case rubber = 8
    case brick = 9
    case camo = 10
    case rivetPanel = 11
    case gravelRoad = 12
    case stainedConcrete = 13
    case gunmetal = 14
    case fabric = 15

    static var surfaceTile: [Surface: MaterialTile] {
        [
            .ground: .sand,
            .rock: .rock,
            .concrete: .concrete,
            .metal: .corrugatedMetal,
            .crate: .crate,
            .sandbag: .sandbag,
            .glass: .grate,
            .flesh: .fabric,
        ]
    }
}

/// Tileable value noise used by the texture bakers.
private struct TileNoise {
    let period: Int
    let seed: UInt64

    private func lattice(_ x: Int, _ y: Int) -> Float {
        let wx = ((x % period) + period) % period
        let wy = ((y % period) + period) % period
        return Hash.unit(wx, wy, seed)
    }

    private func fade(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    func value(_ u: Float, _ v: Float, frequency: Float) -> Float {
        let x = u * Float(period) * frequency
        let y = v * Float(period) * frequency
        let x0 = Int(floorf(x))
        let y0 = Int(floorf(y))
        let fx = fade(x - Float(x0))
        let fy = fade(y - Float(y0))
        let top = lerp(lattice(x0, y0), lattice(x0 + 1, y0), fx)
        let bottom = lerp(lattice(x0, y0 + 1), lattice(x0 + 1, y0 + 1), fx)
        return lerp(top, bottom, fy)
    }

    func fbm(_ u: Float, _ v: Float, octaves: Int = 4, frequency: Float = 1) -> Float {
        var sum: Float = 0
        var amplitude: Float = 1
        var norm: Float = 0
        var f = frequency
        for _ in 0..<octaves {
            sum += value(u, v, frequency: f) * amplitude
            norm += amplitude
            f *= 2
            amplitude *= 0.5
        }
        return sum / max(norm, 0.0001)
    }
}

// MARK: - Shader-like helpers

private func fract(_ x: Float) -> Float { x - floorf(x) }

private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
    a + (b - a) * t
}

private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.x + (b.x - a.x) * t.x, a.y + (b.y - a.y) * t.y, a.z + (b.z - a.z) * t.z)
}

private func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = clamp((x - edge0) / (edge1 - edge0), 0, 1)
    return t * t * (3 - 2 * t)
}

private struct Pixel {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8
}

final class TextureFactory {

    let device: MTLDevice
    private(set) var atlas: MTLTexture?
    private(set) var spriteSheet: MTLTexture?

    static let atlasSize = 1024
    static let tileSize = 256

    init(device: MTLDevice) {
        self.device = device
    }

    // MARK: - Public

    func buildAll() {
        atlas = buildAtlas()
        spriteSheet = buildSpriteSheet()
    }

    // MARK: - Atlas

    private func buildAtlas() -> MTLTexture? {
        let size = TextureFactory.atlasSize
        var pixels = [Pixel](repeating: Pixel(r: 0, g: 0, b: 0, a: 255), count: size * size)
        let tile = TextureFactory.tileSize

        for index in 0..<16 {
            let tileX = (index % 4) * tile
            let tileY = (index / 4) * tile
            bakeTile(index: index, pixels: &pixels, originX: tileX, originY: tileY, size: tile)
        }

        // Single level on purpose: a blit-generated mip chain was leaving the
        // higher levels uninitialised on device, so any sampled LOD > 0
        // returned garbage (green / magenta surfaces). One level cannot fail.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegion(origin: .init(), size: .init(width: size, height: size, depth: 1)),
                            mipmapLevel: 0,
                            withBytes: raw.baseAddress!,
                            bytesPerRow: size * 4)
        }
        return texture
    }

    private func bakeTile(index: Int, pixels: inout [Pixel], originX: Int, originY: Int, size: Int) {
        let noise = TileNoise(period: 64, seed: UInt64(index) &* 0x9E37 &+ 17)
        let detail = TileNoise(period: 128, seed: UInt64(index) &* 0x51ED &+ 91)

        for y in 0..<size {
            for x in 0..<size {
                let u = Float(x) / Float(size)
                let v = Float(y) / Float(size)
                var colour = SIMD3<Float>(repeating: 0.5)
                var roughness: Float = 0.8

                switch index {
                case MaterialTile.sand.rawValue:
                    let n = noise.fbm(u, v, octaves: 5, frequency: 2)
                    let grains = detail.value(u, v, frequency: 12)
                    colour = SIMD3(0.56, 0.48, 0.35) * (0.78 + n * 0.42) + SIMD3(repeating: grains * 0.05)
                    if detail.value(u, v, frequency: 5) > 0.86 {
                        colour *= 0.7   // pebbles
                    }
                    roughness = 0.95

                case MaterialTile.concrete.rawValue:
                    let n = noise.fbm(u, v, octaves: 4, frequency: 1.5)
                    let stains = detail.fbm(u, v, octaves: 3, frequency: 3)
                    colour = SIMD3(0.44, 0.43, 0.41) * (0.82 + n * 0.3)
                    colour = mix(colour, SIMD3(0.30, 0.29, 0.27), stains * 0.35)
                    // Panel seams.
                    let seamX = absf(fract(u * 2) - 0.5)
                    let seamY = absf(fract(v * 2) - 0.5)
                    if min(seamX, seamY) < 0.012 { colour *= 0.62 }
                    // Cracks.
                    if crackMask(u: u, v: v, noise: detail) { colour *= 0.55 }
                    roughness = 0.88

                case MaterialTile.corrugatedMetal.rawValue:
                    let ribs = sinf(u * .pi * 2 * 9) * 0.5 + 0.5
                    let rust = detail.fbm(u, v, octaves: 4, frequency: 4)
                    colour = SIMD3(0.28, 0.31, 0.24) * (0.6 + ribs * 0.65)
                    colour = mix(colour, SIMD3(0.45, 0.28, 0.16), smoothstep(0.62, 0.9, rust) * 0.75)
                    let scratches = detail.value(u, v, frequency: 20)
                    colour += SIMD3(repeating: scratches > 0.93 ? 0.12 : 0)
                    // Scalar blend: `lerp`, not `mix` (this file's `mix`
                    // overloads are for colour vectors only).
                    roughness = lerp(0.35, 0.8, smoothstep(0.6, 0.9, rust))

                case MaterialTile.crate.rawValue:
                    let plank = floorf(v * 5)
                    let edge = absf(fract(v * 5) - 0.5)
                    let wood = noise.fbm(u, v * 0.3, octaves: 4, frequency: 3)
                    colour = SIMD3(0.47, 0.35, 0.21) * (0.8 + wood * 0.35)
                    if edge > 0.46 { colour *= 0.55 }
                    // Steel banding.
                    if absf(u - 0.5) < 0.035 || absf(fract(plank / 5) - 0.5) < 0.02 {
                        colour = mix(SIMD3(0.22, 0.22, 0.21), colour, 0.25)
                    }
                    roughness = 0.78

                case MaterialTile.sandbag.rawValue:
                    let bagU = fract(u * 3)
                    let bagV = fract(v * 2 + (floorf(u * 3).truncatingRemainder(dividingBy: 2)) * 0.5)
                    let bulge = sinf(bagU * .pi) * sinf(bagV * .pi)
                    let grain = noise.fbm(u, v, octaves: 5, frequency: 6)
                    colour = SIMD3(0.52, 0.46, 0.33) * (0.7 + bulge * 0.4 + grain * 0.2)
                    if bagU < 0.04 || bagV < 0.05 { colour *= 0.6 }
                    roughness = 0.97

                case MaterialTile.rock.rawValue:
                    let n = noise.fbm(u, v, octaves: 6, frequency: 3)
                    let cracks = detail.fbm(u, v, octaves: 3, frequency: 8)
                    colour = mix(SIMD3(0.33, 0.31, 0.28), SIMD3(0.52, 0.49, 0.44), n)
                    colour *= 1 - smoothstep(0.6, 0.85, cracks) * 0.5
                    roughness = 0.93

                case MaterialTile.paintedSteel.rawValue:
                    let base = SIMD3<Float>(0.17, 0.19, 0.20)
                    let wear = detail.fbm(u, v, octaves: 4, frequency: 5)
                    colour = base * (0.85 + wear * 0.35)
                    // Hazard stripes.
                    let stripe = fract((u + v) * 6)
                    if stripe < 0.42 { colour = mix(colour, SIMD3(0.75, 0.58, 0.12), 0.85) }
                    colour = mix(colour, SIMD3(0.42, 0.30, 0.18), smoothstep(0.78, 0.95, wear) * 0.5)
                    roughness = 0.4

                case MaterialTile.grate.rawValue:
                    let holeU = fract(u * 8)
                    let holeV = fract(v * 8)
                    let inHole = holeU > 0.28 && holeU < 0.72 && holeV > 0.28 && holeV < 0.72
                    colour = inHole ? SIMD3(0.05, 0.05, 0.06) : SIMD3(0.24, 0.25, 0.26)
                    roughness = inHole ? 1.0 : 0.5

                case MaterialTile.rubber.rawValue:
                    let n = noise.fbm(u, v, octaves: 5, frequency: 8)
                    colour = SIMD3(0.09, 0.09, 0.10) * (0.8 + n * 0.5)
                    let tread = absf(fract(u * 12) - 0.5)
                    if tread < 0.16 { colour *= 1.5 }
                    roughness = 0.85

                case MaterialTile.brick.rawValue:
                    let rowHeight: Float = 0.125
                    let row = floorf(v / rowHeight)
                    let offset = row.truncatingRemainder(dividingBy: 2) * 0.125
                    let brickU = fract((u + offset) / 0.25)
                    let brickV = fract(v / rowHeight)
                    let mortar = brickU < 0.06 || brickV < 0.12
                    let n = noise.fbm(u * 3, v * 3, octaves: 4, frequency: 4)
                    colour = mortar ? SIMD3(0.55, 0.53, 0.49) : SIMD3(0.45, 0.26, 0.20) * (0.8 + n * 0.4)
                    roughness = mortar ? 0.95 : 0.88

                case MaterialTile.camo.rawValue:
                    let n1 = noise.fbm(u, v, octaves: 3, frequency: 2)
                    let n2 = detail.fbm(u, v, octaves: 3, frequency: 4)
                    colour = SIMD3(0.30, 0.33, 0.22)
                    if n1 > 0.55 { colour = SIMD3(0.44, 0.40, 0.28) }
                    if n2 > 0.68 { colour = SIMD3(0.19, 0.20, 0.15) }
                    if n2 < 0.28 { colour = SIMD3(0.36, 0.31, 0.22) }
                    roughness = 0.9

                case MaterialTile.rivetPanel.rawValue:
                    let n = noise.fbm(u, v, octaves: 3, frequency: 3)
                    colour = SIMD3(0.22, 0.23, 0.25) * (0.85 + n * 0.3)
                    let panelU = fract(u * 2)
                    let panelV = fract(v * 2)
                    if panelU < 0.03 || panelV < 0.03 { colour *= 0.6 }
                    // Rivets in a grid.
                    let rivetU = fract(u * 8) - 0.5
                    let rivetV = fract(v * 8) - 0.5
                    let rivetDistance = sqrtf(rivetU * rivetU + rivetV * rivetV)
                    if rivetDistance < 0.1 { colour = SIMD3(0.42, 0.43, 0.45) }
                    roughness = 0.42

                case MaterialTile.gravelRoad.rawValue:
                    let n = noise.fbm(u, v, octaves: 6, frequency: 4)
                    let stones = detail.value(u, v, frequency: 16)
                    colour = mix(SIMD3(0.32, 0.30, 0.27), SIMD3(0.48, 0.45, 0.40), n)
                    if stones > 0.8 { colour = SIMD3(0.55, 0.53, 0.49) }
                    // Tyre ruts.
                    let rut = min(absf(u - 0.35), absf(u - 0.65))
                    colour *= 1 - (1 - smoothstep(0.0, 0.08, rut)) * 0.25
                    roughness = 0.97

                case MaterialTile.stainedConcrete.rawValue:
                    let n = noise.fbm(u, v, octaves: 4, frequency: 2)
                    let streak = detail.fbm(u * 0.5, v, octaves: 3, frequency: 6)
                    colour = SIMD3(0.50, 0.49, 0.46) * (0.85 + n * 0.25)
                    colour = mix(colour, SIMD3(0.34, 0.31, 0.27), smoothstep(0.55, 0.9, streak) * 0.6)
                    if crackMask(u: u, v: v, noise: noise) { colour *= 0.6 }
                    roughness = 0.86

                case MaterialTile.gunmetal.rawValue:
                    let n = noise.fbm(u, v, octaves: 3, frequency: 6)
                    colour = SIMD3(0.13, 0.135, 0.145) * (0.85 + n * 0.4)
                    let brushing = detail.value(u, v * 0.2, frequency: 24)
                    colour += SIMD3(repeating: brushing * 0.05)
                    roughness = 0.32

                default:   // fabric
                    let weaveU = sinf(u * .pi * 2 * 40) * 0.5 + 0.5
                    let weaveV = sinf(v * .pi * 2 * 40) * 0.5 + 0.5
                    let n = noise.fbm(u, v, octaves: 4, frequency: 4)
                    colour = SIMD3(0.42, 0.43, 0.38) * (0.82 + weaveU * 0.08 + weaveV * 0.08 + n * 0.22)
                    roughness = 0.92
                }

                let clamped = SIMD3(clamp(colour.x, 0, 1), clamp(colour.y, 0, 1), clamp(colour.z, 0, 1))
                let offset = (originY + y) * TextureFactory.atlasSize + (originX + x)
                pixels[offset] = Pixel(r: UInt8(clamped.x * 255),
                                       g: UInt8(clamped.y * 255),
                                       b: UInt8(clamped.z * 255),
                                       a: UInt8(clamp(roughness, 0, 1) * 255))
            }
        }
    }

    /// Cheap procedural crack: a few wandering dark lines.
    private func crackMask(u: Float, v: Float, noise: TileNoise) -> Bool {
        for seed in 0..<3 {
            let startU = Float(seed) * 0.31 + 0.1
            var cu = startU
            var best: Float = 1
            var cv: Float = 0
            while cv < 1 {
                cu += (noise.value(cu, cv, frequency: 3 + Float(seed)) - 0.5) * 0.09
                cv += 0.05
                best = min(best, absf(u - cu))
            }
            if best < 0.004 { return true }
        }
        return false
    }

    // MARK: - Particle sprite sheet
    //
    // 256 x 512, two stacked tiles: v in [0, 0.5] is the soft blob used by
    // smoke, fire and sparks; v in [0.5, 1] is the shockwave ring.

    private func buildSpriteSheet() -> MTLTexture? {
        let size = 256
        var pixels = [Pixel](repeating: Pixel(r: 255, g: 255, b: 255, a: 0), count: size * size * 2)

        for y in 0..<size {
            for x in 0..<size {
                let u = (Float(x) / Float(size)) * 2 - 1
                let v = (Float(y) / Float(size)) * 2 - 1
                let distance = sqrtf(u * u + v * v)

                // Tile 0: soft radial falloff with a hot core.
                let blob = powf(max(0, 1 - distance), 2.2)
                let core = powf(max(0, 1 - distance * 2.4), 3.0)
                let intensity = clamp(blob + core * 0.7, 0, 1)
                pixels[y * size + x] = Pixel(r: 255, g: 255, b: 255,
                                             a: UInt8(intensity * 255))

                // Tile 1: expanding ring / shockwave.
                let ring = exp(-powf((distance - 0.72) * 7.0, 2))
                pixels[size * size + y * size + x] = Pixel(r: 255, g: 255, b: 255,
                                                           a: UInt8(clamp(ring, 0, 1) * 255))
            }
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size * 2, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegion(origin: .init(),
                                              size: .init(width: size, height: size * 2, depth: 1)),
                            mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: size * 4)
        }
        return texture
    }
}
