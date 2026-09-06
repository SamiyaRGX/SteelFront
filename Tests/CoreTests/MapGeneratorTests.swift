import XCTest
@testable import Core

final class MapGeneratorTests: XCTestCase {

    func testGenerationIsDeterministicPerCell() {
        let a = MapGenerator(worldSeed: 4242)
        let b = MapGenerator(worldSeed: 4242)
        for cx in -6...6 {
            for cz in -6...6 {
                XCTAssertEqual(a.structures(cellX: cx, cellZ: cz), b.structures(cellX: cx, cellZ: cz),
                               "cell \(cx),\(cz) differed between two generators")
            }
        }
    }

    func testDifferentSeedsProduceDifferentMaps() {
        let a = MapGenerator(worldSeed: 1)
        let b = MapGenerator(worldSeed: 2)
        var differences = 0
        for cx in -8...8 {
            for cz in -8...8 where a.structures(cellX: cx, cellZ: cz) != b.structures(cellX: cx, cellZ: cz) {
                differences += 1
            }
        }
        XCTAssertGreaterThan(differences, 50, "two seeds produced nearly identical maps")
    }

    func testSpawnAreaStaysClear() {
        let map = MapGenerator(worldSeed: 77)
        for cx in -3...3 {
            for cz in -3...3 {
                for s in map.structures(cellX: cx, cellZ: cz) {
                    XCTAssertGreaterThanOrEqual(distance2D(s.center, Vec3.zero), map.spawnClearance - 1,
                                                "structure spawned inside the player start area")
                }
            }
        }
    }

    func testStructuresStayInsideTheirCell() {
        let map = MapGenerator(cellSize: 24, worldSeed: 909)
        for cx in -5...5 {
            for cz in -5...5 {
                for s in map.structures(cellX: cx, cellZ: cz) {
                    let minX = Float(cx) * 24 - 1
                    let maxX = Float(cx + 1) * 24 + 1
                    let minZ = Float(cz) * 24 - 1
                    let maxZ = Float(cz + 1) * 24 + 1
                    XCTAssertGreaterThanOrEqual(s.center.x, minX)
                    XCTAssertLessThanOrEqual(s.center.x, maxX)
                    XCTAssertGreaterThanOrEqual(s.center.z, minZ)
                    XCTAssertLessThanOrEqual(s.center.z, maxZ)
                    XCTAssertFalse(s.boxes.isEmpty, "\(s.kind) produced no collision")
                }
            }
        }
    }

    func testStructuresRestOnTheTerrain() {
        let map = MapGenerator(worldSeed: 31337)
        for cx in -4...4 {
            for cz in -4...4 {
                for s in map.structures(cellX: cx, cellZ: cz) {
                    // Every structure must have at least one box anchored in
                    // the ground; decks and door lintels may float by design.
                    var anchored = false
                    for box in s.boxes {
                        let ground = Terrain.height(at: box.center.x, box.center.z)
                        XCTAssertGreaterThanOrEqual(box.max.y, ground + 0.4,
                                                    "box is buried in the ground")
                        if box.min.y <= ground + 1.0 { anchored = true }
                    }
                    XCTAssertTrue(anchored, "\(s.kind) has no foundation")
                }
            }
        }
    }

    func testWorldHasEnoughCoverToFightAround() {
        let map = MapGenerator(worldSeed: 20260906)
        var boxes = 0
        var kinds = Set<Structure.Kind>()
        for cx in -8...8 {
            for cz in -8...8 {
                for s in map.structures(cellX: cx, cellZ: cz) {
                    boxes += s.boxes.count
                    kinds.insert(s.kind)
                }
            }
        }
        XCTAssertGreaterThan(boxes, 300)
        XCTAssertGreaterThanOrEqual(kinds.count, 5, "expected visual variety, got \(kinds)")
    }

    func testTerrainIsBoundedAndFlatNearSpawn() {
        XCTAssertEqual(Terrain.height(at: 0, 0), 0, accuracy: 1e-3)
        XCTAssertEqual(Terrain.height(at: 3, -4), 0, accuracy: 1e-3)
        for i in 0..<500 {
            let x = Float(i) * 3.1 - 700
            let z = Float(i) * -2.7 + 400
            let h = Terrain.height(at: x, z)
            XCTAssertGreaterThan(h, -3)
            XCTAssertLessThan(h, 3)
        }
    }
}
