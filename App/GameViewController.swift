//
//  GameViewController.swift
//  SteelFront
//
//  The game loop: input, player movement, the endless director, enemy AI,
//  weapons and ballistics, effects and the frame assembly for the renderer.
//

import UIKit
import QuartzCore
import MetalKit
import simd
import AVFoundation

final class GameViewController: UIViewController {

    // MARK: - Systems

    private var metalView: MTKView!
    private var renderer: MetalRenderer?
    private var textures: TextureFactory?
    private var generator: MapGenerator!
    private var streamer: WorldStreamer!
    private var particles = ParticleSystem()
    private var projectiles = ProjectileSystem()
    private var audio: AudioEngine?
    private let input = InputController()
    private var hud: HUDView!

    // MARK: - Simulation state

    private let player = Player()
    private let weapons = WeaponManager()
    private var director = Director()
    private var enemies: [Enemy] = []
    private var pickups: [Pickup] = []
    private var lights: [TimedLight] = []
    private var enemyModels: [EnemyKind: EnemyModel] = [:]
    private var weaponModels: [String: Mesh] = [:]
    private var pickupMesh: Mesh?

    private var time: Float = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var nextEnemyID = 1
    private var score = 0
    private var combo = 0
    private var comboTimer: Float = 0
    private var killFeed: [KillFeedEntry] = []
    private var hitMarkerTimer: Float = 0
    private var headshotMarkerTimer: Float = 0
    private var adsBlend: Float = 0
    private var isDead = false
    private var bestScore: Int {
        get { UserDefaults.standard.integer(forKey: "steelfront.best") }
        set { UserDefaults.standard.set(newValue, forKey: "steelfront.best") }
    }
    private var pickupTimer: Float = 8
    private var wasFiringWhenDead = false
    private var notice: String?
    private var noticeTimer: Float = 0
    private var fpsAccumulator: Float = 0
    private var fpsFrames = 0
    private var fps = 60
    private var rng = GameRandom(seed: 0xC0FFEE)
    private var texturesReady = false

    // MARK: - Lifecycle

    override func loadView() {
        let frame = UIScreen.main.bounds
        let view = UIView(frame: frame)
        view.backgroundColor = UIColor(white: 0.05, alpha: 1)

        metalView = MTKView(frame: frame)
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .invalid
        metalView.sampleCount = 4
        metalView.preferredFramesPerSecond = 60
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.framebufferOnly = true
        metalView.delegate = self
        view.addSubview(metalView)

        let compact = min(frame.width, frame.height) < 400
        hud = HUDView(compact: compact)
        hud.frame = frame
        hud.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hud)

        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = MetalRenderer(device: device) else {
            showFatalError()
            return
        }
        self.renderer = renderer

        generator = MapGenerator()
        streamer = WorldStreamer(generator: generator, device: device)

        let factory = TextureFactory(device: device)
        textures = factory
        enemyModels = EnemyMesher.buildAll(device: device)
        for definition in WeaponCatalog.all {
            weaponModels[definition.id] = WeaponMesher.build(id: definition.id, device: device)
        }
        let pickupBuilder = MeshBuilder()
        pickupBuilder.addBox(min: SIMD3(-0.18, -0.18, -0.18), max: SIMD3(0.18, 0.18, 0.18),
                             uvScale: 1.2)
        pickupMesh = pickupBuilder.makeMesh(device: device)

