// Drawing on the screen while talking. While ⌃⌥ is held, moving the cursor draws teal pen strokes (tapered,
// faster = thinner, with a soft glow) on a see-through panel over every screen: circle something, no clicking.
// A stroke counts only once it closes round something: it snaps shut (a glow pulse, a soft click, a trackpad tick)
// and stays. One circle per talk: after it snaps, the cursor stops drawing until the keys are let go. Lines and
// scribbles that never close fade on their own and are never sent. When the talk ends, the part of the screen with
// the circle is captured with it on it and sent with what was said; then it fades.
// The panels never take a click (macOS may not deliver one while ⌃⌥ is down anyway), and are off screen when empty.
import AppKit
import QuartzCore

private let accent = CGColor(srgbRed: 0x78 / 255, green: 1, blue: 0xe2 / 255, alpha: 1)
private let rim = CGColor(srgbRed: 0x03 / 255, green: 0x27 / 255, blue: 0x22 / 255, alpha: 0.6)

/// One pen stroke: points in its view's coordinates (top-left origin), drawn as a filled, tapered outline.
final class InkStroke {
    var pts: [CGPoint] = []
    var radii: [CGFloat] = []
    var done = false, closed = false
    let group = CALayer(), edge = CAShapeLayer(), fill = CAShapeLayer()

