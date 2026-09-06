//
//  HUDView.swift
//  SteelFront
//
//  The military HUD, drawn with Core Graphics so it stays crisp at any device
//  scale and needs no image assets: health and armour plates, ammo readout,
//  threat meter, kill feed, compass, damage direction indicator, hit markers
//  and the on-screen controls.
//

import Foundation
import UIKit
import QuartzCore

struct HUDState {
    var health: Float = 100
    var maxHealth: Float = 100
    var armour: Float = 0
    var maxArmour: Float = 100
    var weaponName = ""
    var magazine = 0
    var magazineSize = 1
    var reserve = 0
    var fireMode = ""
    var reloading = false
    var reloadProgress: Float = 0
    var kills = 0
    var score = 0
    var threat: Float = 0
    var combo: Int = 0
    var distance: Float = 0
    var elapsed: Float = 0
    var compassYaw: Float = 0
    var hitMarker: Float = 0
    var headshotMarker: Float = 0
    var damageFlash: Float = 0
    var damageDirection: Float = 0
    var enemiesAlive = 0
    var killFeed: [KillFeedEntry] = []
    var weaponSlots: [WeaponSlotHUD] = []
    var unlockedNotice: String?
    var isDead = false
    var bestScore = 0
    var fps = 0
}

struct KillFeedEntry {
    let text: String
    let age: Float
    let isHeadshot: Bool
}

struct WeaponSlotHUD {
    let shortName: String
    let selected: Bool
    let ammo: Int
}

final class HUDView: UIView {

    var state = HUDState() {
        didSet { setNeedsDisplay() }
    }

    /// Live controls, positioned on layout.
    var buttons: [ControlButton] = []
    var moveStickCenter = CGPoint.zero
    var moveStickVector = SIMD2<Float>(repeating: 0)
    var showMoveStick = false

    private let compactLayout: Bool
    private var fonts: [String: UIFont] = [:]

    init(compact: Bool) {
        self.compactLayout = compact
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentScaleFactor = UIScreen.main.scale
        buildButtons()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        buildButtons()
    }

    private func buildButtons() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        let scale: CGFloat = compactLayout ? 0.82 : 1.0
        let big: CGFloat = 96 * scale
        let small: CGFloat = 62 * scale
        let margin: CGFloat = 22 * scale
        let bottomSafe: CGFloat = max(margin, safeAreaInsets.bottom + 14)

        var list: [ControlButton] = []

        // Fire: large, bottom right.
        list.append(ControlButton(action: .fire, title: "FIRE",
                                  frame: CGRect(x: w - margin - big, y: h - bottomSafe - big,
                                                width: big, height: big)))
        // Aim, above fire.
        list.append(ControlButton(action: .aim, title: "ADS",
                                  frame: CGRect(x: w - margin - big - small - 14,
                                                y: h - bottomSafe - big + 8,
                                                width: small, height: small),
                                  isToggle: true))
        // Reload.
        list.append(ControlButton(action: .reload, title: "RLD",
                                  frame: CGRect(x: w - margin - small, y: h - bottomSafe - big - small - 18,
                                                width: small, height: small)))
        // Jump.
        list.append(ControlButton(action: .jump, title: "JMP",
                                  frame: CGRect(x: w - margin - big - small - 14,
                                                y: h - bottomSafe - big - small - 18,
                                                width: small, height: small)))
        // Sprint (toggle) bottom left, above the move area.
        list.append(ControlButton(action: .sprint, title: "RUN",
                                  frame: CGRect(x: margin, y: h - bottomSafe - big + 6,
                                                width: small, height: small),
                                  isToggle: true))
        // Weapon cycle.
        list.append(ControlButton(action: .cycleWeapon, title: "WPN",
                                  frame: CGRect(x: margin + small + 12, y: h - bottomSafe - big + 6,
                                                width: small, height: small)))
        // Fire mode.
        list.append(ControlButton(action: .fireMode, title: "MODE",
                                  frame: CGRect(x: margin, y: h - bottomSafe - big - small - 12,
                                                width: small, height: small)))