        // Textures are the slowest part of start up; build them off the main
        // thread so the first frame is not blocked.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            factory.buildAll()
            DispatchQueue.main.async {
                self?.texturesReady = true
                self?.streamer.prime(around: self?.player.position ?? Vec3.zero)
            }
        }

        metalView.device = device
        configureInput()
        configureWeapons()
        player.onFootstep = { [weak self] in
            guard let self, self.player.grounded else { return }
            self.particles.landingDust(at: self.player.position,
                                       strength: self.player.sprinting ? 0.5 : 0.25)
            self.audio?.play(.impact, volume: 0.12, pitch: 0.6)
        }
        audio = AudioEngine()
        resetRun()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var shouldAutorotate: Bool { true }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        hud.frame = view.bounds
        metalView.frame = view.bounds
        input.layout.screenSize = view.bounds.size
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        input.startGyroscopeIfNeeded()
    }

    private func showFatalError() {
        let label = UILabel(frame: view.bounds)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.text = "Metal is not available on this device."
        view.addSubview(label)
    }

    // MARK: - Setup

    private func configureInput() {
        input.onWeaponSlotSelected = { [weak self] index in
            guard let self else { return }
            let unlocked = self.weapons.unlocked
            guard index < unlocked.count else { return }
            if self.weapons.select(unlocked[index]) {
                self.audio?.play(.reload, volume: 0.4, pitch: 1.4)
            }
        }
    }

    private func configureWeapons() {
        weapons.onWeaponUnlocked = { [weak self] definition in
            self?.notice = "\(definition.displayName) ACQUIRED"
            self?.noticeTimer = 3
            self?.audio?.play(.pickup, volume: 0.7)
        }
        weapons.onReloadStarted = { [weak self] _ in
            self?.audio?.play(.reload, volume: 0.8)
        }
        weapons.onWeaponSwitched = { [weak self] _ in
            self?.audio?.play(.reload, volume: 0.5, pitch: 1.2)
        }
    }

    private func resetRun() {
        enemies.removeAll()
        projectiles.clear()
        particles.clear()
        pickups.removeAll()
        lights.removeAll()
        killFeed.removeAll()

        player.position = Vec3(0, Terrain.height(at: 0, 0), 0)
        player.velocity = Vec3.zero
        player.yaw = 0
        player.pitch = 0
        player.health = player.config.maxHealth
        player.armour = 25
        player.stance = .standing
        weapons.refillAll()
        weapons.select(WeaponCatalog.rifle.id)
        director = Director()
        score = 0
        combo = 0
        isDead = false
        wasFiringWhenDead = false
        time = 0
        pickupTimer = 8
    }

    // MARK: - Frame

    private func update(dt: Float) {
        time += dt
        updateInputAndPlayer(dt: dt)
        updateWeapons(dt: dt)
        updateDirectorAndSpawns(dt: dt)
        updateEnemies(dt: dt)
        updateProjectiles(dt: dt)
        updatePickups(dt: dt)
        particles.update(dt: dt)
        updateLights(dt: dt)
        updateHUDState()

        comboTimer -= dt
        if comboTimer <= 0 { combo = 0 }
        hitMarkerTimer = max(0, hitMarkerTimer - dt * 3.4)
        headshotMarkerTimer = max(0, headshotMarkerTimer - dt * 3.4)
        noticeTimer = max(0, noticeTimer - dt)
        if noticeTimer <= 0 { notice = nil }

        for index in stride(from: killFeed.count - 1, through: 0, by: -1) {
            killFeed[index] = KillFeedEntry(text: killFeed[index].text,
                                            age: killFeed[index].age + dt,
                                            isHeadshot: killFeed[index].isHeadshot)
            if killFeed[index].age > 3.4 { killFeed.remove(at: index) }
        }
    }

    private func updateInputAndPlayer(dt: Float) {
        guard !isDead else {
            // "TAP TO REDEPLOY": any brand new touch restarts the run.
            // Touches already held at the moment of death do not count, so
            // there is no accidental instant restart.
            if input.freshTouch {
                resetRun()
            }
            input.endFrame()
            return
        }

        // Look: touch delta plus optional gyro.
        let look = input.lookDelta * input.lookSensitivity
        let gyro = input.consumeGyro() * dt
        player.yaw += look.x + gyro.x
        player.pitch = clamp(player.pitch - look.y - gyro.y, -.pi / 2 + 0.05, .pi / 2 - 0.05)
        if player.yaw > .pi { player.yaw -= .pi * 2 }
        if player.yaw < -.pi { player.yaw += .pi * 2 }

        player.aiming = input.aiming
        player.sprinting = input.sprinting && !input.aiming

        let speedMultiplier = weapons.currentDefinition.moveSpeedMultiplier
        player.updateMovement(wish: input.moveVector, jumpPressed: input.jumpQueued,
                              world: streamer.collision,
                              groundHeight: Terrain.height(at: player.position.x, player.position.z),
                              dt: dt, speedMultiplier: speedMultiplier)
        player.tickStatus(dt)
        director.registerMovement(length(player.velocity) * dt)

        streamer.update(around: player.position)
    }

    private func updateWeapons(dt: Float) {
        guard !isDead else { return }

        if input.reloadQueued { weapons.reload() }
        if input.fireModeQueued {
            weapons.current.cycleFireMode()
            audio?.play(.dryFire, volume: 0.5, pitch: 1.6)
        }
        for _ in 0..<input.weaponCycleQueued { weapons.cycle(1) }

        let burstPellets = weapons.tick(dt)
        if burstPellets > 0 {
            for _ in 0..<burstPellets { emitShot() }
        }

        if input.firing, weapons.current.isReady, !weapons.current.isReloading {
            if weapons.current.magazineAmmo > 0 {
                if weapons.current.fire(aiming: player.aiming,
                                        moving: length(player.velocity) > 1) > 0 {
                    emitShot()
                }
            } else {
                audio?.play(.dryFire, volume: 0.7)
                weapons.reload()
            }
        }

        // Aim down sights blend.
        let wantsADS = player.aiming && weapons.currentDefinition.zoomFOVDegrees != nil
        adsBlend = damp(adsBlend, wantsADS ? 1 : 0, 14, dt)
    }

    // MARK: - Shooting

    private func emitShot() {
        let state = weapons.current
        let definition = state.definition
        let spreadDegrees = state.effectiveSpread(aiming: player.aiming,
                                                  moving: length(player.velocity) > 1)
        let cone = spreadDegrees * .pi / 180

        let origin = player.eyePosition + player.forward * 0.35 + player.right * 0.12
        let muzzle = origin + player.forward * 0.55

        particles.muzzleFlash(at: muzzle, direction: player.forward,
                              scale: definition.viewKick * 0.8 + 0.4)
        addLight(at: muzzle, colour: SIMD3(1.0, 0.75, 0.42), radius: 7, life: 0.07,
                 intensity: 5.5 * definition.viewKick)
        particles.shellCasing(at: muzzle, right: player.right)
        audio?.play(shotSound(for: definition.id), volume: 0.9, pitch: rng.range(0.94, 1.06))
        player.shake = min(1.2, player.shake + definition.viewKick * 0.055)

        for _ in 0..<definition.pellets {
            let direction = spreadDirection(around: player.forward, cone: cone)
            if definition.projectileSpeed > 0 {
                projectiles.spawn(definition.id == "launcher" ? .grenade : .rocket,
                                  from: muzzle, direction: direction,
                                  speed: definition.projectileSpeed,
                                  damage: definition.blastDamage,
                                  blastRadius: definition.blastRadius,
                                  gravity: definition.id == "launcher" ? 15 : 0,
                                  fuse: definition.id == "launcher" ? 3.4 : 99,
                                  proximity: definition.id == "launcher" ? 0 : 1.6,
                                  bounces: definition.id == "launcher" ? 2 : 0)
                audio?.play(.shotLauncher, volume: 0.9)
            } else {
                hitscan(from: muzzle, direction: direction, definition: definition)
            }
        }
    }

    private func hitscan(from origin: Vec3, direction: Vec3, definition: WeaponDefinition) {
        let worldHit = streamer.collision.raycast(origin: origin, direction: direction,
                                                  maxDistance: definition.range)
        let blockedByCover = worldHit.map { $0.penetrable == false } ?? false
        let effectiveRange = (definition.supportsPenetration && !blockedByCover)
            ? definition.range
            : (worldHit?.distance ?? definition.range)

        let enemyHit = raycastEnemies(origin: origin, direction: direction,
                                      maxDistance: effectiveRange)

        if let hit = enemyHit {
            applyHit(to: hit.enemy, damage: definition.damage,
                     headshot: hit.headshot,
                     multiplier: definition.headshotMultiplier,
                     at: hit.point, direction: direction)
            particles.tracer(from: origin, to: hit.point, colour: SIMD4(1.0, 0.85, 0.5, 1))
            return
        }

        if let hit = worldHit, hit.distance <= effectiveRange + 0.01 {
            particles.impact(at: hit.point, normal: hit.normal, power: definition.viewKick)
            particles.tracer(from: origin, to: hit.point, colour: SIMD4(1.0, 0.85, 0.5, 1))
            audio?.play(.impact, volume: 0.35, pitch: rng.range(0.9, 1.2))
            return
        }
        // Fired into the sky.
        particles.tracer(from: origin, to: origin + direction * definition.range,
                         colour: SIMD4(1.0, 0.85, 0.5, 1))
    }

    private struct EnemyHit {
        let enemy: Enemy
        let distance: Float
        let headshot: Bool
        let point: Vec3
    }

    private func raycastEnemies(origin: Vec3, direction: Vec3,
                                maxDistance: Float) -> EnemyHit? {
        var best: EnemyHit?
        for enemy in enemies where !enemy.isDead {
            let scale = enemyModels[enemy.kind]?.scale ?? 1
            let definition = enemy.definition

            let headCenter = enemy.position
                + Vec3(0, (definition.height - definition.headRadius) * scale, 0)
            if let t = CollisionWorld.raySphere(origin: origin, direction: direction,
                                                center: headCenter,
                                                radius: definition.headRadius * scale * 1.15),
               t <= maxDistance, best == nil || t < best!.distance {
                best = EnemyHit(enemy: enemy, distance: t, headshot: true,
                                point: origin + direction * t)
            }

            let bodyLow = enemy.position + Vec3(0, 0.12 * scale, 0)
            let bodyHigh = enemy.position + Vec3(0, (definition.height - 0.20) * scale, 0)
            if let t = CollisionWorld.raySegment(origin: origin, direction: direction,
                                                 a: bodyLow, b: bodyHigh,
                                                 radius: definition.radius * scale),
               t <= maxDistance, best == nil || t < best!.distance {
                best = EnemyHit(enemy: enemy, distance: t, headshot: false,
                                point: origin + direction * t)
            }
        }
        return best
    }

    private func applyHit(to enemy: Enemy, damage: Float, headshot: Bool,
                          multiplier: Float, at point: Vec3, direction: Vec3) {
        let scaled = damage * (headshot ? multiplier : 1)
        let result = enemy.applyDamage(scaled, headshot: headshot)
        particles.blood(at: point, direction: direction)

        if headshot {
            headshotMarkerTimer = 1
            audio?.play(.headshot, volume: 0.75)
        } else {
            hitMarkerTimer = 1
            audio?.play(.flesh, volume: 0.5, pitch: rng.range(0.9, 1.15))
        }

        if result.killed {
            onEnemyKilled(enemy, headshot: headshot)
        }
    }

    private func onEnemyKilled(_ enemy: Enemy, headshot: Bool) {
        let base = enemy.definition.score
        combo += 1
        comboTimer = 4.5
        let multiplier = 1 + Float(min(combo, 20)) * 0.08
        let gained = Int(Float(base) * multiplier * (headshot ? 1.5 : 1))
        score += gained
        director.registerKill()
        weapons.kills = director.kills

        let name = enemy.definition.displayName.uppercased()
        killFeed.insert(KillFeedEntry(text: headshot ? "⌖ \(name) HEADSHOT +\(gained)"
                                                     : "\(name) +\(gained)",
                                      age: 0, isHeadshot: headshot), at: 0)
        if killFeed.count > 6 { killFeed.removeLast() }

        audio?.play(.death, volume: 0.5, pitch: rng.range(0.9, 1.1))

        if enemy.definition.explosiveOnDeath > 0 {
            applyExplosion(at: enemy.position + Vec3(0, enemy.definition.height * 0.4, 0),
                           radius: enemy.definition.explosiveOnDeath,
                           damage: 60, fromPlayer: false, source: enemy)
        }
        if rng.bool(0.28) { spawnPickup(near: enemy.position) }
    }

    // MARK: - Explosions

    private func applyExplosion(at position: Vec3, radius: Float, damage: Float,
                                fromPlayer: Bool, source: Enemy? = nil) {
        particles.explosion(at: position, radius: radius)
        addLight(at: position, colour: SIMD3(1.0, 0.55, 0.22), radius: radius * 3.2,
                 life: 0.55, intensity: 12)
        let distance = distance(position, player.eyePosition)
        audio?.play(.explosion, volume: clamp(1.4 - distance / 40, 0.05, 1), pitch: rng.range(0.9, 1.1))
        player.shake = min(1.5, player.shake + clamp(1.2 - distance / 25, 0, 1))

        for enemy in enemies where !enemy.isDead && enemy.id != source?.id {
            let target = enemy.position + Vec3(0, enemy.definition.height * 0.45, 0)
            let amount = ProjectileSystem.blastDamage(center: position, radius: radius,
                                                      damage: damage, target: target,
                                                      world: streamer.collision)
            guard amount > 1 else { continue }
            let result = enemy.applyDamage(amount, headshot: false)
            particles.blood(at: target, direction: normalize(target - position))
            if result.killed { onEnemyKilled(enemy, headshot: false) }
        }

        // The player takes splash too, so rockets demand respect.
        let selfDamage = ProjectileSystem.blastDamage(center: position, radius: radius,
                                                      damage: damage * 0.55,
                                                      target: player.eyePosition,
                                                      world: streamer.collision)
        if selfDamage > 1 {
            damagePlayer(selfDamage, from: normalize(player.position - position))
        }
    }

    private func damagePlayer(_ amount: Float, from direction: Vec3) {
        guard !isDead else { return }
        let outcome = player.takeDamage(amount, from: direction)
        audio?.play(.hurt, volume: clamp(amount / 40, 0.2, 1), pitch: rng.range(0.9, 1.1))
        if outcome.died {
            isDead = true
            audio?.play(.death, volume: 0.9, pitch: 0.7)
            if score > bestScore { bestScore = score }
        }
    }

    // MARK: - Director / spawning

    private func updateDirectorAndSpawns(dt: Float) {
        guard !isDead, texturesReady else { return }
        let requests = director.update(dt: dt, aliveCount: enemies.filter { !$0.isDead }.count)
        for request in requests {
            guard case .enemy(let kind, let powerScale) = request else { continue }
            spawnEnemy(kind: kind, powerScale: powerScale)
        }
    }

    private func spawnEnemy(kind: EnemyKind, powerScale: Float) {
        let forward = player.forwardFlat
        var position = director.spawnPosition(around: player.position, rng: &rng,
                                              avoidDirection: forward)
        // Keep spawns off the terrain surface and out of solid geometry.
        for _ in 0..<6 {
            position.y = Terrain.height(at: position.x, position.z)
            if streamer.collision.query(center: position, radius: 1.2,
                                        minY: position.y, maxY: position.y + 2).isEmpty {
                break
            }
            position = director.spawnPosition(around: player.position, rng: &rng,
                                              avoidDirection: forward)
        }
        position.y = Terrain.height(at: position.x, position.z)
        let enemy = Enemy(id: nextEnemyID, definition: EnemyRoster.definition(kind),
                          position: position, powerScale: powerScale)
        nextEnemyID += 1
        enemies.append(enemy)
        particles.landingDust(at: position, strength: 0.6)
    }

    private func updateEnemies(dt: Float) {
        guard texturesReady else { return }
        let context = EnemyBrain.Context(playerPosition: player.position,
                                         playerEye: player.eyePosition,
                                         world: streamer.collision,
                                         difficulty: director.difficulty)
        var survivors: [Enemy] = []
        survivors.reserveCapacity(enemies.count)

        for enemy in enemies {
            let actions = EnemyBrain.update(enemy, context: context, dt: dt, neighbours: enemies)
            enemy.tickTimers(dt)
            handle(actions: actions, from: enemy)

            if enemy.isDead {
                if enemy.deathTimer < 3.0 { survivors.append(enemy) }
                continue
            }
            // Despawn anything absurdly far away so the run never leaks.
            if distance2D(enemy.position, player.position) > 190 { continue }
            survivors.append(enemy)
        }
        enemies = survivors
    }

    private func handle(actions: [EnemyAction], from enemy: Enemy) {
        for action in actions {
            switch action {
            case .shot(let origin, let spread, let damage):
                enemyShoot(from: origin, spread: spread, damage: damage, enemy: enemy)
            case .melee(let damage):
                if distance2D(enemy.position, player.position) < 2.6 {
                    damagePlayer(damage, from: normalize(player.position - enemy.position))
                    player.shake = min(1.2, player.shake + 0.35)
                }
            case .telegraph:
                audio?.play(.drone, volume: 0.35, pitch: 1.3)
            case .explode(let position, let radius, let damage):
                applyExplosion(at: position, radius: radius, damage: damage,
                               fromPlayer: false, source: enemy)
            case .died:
                break
            }
        }
        // Laser sight while a sniper telegraphs its shot.
        if enemy.kind == .sniper, enemy.telegraphTimer > 0 {
            particles.tracer(from: enemy.eyePosition, to: player.eyePosition,
                             colour: SIMD4(1.0, 0.15, 0.1, 0.55))
        }
    }

    private func enemyShoot(from origin: Vec3, spread: Float, damage: Float, enemy: Enemy) {
        let target = player.eyePosition + Vec3(0, -0.25, 0)
        var direction = normalize(target - origin)
        direction = spreadDirection(around: direction, cone: spread * 0.09)

        let feet = player.position + Vec3(0, 0.2, 0)
        let head = player.position + Vec3(0, player.eyeHeight, 0)
        let worldHit = streamer.collision.raycast(origin: origin, direction: direction,
                                                  maxDistance: 220)
        let playerHit = CollisionWorld.raySegment(origin: origin, direction: direction,
                                                  a: feet, b: head,
                                                  radius: player.config.capsuleRadius)

        var endPoint = origin + direction * 120
        if let hit = worldHit { endPoint = origin + direction * hit.distance }

        if let hitDistance = playerHit, worldHit == nil || hitDistance < (worldHit?.distance ?? .infinity) {
            endPoint = origin + direction * hitDistance
            damagePlayer(damage, from: -direction)
        } else if let hit = worldHit {
            particles.impact(at: hit.point, normal: hit.normal, power: 0.5)
        }

        particles.tracer(from: origin, to: endPoint, colour: SIMD4(1.0, 0.45, 0.25, 0.9))
        addLight(at: origin, colour: SIMD3(1.0, 0.6, 0.3), radius: 4, life: 0.05, intensity: 2.2)
        audio?.play(.shotRifle, volume: clamp(0.55 - distance(origin, player.eyePosition) / 90,
                                              0.05, 0.55), pitch: rng.range(0.85, 1.1))
    }

    private func spreadDirection(around direction: Vec3, cone: Float) -> Vec3 {
        guard cone > 0.0001 else { return direction }
        let forward = normalize(direction)
        var helper = Vec3(0, 1, 0)
        if absf(dot(forward, helper)) > 0.9 { helper = Vec3(1, 0, 0) }
        let u = normalize(cross(forward, helper))
        let v = cross(forward, u)
        let angle = rng.range(0, .pi * 2)
        let tilt = rng.range(0, cone)
        return normalize(forward + (u * cosf(angle) + v * sinf(angle)) * tilt)
    }

    // MARK: - Projectiles

    private func updateProjectiles(dt: Float) {
        let events = projectiles.update(dt: dt, world: streamer.collision,
                                        playerPosition: player.position, enemies: enemies)
        for event in events {
            switch event {
            case .impact(let position, let normal, _):
                particles.impact(at: position, normal: normal, power: 0.6)
                audio?.play(.impact, volume: 0.4, pitch: 0.8)
            case .explode(let position, let radius, let damage, let fromPlayer, _):
                applyExplosion(at: position, radius: radius, damage: damage,
                               fromPlayer: fromPlayer)
            }
        }
    }

    // MARK: - Pickups

    private enum PickupKind {
        case health, armour, ammoLight, ammoRifle, ammoShell, ammoHeavy, ammoCell
    }

    private struct Pickup {
        var kind: PickupKind
        var position: Vec3
        var age: Float = 0
        var spin: Float
    }

    private func spawnPickup(near position: Vec3) {
        guard pickups.count < 8 else { return }
        let offset = rng.direction2D() * rng.range(0.6, 2.4)
        var spot = position + offset
        spot.y = Terrain.height(at: spot.x, spot.z) + 0.55
        let roll = rng.nextFloat()
        let kind: PickupKind
        switch roll {
        case ..<0.30: kind = .health
        case ..<0.45: kind = .armour
        case ..<0.62: kind = .ammoRifle
        case ..<0.76: kind = .ammoLight
        case ..<0.86: kind = .ammoShell
        case ..<0.95: kind = .ammoHeavy
        default: kind = .ammoCell
        }
        pickups.append(Pickup(kind: kind, position: spot, spin: rng.range(0, .pi * 2)))
    }

    private func updatePickups(dt: Float) {
        guard !isDead else { return }
        pickupTimer -= dt
        if pickupTimer <= 0 {
            pickupTimer = rng.range(9, 16)
            let offset = rng.direction2D() * rng.range(10, 26)
            var spot = player.position + offset
            spot.y = Terrain.height(at: spot.x, spot.z) + 0.55
            pickups.append(Pickup(kind: rng.bool(0.5) ? .health : .ammoRifle,
                                  position: spot, spin: rng.range(0, .pi * 2)))
        }

        var survivors: [Pickup] = []
        for var pickup in pickups {
            pickup.age += dt
            pickup.position.y = Terrain.height(at: pickup.position.x, pickup.position.z)
                + 0.55 + sinf(pickup.age * 2 + pickup.spin) * 0.12
            if distance2D(pickup.position, player.position) > 120 { continue }
            if pickup.age > 45 { continue }
            if distance(pickup.position, player.position + Vec3(0, 0.9, 0)) < 1.4 {
                collect(pickup)
                continue
            }
            survivors.append(pickup)
        }
        pickups = survivors
    }

    private func collect(_ pickup: Pickup) {
        audio?.play(.pickup, volume: 0.8, pitch: rng.range(0.95, 1.1))
        switch pickup.kind {
        case .health: player.heal(35)
        case .armour: player.addArmour(40)
        case .ammoLight: weapons.refillReserve(.light, amount: 90)
        case .ammoRifle: weapons.refillReserve(.rifle, amount: 90)
        case .ammoShell: weapons.refillReserve(.shell, amount: 16)
        case .ammoHeavy: weapons.refillReserve(.heavy, amount: 4)
        case .ammoCell: weapons.refillReserve(.cell, amount: 8)
        }
        particles.landingDust(at: pickup.position, strength: 0.4)
    }

    private func pickupTint(_ kind: PickupKind) -> SIMD4<Float> {
        switch kind {
        case .health: return SIMD4(0.35, 0.95, 0.45, 1)
        case .armour: return SIMD4(0.35, 0.65, 1.0, 1)
        case .ammoLight: return SIMD4(0.95, 0.85, 0.35, 1)
        case .ammoRifle: return SIMD4(0.95, 0.65, 0.25, 1)
        case .ammoShell: return SIMD4(0.9, 0.35, 0.25, 1)
        case .ammoHeavy: return SIMD4(0.75, 0.85, 0.95, 1)
        case .ammoCell: return SIMD4(0.45, 0.95, 1.0, 1)
        }
    }

    // MARK: - Lights

    private struct TimedLight {
        var position: SIMD3<Float>
        var colour: SIMD3<Float>
        var radius: Float
        var life: Float
        var maxLife: Float
        var intensity: Float
    }

    private func addLight(at position: SIMD3<Float>, colour: SIMD3<Float>, radius: Float,
                          life: Float, intensity: Float) {
        lights.append(TimedLight(position: position, colour: colour, radius: radius,
                                 life: life, maxLife: life, intensity: intensity))
        if lights.count > 12 { lights.removeFirst(lights.count - 12) }
    }

    private func updateLights(dt: Float) {
        for index in stride(from: lights.count - 1, through: 0, by: -1) {
            lights[index].life -= dt
            if lights[index].life <= 0 { lights.remove(at: index) }
        }
    }

    // MARK: - HUD

    private func updateHUDState() {
        let state = weapons.current
        var hudState = HUDState()
        hudState.health = player.health
        hudState.maxHealth = player.config.maxHealth
        hudState.armour = player.armour
        hudState.maxArmour = player.config.maxArmour
        hudState.weaponName = state.definition.shortName
        hudState.magazine = state.magazineAmmo
        hudState.magazineSize = state.definition.magazine
        hudState.reserve = state.reserveAmmo
        hudState.fireMode = state.fireMode.rawValue.uppercased()
        hudState.reloading = state.isReloading
        hudState.reloadProgress = state.isReloading
            ? 1 - state.reloadTimer / state.definition.reloadSeconds : 0
        hudState.kills = director.kills
        hudState.score = score
        hudState.threat = director.threatFraction
        hudState.combo = combo
        hudState.distance = director.distanceTravelled
        hudState.elapsed = director.elapsed
        hudState.compassYaw = player.yaw
        hudState.hitMarker = hitMarkerTimer
        hudState.headshotMarker = headshotMarkerTimer
        hudState.damageFlash = player.damageFlash
        hudState.damageDirection = atan2f(player.lastHitDirection.x, player.lastHitDirection.z)
            - player.yaw
        hudState.enemiesAlive = enemies.filter { !$0.isDead }.count
        hudState.killFeed = killFeed
        hudState.weaponSlots = weapons.unlocked.prefix(6).map { id in
            WeaponSlotHUD(shortName: WeaponCatalog.definition(for: id)?.shortName ?? id,
                          selected: id == weapons.currentID,
                          ammo: weapons.slots[id]?.magazineAmmo ?? 0)
        }
        hudState.unlockedNotice = notice
        hudState.isDead = isDead
        hudState.bestScore = bestScore
        hudState.fps = fps
        hudState.debugText = [
            "ATLAS \(textures?.atlas != nil ? "OK" : "NIL")  SPRITE \(textures?.spriteSheet != nil ? "OK" : "NIL")",
            "CHUNKS \(streamer.loadedCount)  DRAWS \(renderer?.lastFrameDrawCalls ?? -1)  FOE \(enemies.count)"
        ].joined(separator: "\n")
        hud.state = hudState

        hud.moveStickCenter = input.layout.moveCenter
        hud.moveStickVector = input.moveVector
        hud.showMoveStick = length(input.moveVector) > 0.02
        input.buttons = hud.buttons
    }

    // MARK: - Frame assembly

    private func buildFrame(dt: Float) -> RenderFrame {
        var frame = RenderFrame()

        // Camera with recoil, bob and damage shake.
        let recoilPitch = weapons.current.recoilPitch * .pi / 180
        let recoilYaw = weapons.current.recoilYaw * .pi / 180
        let shakeAmount = player.shake * 0.02
        let shakeX = sinf(time * 47) * shakeAmount
        let shakeY = cosf(time * 39) * shakeAmount
        let pitch = clamp(player.pitch + recoilPitch + shakeY, -.pi / 2, .pi / 2)
        let yaw = player.yaw + recoilYaw + shakeX

        let forward = Vec3(sinf(yaw) * cosf(pitch), sinf(pitch), cosf(yaw) * cosf(pitch))
        let bob = sinf(player.headBob) * 0.035
        let bobVertical = absf(cosf(player.headBob)) * 0.045
        let eye = player.eyePosition + Vec3(cosf(yaw) * bob, bobVertical, -sinf(yaw) * bob)

        let aspect = Float(metalView.drawableSize.width / max(1, metalView.drawableSize.height))
        let hipFOV: Float = 76 * .pi / 180
        let zoomFOV = (weapons.currentDefinition.zoomFOVDegrees ?? 76) * .pi / 180
        let fov = lerp(hipFOV, zoomFOV, adsBlend)
        frame.projMatrix = Mat.perspective(fovYRadians: fov, aspect: aspect, near: 0.08, far: 600)
        frame.viewMatrix = Mat.lookAt(eye: eye, center: eye + forward, up: Vec3(0, 1, 0))
        frame.cameraPosition = eye
        frame.fovScale = tanf(fov * 0.5)

        frame.viewModelProj = Mat.perspective(fovYRadians: 58 * .pi / 180, aspect: aspect,
                                              near: 0.01, far: 12)

        // Cold, hazy military palette.
        frame.sunDirection = SIMD4(normalize(SIMD3(0.42, 0.72, 0.32)), 1.85)
        frame.sunColour = SIMD4(1.0, 0.90, 0.74, 1)
        frame.skyColour = SIMD4(0.46, 0.55, 0.68, 0.38)
        frame.fog = SIMD4(0.58, 0.57, 0.52, 0.0052)
        frame.params = SIMD4(time, adsBlend > 0.5 ? 1.22 : 1.08, player.damageFlash, hitMarkerTimer)
        frame.atlas = textures?.atlas
        frame.spriteSheet = textures?.spriteSheet

        // --- Lights ---
        frame.lights = lights.sorted { $0.life / $0.maxLife > $1.life / $1.maxLife }
            .prefix(4).map { light in
                let fade = clamp(light.life / light.maxLife, 0, 1)
                return SceneLight(position: light.position,
                                  colour: light.colour * light.intensity * fade,
                                  radius: light.radius * (0.6 + fade * 0.4))
            }

        // --- Level ---
        let cameraForward = SIMD3(forward.x, forward.y, forward.z)
        let cullDistance = streamer.generator.cellSize * Float(streamer.radius + 1)
        for chunk in streamer.chunks.values {
            let delta = chunk.center - eye
            if length(delta) > cullDistance { continue }
            // Cheap hemisphere cull: skip cells directly behind the camera.
            if dot(delta, cameraForward) < -streamer.generator.cellSize { continue }
            for chunkMesh in chunk.meshes {
                var draw = SceneDraw(mesh: chunkMesh.mesh)
                draw.params = SIMD4(chunkMesh.tile, 1, 1, 0)
                frame.levelDraws.append(draw)
            }
        }

        // --- Enemies ---
        for enemy in enemies {
            guard let model = enemyModels[enemy.kind] else { continue }
            let delta = enemy.position - eye
            if length(delta) > cullDistance { continue }
            if dot(delta, cameraForward) < -4 { continue }

            let moveIntensity = clamp(length(enemy.velocity) / max(enemy.definition.speed, 0.1), 0, 1)
            let deathT = enemy.isDead ? clamp(enemy.deathTimer / 1.1, 0, 1) : 0
            let alpha = enemy.isDead ? max(0, 1 - max(0, enemy.deathTimer - 2.2) / 0.8) : 1

            let rotation = Mat.rotationY(enemy.yaw)
            let model_ = Mat.translation(enemy.position) * rotation
            var body = SceneDraw(mesh: model.body)
            body.model = model_
            body.tint = SIMD4(model.bodyTint.x, model.bodyTint.y, model.bodyTint.z, alpha)
            body.params = SIMD4(Float(MaterialTile.fabric.rawValue), 1.4, 1, 0)
            body.anim = SIMD4(enemy.walkPhase, enemy.isDead ? 0 : moveIntensity,
                              enemy.hitFlash, deathT)
            body.extra = SIMD4(0, enemy.yaw, model.scale, enemy.hasLineOfSight && !enemy.isDead ? 1 : 0)
            frame.enemyDraws.append(body)

            if let kit = model.kit {
                var kitDraw = SceneDraw(mesh: kit)
                kitDraw.model = model_
                kitDraw.tint = SIMD4(0.75, 0.76, 0.74, alpha)
                kitDraw.params = SIMD4(Float(MaterialTile.gunmetal.rawValue), 1.8, 1, 0)
                kitDraw.anim = body.anim
                kitDraw.extra = body.extra
                frame.enemyDraws.append(kitDraw)
            }
            if let glow = model.glow {
                var glowDraw = SceneDraw(mesh: glow)
                glowDraw.model = model_
                glowDraw.tint = SIMD4(1, 1, 1, alpha)
                glowDraw.params = SIMD4(Float(MaterialTile.gunmetal.rawValue), 1, 1, 1)
                glowDraw.anim = body.anim
                glowDraw.extra = body.extra
                frame.enemyDraws.append(glowDraw)
            }
        }

        // --- Pickups ---
        if let pickupMesh {
            for pickup in pickups {
                var draw = SceneDraw(mesh: pickupMesh)
                draw.model = Mat.translation(pickup.position)
                    * Mat.rotationY(pickup.age * 1.8 + pickup.spin)
                draw.tint = pickupTint(pickup.kind)
                draw.params = SIMD4(Float(MaterialTile.rivetPanel.rawValue), 2.0, 0.6, 0.85)
                frame.levelDraws.append(draw)
            }
        }

        // --- First person weapon ---
        if let weaponMesh = weaponModels[weapons.currentID] {
            var draw = SceneDraw(mesh: weaponMesh)
            let kick = weapons.current.kick
            let swayX = clamp(input.moveVector.x, -1, 1) * 0.012
            let bobX = sinf(player.headBob) * 0.008
            let bobY = absf(cosf(player.headBob)) * 0.008
            let hip = SIMD3<Float>(0.185 + bobX + swayX, -0.175 + bobY, -0.38 + kick * 0.06)
            let ads = SIMD3<Float>(0.0, -0.093, -0.24 + kick * 0.03)
            let position = mix(hip, ads, adsBlend)
            let pitchKick = -kick * 0.10 + player.pitch * 0.02
            draw.model = Mat.translation(SIMD3(position.x, position.y, position.z))
                * Mat.rotationY(.pi)
                * Mat.rotationX(pitchKick)
            draw.tint = SIMD4(1, 1, 1, 1)
            draw.params = SIMD4(Float(MaterialTile.gunmetal.rawValue), 3.0, 0.8, 0)
            frame.viewModelDraws.append(draw)
        }

        // --- Effects ---
        let right = normalize(cross(forward, Vec3(0, 1, 0)))
        let up = cross(right, forward)
        frame.fxBatch = particles.makeBatch(device: metalView.device!, right: right, up: up, eye: eye)

        return frame
    }

    private func shotSound(for weaponID: String) -> AudioEngine.Sound {
        switch weaponID {
        case "sidearm", "smg": return .shotLight
        case "shotgun": return .shotShotgun
        case "marksman": return .shotSniper
        case "launcher", "rpg": return .shotLauncher
        case "railgun": return .shotRail
        default: return .shotRifle
        }
    }
}

// MARK: - MTKViewDelegate

extension GameViewController: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // `size` is already expressed in pixels.
        renderer?.prepareTargets(size: size, view: view)
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        var dt = Float(now - lastFrameTime)
        lastFrameTime = now
        if dt <= 0 || dt > 0.25 { dt = 1.0 / 60.0 }

        fpsAccumulator += dt
        fpsFrames += 1
        if fpsAccumulator > 0.5 {
            fps = Int(Float(fpsFrames) / fpsAccumulator)
            fpsAccumulator = 0
            fpsFrames = 0
        }

        update(dt: dt)
        input.endFrame()

        guard let renderer, texturesReady else { return }
        let pixelSize = CGSize(width: view.drawableSize.width, height: view.drawableSize.height)
        renderer.prepareTargets(size: pixelSize, view: view)
        renderer.render(frame: buildFrame(dt: dt), view: view)
    }
}

// MARK: - Touch forwarding

extension GameViewController {

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        input.touchesBegan(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        input.touchesMoved(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        input.touchesEnded(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        input.touchesEnded(touches)
    }
}

private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
    a + (b - a) * t
}
