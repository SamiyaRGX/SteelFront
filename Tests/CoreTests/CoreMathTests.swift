import XCTest
@testable import Core

final class CoreMathTests: XCTestCase {

    func testVectorBasics() {
        let a = makeVec3(3, 0, 4)
        XCTAssertEqual(length(a), 5, accuracy: 1e-5)
        let n = normalize(a)
        XCTAssertEqual(length(n), 1, accuracy: 1e-5)
        XCTAssertEqual(cross(makeVec3(1, 0, 0), makeVec3(0, 1, 0)).z, 1, accuracy: 1e-5)
        XCTAssertEqual(dot(makeVec3(1, 2, 3), makeVec3(4, 5, 6)), 32, accuracy: 1e-5)
        XCTAssertEqual(length(normalize(Vec3.zero)), 0, accuracy: 1e-5)
    }

    func testDampConvergesToTarget() {
        var value: Float = 0
        for _ in 0..<200 { value = damp(value, 10, 8, 1.0 / 60) }
        XCTAssertEqual(value, 10, accuracy: 1e-3)
    }

    func testPerspectiveProjectsNearPlaneToUnitDepth() {
        let m = Mat.perspective(fovYRadians: .pi / 3, aspect: 16 / 9, near: 0.1, far: 200)
        let p = m * makeVec4(0, 0, -0.1, 1)
        XCTAssertEqual(p.z / p.w, 0, accuracy: 1e-4)
        let farPoint = m * makeVec4(0, 0, -200, 1)
        XCTAssertEqual(farPoint.z / farPoint.w, 1, accuracy: 1e-3)
        // Points in front of the camera must end up with positive w.
        XCTAssertGreaterThan(p.w, 0)
    }

    func testLookAtPlacesEyeAtOrigin() {
        let eye = makeVec3(1, 2, 3)
        let v = Mat.lookAt(eye: eye, center: makeVec3(0, 2, 0), up: makeVec3(0, 1, 0))
        let transformed = v * makeVec4(eye.x, eye.y, eye.z, 1)
        XCTAssertEqual(transformed.x, 0, accuracy: 1e-4)
        XCTAssertEqual(transformed.y, 0, accuracy: 1e-4)
        XCTAssertEqual(transformed.z, 0, accuracy: 1e-4)
    }

    func testAngleDampingTakesShortestPath() {
        let result = dampAngle(3.0, -3.0, 10, 1.0 / 60)
        // 3.0 -> -3.0 the short way wraps through pi, so we move upward.
        XCTAssertGreaterThan(result, 3.0)
    }

    func testUniformWriterMat4Layout() {
        let matrix = Mat.translation(makeVec3(5, 6, 7))
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
        defer { buffer.deallocate() }
        UniformWriter(buffer).mat4(0, matrix)
        let stored = buffer.load(fromByteOffset: 48, as: Float.self)
        XCTAssertEqual(stored, 5, accuracy: 1e-6)
        let storedZ = buffer.load(fromByteOffset: 56, as: Float.self)
        XCTAssertEqual(storedZ, 7, accuracy: 1e-6)
    }
}
