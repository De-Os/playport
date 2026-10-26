// SPDX-License-Identifier: GPL-3.0-or-later
// The virtual gamepad (a game's option, LaunchSettings.virtualPad): on a
// foldable's inner panel held upright (iPhone Duo), the game in the top half
// and an on-screen Xbox controller in the bottom one. It is an XInput pad like
// a GameController one: a slot of its own from the start of the launch (Unity
// lists controllers only when its input starts), its values through HostIO's
// gate, and Home held opens Playport's in-game menu (HostIO.menuInput). Folded
// or turned sideways the game has the whole panel and the pad rests.

#if canImport(UIKit)
import HostIO
import HostIOKit
import SwiftUI
import UIKit

@MainActor
final class VirtualGamepad: ObservableObject {
    static let shared = VirtualGamepad()

    /// The launching game has the option on, on a foldable.
    @Published private(set) var enabled = false
    private var slot: Int?
    private var last = PadInput()

    /// Before the launch: whether this game gets the pad.
    func prepare(_ on: Bool) { enabled = on }

    /// As the game's host I/O starts: the pad's slot, at rest.
    func connect() {
        guard enabled, slot == nil else { return }
        guard let s = HostIO.shared.connectSlot(ObjectIdentifier(VirtualGamepad.self)) else {
            HostIO.log("virtual gamepad: no free XInput slot")
            return
        }
        slot = s
        HostIO.publish(PadValues(), slot: s)
        HostIO.log("virtual gamepad: XInput slot \(s)")
    }

    /// The pad's controls now.
    func send(_ p: PadInput) {
        guard let slot, p != last else { return }
        last = p
        HostIO.shared.menuInput(p)
        HostIO.publish(PadMapping.values(p), slot: slot)
    }
}

/// The game above the pad when the option is on and the panel is upright
/// (only a foldable's inner panel turns to portrait during a game, AppDelegate);
/// the whole screen the game's otherwise.
struct GameArea: View {
    @ObservedObject private var pad = VirtualGamepad.shared

    var body: some View {
        GeometryReader { g in
            let split = pad.enabled && g.size.height > g.size.width
            VStack(spacing: 0) {
                GameSurface().frame(height: split ? (g.size.height * 0.5).rounded() : g.size.height)
                if split {
                    VirtualPadControls().frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.identity)
                }
            }
            .onChange(of: split) { _, on in if !on { VirtualGamepad.shared.send(PadInput()) } }
        }
        .background(Color.black)
    }
}

private struct VirtualPadControls: UIViewRepresentable {
    func makeUIView(context: Context) -> VirtualPadView { VirtualPadView() }
    func updateUIView(_ view: VirtualPadView, context: Context) {}
}

/// The controller's face, drawn and touched in one view so that several fingers
/// work at once and a finger slides from button to button: a stick follows the
/// finger that went down on it; any other finger presses what it is over.
/// A stick pressed again within 0.3 s of letting go is its click (LS, RS) while held.
/// Xbox's layout, or PlayStation's with the left stick and the d-pad swapped
/// (Settings › Controllers, dpadOnTopKey).
final class VirtualPadView: UIView {
    /// UserDefaults: the d-pad above the left stick.
    static let dpadOnTopKey = "virtualPad.dpadOnTop"

    private enum Control: Hashable {
        case leftStick, rightStick, dpad
        case a, b, x, y, lb, rb, lt, rt, back, start, home
    }

    private struct Stick {
        var center = CGPoint.zero, radius: CGFloat = 0
        var value = CGPoint.zero      // -1...1, +y down as on screen
        var touch: UITouch?
        var clicked = false
        var lastUp: TimeInterval = 0
    }

