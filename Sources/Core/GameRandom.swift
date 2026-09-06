//
//  GameRandom.swift
//  SteelFront
//
//  Deterministic RNG so every chunk of the infinite map can be regenerated
//  byte-for-byte when the player walks back into it.
//

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// SplitMix64: tiny, fast, good quality, trivially seedable from coordinates.
public struct GameRandom {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        // Avoid the degenerate all-zero state.
        self.state = seed &+ 0x9E3779B97F4A7C15
    }

    public mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// [0, 1)
    public mutating func nextFloat() -> Float {
        Float(nextUInt64() >> 40) / Float(1 << 24)
    }

    /// [lo, hi)
    public mutating func range(_ lo: Float, _ hi: Float) -> Float {
        lo + (hi - lo) * nextFloat()
    }

    /// [lo, hi] inclusive on integers
    public mutating func int(_ lo: Int, _ hi: Int) -> Int {
        guard hi >= lo else { return lo }
        let span = UInt64(hi - lo + 1)
        return lo + Int(nextUInt64() % span)
    }

    public mutating func bool(_ probability: Float = 0.5) -> Bool {
        nextFloat() < probability
    }

    public mutating func pick<T>(_ items: [T]) -> T? {
        guard !items.isEmpty else { return nil }
        return items[int(0, items.count - 1)]
    }

    /// Unit vector on the XZ plane.
    public mutating func direction2D() -> Vec3 {
        let a = range(0, .pi * 2)
        return Vec3(cosf(a), 0, sinf(a))
    }
}

/// Coordinate hashing — the backbone of the endless procedural map.
public enum Hash {

    @inline(__always)
    public static func mix64(_ x: Int, _ y: Int, _ salt: UInt64 = 0) -> UInt64 {
        var h = UInt64(bitPattern: Int64(x)) &* 0x27D4EB2F165667C5
        h ^= (UInt64(bitPattern: Int64(y)) &+ 0x165667B19E3779F9) &* 0x9E3779B97F4A7C15
        h ^= salt &* 0xC2B2AE3D27D4EB4F
        h ^= h >> 33
        h &*= 0xFF51AFD7ED558CCD
        h ^= h >> 33
        return h
    }

    /// Stable random generator for a map cell + salt.
    @inline(__always)
    public static func rng(_ x: Int, _ y: Int, _ salt: UInt64) -> GameRandom {
        GameRandom(seed: mix64(x, y, salt))
    }

    /// [0, 1)
    @inline(__always)
    public static func unit(_ x: Int, _ y: Int, _ salt: UInt64) -> Float {
        Float(mix64(x, y, salt) >> 40) / Float(1 << 24)
    }
}
