import XCTest
@testable import Core

final class WeaponTests: XCTestCase {

    func testFiringConsumesMagazineAndRespectsFireRate() {
        var state = WeaponState(definition: WeaponCatalog.rifle)
        let start = state.magazineAmmo
        XCTAssertEqual(state.fire(aiming: false, moving: false), WeaponCatalog.rifle.pellets)
        XCTAssertEqual(state.magazineAmmo, start - 1)
        // Cooldown blocks the next shot in the same frame.
        XCTAssertEqual(state.fire(aiming: false, moving: false), 0)
        state.tick(1.0 / WeaponCatalog.rifle.fireRate + 0.01)
        XCTAssertEqual(state.fire(aiming: false, moving: false), 1)
    }

    func testShotgunFiresAllPellets() {
        var state = WeaponState(definition: WeaponCatalog.shotgun)
        XCTAssertEqual(state.fire(aiming: false, moving: false), WeaponCatalog.shotgun.pellets)
        XCTAssertEqual(state.magazineAmmo, WeaponCatalog.shotgun.magazine - 1)
    }

    func testEmptyMagazineTriggersAutomaticReloadAndRefillsFromReserve() {
        var state = WeaponState(definition: WeaponCatalog.sidearm)
        state.reserveAmmo = 100
        for _ in 0..<WeaponCatalog.sidearm.magazine {
            state.fire(aiming: false, moving: false)
            state.tick(1.0)
        }
        XCTAssertEqual(state.magazineAmmo, 0)
        XCTAssertTrue(state.isReloading)
        state.tick(WeaponCatalog.sidearm.reloadSeconds + 0.05)
        XCTAssertEqual(state.magazineAmmo, WeaponCatalog.sidearm.magazine)
        XCTAssertEqual(state.reserveAmmo, 100 - WeaponCatalog.sidearm.magazine)
    }

    func testDryFireWhenReserveIsEmpty() {
        var state = WeaponState(definition: WeaponCatalog.sidearm)
        state.magazineAmmo = 0
        state.reserveAmmo = 0
        XCTAssertEqual(state.fire(aiming: false, moving: false), 0)
        state.startReload()
        XCTAssertFalse(state.isReloading, "cannot reload with no reserve ammo")
    }

    func testRecoilBuildsAndRecovers() {
        var state = WeaponState(definition: WeaponCatalog.rifle)
        for _ in 0..<6 {
            state.fire(aiming: false, moving: false)
            state.tick(1.0 / WeaponCatalog.rifle.fireRate + 0.01)
        }
        let built = state.recoilPitch
        XCTAssertGreaterThan(built, 0)
        for _ in 0..<240 { state.tick(1.0 / 60) }
        XCTAssertLessThan(absf(state.recoilPitch), 0.001)
    }

    func testSpreadGrowsWhileFiringAndShrinksWhenAiming() {
        var state = WeaponState(definition: WeaponCatalog.smg)
        let base = state.effectiveSpread(aiming: false, moving: false)
        for _ in 0..<10 {
            state.fire(aiming: false, moving: false)
            state.tick(1.0 / WeaponCatalog.smg.fireRate + 0.01)
        }
        XCTAssertGreaterThan(state.effectiveSpread(aiming: false, moving: false), base)
        XCTAssertLessThan(state.effectiveSpread(aiming: true, moving: false),
                          state.effectiveSpread(aiming: false, moving: false))
        XCTAssertGreaterThan(state.effectiveSpread(aiming: false, moving: true),
                             state.effectiveSpread(aiming: false, moving: false))
    }

    func testBurstFireEmitsExtraRoundsOverTime() {
        let manager = WeaponManager()
        manager.select(WeaponCatalog.rifle.id)
        manager.current.fireMode = .burst
        XCTAssertEqual(manager.current.fire(aiming: false, moving: false), 1)
        var extra = 0
        for _ in 0..<60 { extra += manager.tick(1.0 / 60) }
        XCTAssertEqual(extra, WeaponCatalog.rifle.burstCount - 1,
                       "burst should continue for burstCount-1 follow up rounds")
    }

    func testFireModeCyclingOnlyForSupportedWeapons() {
        var rifle = WeaponState(definition: WeaponCatalog.rifle)
        let first = rifle.fireMode
        rifle.cycleFireMode()
        XCTAssertNotEqual(rifle.fireMode, first)

        var pistol = WeaponState(definition: WeaponCatalog.sidearm)
        pistol.cycleFireMode()
        XCTAssertEqual(pistol.fireMode, .semi)
    }

    func testWeaponsUnlockAsKillsRise() {
        let manager = WeaponManager()
        XCTAssertEqual(manager.unlocked.count, 3)
        var unlocked: [String] = []
        manager.onWeaponUnlocked = { unlocked.append($0.id) }
        manager.kills = 300
        XCTAssertEqual(manager.unlocked.count, WeaponCatalog.all.count)
        XCTAssertTrue(unlocked.contains("railgun"))
        XCTAssertTrue(unlocked.contains("rpg"))
        XCTAssertNotNil(manager.slots["shotgun"])
    }

    func testWeaponSwitchingCancelsReload() {
        let manager = WeaponManager()
        manager.current.magazineAmmo = 5
        manager.reload()
        XCTAssertTrue(manager.current.isReloading)
        manager.select(WeaponCatalog.sidearm.id)
        XCTAssertEqual(manager.currentID, "sidearm")
        XCTAssertFalse(manager.current.isReloading)
        XCTAssertFalse(manager.slots["rifle"]!.isReloading)
    }

    func testRefillReserveOnlyTouchesMatchingAmmo() {
        let manager = WeaponManager()
        manager.unlock(WeaponCatalog.shotgun)
        manager.slots["rifle"]?.reserveAmmo = 10
        manager.slots["shotgun"]?.reserveAmmo = 2
        manager.refillReserve(.shell, amount: 20)
        XCTAssertEqual(manager.slots["shotgun"]?.reserveAmmo, 22)
        XCTAssertEqual(manager.slots["rifle"]?.reserveAmmo, 10)
        manager.refillAll()
        XCTAssertEqual(manager.slots["rifle"]?.reserveAmmo, WeaponCatalog.rifle.reserveMax)
        XCTAssertEqual(manager.slots["shotgun"]?.magazineAmmo, WeaponCatalog.shotgun.magazine)
    }

    func testCatalogIsInternallyConsistent() {
        for def in WeaponCatalog.all {
            XCTAssertGreaterThan(def.damage, 0, "\(def.id) has no damage")
            XCTAssertGreaterThan(def.fireRate, 0, "\(def.id) cannot fire")
            XCTAssertGreaterThan(def.magazine, 0, "\(def.id) has no magazine")
            XCTAssertGreaterThan(def.reserveMax, def.magazine, "\(def.id) reserve too small")
            XCTAssertFalse(def.availableFireModes.isEmpty)
            if def.projectileSpeed > 0 {
                XCTAssertGreaterThan(def.blastRadius, 0, "\(def.id) projectile has no blast")
            }
            XCTAssertFalse(WeaponCatalog.definition(for: def.id) == nil)
        }
        // Every unlock threshold must reference a real weapon.
        for entry in WeaponCatalog.unlockThresholds {
            XCTAssertNotNil(WeaponCatalog.definition(for: entry.id))
        }
    }
}

