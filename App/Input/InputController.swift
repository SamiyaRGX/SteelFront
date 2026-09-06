//
//  InputController.swift
//  SteelFront
//
//  Touch controls: left thumb drives movement, the right half of the screen is
//  a look surface, with dedicated buttons for fire, jump, sprint, reload,
//  aim, weapon cycling and fire mode. Optional gyroscope fine aim on top.
//

import Foundation
import UIKit
import CoreMotion
import simd

final class InputController {

    // Normalised outputs read by the game loop.
    private(set) var moveVector = SIMD2<Float>(repeating: 0)
    private(set) var lookDelta = SIMD2<Float>(repeating: 0)
    private(set) var firing = false

    /// True for one frame after any new touch landed anywhere on screen.
    /// Used by the death screen ("TAP TO REDEPLOY"). Cleared by endFrame().
    private(set) var freshTouch = false
    private(set) var aiming = false
    private(set) var sprinting = false
    private(set) var jumpQueued = false
    private(set) var reloadQueued = false
    private(set) var weaponCycleQueued = 0
    private(set) var fireModeQueued = false
    var onWeaponSlotSelected: ((Int) -> Void)?

    // Sensitivity.
    var lookSensitivity: Float = 0.0032
    var gyroscopeEnabled = false
    var gyroscopeGain: Float = 1.4

    /// Layout metrics, in points, provided by the HUD.
    struct Layout {
        var moveCenter = CGPoint(x: 130, y: 0)
        var moveRadius: CGFloat = 78
        var screenSize = CGSize.zero
    }
    var layout = Layout()

    private var moveTouch: UITouch?
    private var lookTouch: UITouch?
    private var lastLookPoint = CGPoint.zero
    private var moveOrigin = CGPoint.zero
    private let motion = CMMotionManager()
    private var gyroYaw: Float = 0
    private var gyroPitch: Float = 0

    private var buttonTouches: [UITouch: ControlButton] = [:]
    var buttons: [ControlButton] = []

    // MARK: - Gyro

    func startGyroscopeIfNeeded() {
        guard gyroscopeEnabled, motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 100.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motionData, _ in
            guard let self, let rotation = motionData?.rotationRate else { return }
            self.gyroYaw = Float(rotation.z)
            self.gyroPitch = Float(rotation.x)
        }
    }

    func stopGyroscope() {
        motion.stopDeviceMotionUpdates()
    }

    func consumeGyro() -> SIMD2<Float> {
        let yaw = gyroYaw
        let pitch = gyroPitch
        gyroYaw = 0
        gyroPitch = 0
        let deadzone: Float = 0.06
        let y = absf(yaw) < deadzone ? 0 : yaw
        let p = absf(pitch) < deadzone ? 0 : pitch
        return SIMD2(y, p) * gyroscopeGain
    }

    // MARK: - Touch handling

    func touchesBegan(_ touches: Set<UITouch>) {
        if !touches.isEmpty { freshTouch = true }
        for touch in touches {
            let point = touch.location(in: touch.view)

            if let button = button(at: point) {
                button.isPressed = true
                buttonTouches[touch] = button
                handle(button: button, pressed: true)
                continue
            }

            // Left third starts a move stick; anywhere else on the right looks.
            if moveTouch == nil, point.x < layout.screenSize.width * 0.42,
               point.y > layout.screenSize.height * 0.22 {
                moveTouch = touch
                moveOrigin = point
                layout.moveCenter = point
                updateMoveVector(point)
            } else if lookTouch == nil {
                lookTouch = touch
                lastLookPoint = point
            }
        }
    }

    func touchesMoved(_ touches: Set<UITouch>) {
        for touch in touches {
            let point = touch.location(in: touch.view)
            if touch === moveTouch {
                updateMoveVector(point)
            } else if touch === lookTouch {
                let dx = Float(point.x - lastLookPoint.x)
                let dy = Float(point.y - lastLookPoint.y)
                lookDelta.x += dx
                lookDelta.y += dy
                lastLookPoint = point
            } else if let button = buttonTouches[touch] {
                let inside = button.frame.insetBy(dx: -14, dy: -14).contains(point)
                if inside != button.isPressed { button.isPressed = inside }
            }
        }
    }

    func touchesEnded(_ touches: Set<UITouch>) {
        for touch in touches {
            if touch === moveTouch {
                moveTouch = nil
                moveVector = SIMD2<Float>(repeating: 0)
            } else if touch === lookTouch {
                lookTouch = nil
            } else if let button = buttonTouches[touch] {
                let point = touch.location(in: touch.view)
                if button.frame.insetBy(dx: -14, dy: -14).contains(point) {
                    handle(button: button, pressed: false)
                }
                button.isPressed = false
                buttonTouches.removeValue(forKey: touch)
            }
        }
    }

    private func updateMoveVector(_ point: CGPoint) {
        let dx = Float(point.x - moveOrigin.x) / Float(layout.moveRadius)
        let dy = Float(point.y - moveOrigin.y) / Float(layout.moveRadius)
        var vector = SIMD2(dx, -dy)
        let magnitude = length(vector)
        if magnitude > 1 { vector /= magnitude }
        moveVector = vector
    }

    private func button(at point: CGPoint) -> ControlButton? {
        buttons.first { $0.frame.insetBy(dx: -12, dy: -12).contains(point) }
    }

    private func handle(button: ControlButton, pressed: Bool) {
        if button.isToggle {
            // Toggles flip on press and then drive their state continuously.
            if pressed { button.state.toggle() }
            switch button.action {
            case .aim: aiming = button.state
            case .sprint: sprinting = button.state
            default: break
            }
            return
        }
        switch button.action {
        case .fire: firing = pressed
        case .aim: aiming = pressed
        case .sprint: sprinting = pressed
        case .jump: if pressed { jumpQueued = true }
        case .reload: if pressed { reloadQueued = true }
        case .cycleWeapon: if pressed { weaponCycleQueued += 1 }
        case .fireMode: if pressed { fireModeQueued = true }
        case .slot(let index): if pressed { onWeaponSlotSelected?(index) }
        }
    }

    /// Called once per frame by the game loop.
    func endFrame() {
        lookDelta = SIMD2<Float>(repeating: 0)
        freshTouch = false
        jumpQueued = false
        reloadQueued = false
        weaponCycleQueued = 0
        fireModeQueued = false
    }
}

/// A round on-screen control.
final class ControlButton {
    enum Action: Equatable {
        case fire, aim, jump, sprint, reload, cycleWeapon, fireMode, slot(Int)
    }

    let action: Action
    let title: String
    var frame: CGRect
    var isPressed = false
    var state = false
    var isToggle: Bool
    var alpha: CGFloat = 0.55

    init(action: Action, title: String, frame: CGRect, isToggle: Bool = false) {
        self.action = action
        self.title = title
        self.frame = frame
        self.isToggle = isToggle
    }
}
