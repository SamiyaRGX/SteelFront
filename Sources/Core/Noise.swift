//
//  Noise.swift
//  SteelFront
//
//  Value noise + fbm used for terrain undulation, prop scatter and the
//  procedural cloud / sky layer. Fully deterministic and tileable.
//

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

public enum Noise {

    /// Hashed lattice value in [0, 1].
    @inline(__always)
    public static func lattice(_ x: Int, _ y: Int) -> Float {
        Hash.unit(x, y, 0xA5_3C_9E_17)
    }

    /// Smoothstep interpolation.
    @inline(__always)
    private static func fade(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    /// Single octave value noise in [0, 1].
    public static func value(_ x: Float, _ y: Float, scale: Float = 1) -> Float {
        let sx = x * scale
        let sy = y * scale
        let x0 = Int(floorf(sx)), y0 = Int(floorf(sy))
        let fx = fade(sx - Float(x0))
        let fy = fade(sy - Float(y0))
        let v00 = lattice(x0, y0)
        let v10 = lattice(x0 + 1, y0)
        let v01 = lattice(x0, y0 + 1)
        let v11 = lattice(x0 + 1, y0 + 1)
        let top = lerp(v00, v10, fx)
        let bottom = lerp(v01, v11, fx)
        return lerp(top, bottom, fy)
    }

    /// Fractal brownian motion in [0, 1].
    public static func fbm(_ x: Float, _ y: Float, octaves: Int = 4,
                           lacunarity: Float = 2.0, gain: Float = 0.5,
                           baseScale: Float = 1) -> Float {
        var amplitude: Float = 1
        var frequency = baseScale
        var sum: Float = 0
        var norm: Float = 0
        for _ in 0..<max(1, octaves) {
            sum += value(x, y, scale: frequency) * amplitude
            norm += amplitude
            frequency *= lacunarity
            amplitude *= gain
        }
        return norm > 0 ? sum / norm : 0
    }

    /// Ridged fbm — nice for rocky ground and mountain silhouettes.
    public static func ridged(_ x: Float, _ y: Float, octaves: Int = 4,
                              baseScale: Float = 1) -> Float {
        var amplitude: Float = 1
        var frequency = baseScale
        var sum: Float = 0
        var norm: Float = 0
        for _ in 0..<max(1, octaves) {
            let v = 1 - absf(value(x, y, scale: frequency) * 2 - 1)
            sum += v * v * amplitude
            norm += amplitude
            frequency *= 2
            amplitude *= 0.5
        }
        return norm > 0 ? sum / norm : 0
    }
}
