import XCTest
@testable import Core

final class DirectorTests: XCTestCase {

    func testThreatRisesOverTimeAndClamps() {
        let director = Director()
        // 200 simulated seconds: threat must saturate at the configured cap.
        for _ in 0..<2000 { director.update(dt: 0.1, aliveCount: 0) }
        XCTAssertEqual(director.elapsed, 200, accuracy: 0.5)
        XCTAssertEqual(director.threat, director.config.maxThreat, accuracy: 0.01)
        XCTAssertEqual(director.threatFraction, 1, accuracy: 0.001)
    }

    func testKillsAndDistanceBothAddThreat() {
        let a = Director()
        a.registerKill()
        XCTAssertGreaterThan(a.threat, 0)
        let beforeDistance = a.threat
        a.registerMovement(100)
        XCTAssertGreaterThan(a.threat, beforeDistance)
        XCTAssertEqual(a.distanceTravelled, 100, accuracy: 0.001)
        XCTAssertEqual(a.kills, 1)
    }

    func testSpawnPressureIncreasesWithThreat() {
        let director = Director()
        let earlyInterval = director.spawnInterval
        let earlyAlive = director.targetAlive
        for _ in 0..<5400 { director.update(dt: 1.0 / 60, aliveCount: 0) }
        XCTAssertLessThan(director.spawnInterval, earlyInterval)
        XCTAssertGreaterThan(director.targetAlive, earlyAlive)
        XCTAssertLessThanOrEqual(director.targetAlive, director.config.maxAlive)
        XCTAssertGreaterThan(director.difficulty, 1)
    }

    func testSpawnsStopOnceTargetPopulationIsReached() {
        let director = Director()
        for _ in 0..<600 { director.update(dt: 1.0 / 60, aliveCount: 999) }
        XCTAssertTrue(director.update(dt: 5, aliveCount: 999).isEmpty)
    }

    func testBruteArrivesOnTheKillCadence() {
        var config = DirectorConfig()
        config.bruteEveryKills = 5
        let director = Director(config: config)
        var brutes = 0
        for _ in 0..<10 {
            director.registerKill()
            let requests = director.update(dt: 10, aliveCount: 0)
            for r in requests {
                if case .enemy(let kind, _) = r, kind == .brute { brutes += 1 }
            }
        }
        XCTAssertEqual(brutes, 2, "expected a brute every 5 kills")
    }

    func testLateGameCompositionIncludesElites() {
        let director = Director()
        for _ in 0..<5400 { director.update(dt: 1.0 / 60, aliveCount: 0) }
        var rng = GameRandom(seed: 4242)
        var seen = Set<EnemyKind>()
        for _ in 0..<4000 { seen.insert(director.pickKind(using: &rng)) }
        XCTAssertTrue(seen.contains(.grunt))
        XCTAssertTrue(seen.contains(.heavy), "no heavies at max threat: \(seen)")
        XCTAssertTrue(seen.contains(.drone))
        XCTAssertTrue(seen.contains(.sniper))
    }

    func testEarlyGameIsMostlyGrunts() {
        let director = Director()
        var rng = GameRandom(seed: 7)
        var grunts = 0
        for _ in 0..<500 where director.pickKind(using: &rng) == .grunt { grunts += 1 }
        XCTAssertGreaterThan(grunts, 350)
    }

    func testSpawnPositionsStayInsideTheRingAndAvoidTheViewCone() {
        let director = Director()
        var rng = GameRandom(seed: 11)
        let facing = makeVec3(0, 0, 1)
        for _ in 0..<400 {
            let p = director.spawnPosition(around: makeVec3(50, 0, 50), rng: &rng,
                                           avoidDirection: facing)
            let d = distance2D(p, makeVec3(50, 0, 50))
            XCTAssertGreaterThanOrEqual(d, director.config.spawnRingMin - 0.01)
            XCTAssertLessThanOrEqual(d, director.config.spawnRingMax + 0.01)
            XCTAssertEqual(p.y, 0)
        }
    }

    func testPowerScaleGrowsWithThreat() {
        let director = Director()
        let early = director.powerScale()
        for _ in 0..<3600 { director.update(dt: 1.0 / 60, aliveCount: 0) }
        XCTAssertGreaterThan(director.powerScale(), early)
    }
}
