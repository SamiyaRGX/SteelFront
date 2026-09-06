//
//  GameMath.swift
//  SteelFront
//
//  Vector / matrix math shared by the game logic and the renderer.
//
//  On Apple platforms these are typealiases to the hardware accelerated
//  `simd` types so the exact same code feeds Metal uniform buffers. On Linux
//  (used only for CI unit tests of the game logic) we provide minimal,
//  layout-compatible stand ins so `swift test` can exercise the real code.
//

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

#if canImport(simd)

import simd

public typealias Vec2 = SIMD2<Float>
public typealias Vec3 = SIMD3<Float>
public typealias Vec4 = SIMD4<Float>
public typealias Mat4 = simd_float4x4

@inline(__always)
public func makeVec2(_ x: Float, _ y: Float) -> Vec2 { Vec2(x, y) }
@inline(__always)
public func makeVec3(_ x: Float, _ y: Float, _ z: Float) -> Vec3 { Vec3(x, y, z) }
@inline(__always)
public func makeVec4(_ x: Float, _ y: Float, _ z: Float, _ w: Float) -> Vec4 { Vec4(x, y, z, w) }

#else

/// Minimal SIMD stand-ins for non-Apple platforms (tests only).
public struct Vec2: Equatable {
    public var x: Float
    public var y: Float
    public init(_ x: Float, _ y: Float) { self.x = x; self.y = y }
    public init(repeating v: Float) { self.init(v, v) }
    public static let zero = Vec2(0, 0)
}

public struct Vec3: Equatable {
    public var x: Float
    public var y: Float
    public var z: Float
    public init(_ x: Float, _ y: Float, _ z: Float) { self.x = x; self.y = y; self.z = z }
    public init(_ v: Vec2, _ z: Float) { self.init(v.x, v.y, z) }
    public init(repeating v: Float) { self.init(v, v, v) }
    public static let zero = Vec3(0, 0, 0)
    public var xy: Vec2 { Vec2(x, y) }

    public static func + (l: Vec3, r: Vec3) -> Vec3 { Vec3(l.x + r.x, l.y + r.y, l.z + r.z) }
    public static func - (l: Vec3, r: Vec3) -> Vec3 { Vec3(l.x - r.x, l.y - r.y, l.z - r.z) }
    public static func * (l: Vec3, r: Float) -> Vec3 { Vec3(l.x * r, l.y * r, l.z * r) }
    public static func * (l: Float, r: Vec3) -> Vec3 { r * l }
    public static func / (l: Vec3, r: Float) -> Vec3 { Vec3(l.x / r, l.y / r, l.z / r) }
    public static prefix func - (v: Vec3) -> Vec3 { Vec3(-v.x, -v.y, -v.z) }
    public static func += (l: inout Vec3, r: Vec3) { l = l + r }
    public static func -= (l: inout Vec3, r: Vec3) { l = l - r }
    public static func *= (l: inout Vec3, r: Float) { l = l * r }
}

public struct Vec4: Equatable {
    public var x: Float
    public var y: Float
    public var z: Float
    public var w: Float
    public init(_ x: Float, _ y: Float, _ z: Float, _ w: Float) { self.x = x; self.y = y; self.z = z; self.w = w }
    public init(_ v: Vec3, _ w: Float) { self.init(v.x, v.y, v.z, w) }
    public init(repeating v: Float) { self.init(v, v, v, v) }
    public static let zero = Vec4(0, 0, 0, 0)
    public var xyz: Vec3 { Vec3(x, y, z) }

    public static func + (l: Vec4, r: Vec4) -> Vec4 { Vec4(l.x + r.x, l.y + r.y, l.z + r.z, l.w + r.w) }
    public static func - (l: Vec4, r: Vec4) -> Vec4 { Vec4(l.x - r.x, l.y - r.y, l.z - r.z, l.w - r.w) }
    public static func * (l: Vec4, r: Float) -> Vec4 { Vec4(l.x * r, l.y * r, l.z * r, l.w * r) }
    public static func * (l: Float, r: Vec4) -> Vec4 { r * l }
    public static func += (l: inout Vec4, r: Vec4) { l = l + r }
}

/// Column major 4x4 matrix, memory layout identical to `simd_float4x4`.
public struct Mat4: Equatable {
    public var columns: (Vec4, Vec4, Vec4, Vec4)