        // Weapon quick slots along the top left.
        let slotSize: CGFloat = 46 * scale
        for index in 0..<6 {
            list.append(ControlButton(action: .slot(index), title: "\(index + 1)",
                                      frame: CGRect(x: margin + CGFloat(index) * (slotSize + 8),
                                                    y: max(safeAreaInsets.top + 8, 12) + 34,
                                                    width: slotSize, height: slotSize * 0.72)))
        }
        buttons = list
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        drawDamageOverlay(ctx)
        drawCompass(ctx)
        drawVitals(ctx)
        drawAmmo(ctx)
        drawThreatMeter(ctx)
        drawKillFeed(ctx)
        drawCrosshairAndMarkers(ctx)
        drawWeaponSlots(ctx)
        drawButtons(ctx)
        drawMoveStick(ctx)
        if let notice = state.unlockedNotice { drawNotice(ctx, text: notice) }
        if state.isDead { drawDeathScreen(ctx) }
    }

    // MARK: Pieces

    private func drawDamageOverlay(_ ctx: CGContext) {
        let flash = CGFloat(state.damageFlash)
        guard flash > 0.01 else { return }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = max(bounds.width, bounds.height) * 0.75
        let colours = [UIColor(red: 0.6, green: 0, blue: 0, alpha: 0).cgColor,
                       UIColor(red: 0.55, green: 0.02, blue: 0.02, alpha: 0.55 * flash).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours,
                                     locations: [0.35, 1.0]) {
            ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: radius * 0.25,
                                   endCenter: centre, endRadius: radius, options: [])
        }
        // Low health pulse.
        if state.health < state.maxHealth * 0.3 {
            let pulse = 0.10 + 0.06 * sinf(Float(CACurrentMediaTime()) * 4)
            ctx.setFillColor(UIColor(red: 0.5, green: 0, blue: 0, alpha: CGFloat(pulse)).cgColor)
            ctx.fill(bounds)
        }
        // Directional damage indicator.
        if flash > 0.05 {
            let centrePoint = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius2: CGFloat = 92
            let angle = CGFloat(state.damageDirection)
            ctx.saveGState()
            ctx.translateBy(x: centrePoint.x, y: centrePoint.y)
            ctx.rotate(by: angle)
            ctx.setFillColor(UIColor(red: 1, green: 0.25, blue: 0.2, alpha: CGFloat(flash) * 0.8).cgColor)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 0, y: -radius2))
            ctx.addLine(to: CGPoint(x: -13, y: -radius2 - 26))
            ctx.addLine(to: CGPoint(x: 13, y: -radius2 - 26))
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    private func drawCompass(_ ctx: CGContext) {
        let width: CGFloat = min(bounds.width * 0.42, 320)
        let x = (bounds.width - width) * 0.5
        let y = max(safeAreaInsets.top + 6, 10)
        let plate = CGRect(x: x, y: y, width: width, height: 26)
        fillPlate(ctx, rect: plate, alpha: 0.42)

        ctx.saveGState()
        ctx.addRect(plate)
        ctx.clip()
        let labels: [(String, Float)] = [("N", 0), ("NE", 45), ("E", 90), ("SE", 135),
                                          ("S", 180), ("SW", 225), ("W", 270), ("NW", 315)]
        let degreesPerPoint: Float = 0.32
        for (label, degrees) in labels {
            var delta = degrees - state.compassYaw * 180 / .pi
            while delta > 180 { delta -= 360 }
            while delta < -180 { delta += 360 }
            let px = plate.midX + CGFloat(delta / degreesPerPoint)
            if px < plate.minX - 20 || px > plate.maxX + 20 { continue }
            let isCardinal = label.count == 1
            let colour = UIColor(white: isCardinal ? 0.98 : 0.72, alpha: isCardinal ? 1 : 0.7)
            drawText(label, at: CGPoint(x: px, y: plate.midY), size: isCardinal ? 13 : 10,
                     colour: colour, centered: true)
        }
        ctx.restoreGState()

        // Centre tick.
        ctx.setFillColor(UIColor(red: 1, green: 0.78, blue: 0.25, alpha: 0.95).cgColor)
        ctx.fill(CGRect(x: plate.midX - 1, y: plate.minY - 3, width: 2, height: 8))

        // Run stats under the compass.
        let stats = String(format: "KILLS %d    SCORE %d    %@    %d ALIVE",
                           state.kills, state.score, formatTime(state.elapsed), state.enemiesAlive)
        drawText(stats, at: CGPoint(x: bounds.midX, y: plate.maxY + 13), size: 11,
                 colour: UIColor(white: 0.9, alpha: 0.85), centered: true)
    }

    private func drawVitals(_ ctx: CGContext) {
        let margin: CGFloat = 22
        let y = bounds.height - max(safeAreaInsets.bottom + 14, margin) - 118
        let barWidth: CGFloat = compactLayout ? 150 : 210
        let plate = CGRect(x: margin - 8, y: y - 12, width: barWidth + 24, height: 108)
        fillPlate(ctx, rect: plate, alpha: 0.42)

        // Health.
        let healthFraction = CGFloat(clamp(state.health / state.maxHealth, 0, 1))
        drawBar(ctx, rect: CGRect(x: margin, y: y, width: barWidth, height: 15),
                fraction: healthFraction,
                colour: healthFraction > 0.5 ? UIColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1)
                    : (healthFraction > 0.25 ? UIColor(red: 0.95, green: 0.72, blue: 0.2, alpha: 1)
                                             : UIColor(red: 0.95, green: 0.25, blue: 0.2, alpha: 1)))
        drawText(String(format: "%d", Int(ceil(state.health))),
                 at: CGPoint(x: margin + 2, y: y - 13), size: 15,
                 colour: UIColor(white: 0.95, alpha: 1))
        drawText("VITALS", at: CGPoint(x: margin + barWidth, y: y - 13), size: 10,
                 colour: UIColor(white: 0.7, alpha: 0.8), rightAlignedAt: margin + barWidth)

        // Armour.
        let armourFraction = CGFloat(clamp(state.armour / state.maxArmour, 0, 1))
        drawBar(ctx, rect: CGRect(x: margin, y: y + 26, width: barWidth, height: 9),
                fraction: armourFraction,
                colour: UIColor(red: 0.35, green: 0.62, blue: 0.95, alpha: 1))
        drawText("ARMOUR", at: CGPoint(x: margin, y: y + 40), size: 9,
                 colour: UIColor(white: 0.7, alpha: 0.75))

        // Combo.
        if state.combo > 1 {
            drawText("x\(state.combo) CHAIN", at: CGPoint(x: margin, y: y + 58), size: 13,
                     colour: UIColor(red: 1, green: 0.78, blue: 0.25, alpha: 1))
        }
    }

    private func drawAmmo(_ ctx: CGContext) {
        let margin: CGFloat = 22
        let width: CGFloat = compactLayout ? 150 : 210
        let y = bounds.height - max(safeAreaInsets.bottom + 14, margin) - 118
        let x = bounds.width - margin - width
        let plate = CGRect(x: x - 12, y: y - 12, width: width + 24, height: 92)
        fillPlate(ctx, rect: plate, alpha: 0.42)

        drawText(state.weaponName.uppercased(), at: CGPoint(x: x, y: y - 11), size: 12,
                 colour: UIColor(white: 0.92, alpha: 1))
        drawText(state.fireMode, at: CGPoint(x: x + width, y: y - 11), size: 10,
                 colour: UIColor(red: 1, green: 0.78, blue: 0.25, alpha: 0.9),
                 rightAlignedAt: x + width)

        let magText = state.reloading ? "--" : String(state.magazine)
        drawText(magText, at: CGPoint(x: x, y: y + 8), size: 34,
                 colour: state.magazine == 0 && !state.reloading
                    ? UIColor(red: 0.95, green: 0.3, blue: 0.25, alpha: 1)
                    : UIColor.white)
        drawText("/ \(state.reserve)", at: CGPoint(x: x + 78, y: y + 26), size: 16,
                 colour: UIColor(white: 0.75, alpha: 0.9))

        if state.reloading {
            drawBar(ctx, rect: CGRect(x: x, y: y + 52, width: width, height: 6),
                    fraction: CGFloat(state.reloadProgress),
                    colour: UIColor(red: 1, green: 0.78, blue: 0.25, alpha: 1))
            drawText("RELOADING", at: CGPoint(x: x, y: y + 62), size: 10,
                     colour: UIColor(white: 0.85, alpha: 0.9))
        } else {
            // Magazine pips.
            let pips = min(state.magazineSize, 30)
            let pipWidth = width / CGFloat(max(pips, 1))
            for i in 0..<pips {
                let filled = i < state.magazine
                ctx.setFillColor((filled ? UIColor(white: 0.92, alpha: 0.95)
                                         : UIColor(white: 0.9, alpha: 0.18)).cgColor)
                ctx.fill(CGRect(x: x + CGFloat(i) * pipWidth, y: y + 52,
                                width: max(1, pipWidth - 1.5), height: 8))
            }
        }
    }

    private func drawThreatMeter(_ ctx: CGContext) {
        let width: CGFloat = min(bounds.width * 0.3, 220)
        let x = bounds.width - 22 - width
        let y = max(safeAreaInsets.top + 8, 12) + 76
        drawText("THREAT", at: CGPoint(x: x, y: y - 12), size: 9,
                 colour: UIColor(white: 0.75, alpha: 0.8))
        drawBar(ctx, rect: CGRect(x: x, y: y, width: width, height: 7),
                fraction: CGFloat(clamp(state.threat, 0, 1)),
                colour: UIColor(red: 0.95, green: 0.35, blue: 0.2, alpha: 1))
        drawText(String(format: "%.0fm", state.distance),
                 at: CGPoint(x: x + width, y: y + 12), size: 10,
                 colour: UIColor(white: 0.7, alpha: 0.7), rightAlignedAt: x + width)
    }

    private func drawKillFeed(_ ctx: CGContext) {
        let y = max(safeAreaInsets.top + 8, 12) + 108
        for (index, entry) in state.killFeed.prefix(5).enumerated() {
            let alpha = clamp(1 - entry.age / 3.2, 0, 1)
            let colour = entry.isHeadshot
                ? UIColor(red: 1, green: 0.78, blue: 0.25, alpha: CGFloat(alpha))
                : UIColor(white: 0.92, alpha: CGFloat(alpha) * 0.9)
            drawText(entry.text, at: CGPoint(x: bounds.width - 22, y: y + CGFloat(index) * 17),
                     size: 12, colour: colour, rightAlignedAt: bounds.width - 22)
        }
    }

    private func drawCrosshairAndMarkers(_ ctx: CGContext) {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let spread = CGFloat(6 + state.threat * 4)

        ctx.setLineWidth(1.6)
        ctx.setStrokeColor(UIColor(white: 1, alpha: 0.82).cgColor)
        for dx in [-1.0, 1.0] as [CGFloat] {
            ctx.move(to: CGPoint(x: centre.x + dx * spread, y: centre.y))
            ctx.addLine(to: CGPoint(x: centre.x + dx * (spread + 8), y: centre.y))
            ctx.move(to: CGPoint(x: centre.x, y: centre.y + dx * spread))
            ctx.addLine(to: CGPoint(x: centre.x, y: centre.y + dx * (spread + 8)))
        }
        ctx.strokePath()
        ctx.setFillColor(UIColor(white: 1, alpha: 0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: centre.x - 1, y: centre.y - 1, width: 2, height: 2))

        // Hit marker.
        if state.hitMarker > 0.01 {
            let alpha = CGFloat(state.hitMarker)
            let size: CGFloat = 9
            ctx.setStrokeColor(UIColor(white: 1, alpha: alpha).cgColor)
            ctx.setLineWidth(2.2)
            for dx in [-1.0, 1.0] as [CGFloat] {
                for dy in [-1.0, 1.0] as [CGFloat] {
                    ctx.move(to: CGPoint(x: centre.x + dx * 5, y: centre.y + dy * 5))
                    ctx.addLine(to: CGPoint(x: centre.x + dx * (5 + size), y: centre.y + dy * (5 + size)))
                }
            }
            ctx.strokePath()
        }
        if state.headshotMarker > 0.01 {
            let alpha = CGFloat(state.headshotMarker)
            ctx.setStrokeColor(UIColor(red: 1, green: 0.3, blue: 0.2, alpha: alpha).cgColor)
            ctx.setLineWidth(2.4)
            ctx.strokeEllipse(in: CGRect(x: centre.x - 14, y: centre.y - 14, width: 28, height: 28))
        }
    }

    private func drawWeaponSlots(_ ctx: CGContext) {
        let margin: CGFloat = 22
        let slotSize: CGFloat = compactLayout ? 46 * 0.82 : 46
        let y = max(safeAreaInsets.top + 8, 12) + 34
        for (index, slot) in state.weaponSlots.prefix(6).enumerated() {
            let rect = CGRect(x: margin + CGFloat(index) * (slotSize + 8), y: y,
                              width: slotSize, height: slotSize * 0.72)
            let selected = slot.selected
            fillPlate(ctx, rect: rect, alpha: selected ? 0.72 : 0.3)
            if selected {
                ctx.setStrokeColor(UIColor(red: 1, green: 0.78, blue: 0.25, alpha: 0.95).cgColor)
                ctx.setLineWidth(1.6)
                ctx.stroke(rect.insetBy(dx: 0.8, dy: 0.8))
            }
            drawText(slot.shortName, at: CGPoint(x: rect.midX, y: rect.midY - 3), size: 10,
                     colour: UIColor(white: selected ? 1 : 0.8, alpha: selected ? 1 : 0.75),
                     centered: true)
            drawText("\(slot.ammo)", at: CGPoint(x: rect.midX, y: rect.midY + 9), size: 9,
                     colour: UIColor(white: 0.7, alpha: 0.7), centered: true)
        }
    }

    private func drawButtons(_ ctx: CGContext) {
        for button in buttons {
            if case .slot = button.action { continue }   // drawn by drawWeaponSlots
            let alpha = button.isPressed ? 0.85 : button.alpha
            ctx.setFillColor(UIColor(white: 0.08, alpha: alpha * 0.55).cgColor)
            ctx.fillEllipse(in: button.frame)
            ctx.setStrokeColor(UIColor(white: 1, alpha: alpha * 0.55).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: button.frame.insetBy(dx: 1, dy: 1))
            if button.isToggle && button.state {
                ctx.setStrokeColor(UIColor(red: 1, green: 0.78, blue: 0.25, alpha: 0.9).cgColor)
                ctx.strokeEllipse(in: button.frame.insetBy(dx: 5, dy: 5))
            }
            drawText(button.title, at: CGPoint(x: button.frame.midX, y: button.frame.midY),
                     size: button.frame.width > 80 ? 17 : 12,
                     colour: UIColor(white: 1, alpha: alpha + 0.15), centered: true)
        }
    }

    private func drawMoveStick(_ ctx: CGContext) {
        guard showMoveStick else { return }
        let radius: CGFloat = 78
        let centre = moveStickCenter
        ctx.setStrokeColor(UIColor(white: 1, alpha: 0.25).cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                     width: radius * 2, height: radius * 2))
        let knob = CGPoint(x: centre.x + CGFloat(moveStickVector.x) * radius,
                           y: centre.y - CGFloat(moveStickVector.y) * radius)
        ctx.setFillColor(UIColor(white: 1, alpha: 0.28).cgColor)
        ctx.fillEllipse(in: CGRect(x: knob.x - 28, y: knob.y - 28, width: 56, height: 56))
    }

    private func drawNotice(_ ctx: CGContext, text: String) {
        let y = bounds.midY - bounds.height * 0.22
        drawText(text, at: CGPoint(x: bounds.midX, y: y), size: 20,
                 colour: UIColor(red: 1, green: 0.82, blue: 0.35, alpha: 1), centered: true)
    }

    private func drawDeathScreen(_ ctx: CGContext) {
        ctx.setFillColor(UIColor(white: 0, alpha: 0.62).cgColor)
        ctx.fill(bounds)
        drawText("KIA", at: CGPoint(x: bounds.midX, y: bounds.midY - 70), size: 56,
                 colour: UIColor(red: 0.9, green: 0.2, blue: 0.15, alpha: 1), centered: true)
        drawText(String(format: "KILLS %d     SCORE %d", state.kills, state.score),
                 at: CGPoint(x: bounds.midX, y: bounds.midY - 8), size: 22,
                 colour: .white, centered: true)
        drawText(String(format: "BEST %d     DISTANCE %.0fm     SURVIVED %@",
                        state.bestScore, state.distance, formatTime(state.elapsed)),
                 at: CGPoint(x: bounds.midX, y: bounds.midY + 22), size: 14,
                 colour: UIColor(white: 0.85, alpha: 0.9), centered: true)
        drawText("TAP TO REDEPLOY", at: CGPoint(x: bounds.midX, y: bounds.midY + 76), size: 16,
                 colour: UIColor(red: 1, green: 0.8, blue: 0.3, alpha: 1), centered: true)
    }

    // MARK: - Primitives

    private func fillPlate(_ ctx: CGContext, rect: CGRect, alpha: CGFloat) {
        ctx.setFillColor(UIColor(white: 0.04, alpha: alpha).cgColor)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 5)
        ctx.addPath(path.cgPath)
        ctx.fillPath()
        ctx.setStrokeColor(UIColor(white: 1, alpha: alpha * 0.35).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(path.cgPath)
        ctx.strokePath()
    }

    private func drawBar(_ ctx: CGContext, rect: CGRect, fraction: CGFloat, colour: UIColor) {
        ctx.setFillColor(UIColor(white: 1, alpha: 0.10).cgColor)
        ctx.fill(rect)
        ctx.setFillColor(colour.cgColor)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height))
        ctx.setStrokeColor(UIColor(white: 1, alpha: 0.25).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(rect)
    }

    private func drawText(_ text: String, at point: CGPoint, size: CGFloat, colour: UIColor,
                          centered: Bool = false, rightAlignedAt rightEdge: CGFloat? = nil) {
        let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: colour,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        var origin = point
        if centered {
            origin.x -= textSize.width * 0.5
        } else if let rightEdge {
            origin.x = rightEdge - textSize.width
        }
        origin.y -= textSize.height * 0.5
        attributed.draw(at: origin)
    }

    private func formatTime(_ seconds: Float) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
