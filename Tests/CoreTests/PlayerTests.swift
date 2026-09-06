import XCTest
@testable import Core

final class PlayerTests: XCTestCase {

    func testArmourAbsorbsPartOfTheDamage() {
        let player = Player()
        player.armour = 100
        let outcome = player.takeDamage(50, from: makeVec3(1, 0, 0))
        XCTAssertEqual(outcome.armourUsed, 30, accuracy: 0.01)   // 60% absorb
        XCTAssertEqual(player.health, 80, accuracy: 0.01)        // 20 through
        XCTAssertEqual(player.armour, 70, accuracy: 0.01)
        XCTAssertFalse(outcome.died)
    }

    func testDeathAtZeroHealth() {
        let player = Player()
        let outcome = player.takeDamage(500, from: makeVec3(0, 0, 1))
        XCTAssertTrue(outcome.died)
        XCTAssertEqual(player.health, 0)
        XCTAssertFalse(player.isAlive)
        // Further damage is ignored.
        XCTAssertFalse(player.takeDamage(100, from: Vec3.zero).died)
    }

    func testRegenerationOnlyStartsAfterTheDelay() {
        let player = Player()
        player.takeDamage(60, from: makeVec3(1, 0, 0))
        let hurtHealth = player.health
        for _ in 0..<60 { player.tickStatus(1.0 / 60) }   // 1 second
        XCTAssertEqual(player.health, hurtHealth, accuracy: 0.001)
        for _ in 0..<60 * 6 { player.tickStatus(1.0 / 60) }
        XCTAssertGreaterThan(player.health, hurtHealth)
        for _ in 0..<60 * 20 { player.tickStatus(1.0 / 60) }
        XCTAssertEqual(player.health, player.config.maxHealth, accuracy: 0.01)
    }

    func testMovementAcceleratesTowardsWishDirection() {
        let player = Player()
        let world = CollisionWorld(cellSize: 8)
        for _ in 0..<90 {
            player.updateMovement(wish: makeVec2(0, 1), jumpPressed: false, world: world,
                                  groundHeight: 0, dt: 1.0 / 60)
        }
        let speed = sqrtf(player.velocity.x * player.velocity.x + player.velocity.z * player.velocity.z)
        XCTAssertEqual(speed, player.config.walkSpeed, accuracy: 0.4)
        // Moving forward along +Z with yaw 0.
        XCTAssertGreaterThan(player.velocity.z, 0)
        XCTAssertGreaterThan(player.position.z, 1)
    }

    func testSprintingIsFasterThanWalking() {
        let walking = Player()
        let sprinting = Player()
        for _ in 0..<120 {
            walking.updateMovement(wish: makeVec2(0, 1), jumpPressed: false,
                                   world: CollisionWorld(cellSize: 8), groundHeight: 0, dt: 1.0 / 60)
            sprinting.sprinting = true
            sprinting.updateMovement(wish: makeVec2(0, 1), jumpPressed: false,
                                     world: CollisionWorld(cellSize: 8), groundHeight: 0, dt: 1.0 / 60)
        }
        XCTAssertGreaterThan(sprinting.position.z, walking.position.z)
    }

    func testJumpRisesThenFalls() {
        let player = Player()
        let world = CollisionWorld(cellSize: 8)
        player.updateMovement(wish: makeVec2(0, 0), jumpPressed: true, world: world,
                              groundHeight: 0, dt: 1.0 / 60)
        var peak: Float = 0
        for _ in 0..<120 {
            player.updateMovement(wish: makeVec2(0, 0), jumpPressed: false, world: world,
                                  groundHeight: 0, dt: 1.0 / 60)
            peak = max(peak, player.position.y)
        }
        XCTAssertGreaterThan(peak, 0.6, "jump did not leave the ground")
        XCTAssertEqual(player.position.y, 0, accuracy: 0.02)
        XCTAssertTrue(player.grounded)
    }

    func testPlayerStopsInsideSolidGeometry() {
        let player = Player()
        let world = CollisionWorld(cellSize: 8)
        world.insert(Box(min: makeVec3(-5, 0, 4), max: makeVec3(5, 4, 5)))
        for _ in 0..<240 {
            player.updateMovement(wish: makeVec2(0, 1), jumpPressed: false, world: world,
                                  groundHeight: 0, dt: 1.0 / 60)
        }
        XCTAssertLessThan(player.position.z, 4.0, "player walked through a wall")
    }

    func testPlayerWalksOnTopOfTerrainHeight() {
        let player = Player(position: makeVec3(120, 10, -80))
        let world = CollisionWorld(cellSize: 8)
        for _ in 0..<60 {
            player.updateMovement(wish: makeVec2(0, 1), jumpPressed: false, world: world,
                                  groundHeight: Terrain.height(at: player.position.x, player.position.z),
                                  dt: 1.0 / 60)
        }
        XCTAssertEqual(player.position.y, Terrain.height(at: player.position.x, player.position.z),
                       accuracy: 0.05)
    }

    func testStanceChangesEyeHeight() {
        let player = Player()
        let standing = player.eyePosition.y
        player.stance = .crouched
        XCTAssertLessThan(player.eyePosition.y, standing)
    }

    func testHeadTracksLookDirection() {
        let player = Player()
        player.yaw = 0
        player.pitch = 0
        XCTAssertEqual(player.forward.z, 1, accuracy: 1e-4)
        player.yaw = .pi / 2
        XCTAssertEqual(player.forward.x, 1, accuracy: 1e-4)
        player.pitch = .pi / 4
        player.yaw = 0
        XCTAssertEqual(player.forward.y, sinf(.pi / 4), accuracy: 1e-4)
    }
}
