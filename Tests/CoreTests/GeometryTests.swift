import XCTest
@testable import Core

final class GeometryTests: XCTestCase {

    private func makeWorld() -> CollisionWorld {
        let world = CollisionWorld(cellSize: 8)
        // A 2 m tall crate at the origin.
        world.insert(Box(min: makeVec3(-1, 0, -1), max: makeVec3(1, 2, 1)))
        // A thin low wall 10 units down +Z (penetrable cover).
        world.insert(Box(min: makeVec3(-3, 0, 9.5), max: makeVec3(3, 0.9, 10.5)))
        return world
    }

    func testRayBoxSlabMath() {
        let box = Box(min: makeVec3(-1, -1, -1), max: makeVec3(1, 1, 1))
        let hit = CollisionWorld.rayBox(origin: makeVec3(0, 0, -5), direction: makeVec3(0, 0, 1), box: box)
        XCTAssertEqual(hit?.0 ?? -1, 4, accuracy: 1e-4)
        let miss = CollisionWorld.rayBox(origin: makeVec3(0, 5, -5), direction: makeVec3(0, 0, 1), box: box)
        XCTAssertNil(miss)
        // Ray starting inside the box reports distance 0.
        let inside = CollisionWorld.rayBox(origin: Vec3.zero, direction: makeVec3(1, 0, 0), box: box)
        XCTAssertEqual(inside?.0 ?? -1, 0, accuracy: 1e-4)
    }

    func testRaycastFindsNearestSurfaceAndNormal() {
        let world = makeWorld()
        let hit = world.raycast(origin: makeVec3(0, 1, -5), direction: makeVec3(0, 0, 1), maxDistance: 20)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit!.distance, 4, accuracy: 1e-3)
        XCTAssertEqual(hit!.normal.z, -1, accuracy: 1e-3)
    }

    func testRaycastMissReturnsNil() {
        let world = makeWorld()
        XCTAssertNil(world.raycast(origin: makeVec3(0, 1, -5), direction: makeVec3(0, 1, 0), maxDistance: 20))
    }

    func testThinCoverIsMarkedPenetrable() {
        let world = makeWorld()
        let hit = world.raycast(origin: makeVec3(0, 0.5, 5), direction: makeVec3(0, 0, 1), maxDistance: 20)
        XCTAssertEqual(hit?.penetrable ?? false, true)
    }

    func testLineOfSightIsBlockedByWall() {
        let world = CollisionWorld(cellSize: 8)
        world.insert(Box(min: makeVec3(-5, 0, 4), max: makeVec3(5, 3, 5)))
        XCTAssertFalse(world.lineOfSight(from: makeVec3(0, 1.6, 0), to: makeVec3(0, 1.6, 10)))
        XCTAssertTrue(world.lineOfSight(from: makeVec3(0, 1.6, 0), to: makeVec3(0, 1.6, 3)))
    }

    func testPlayerIsPushedOutOfSolidBox() {
        let world = makeWorld()
        var position = makeVec3(0.4, 0, 0) // overlapping the crate
        world.move(position: &position, radius: 0.42, height: 1.75, stepHeight: 0.75)
        // Pushed out to the crate surface (2 m tall, cannot be stepped onto from inside).
        let distanceFromCentre = sqrtf(position.x * position.x + position.z * position.z)
        XCTAssertGreaterThan(distanceFromCentre, 0.95)
    }

    func testPlayerStepsUpOntoLowCrate() {
        let world = CollisionWorld(cellSize: 8)
        world.insert(Box(min: makeVec3(-2, 0, -2), max: makeVec3(2, 0.6, 2)))
        var position = makeVec3(0, 0, 0)
        let result = world.move(position: &position, radius: 0.42, height: 1.75, stepHeight: 0.75)
        XCTAssertTrue(result.grounded)
        XCTAssertEqual(position.y, 0.6, accuracy: 1e-3)
    }

    func testPlayerCannotStepOntoTallWall() {
        let world = CollisionWorld(cellSize: 8)
        world.insert(Box(min: makeVec3(-2, 0, -2), max: makeVec3(2, 4, 2)))
        var position = makeVec3(3.0, 0, 0)
        let result = world.move(position: &position, radius: 0.42, height: 1.75, stepHeight: 0.75)
        XCTAssertEqual(position.y, 0, accuracy: 1e-3)
        XCTAssertFalse(result.grounded)
    }

    func testQueryReturnsOnlyNearbyBoxes() {
        let world = CollisionWorld(cellSize: 8)
        world.insert(Box(min: makeVec3(0, 0, 0), max: makeVec3(1, 1, 1)))
        world.insert(Box(min: makeVec3(200, 0, 200), max: makeVec3(201, 1, 201)))
        XCTAssertEqual(world.query(center: makeVec3(0.5, 0, 0.5), radius: 1).count, 1)
        XCTAssertEqual(world.boxCount, 2)
    }
}

extension GeometryTests {

    func testRaySphereHitAndMiss() {
        let hit = CollisionWorld.raySphere(origin: makeVec3(0, 0, -5), direction: makeVec3(0, 0, 1),
                                           center: Vec3.zero, radius: 1)
        XCTAssertEqual(hit ?? -1, 4, accuracy: 1e-3)
        let miss = CollisionWorld.raySphere(origin: makeVec3(0, 3, -5), direction: makeVec3(0, 0, 1),
                                            center: Vec3.zero, radius: 1)
        XCTAssertNil(miss)
        // Starting inside the sphere reports 0.
        let inside = CollisionWorld.raySphere(origin: Vec3.zero, direction: makeVec3(1, 0, 0),
                                              center: Vec3.zero, radius: 1)
        XCTAssertEqual(inside ?? -1, 0, accuracy: 1e-3)
    }

    func testRaySegmentHitsBodyAndMissesAroundIt() {
        let a = makeVec3(0, 0.2, 6)
        let b = makeVec3(0, 1.5, 6)
        let hit = CollisionWorld.raySegment(origin: makeVec3(0, 1, 0), direction: makeVec3(0, 0, 1),
                                            a: a, b: b, radius: 0.45)
        XCTAssertEqual(hit ?? -1, 5.55, accuracy: 0.05)

        let missHigh = CollisionWorld.raySegment(origin: makeVec3(0, 4, 0),
                                                 direction: makeVec3(0, 0, 1),
                                                 a: a, b: b, radius: 0.45)
        XCTAssertNil(missHigh)

        let missWide = CollisionWorld.raySegment(origin: makeVec3(2, 1, 0),
                                                 direction: makeVec3(0, 0, 1),
                                                 a: a, b: b, radius: 0.45)
        XCTAssertNil(missWide)
    }

    func testRaySegmentRespectsCapsuleEnds() {
        let a = makeVec3(0, 0.5, 6)
        let b = makeVec3(0, 1.5, 6)
        // Below the capsule but within the infinite line: must miss.
        let below = CollisionWorld.raySegment(origin: makeVec3(0, -1, 0),
                                              direction: makeVec3(0, 0, 1),
                                              a: a, b: b, radius: 0.45)
        XCTAssertNil(below)
    }
}
