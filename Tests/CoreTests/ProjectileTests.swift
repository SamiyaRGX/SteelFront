import XCTest
@testable import Core

final class ProjectileTests: XCTestCase {

    func testRocketDetonatesOnImpact() {
        let system = ProjectileSystem()
        let world = CollisionWorld(cellSize: 8)
        world.insert(Box(min: makeVec3(-5, 0, 8), max: makeVec3(5, 5, 9)))
        system.spawn(.rocket, from: makeVec3(0, 1, 0), direction: makeVec3(0, 0, 1),
                     speed: 45, damage: 190, blastRadius: 10, proximity: 0)
        var exploded = 0
        for _ in 0..<120 {
            for e in system.update(dt: 1.0 / 60, world: world, playerPosition: Vec3.zero,
                                   enemies: []) {
                if case .explode = e { exploded += 1 }
            }
        }
        XCTAssertEqual(exploded, 1)
        XCTAssertEqual(system.count, 0)
    }

    func testGrenadeBouncesThenDetonatesOnFuse() {
        let system = ProjectileSystem()
        let world = CollisionWorld(cellSize: 8)
        // Lobbed upward so it lands on the terrain and bounces.
        system.spawn(.grenade, from: makeVec3(0, 1.5, 0), direction: makeVec3(0.3, 0.9, 1),
                     speed: 18, damage: 125, blastRadius: 7, gravity: 18, fuse: 3.0, bounces: 3)
        var impacts = 0
        var explodes = 0
        for _ in 0..<400 {
            for e in system.update(dt: 1.0 / 60, world: world, playerPosition: Vec3.zero,
                                   enemies: []) {
                switch e {
                case .impact: impacts += 1
                case .explode: explodes += 1
                }
            }
        }
        XCTAssertGreaterThan(impacts, 0, "grenade never bounced")
        XCTAssertEqual(explodes, 1, "grenade should detonate exactly once")
        XCTAssertEqual(system.count, 0)
    }

    func testProximityRocketDetonatesNearAnEnemy() {
        let system = ProjectileSystem()
        let world = CollisionWorld(cellSize: 8)
        let enemy = Enemy(id: 1, definition: EnemyRoster.grunt, position: makeVec3(0, 0, 12))
        system.spawn(.rocket, from: makeVec3(0, 1, 0), direction: makeVec3(0, 0, 1),
                     speed: 40, damage: 150, blastRadius: 8, proximity: 2.5)
        var exploded = false
        for _ in 0..<180 {
            for e in system.update(dt: 1.0 / 60, world: world, playerPosition: Vec3.zero,
                                   enemies: [enemy]) {
                if case .explode(let position, _, _, let fromPlayer, _) = e {
                    exploded = true
                    XCTAssertTrue(fromPlayer)
                    XCTAssertLessThan(absf(position.z - 12), 4)
                }
            }
        }
        XCTAssertTrue(exploded)
    }

    func testBlastFalloffDecreasesWithDistance() {
        let world = CollisionWorld(cellSize: 8)
        let centre = makeVec3(0, 1, 0)
        let near = ProjectileSystem.blastDamage(center: centre, radius: 10, damage: 100,
                                                target: makeVec3(1, 1, 0), world: world)
        let mid = ProjectileSystem.blastDamage(center: centre, radius: 10, damage: 100,
                                               target: makeVec3(5, 1, 0), world: world)
        let outside = ProjectileSystem.blastDamage(center: centre, radius: 10, damage: 100,
                                                   target: makeVec3(12, 1, 0), world: world)
        XCTAssertGreaterThan(near, mid)
        XCTAssertGreaterThan(mid, 0)
        XCTAssertEqual(outside, 0)
    }

    func testCoverReducesBlastDamage() {
        let world = CollisionWorld(cellSize: 8)
        world.insert(Box(min: makeVec3(-5, 0, 4), max: makeVec3(5, 4, 5)))
        let open = ProjectileSystem.blastDamage(center: makeVec3(0, 1, 0), radius: 12, damage: 100,
                                                target: makeVec3(0, 1, 3), world: world)
        let sheltered = ProjectileSystem.blastDamage(center: makeVec3(0, 1, 0), radius: 12,
                                                     damage: 100, target: makeVec3(0, 1, 8),
                                                     world: world)
        XCTAssertGreaterThan(open, sheltered, "cover should reduce splash damage")
    }

    func testProjectilesExpireAfterTheirLifetime() {
        let system = ProjectileSystem()
        let world = CollisionWorld(cellSize: 8)
        system.spawn(.grenade, from: makeVec3(0, 200, 0), direction: makeVec3(0, 1, 0),
                     speed: 200, damage: 100, blastRadius: 5, fuse: 99)
        var exploded = false
        for _ in 0..<1200 {
            for e in system.update(dt: 1.0 / 60, world: world, playerPosition: Vec3.zero,
                                   enemies: []) {
                if case .explode = e { exploded = true }
            }
        }
        XCTAssertTrue(exploded, "projectile should clean itself up")
        XCTAssertEqual(system.count, 0)
    }
}
