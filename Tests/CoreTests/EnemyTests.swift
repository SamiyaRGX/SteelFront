import XCTest
@testable import Core

final class EnemyTests: XCTestCase {

    private func flatWorld() -> CollisionWorld {
        CollisionWorld(cellSize: 8)
    }

    func testDamageAppliesArmourReduction() {
        let heavy = Enemy(id: 1, definition: EnemyRoster.heavy, position: Vec3.zero)
        let result = heavy.applyDamage(100, headshot: false)
        // Heavy has 30% armour.
        XCTAssertEqual(result.applied, 70, accuracy: 0.01)
        XCTAssertFalse(result.killed)
        XCTAssertGreaterThan(heavy.hitFlash, 0)
    }

    func testHeadshotsDoubleDamage() {
        let grunt = Enemy(id: 2, definition: EnemyRoster.grunt, position: Vec3.zero)
        let body = grunt.applyDamage(20, headshot: false)
        let head = grunt.applyDamage(20, headshot: true)
        XCTAssertEqual(head.applied, body.applied * 2, accuracy: 0.001)
    }

    func testEnemyDiesAtZeroHealthAndStaysDead() {
        let grunt = Enemy(id: 3, definition: EnemyRoster.grunt, position: Vec3.zero)
        grunt.applyDamage(500, headshot: false)
        XCTAssertTrue(grunt.isDead)
        XCTAssertEqual(grunt.health, 0)
        let after = grunt.applyDamage(100, headshot: false)
        XCTAssertEqual(after.applied, 0)
        XCTAssertFalse(after.killed)
    }

    func testPowerScaleIncreasesEffectiveHealth() {
        let base = Enemy(id: 4, definition: EnemyRoster.grunt, position: Vec3.zero)
        let scaled = Enemy(id: 5, definition: EnemyRoster.grunt, position: Vec3.zero, powerScale: 2)
        XCTAssertEqual(scaled.health, base.health * 2, accuracy: 0.01)
        XCTAssertEqual(scaled.healthFraction, 1, accuracy: 0.001)
    }

    func testGruntFiresWhenItHasLineOfSight() {
        let enemy = Enemy(id: 10, definition: EnemyRoster.grunt, position: makeVec3(0, 0, 10))
        enemy.spawnTimer = 0
        var context = EnemyBrain.Context(playerPosition: Vec3.zero,
                                         playerEye: makeVec3(0, 1.6, 0),
                                         world: flatWorld())
        var shots = 0
        for _ in 0..<400 {
            let actions = EnemyBrain.update(enemy, context: context, dt: 1.0 / 60)
            for a in actions {
                if case .shot = a { shots += 1 }
            }
        }
        XCTAssertGreaterThan(shots, 3)
        XCTAssertTrue(enemy.hasLineOfSight)
    }

    func testGruntStopsFiringWhenBlockedByCover() {
        let world = CollisionWorld(cellSize: 8)
        world.insert(Box(min: makeVec3(-10, 0, 4), max: makeVec3(10, 4, 5)))
        let enemy = Enemy(id: 11, definition: EnemyRoster.grunt, position: makeVec3(0, 0, 10))
        enemy.spawnTimer = 0
        let context = EnemyBrain.Context(playerPosition: Vec3.zero,
                                         playerEye: makeVec3(0, 1.6, 0),
                                         world: world)
        var shots = 0
        for _ in 0..<300 {
            for a in EnemyBrain.update(enemy, context: context, dt: 1.0 / 60) {
                if case .shot = a { shots += 1 }
            }
        }
        XCTAssertEqual(shots, 0, "enemy shot through a wall")
        XCTAssertFalse(enemy.hasLineOfSight)
    }

    func testSniperTelegraphsBeforeShooting() {
        let enemy = Enemy(id: 12, definition: EnemyRoster.sniper, position: makeVec3(0, 0, 40))
        enemy.spawnTimer = 0
        let context = EnemyBrain.Context(playerPosition: Vec3.zero,
                                         playerEye: makeVec3(0, 1.6, 0),
                                         world: flatWorld())
        var telegraphs = 0
        var shots = 0
        var telegraphFrame = -1
        var shotFrame = -1
        for frame in 0..<300 {
            for a in EnemyBrain.update(enemy, context: context, dt: 1.0 / 60) {
                switch a {
                case .telegraph:
                    telegraphs += 1
                    if telegraphFrame < 0 { telegraphFrame = frame }
                case .shot:
                    shots += 1
                    if shotFrame < 0 { shotFrame = frame }
                default: break
                }
            }
        }
        XCTAssertGreaterThan(telegraphs, 0)
        XCTAssertGreaterThan(shots, 0)
        XCTAssertGreaterThan(shotFrame, telegraphFrame, "sniper fired without telegraphing")
    }

    func testRusherClosesDistanceAndMelees() {
        let enemy = Enemy(id: 13, definition: EnemyRoster.rusher, position: makeVec3(0, 0, 12))
        enemy.spawnTimer = 0
        let context = EnemyBrain.Context(playerPosition: Vec3.zero,
                                         playerEye: makeVec3(0, 1.6, 0),
                                         world: flatWorld())
        var melees = 0
        for _ in 0..<600 {
            for a in EnemyBrain.update(enemy, context: context, dt: 1.0 / 60) {
                if case .melee = a { melees += 1 }
            }
        }
        XCTAssertGreaterThan(melees, 0, "rusher reached the player but never swung")
        XCTAssertLessThan(distance2D(enemy.position, Vec3.zero), 4,
                          "rusher did not hold contact range: \(enemy.position)")
    }

    func testSeekDirectionAvoidsWallDirectlyAhead() {
        let world = CollisionWorld(cellSize: 8)
        world.insert(Box(min: makeVec3(-6, 0, 2), max: makeVec3(6, 4, 3)))
        let enemy = Enemy(id: 14, definition: EnemyRoster.grunt, position: Vec3.zero)
        enemy.hasLineOfSight = false
        let context = EnemyBrain.Context(playerPosition: makeVec3(0, 0, 12),
                                         playerEye: makeVec3(0, 1.6, 12),
                                         world: world)
        enemy.spawnTimer = 0
        var movedSideways = false
        for _ in 0..<120 {
            _ = EnemyBrain.update(enemy, context: context, dt: 1.0 / 60)
            if absf(enemy.velocity.x) > 0.5 { movedSideways = true }
        }
        XCTAssertTrue(movedSideways, "enemy walked straight into a wall instead of around it")
    }

    func testDeadEnemiesStopActing() {
        let enemy = Enemy(id: 15, definition: EnemyRoster.grunt, position: makeVec3(0, 0, 8))
        enemy.spawnTimer = 0
        enemy.applyDamage(1000, headshot: false)
        let context = EnemyBrain.Context(playerPosition: Vec3.zero,
                                         playerEye: makeVec3(0, 1.6, 0),
                                         world: flatWorld())
        for _ in 0..<120 {
            XCTAssertTrue(EnemyBrain.update(enemy, context: context, dt: 1.0 / 60).isEmpty)
            enemy.tickTimers(1.0 / 60)
        }
        XCTAssertGreaterThan(enemy.deathTimer, 0)
    }
}