    private var left = Stick(), right = Stick()
    private var dpadCenter = CGPoint.zero, dpadArm: CGFloat = 0
    private var faceCenter = CGPoint.zero, faceOffset: CGFloat = 0, faceRadius: CGFloat = 0
    private var rects: [Control: CGRect] = [:]
    /// What each finger not on a stick presses.
    private var fingers: [UITouch: Set<Control>] = [:]
    private var pressed: Set<Control> = []
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.07, alpha: 1)
        isMultipleTouchEnabled = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("VirtualPadView is created in code") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let unit = min(w / 670, h / 470)
        // Shoulders along the top edge.
        let sw = 96 * unit, sh = 46 * unit, top = 12 * unit, edge = 18 * unit
        rects[.lt] = CGRect(x: edge, y: top, width: sw, height: sh)
        rects[.lb] = CGRect(x: edge + sw + 10 * unit, y: top, width: sw, height: sh)
        rects[.rb] = CGRect(x: w - edge - 2 * sw - 10 * unit, y: top, width: sw, height: sh)
        rects[.rt] = CGRect(x: w - edge - sw, y: top, width: sw, height: sh)
        // Back, Home, Start in the middle under them.
        let small = 44 * unit, my = top + sh + 30 * unit
        for (c, fx) in [(Control.back, 0.4), (.home, 0.5), (.start, 0.6)] {
            rects[c] = CGRect(x: w * fx - small / 2, y: my, width: small, height: small)
        }
        // Xbox layout: left stick and face buttons high, d-pad and right stick low;
        // PlayStation's has the d-pad high and the left stick low.
        let upper = h * 0.44, lower = h * 0.76
        let high = CGPoint(x: w * 0.19, y: upper), low = CGPoint(x: w * 0.36, y: lower)
        let dpadOnTop = UserDefaults.standard.bool(forKey: Self.dpadOnTopKey)
        left.center = dpadOnTop ? low : high
        left.radius = (dpadOnTop ? 70 : 78) * unit
        right.center = CGPoint(x: w * 0.64, y: lower)
        right.radius = 66 * unit
        dpadCenter = dpadOnTop ? high : low
        dpadArm = 64 * unit
        faceCenter = CGPoint(x: w * 0.81, y: upper)
        faceOffset = 56 * unit
        faceRadius = 30 * unit
        setNeedsDisplay()
    }

    // MARK: touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            if left.touch == nil, hits(left, p) {
                grab(&left, t, p)
            } else if right.touch == nil, hits(right, p) {
                grab(&right, t, p)
            } else {
                fingers[t] = controls(at: p)
            }
        }
        update()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            if t === left.touch { move(&left, p) }
            else if t === right.touch { move(&right, p) }
            else if fingers[t] != nil { fingers[t] = controls(at: p) }
        }
        update()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        for t in touches {
            if t === left.touch { release(&left, t) }
            else if t === right.touch { release(&right, t) }
            else { fingers[t] = nil }
        }
        update()
    }

    private func hits(_ s: Stick, _ p: CGPoint) -> Bool { hypot(p.x - s.center.x, p.y - s.center.y) <= s.radius * 1.35 }

    private func grab(_ s: inout Stick, _ t: UITouch, _ p: CGPoint) {
        s.touch = t
        s.clicked = t.timestamp - s.lastUp < 0.3
        move(&s, p)
    }

    private func move(_ s: inout Stick, _ p: CGPoint) {
        var v = CGPoint(x: (p.x - s.center.x) / s.radius, y: (p.y - s.center.y) / s.radius)
        let len = hypot(v.x, v.y)
        if len > 1 { v = CGPoint(x: v.x / len, y: v.y / len) }
        // A small dead zone, the rest rescaled so the edge is still full.
        let dead: CGFloat = 0.12
        let l = min(1, len)
        let scaled = l <= dead ? 0 : (l - dead) / (1 - dead)
        s.value = l == 0 ? .zero : CGPoint(x: v.x / max(l, 0.0001) * scaled, y: v.y / max(l, 0.0001) * scaled)
    }

    private func release(_ s: inout Stick, _ t: UITouch) {
        s.touch = nil
        s.value = .zero
        s.clicked = false
        s.lastUp = t.timestamp
    }

    /// What a finger at p presses: a button under it, a d-pad direction (eight
    /// ways), or the face button nearest to it.
    private func controls(at p: CGPoint) -> Set<Control> {
        for (c, r) in rects where r.insetBy(dx: -8, dy: -8).contains(p) { return [c] }
        let dx = p.x - dpadCenter.x, dy = p.y - dpadCenter.y
        // Its directions come from where the finger is (update()).
        if abs(dx) <= dpadArm * 1.5, abs(dy) <= dpadArm * 1.5, hypot(dx, dy) >= dpadArm * 0.2 { return [.dpad] }
        let fx = p.x - faceCenter.x, fy = p.y - faceCenter.y
        if abs(fx) <= faceOffset + faceRadius * 1.6, abs(fy) <= faceOffset + faceRadius * 1.6 {
            let face: [(Control, CGPoint)] = [(.a, CGPoint(x: 0, y: faceOffset)), (.b, CGPoint(x: faceOffset, y: 0)),
                                              (.x, CGPoint(x: -faceOffset, y: 0)), (.y, CGPoint(x: 0, y: -faceOffset))]
            let near = face.min { hypot(fx - $0.1.x, fy - $0.1.y) < hypot(fx - $1.1.x, fy - $1.1.y) }!
            return [near.0]
        }
        return []
    }

    /// The d-pad's directions held now.
    private var dpadDirection: (up: Bool, down: Bool, left: Bool, right: Bool) = (false, false, false, false)

    private func update() {
        var now: Set<Control> = []
        var dir = (up: false, down: false, left: false, right: false)
        for (t, cs) in fingers {
            now.formUnion(cs)
            if cs.contains(.dpad) {
                let p = t.location(in: self)
                let angle = atan2(p.y - dpadCenter.y, p.x - dpadCenter.x)
                // Eight ways: 0 is left, 2 up, 4 right, 6 down (the screen's +y is down).
                switch Int(((angle + .pi) / (.pi / 4)).rounded()) % 8 {
                case 0: dir.left = true
                case 1: dir.left = true; dir.up = true
                case 2: dir.up = true
                case 3: dir.up = true; dir.right = true
                case 4: dir.right = true
                case 5: dir.right = true; dir.down = true
                case 6: dir.down = true
                default: dir.down = true; dir.left = true
                }
            }
        }
        if !now.subtracting(pressed).isEmpty || dir.up && !dpadDirection.up || dir.down && !dpadDirection.down
            || dir.left && !dpadDirection.left || dir.right && !dpadDirection.right {
            haptic.impactOccurred()
        }
        pressed = now
        dpadDirection = dir
        var p = PadInput()
        p.a = now.contains(.a); p.b = now.contains(.b); p.x = now.contains(.x); p.y = now.contains(.y)
        p.leftShoulder = now.contains(.lb); p.rightShoulder = now.contains(.rb)
        p.leftTrigger = now.contains(.lt) ? 1 : 0; p.rightTrigger = now.contains(.rt) ? 1 : 0
        p.menu = now.contains(.start); p.options = now.contains(.back); p.home = now.contains(.home)
        p.up = dir.up; p.down = dir.down; p.left = dir.left; p.right = dir.right
        // XInput's +y is up, the screen's down.
        p.lx = Float(left.value.x); p.ly = Float(-left.value.y)
        p.rx = Float(right.value.x); p.ry = Float(-right.value.y)
        p.leftThumb = left.clicked; p.rightThumb = right.clicked
        VirtualGamepad.shared.send(p)
        setNeedsDisplay()
    }

    // MARK: drawing

    private static let rim = UIColor(white: 1, alpha: 0.28)
    private static let fill = UIColor(white: 1, alpha: 0.08)
    private static let lit = UIColor(white: 1, alpha: 0.32)
    private static let faceColors: [Control: UIColor] = [
        .a: UIColor(red: 0.42, green: 0.80, blue: 0.27, alpha: 1), .b: UIColor(red: 0.90, green: 0.29, blue: 0.25, alpha: 1),
        .x: UIColor(red: 0.25, green: 0.52, blue: 0.95, alpha: 1), .y: UIColor(red: 0.98, green: 0.78, blue: 0.20, alpha: 1),
    ]

    override func draw(_ rect: CGRect) {
        let unit = min(bounds.width / 670, bounds.height / 470)
        for (c, label) in [(Control.lt, "LT"), (.lb, "LB"), (.rb, "RB"), (.rt, "RT")] {
            guard let r = rects[c] else { continue }
            shape(UIBezierPath(roundedRect: r, cornerRadius: r.height / 2), on: pressed.contains(c))
            text(label, at: CGPoint(x: r.midX, y: r.midY), size: 17 * unit)
        }
        for (c, label) in [(Control.back, "⧉"), (.home, "⌂"), (.start, "≡")] {
            guard let r = rects[c] else { continue }
            shape(UIBezierPath(ovalIn: r), on: pressed.contains(c))
            text(label, at: CGPoint(x: r.midX, y: r.midY), size: 20 * unit)
        }
        stick(left, label: "L")
        stick(right, label: "R")
        // The d-pad: a plus, each arm lit when its direction is held.
        let a = dpadArm, half = a * 0.36
        let arms: [(CGRect, Bool)] = [
            (CGRect(x: dpadCenter.x - half, y: dpadCenter.y - a, width: 2 * half, height: a - half), dpadDirection.up),
            (CGRect(x: dpadCenter.x - half, y: dpadCenter.y + half, width: 2 * half, height: a - half), dpadDirection.down),
            (CGRect(x: dpadCenter.x - a, y: dpadCenter.y - half, width: a - half, height: 2 * half), dpadDirection.left),
            (CGRect(x: dpadCenter.x + half, y: dpadCenter.y - half, width: a - half, height: 2 * half), dpadDirection.right),
        ]
        shape(UIBezierPath(roundedRect: CGRect(x: dpadCenter.x - half, y: dpadCenter.y - half, width: 2 * half, height: 2 * half),
                           cornerRadius: 2), on: false, rim: false)
        for (r, on) in arms { shape(UIBezierPath(roundedRect: r, cornerRadius: 6 * unit), on: on) }
        // Face buttons.
        let face: [(Control, String, CGPoint)] = [
            (.a, "A", CGPoint(x: 0, y: faceOffset)), (.b, "B", CGPoint(x: faceOffset, y: 0)),
            (.x, "X", CGPoint(x: -faceOffset, y: 0)), (.y, "Y", CGPoint(x: 0, y: -faceOffset)),
        ]
        for (c, label, d) in face {
            let center = CGPoint(x: faceCenter.x + d.x, y: faceCenter.y + d.y)
            let r = CGRect(x: center.x - faceRadius, y: center.y - faceRadius, width: 2 * faceRadius, height: 2 * faceRadius)
            let on = pressed.contains(c)
            let color = Self.faceColors[c]!
            color.withAlphaComponent(on ? 0.85 : 0.22).setFill()
            UIBezierPath(ovalIn: r).fill()
            color.withAlphaComponent(0.9).setStroke()
            let path = UIBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
            text(label, at: center, size: 22 * unit, color: on ? .black : color)
        }
    }

    private func stick(_ s: Stick, label: String) {
        let base = UIBezierPath(ovalIn: CGRect(x: s.center.x - s.radius, y: s.center.y - s.radius,
                                               width: 2 * s.radius, height: 2 * s.radius))
        shape(base, on: false)
        let knob = s.radius * 0.48
        let c = CGPoint(x: s.center.x + s.value.x * (s.radius - knob * 0.6), y: s.center.y + s.value.y * (s.radius - knob * 0.6))
        let k = UIBezierPath(ovalIn: CGRect(x: c.x - knob, y: c.y - knob, width: 2 * knob, height: 2 * knob))
        (s.touch != nil ? Self.lit : UIColor(white: 1, alpha: 0.16)).setFill()
        k.fill()
        (s.clicked ? UIColor.white : Self.rim).setStroke()
        k.lineWidth = s.clicked ? 3 : 1.5
        k.stroke()
        text(label, at: c, size: knob * 0.6)
    }

    private func shape(_ path: UIBezierPath, on: Bool, rim: Bool = true) {
        (on ? Self.lit : Self.fill).setFill()
        path.fill()
        if rim {
            Self.rim.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    private func text(_ s: String, at p: CGPoint, size: CGFloat, color: UIColor = UIColor(white: 1, alpha: 0.85)) {
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color]
        let str = NSAttributedString(string: s, attributes: attrs)
        let sz = str.size()
        str.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
    }
}
#endif