    public init(columns: (Vec4, Vec4, Vec4, Vec4)) { self.columns = columns }

    public init(_ c0: Vec4, _ c1: Vec4, _ c2: Vec4, _ c3: Vec4) {
        self.columns = (c0, c1, c2, c3)
    }

    public static let identity = Mat4(
        Vec4(1, 0, 0, 0), Vec4(0, 1, 0, 0), Vec4(0, 0, 1, 0), Vec4(0, 0, 0, 1))

    public static func == (l: Mat4, r: Mat4) -> Bool {
        for i in 0..<4 where l[i] != r[i] { return false }
        return true
    }

    public subscript(column: Int) -> Vec4 {
        get {
            switch column {
            case 0: return columns.0
            case 1: return columns.1
            case 2: return columns.2
            default: return columns.3
            }
        }
        set {
            switch column {
            case 0: columns.0 = newValue
            case 1: columns.1 = newValue
            case 2: columns.2 = newValue
            default: columns.3 = newValue
            }
        }
    }

    public static func * (l: Mat4, r: Mat4) -> Mat4 {
        var out = Mat4.identity
        for c in 0..<4 {
            let rc = r[c]
            out[c] = l[0] * rc.x + l[1] * rc.y + l[2] * rc.z + l[3] * rc.w
        }
        return out
    }

    public static func * (m: Mat4, v: Vec4) -> Vec4 {
        m[0] * v.x + m[1] * v.y + m[2] * v.z + m[3] * v.w
    }
}

@inline(__always)
public func makeVec2(_ x: Float, _ y: Float) -> Vec2 { Vec2(x, y) }
@inline(__always)
public func makeVec3(_ x: Float, _ y: Float, _ z: Float) -> Vec3 { Vec3(x, y, z) }
@inline(__always)
public func makeVec4(_ x: Float, _ y: Float, _ z: Float, _ w: Float) -> Vec4 { Vec4(x, y, z, w) }

#endif

/// absf exists neither a C name on neither platform. Swift exposes it as/// `abs`. for Float. so define it universally without clashes.
@inline(__always)
public func absf(_ x: Float) -> Float { x < 0 ? -x : x }

/// Length of the horizontal (X/Z) part of a vector.
@inline(__always)
public func horizontalLength(_ v: Vec3) -> Float { sqrtf(v.x * v.x + v.z * v.z) }

// MARK: - Common helpers (identical behaviour on every platform)

#if canImport(simd)
/// The hardware simd types don't ship `.identity` or `.xy` helpers that
/// the Linux stand-ins have; add them here so one codebase compiles everywhere.
public extension Mat4 {
    static var identity: Mat4 { matrix_identity_float4x4 }
}

public extension SIMD3 where Scalar == Float {
    var xy: SIMD2<Float> { SIMD2(x, y) }
    var xz: SIMD2<Float> { SIMD2(x, z) }
}
#endif

@inline(__always)
public func dot(_ a: Vec3, _ b: Vec3) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }

@inline(__always)
public func dot(_ a: Vec2, _ b: Vec2) -> Float { a.x * b.x + a.y * b.y }

public func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
    Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

@inline(__always)
public func length(_ v: Vec3) -> Float { sqrtf(dot(v, v)) }

@inline(__always)
public func length(_ v: Vec2) -> Float { sqrtf(dot(v, v)) }

@inline(__always)
public func distance(_ a: Vec3, _ b: Vec3) -> Float { length(a - b) }

@inline(__always)
public func distance2D(_ a: Vec3, _ b: Vec3) -> Float {
    let dx = a.x - b.x, dz = a.z - b.z
    return sqrtf(dx * dx + dz * dz)
}

public func normalize(_ v: Vec3) -> Vec3 {
    let l = length(v)
    return l > 1e-6 ? v / l : Vec3.zero
}

public func normalize(_ v: Vec2) -> Vec2 {
    let l = length(v)
    return l > 1e-6 ? Vec2(v.x / l, v.y / l) : Vec2.zero
}

public func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

@inline(__always)
public func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

public func lerp(_ a: Vec3, _ b: Vec3, _ t: Float) -> Vec3 { a + (b - a) * t }

