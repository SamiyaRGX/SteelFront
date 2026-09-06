import XCTest
@testable import Core

final class RandomAndNoiseTests: XCTestCase {

    func testRandomIsDeterministicForSameSeed() {
        var a = GameRandom(seed: 1234)
        var b = GameRandom(seed: 1234)
        for _ in 0..<64 {
            XCTAssertEqual(a.nextUInt64(), b.nextUInt64())
        }
    }

    func testRandomDifferentSeedsDiverge() {
        var a = GameRandom(seed: 1)
        var b = GameRandom(seed: 2)
        var same = 0
        for _ in 0..<32 where a.nextUInt64() == b.nextUInt64() { same += 1 }
        XCTAssertLessThan(same, 2)
    }

    func testFloatAndIntRanges() {
        var rng = GameRandom(seed: 99)
        for _ in 0..<5000 {
            let f = rng.nextFloat()
            XCTAssertGreaterThanOrEqual(f, 0)
            XCTAssertLessThan(f, 1)
            let i = rng.int(3, 7)
            XCTAssertGreaterThanOrEqual(i, 3)
            XCTAssertLessThanOrEqual(i, 7)
            let r = rng.range(-2, 5)
            XCTAssertGreaterThanOrEqual(r, -2)
            XCTAssertLessThan(r, 5)
        }
    }

    func testDirection2DIsUnitLength() {
        var rng = GameRandom(seed: 7)
        for _ in 0..<500 {
            let d = rng.direction2D()
            XCTAssertEqual(length(d), 1, accuracy: 1e-4)
            XCTAssertEqual(d.y, 0, accuracy: 1e-6)
        }
    }

    func testHashIsStableAcrossCalls() {
        XCTAssertEqual(Hash.mix64(12, -5, 3), Hash.mix64(12, -5, 3))
        XCTAssertNotEqual(Hash.mix64(12, -5, 3), Hash.mix64(-5, 12, 3))
    }

    func testNoiseStaysInRangeAndIsDeterministic() {
        for i in 0..<400 {
            let x = Float(i) * 0.37
            let y = Float(i) * -0.21
            let v = Noise.fbm(x, y, octaves: 4, baseScale: 0.05)
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 1)
            XCTAssertEqual(v, Noise.fbm(x, y, octaves: 4, baseScale: 0.05))
            let r = Noise.ridged(x, y, octaves: 3, baseScale: 0.05)
            XCTAssertGreaterThanOrEqual(r, 0)
            XCTAssertLessThanOrEqual(r, 1)
        }
    }

    func testNoiseVariesOverDistance() {
        let a = Noise.fbm(0, 0, octaves: 4, baseScale: 0.05)
        let b = Noise.fbm(500, 500, octaves: 4, baseScale: 0.05)
        XCTAssertNotEqual(a, b)
    }
}