    init() {
        edge.fillColor = nil
        edge.strokeColor = rim
        edge.lineWidth = 2.5
        edge.lineJoin = .round
        fill.fillColor = accent
        fill.shadowColor = accent
        fill.shadowOpacity = 0.75
        fill.shadowRadius = 6
        fill.shadowOffset = .zero
        group.addSublayer(edge)
        group.addSublayer(fill)
        // Dimmer until it snaps shut, so it's clear when a mark has counted.
        group.opacity = 0.55
        for l in [group, edge, fill] { l.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "opacity": NSNull()] }
    }

    static let base: CGFloat = 2.8

    func add(_ p: CGPoint) {
        guard let last = pts.last else { pts = [p]; radii = [Self.base * 0.55]; redraw(); return }
        let d = hypot(p.x - last.x, p.y - last.y)
        if d < 2 { return }
        // A little smoothing takes the jitter out of a mouse or trackpad without lagging behind the pointer.
        let q = CGPoint(x: last.x + (p.x - last.x) * 0.65, y: last.y + (p.y - last.y) * 0.65)
        let speed = min(1, d / 40)
        let target = Self.base * (1.15 - 0.45 * speed) * min(1, 0.55 + CGFloat(pts.count) * 0.09)
        pts.append(q)
        radii.append(radii[radii.count - 1] * 0.7 + target * 0.3)
        redraw()
    }

    func finish() {
        done = true
        // Taper the tail, like a pen lifting off.
        let n = radii.count
        for k in 0 ..< min(6, n) { radii[n - 1 - k] *= 0.45 + 0.55 * CGFloat(k) / 6 }
        redraw()
    }

    /// Close the stroke into the loop that starts at pts[i], dropping what came before it (the run-up).
    func snap(from i: Int) {
        pts = Array(pts[i...]); radii = Array(radii[i...])
        pts.append(pts[0]); radii.append(radii[0])
        closed = true; done = true
        group.opacity = 1
        redraw()
    }

    func redraw() {
        let path = Self.outline(pts, radii)
        edge.path = path
        fill.path = path
    }

    /// The stroke's outline: offset both sides by the radius, join with curves, round caps at both ends.
    static func outline(_ p: [CGPoint], _ r: [CGFloat]) -> CGPath {
        let path = CGMutablePath()
        guard let first = p.first else { return path }
        if p.count == 1 {
            path.addEllipse(in: CGRect(x: first.x - r[0], y: first.y - r[0], width: r[0] * 2, height: r[0] * 2))
            return path
        }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0 ..< p.count {
            let a = p[max(0, i - 1)], b = p[min(p.count - 1, i + 1)]
            let len = max(0.0001, hypot(b.x - a.x, b.y - a.y))
            let n = CGPoint(x: -(b.y - a.y) / len, y: (b.x - a.x) / len)
            left.append(CGPoint(x: p[i].x + n.x * r[i], y: p[i].y + n.y * r[i]))
            right.append(CGPoint(x: p[i].x - n.x * r[i], y: p[i].y - n.y * r[i]))
        }
        func curve(_ q: [CGPoint]) {
            for i in 1 ..< max(1, q.count - 1) {
                path.addQuadCurve(to: CGPoint(x: (q[i].x + q[i + 1].x) / 2, y: (q[i].y + q[i + 1].y) / 2), control: q[i])
            }
            path.addLine(to: q[q.count - 1])
        }
        path.move(to: left[0])
        curve(left)
        let e = p[p.count - 1], le = left[left.count - 1]
        let endAngle = atan2(le.y - e.y, le.x - e.x)
        path.addArc(center: e, radius: r[r.count - 1], startAngle: endAngle, endAngle: endAngle - .pi, clockwise: true)
        curve(Array(right.reversed()))
        let startAngle = atan2(right[0].y - first.y, right[0].x - first.x)
        path.addArc(center: first, radius: r[0], startAngle: startAngle, endAngle: startAngle - .pi, clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// When a path closes round something: its newest point comes back near an earlier one, round a shape with room
/// inside it. A line, a line drawn back over itself, a zigzag or a tiny scribble never closes.
enum Loop {
    static let closeGap: CGFloat = 22, minRun: CGFloat = 110, minSide: CGFloat = 26, minFill: CGFloat = 0.3

    /// Where the loop the path has just closed starts (an index into p), or nil.
    static func closing(_ p: [CGPoint], gap: CGFloat = closeGap) -> Int? {
        guard p.count >= 8, let end = p.last else { return nil }
        var run: CGFloat = 0
        var i = p.count - 1
        while i > 0 {
            run += hypot(p[i].x - p[i - 1].x, p[i].y - p[i - 1].y)
            i -= 1
            if run >= minRun, hypot(p[i].x - end.x, p[i].y - end.y) <= gap, encloses(Array(p[i...])) { return i }
        }
        return nil
    }

    /// Big enough both ways, and its outline holds a fair share of its box (a closed zigzag or a sliver doesn't).
    static func encloses(_ q: [CGPoint]) -> Bool {
        guard q.count >= 3 else { return false }
        let xs = q.map(\.x), ys = q.map(\.y)
        let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
        guard w >= minSide, h >= minSide else { return false }
        var a: CGFloat = 0
        for k in 0 ..< q.count { let u = q[k], v = q[(k + 1) % q.count]; a += u.x * v.y - v.x * u.y }
        return abs(a) / 2 >= minFill * w * h
    }
}

/// The snap: a short, soft two-note chime with a click on the front, made once (quiet triangle tones, like the
/// app's own sound effects), plus a tick on a Force Touch trackpad.
enum SnapCue {
    static var soundOn = true
    private static let sound: NSSound? = {
        let rate = 44100.0, n = Int(rate * 0.16)
        var pcm = [Int16](repeating: 0, count: n)
        func tri(_ f: Double, _ t: Double) -> Double { let x = (t * f).truncatingRemainder(dividingBy: 1); return 4 * abs(x - 0.5) - 1 }
        for i in 0 ..< n {
            let t = Double(i) / rate
            var v = 0.0
            if t < 0.004 { v += Double.random(in: -1 ... 1) * 0.10 * (1 - t / 0.004) } // the click
            if t < 0.05 { v += tri(1318.5, t) * 0.16 * min(1, t / 0.002) * exp(-t * 40) } // E6
            if t >= 0.035 { let u = t - 0.035; v += tri(1568, u) * 0.14 * min(1, u / 0.003) * exp(-u * 28) } // G6
            pcm[i] = Int16(max(-1, min(1, v)) * 32767)
        }
        var d = Data()
        func le<T: FixedWidthInteger>(_ x: T) { withUnsafeBytes(of: x.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + n * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(rate)); le(UInt32(rate * 2)); le(UInt16(2)); le(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); le(UInt32(n * 2))
        pcm.forEach { le($0) }
        return NSSound(data: d)
    }()

    static func play() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        guard soundOn, let s = sound else { return }
        // Output is muted while listening (a setting): lift it just for the chime.
        OutputMute.lift(for: 0.2)
        s.stop(); s.play()
    }
}

final class InkView: NSView {
    var strokes: [InkStroke] = []
    var current: InkStroke?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func begin(at p: CGPoint) {
        end()
        let s = InkStroke()
        s.group.frame = bounds
        for l in [s.edge, s.fill] { l.frame = bounds }
        layer?.addSublayer(s.group)
        strokes.append(s)
        current = s
        s.add(p)
    }
    /// Adds the point; true when that closed the stroke into a loop (it has snapped and ended).
    @discardableResult
    func move(to p: CGPoint) -> Bool {
        guard let s = current else { return false }
        s.add(p)
        guard let i = Loop.closing(s.pts) else { return false }
        current = nil
        s.snap(from: i)
        pulse(s)
        SnapCue.play()
        return true
    }

    private func pulse(_ s: InkStroke) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let a = CABasicAnimation(keyPath: "shadowRadius")
        a.fromValue = 6; a.toValue = 16; a.duration = 0.16; a.autoreverses = true
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        s.fill.add(a, forKey: "snap")
    }

    /// The stroke ended (a pause, another screen, letting go): if it nearly closed, it snaps shut now; otherwise it
    /// was a line or a scribble, so it fades and never counts.
    /// Returns true when it snapped shut here.
    @discardableResult
    func end() -> Bool {
        guard let s = current else { return false }
        current = nil
        if let i = Loop.closing(s.pts, gap: Loop.closeGap * 1.8) {
            s.snap(from: i); pulse(s); SnapCue.play(); return true
        }
        s.finish()
        strokes.removeAll { $0 === s }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = s.group.opacity; a.toValue = 0; a.duration = 0.35
        CATransaction.begin()
        CATransaction.setCompletionBlock { s.group.removeFromSuperlayer() }
        s.group.opacity = 0
        s.group.add(a, forKey: "drop")
        CATransaction.commit()
        return false
    }
}

final class InkPanel: NSPanel {
    let view: InkView
    init(screen: NSScreen) {
        view = InkView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = view
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class Ink {
    private var panels: [InkPanel] = []
    private var armed = false
    // Following the cursor while armed: where it was, when it last moved, and the panel the stroke is on.
    private var last: CGPoint?, lastMoved = 0.0, onPanel: InkPanel?
    // A circle has snapped this talk: nothing more draws until the keys are let go.
    private var snapped = false
    private static let startAfter: CGFloat = 6, pauseEnds = 0.35
    // The capture of the last talk: under way, or done and waiting to be taken.
    private var pending = false, abandoned = false
    private var result: [String: Any]?
    private var waiter: (([String: Any]?) -> Void)?

    /// The mouse draws only while ⌃⌥ is down; otherwise clicks go to the apps underneath.
    func setArmed(_ on: Bool) {
        if on == armed { return }
        armed = on
        if on {
            syncScreens()
            for p in panels { p.orderFrontRegardless() }
            last = NSEvent.mouseLocation; lastMoved = ProcessInfo.processInfo.systemUptime; onPanel = nil; snapped = false
        } else {
            for p in panels {
                p.view.end()
                if p.view.strokes.isEmpty { p.orderOut(nil) }
            }
            last = nil; onPanel = nil
        }
    }

    /// Called every display tick: while armed, the cursor's path becomes ink. A stroke starts once the cursor has
    /// clearly moved (not a nudge) and ends after a short pause or on another screen.
    func follow() {
        guard armed, !snapped, let prev = last else { return }
        let m = NSEvent.mouseLocation, now = ProcessInfo.processInfo.systemUptime
        if let p = onPanel, now - lastMoved > Self.pauseEnds { snapped = p.view.end(); onPanel = nil; if snapped { return } }
        guard hypot(m.x - prev.x, m.y - prev.y) >= (onPanel == nil ? Self.startAfter : 0.5) else { return }
        last = m; lastMoved = now
        guard let p = panels.first(where: { NSMouseInRect(m, $0.frame, false) }) else { return }
        // The view is flipped: y runs down from the panel's top.
        let at = { (q: CGPoint) in CGPoint(x: q.x - p.frame.minX, y: p.frame.maxY - q.y) }
        if p !== onPanel {
            if onPanel?.view.end() == true { onPanel = nil; snapped = true; return }
            onPanel = p
            p.view.begin(at: at(prev))
        }
        if p.view.move(to: at(m)) { onPanel = nil; snapped = true }
    }

    private func syncScreens() {
        let frames = NSScreen.screens.map(\.frame)
        if panels.map(\.frame) == frames { return }
        // Screens changed: strokes on the old panels go with them.
        for p in panels { p.orderOut(nil) }
        panels = NSScreen.screens.map { InkPanel(screen: $0) }
    }

    /// Top-left of a screen in global points (CoreGraphics, origin at the main screen's top-left).
    private func origin(_ p: InkPanel) -> CGPoint {
        let mainH = NSScreen.screens.first?.frame.height ?? p.frame.height
        return CGPoint(x: p.frame.minX, y: mainH - p.frame.maxY)
    }

    /// The talk ended: shoot the marked part of the screen with the strokes still on it, then fade them.
    /// done: called on the main queue once the screen has been shot (straight away if nothing was drawn).
    func capture(then done: @escaping () -> Void = {}) {
        setArmed(false)
        // Only loops that snapped shut count (end() above already dropped the rest).
        let loops = { (p: InkPanel) in p.view.strokes.filter(\.closed) }
        guard let panel = panels.max(by: { loops($0).count < loops($1).count }), !loops(panel).isEmpty else { return done() }
        let o = origin(panel)
        let strokes = loops(panel)
        log("drawing: \(strokes.count) circled area(s) captured")
        var box = CGRect.null
        for s in strokes { for p in s.pts { box = box.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) } }
        box = box.insetBy(dx: -48, dy: -48)
        if box.width < 320 { box = box.insetBy(dx: -(320 - box.width) / 2, dy: 0) }
        if box.height < 220 { box = box.insetBy(dx: 0, dy: -(220 - box.height) / 2) }
        box = box.intersection(CGRect(origin: .zero, size: panel.frame.size)).integral
        let rect = box.offsetBy(dx: o.x, dy: o.y)
        // At most 48 points per stroke: plenty to tell a circle from a line.
        let marks: [[[Int]]] = strokes.map { s in
            let step = max(1, s.pts.count / 48)
            var picked = stride(from: 0, to: s.pts.count, by: step).map { s.pts[$0] }
            if let last = s.pts.last, picked.last != last { picked.append(last) }
            return picked.map { [Int(($0.x + o.x).rounded()), Int(($0.y + o.y).rounded())] }
        }
        let file = NSTemporaryDirectory() + "sidekick-marked-\(Int(Date().timeIntervalSince1970 * 1000)).png"
        pending = true; abandoned = false; result = nil
        let pen = CGWindowID(panel.windowNumber)
        // A beat first, so windows hidden for the shot (the listening pill) are off screen.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.06) {
            // Without BitJarvis in it, but with the pen strokes (shared/shot.swift); older macOS: screencapture.
            var ok = Shot.capture(rect, to: file, png: true, keep: [pen]) != nil
            if !ok {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-t", "png", "-R", "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", file]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                if (try? p.run()) != nil { p.waitUntilExit(); ok = p.terminationStatus == 0 && FileManager.default.fileExists(atPath: file) }
            }
            DispatchQueue.main.async {
                let area: [String: Any]? = ok ? ["file": file, "rect": [Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height)], "strokes": marks] : nil
                if !ok { log("marked-area capture failed (Screen Recording off?)") }
                done()
                self.pending = false
                if self.abandoned {
                    try? FileManager.default.removeItem(atPath: file)
                } else if let w = self.waiter {
                    self.waiter = nil
                    w(area)
                } else {
                    self.result = area
                }
                self.fade(strokes, in: panel, after: 0.5)
            }
        }
    }

    /// What was captured, once it's ready (nil: nothing was drawn, or the capture failed).
    func take(_ done: @escaping ([String: Any]?) -> Void) {
        if !pending { let r = result; result = nil; done(r); return }
        waiter = done
        // A stuck capture never holds up what was said.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard self.pending, let w = self.waiter else { return }
            self.waiter = nil; self.abandoned = true
            w(nil)
        }
    }

    /// The talk was dropped (a shortcut, or nothing said): wipe the strokes and anything captured.
    func clear() {
        setArmed(false)
        if let f = result?["file"] as? String { try? FileManager.default.removeItem(atPath: f) }
        result = nil
        if pending { abandoned = true; waiter = nil }
        for p in panels { fade(p.view.strokes, in: p, after: 0) }
    }

    private func fade(_ strokes: [InkStroke], in panel: InkPanel, after delay: Double) {
        guard !strokes.isEmpty else { return }
        panel.view.strokes.removeAll { s in strokes.contains { $0 === s } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                strokes.forEach { $0.group.removeFromSuperlayer() }
                if !self.armed && panel.view.strokes.isEmpty { panel.orderOut(nil) }
            }
            for s in strokes {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1; a.toValue = 0; a.duration = 0.45
                a.timingFunction = CAMediaTimingFunction(name: .easeIn)
                s.group.opacity = 0
                s.group.add(a, forKey: "fade")
            }
            CATransaction.commit()
        }
    }
}