/// Frame rate independent exponential smoothing.
@inline(__always)
public func damp(_ current: Float, _ target: Float, _ rate: Float, _ dt: Float) -> Float {
    lerp(current, target, 1 - exp(-rate * dt))
}

public func damp(_ current: Vec3, _ target: Vec3, _ rate: Float, _ dt: Float) -> Vec3 {
    lerp(current, target, 1 - exp(-rate * dt))
}

// MARK: - Matrix construction

public enum Mat {

    public static func translation(_ t: Vec3) -> Mat4 {
        var m = Mat4.identity
        m[3] = Vec4(t.x, t.y, t.z, 1)
        return m
    }

    public static func scale(_ s: Vec3) -> Mat4 {
        var m = Mat4.identity
        m[0] = Vec4(s.x, 0, 0, 0)
        m[1] = Vec4(0, s.y, 0, 0)
        m[2] = Vec4(0, 0, s.z, 0)
        return m
    }

    /// Right handed perspective, depth mapped to [0, 1] (Metal convention).
    public static func perspective(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> Mat4 {
        let ys = 1 / tanf(fovYRadians * 0.5)
        let xs = ys / max(aspect, 1e-4)
        let zs = far / (near - far)
        return Mat4(
            Vec4(xs, 0, 0, 0),
            Vec4(0, ys, 0, 0),
            Vec4(0, 0, zs, -1),
            Vec4(0, 0, near * zs, 0))
    }

    /// Right handed look-at view matrix.
    public static func lookAt(eye: Vec3, center: Vec3, up: Vec3) -> Mat4 {
        let z = normalize(eye - center)
        var x = normalize(cross(up, z))
        if length(x) < 1e-5 { x = Vec3(1, 0, 0) }
        let y = cross(z, x)
        return Mat4(
            Vec4(x.x, y.x, z.x, 0),
            Vec4(x.y, y.y, z.y, 0),
            Vec4(x.z, y.z, z.z, 0),
            Vec4(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1))
    }

    /// Rotation about the Y axis (yaw), used for world placed props.
    public static func rotationY(_ radians: Float) -> Mat4 {
        let c = cosf(radians), s = sinf(radians)
        return Mat4(
            Vec4(c, 0, -s, 0),
            Vec4(0, 1, 0, 0),
            Vec4(s, 0, c, 0),
            Vec4(0, 0, 0, 1))
    }

    /// Rotation about the X axis (pitch), used for weapon kick.
    public static func rotationX(_ radians: Float) -> Mat4 {
        let c = cosf(radians), s = sinf(radians)
        return Mat4(
            Vec4(1, 0, 0, 0),
            Vec4(0, c, s, 0),
            Vec4(0, -s, c, 0),
            Vec4(0, 0, 0, 1))
    }

    public static func mul(_ a: Mat4, _ b: Mat4) -> Mat4 { a * b }
}

// MARK: - Explicit uniform packing
//
// Metal structs and Swift structs do not always agree on padding, so uniforms
// are written at explicit byte offsets. The shader side documents the same
// offsets. This keeps the CPU/GPU contract honest across platforms.

public struct UniformWriter {
    public let bytes: UnsafeMutableRawPointer
    public init(_ pointer: UnsafeMutableRawPointer) { self.bytes = pointer }

    @inline(__always)
    public func float(_ offset: Int, _ value: Float) {
        bytes.storeBytes(of: value, toByteOffset: offset, as: Float.self)
    }

    @inline(__always)
    public func vec2(_ offset: Int, _ value: Vec2) {
        float(offset, value.x); float(offset + 4, value.y)
    }

    public func vec3(_ offset: Int, _ value: Vec3) {
        float(offset, value.x); float(offset + 4, value.y); float(offset + 8, value.z)
    }

    public func vec4(_ offset: Int, _ value: Vec4) {
        float(offset, value.x); float(offset + 4, value.y)
        float(offset + 8, value.z); float(offset + 12, value.w)
    }

    public func int32(_ offset: Int, _ value: Int32) {
        bytes.storeBytes(of: value, toByteOffset: offset, as: Int32.self)
    }

    /// Column major, 64 bytes, identical layout to simd_float4x4.
    public func mat4(_ offset: Int, _ value: Mat4) {
        vec4(offset + 0, value[0])
        vec4(offset + 16, value[1])
        vec4(offset + 32, value[2])
        vec4(offset + 48, value[3])
    }
}
