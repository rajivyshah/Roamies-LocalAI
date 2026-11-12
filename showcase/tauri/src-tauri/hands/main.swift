// Hands helper for BitJarvis (macOS): lets the agent see one window or app, read its controls, and type,
// press keys or click into it. One command per run; prints one JSON object. Runs as a child of BitJarvis,
// so macOS attributes Screen Recording and Accessibility to BitJarvis.
//
//   roamies-hands windows                      visible windows, front to back
//   roamies-hands capture <out.jpg> front|app:<name>|window:<id>|screen
//   roamies-hands locate front|app:<name>|window:<id>   which window that is, without capturing (for the animation)
//   roamies-hands select <out.png>             drag to choose an area (built-in macOS selection UI)
//   roamies-hands ui front|app:<name>          the window's buttons, fields, etc. with ids
//   roamies-hands act <json>                   {"app":"Brave","steps":[{"do":"focus","id":3},{"do":"type","text":"hi"}]}
//   roamies-hands trusted [--prompt]           Accessibility permission status
//   roamies-hands locate-control <target> <id>  where one control (from `ui`) is on screen, for pointing
//   roamies-hands screencheck                  takes (and deletes) one test screenshot: {"seen": true|false}
//   roamies-hands guide accessibility|screen [<Roamies.app>] [--preview]  drag-me-in panel under System Settings (until stdin closes)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers
import Vision

setvbuf(stdout, nil, _IOLBF, 0)
func out(_ o: [String: Any]) -> Never {
    giveBack()
    let d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
    print(String(data: d, encoding: .utf8) ?? "{}")
    exit(0)
}
func fail(_ msg: String) -> Never { out(["ok": false, "error": msg]) }

let me = ProcessInfo.processInfo.processIdentifier
let myParent = getppid()
// Never point at BitJarvis itself (its overlay windows cover every screen).
func isRoamies(_ pid: pid_t) -> Bool {
    pid == me || pid == myParent || NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.kenkai.roamies"
}

// ---------- windows ----------

struct Win { let id: Int; let pid: pid_t; let app: String; let title: String; let x, y, w, h: Double }

func windows() -> [Win] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let id = w[kCGWindowNumber as String] as? Int,
              let pid = w[kCGWindowOwnerPID as String] as? Int32, !isRoamies(pid),
              let b = w[kCGWindowBounds as String] as? [String: Double],
              (b["Width"] ?? 0) > 80, (b["Height"] ?? 0) > 60 else { return nil }
        return Win(id: id, pid: pid, app: (w[kCGWindowOwnerName as String] as? String) ?? "?",
                   title: (w[kCGWindowName as String] as? String) ?? "", x: b["X"] ?? 0, y: b["Y"] ?? 0, w: b["Width"] ?? 0, h: b["Height"] ?? 0)
    }
}

/// Fuzzy app match: "browser" finds the frontmost known browser; otherwise a case-insensitive name match.
let BROWSERS = ["Brave Browser", "Google Chrome", "Safari", "Arc", "Firefox", "Microsoft Edge", "Opera", "Vivaldi", "Chromium", "Orion", "Zen"]
func appMatches(_ app: String, _ want: String) -> Bool {
    let w = want.lowercased().trimmingCharacters(in: .whitespaces)
    if ["browser", "web browser", "my browser"].contains(w) { return BROWSERS.contains(app) }
    let a = app.lowercased()
    return a == w || a.contains(w) || w.contains(a)
}

/// Resolves a target to a window. "front" = the frontmost app that isn't BitJarvis.
func resolve(_ target: String) -> Win? {
    let w = resolveWin(target)
    if BG, let w { bgPid = w.pid }
    return w
}
/// An app's window to use, from its windows front to back: the frontmost one, passing over small untitled ones
/// floating above a much bigger window (CapCut's EditPilot button). Capturing one of those gave the big window's
/// picture with the button's bounds, so drawings landed squeezed into the button's corner.
func mainWindow(_ wins: [Win]) -> Win? {
    let big = wins.map { $0.w * $0.h }.max() ?? 0
    return wins.first { !$0.title.isEmpty || $0.w * $0.h >= big * 0.05 } ?? wins.first
}

// The same app's windows that opened over the plan's window (a new document, a dialog), front first, at most 3;
// all of that app's windows when the plan's window has closed. Never the older windows behind it.
func newerWindows(_ all: [Win], pinned: Win) -> [Win] {
    let own = all.filter { $0.pid == pinned.pid }
    return Array((own.firstIndex { $0.id == pinned.id }.map { own[..<$0] } ?? own[...]).prefix(3))
}

// The plan's window as it is now (it may have moved or been resized); once it has closed, that app's front window.
// nil: the app has no window open.
func currentWindow(_ all: [Win], pinned: Win) -> Win? {
    all.first { $0.id == pinned.id } ?? mainWindow(all.filter { $0.pid == pinned.pid })
}

/// What a window capture really shows, when it isn't just the window: macOS adds the window's child windows
/// (CapCut's EditPilot button hangs past its corner), so the picture covers both. nil: the window alone.
func shotArea(_ w: Win, _ all: [Win], _ px: [Int]) -> CGRect? {
    let own = CGRect(x: w.x, y: w.y, width: w.w, height: w.h)
    let group = all.filter { $0.pid == w.pid && $0.id != w.id }.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
        .filter { $0.intersects(own) }.reduce(own) { $0.union($1) }
    guard group != own, px.count == 2, px[1] > 0 else { return nil }
    let ratio = Double(px[0]) / Double(px[1]), off = { (r: CGRect) in abs(r.width / r.height - ratio) }
    return off(group) < off(own) ? group : nil
}

func resolveWin(_ target: String) -> Win? {
    let all = windows()
    if target == "front" {
        if let f = NSWorkspace.shared.frontmostApplication, !isRoamies(f.processIdentifier), let w = mainWindow(all.filter { $0.pid == f.processIdentifier }) { return w }
        return all.first
    }
    if target.hasPrefix("window:"), let id = Int(target.dropFirst(7)) { return all.first { $0.id == id } }
    if target.hasPrefix("app:") {
        let name = String(target.dropFirst(4))
        if let w = mainWindow(all.filter { appMatches($0.app, name) }) { return w }
        // Running but no visible window (hidden or minimised): bring it forward and look again.
        if let app = NSWorkspace.shared.runningApplications.first(where: { appMatches($0.localizedName ?? "", name) }) {
            app.unhide()
            app.activate(options: [.activateAllWindows])
            Thread.sleep(forTimeInterval: 0.6)
            return windows().first { $0.pid == app.processIdentifier }
        }
    }
    return nil
}

func winInfo(_ w: Win) -> [String: Any] { ["id": w.id, "app": w.app, "title": w.title, "bounds": [Int(w.x), Int(w.y), Int(w.w), Int(w.h)]] }

func run(_ path: String, _ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

// ---------- accessibility tree ----------

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
func str(_ el: AXUIElement, _ name: String) -> String? {
    guard let v = attr(el, name) else { return nil }
    if let s = v as? String { return s.isEmpty ? nil : s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}
/// Several attributes in one round trip to the app: each attr() call is its own message to the app, and walking a
/// web page makes thousands of them. Missing attributes come back nil. Falls back to one call each if the app refuses.
func attrs(_ el: AXUIElement, _ names: [String]) -> [AnyObject?] {
    var v: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &v) == .success,
          let arr = v as [AnyObject]?, arr.count == names.count else { return names.map { attr(el, $0) } }
    return arr.map { x in
        if x is NSNull { return nil }
        if CFGetTypeID(x) == AXValueGetTypeID(), AXValueGetType(x as! AXValue) == .axError { return nil }
        return x
    }
}
/// str() for a value already fetched.
func strOf(_ v: AnyObject?) -> String? {
    if let s = v as? String { return s.isEmpty ? nil : s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}
/// frame() from already-fetched position and size.
func frameOf(_ p: AnyObject?, _ s: AnyObject?) -> CGRect? {
    guard let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
    return CGRect(origin: pt, size: sz)
}
func frame(_ el: AXUIElement) -> CGRect? {
    guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
    return CGRect(origin: pt, size: sz)
}

let INTERACTIVE: Set<String> = ["AXButton", "AXTextField", "AXTextArea", "AXSearchField", "AXSecureTextField", "AXCheckBox", "AXRadioButton",
                                "AXPopUpButton", "AXComboBox", "AXMenuButton", "AXLink", "AXSlider", "AXTab", "AXDisclosureTriangle", "AXIncrementor",
                                "AXDateField", "AXTimeField", "AXDateTimeArea"]
let ROLE_NAME: [String: String] = ["AXButton": "button", "AXTextField": "text field", "AXTextArea": "text area", "AXSearchField": "search field",
                                   "AXSecureTextField": "password field", "AXCheckBox": "checkbox", "AXRadioButton": "radio", "AXPopUpButton": "dropdown",
                                   "AXComboBox": "combo box", "AXMenuButton": "menu button", "AXLink": "link", "AXSlider": "slider", "AXTab": "tab",
                                   "AXDisclosureTriangle": "disclosure", "AXIncrementor": "stepper",
                                   "AXDateField": "date field", "AXTimeField": "time field", "AXDateTimeArea": "date field"]

/// The app's accessibility window that is the same window as `w` (by position and size), so apps with
/// several windows are read from the one that was asked for, not whichever has focus.
func axWindow(_ app: AXUIElement, _ w: Win?) -> AXUIElement? {
    let all = attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    if let w {
        let want = CGRect(x: w.x, y: w.y, width: w.w, height: w.h)
        let same = all.filter { frame($0).map { abs($0.minX - want.minX) <= 2 && abs($0.minY - want.minY) <= 2 && abs($0.width - want.width) <= 2 && abs($0.height - want.height) <= 2 } ?? false }
        // Windows stacked at the same size (Safari's often are): the title tells them apart.
        if let m = same.first(where: { str($0, kAXTitleAttribute) == w.title }) ?? same.first { return m }
    }
    if let f = attr(app, kAXFocusedWindowAttribute) { return (f as! AXUIElement) }
    return all.first
}

/// Walks the window's tree and numbers every control. Ids are stable for the same walk, so
/// `act` re-walks and finds the same element by id (checking its label still matches).
func frontPid() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

/// Brings the window's app forward and waits until macOS reports it frontmost (up to ~1.2 s).
func bringToFront(_ w: Win, _ app: AXUIElement, raise: Bool = true) -> Bool {
    if BG, !fgActive { return true }
    if frontPid() == w.pid { return true }
    let run = NSRunningApplication(processIdentifier: w.pid)
    for attempt in 0..<3 {
        run?.unhide()
        run?.activate(options: [.activateAllWindows])
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if raise, let win = axWindow(app, w) { AXUIElementPerformAction(win, kAXRaiseAction as CFString) }
        if attempt == 2, let url = run?.bundleURL {
            // Last resort: open the app again, which macOS always honours.
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        }
        // Opening the app again is asynchronous, so give the last attempt longer.
        for _ in 0..<(attempt == 2 ? 40 : 8) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if frontPid() == w.pid { Thread.sleep(forTimeInterval: 0.1); return true }
        }
    }
    return frontPid() == w.pid
}

/// A field with no label of its own: the text just before it in its row (many forms put the label in a
/// plain element next to the field instead of a linked <label>).
func nearbyLabel(_ e: AXUIElement) -> String? {
    var cur = e
    for _ in 0..<3 {
        guard let parent = attr(cur, kAXParentAttribute).map({ $0 as! AXUIElement }),
              let kids = attr(parent, kAXChildrenAttribute) as? [AXUIElement],
              let at = kids.firstIndex(where: { CFEqual($0, cur) }) else { return nil }
        for sib in kids[..<at].reversed() {
            var stack: [(AXUIElement, Int)] = [(sib, 0)]
            while let (el, d) = stack.popLast() {
                let role = axRole(el)
                if FIELD_ROLES.contains(role) || INTERACTIVE.contains(role) { break }
                if role == "AXStaticText", let t = str(el, kAXValueAttribute), t.trimmingCharacters(in: .whitespaces).count >= 2 {
                    return String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
                }
                if d < 3 { stack += ((attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []).reversed().map { ($0, d + 1) } }
            }
        }
        cur = parent
    }
    return nil
}

/// Controls scrolled out of view come after the visible ones (marked offscreen), so long pages and chat
/// histories can't push what's actually on screen off the list.
func walk(_ app: AXUIElement, _ w: Win? = nil, limit: Int = 260) -> [(AXUIElement, [String: Any])] {
    guard let root = axWindow(app, w) else { return [] }
    let view = w.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) } ?? frame(root) ?? .infinite
    var found: [(AXUIElement, [String: Any])] = [], hidden: [(AXUIElement, [String: Any])] = []
    var stack: [(AXUIElement, Int)] = [(root as! AXUIElement, 0)]
    var visited = 0
    while let (el, depth) = stack.popLast(), found.count < limit, visited < 8000 {
        visited += 1
        let rc = attrs(el, [kAXRoleAttribute, kAXChildrenAttribute])
        let role = strOf(rc[0]) ?? ""
        // Everything a control's line needs, in one round trip.
        let c = INTERACTIVE.contains(role) ? attrs(el, [kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                                        "AXPlaceholderValue", kAXHelpAttribute, kAXTitleUIElementAttribute, kAXValueAttribute, kAXFocusedAttribute]) : []
        if !c.isEmpty, let f = frameOf(c[0], c[1]), f.width > 1, f.height > 1 {
            if (c[2] as? Bool) != false {
                let title = strOf(c[3]), placeholder = strOf(c[5])
                var label = title ?? strOf(c[4]) ?? placeholder ?? strOf(c[6]) ?? ""
                if label.isEmpty, let t = c[7], CFGetTypeID(t) == AXUIElementGetTypeID() { label = str(t as! AXUIElement, kAXValueAttribute) ?? "" }
                if label.isEmpty, FIELD_ROLES.contains(role) { label = nearbyLabel(el) ?? "" }
                // A placeholder alone hides the real label ("e.g. Jane Doe" is the Full Name field): add the label too.
                if FIELD_ROLES.contains(role), title == nil, let ph = placeholder, label == ph, let near = nearbyLabel(el), near != ph { label = "\(near) (\(ph))" }
                var item: [String: Any] = ["role": ROLE_NAME[role] ?? role, "label": String(label.prefix(80)),
                                           "bounds": [Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)]]
                if role != "AXSecureTextField", let v = strOf(c[8]), !v.isEmpty { item["value"] = String(v.prefix(80)) }
                if (c[9] as? Bool) == true { item["focused"] = true }
                // Mostly on screen counts as visible; a sliver at the edge doesn't.
                let seen = view.intersection(f)
                if !seen.isNull, seen.width * seen.height >= f.width * f.height * 0.5 { found.append((el, item)) }
                else if hidden.count < 40 { item["offscreen"] = true; hidden.append((el, item)) }
            }
        }
        if depth < 40, let kids = rc[1] as? [AXUIElement] {
            for k in kids.reversed() { stack.append((k, depth + 1)) }
        }
    }
    return (found + hidden.prefix(max(0, limit - found.count))).enumerated().map { i, c in
        var item = c.1; item["id"] = i + 1; return (c.0, item)
    }
}

/// Any visible element whose text matches `query` (labels, headings, version numbers, plain text), best first:
/// exact matches, then whole words, then contains; on screen in this window; smallest first (the text, not its container).
func findText(_ app: AXUIElement, _ w: Win, _ query: String) -> [[String: Any]] { findTextEls(app, w, query).map { $0.1 } }

/// How text (lowercased, trimmed) holds the query: 0 the whole text, 1 a whole word or phrase in it, 2 only inside other
/// words. Joined by . : _ / @ or \ isn't a word of its own: "speed" in a clip called "MTLSVideoP:speed.mp4" is part of a
/// name. (\b fails when the text starts or ends with a symbol, like "$1,250".)
func matchScore(_ low: String, _ q: String) -> Int {
    if low == q { return 0 }
    let pat = "(?<![\\p{L}\\p{N}_./:@\\\\])\(NSRegularExpression.escapedPattern(for: q))(?![\\p{L}\\p{N}_])(?![./:@\\\\][\\p{L}\\p{N}])"
    return low.range(of: pat, options: .regularExpression) != nil ? 1 : 2
}

func findTextEls(_ app: AXUIElement, _ w: Win, _ query: String, hidden: Bool = false, limit: Int = 8) -> [(AXUIElement, [String: Any])] {
    guard let root = axWindow(app, w) else { return [] }
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return [] }
    let win = CGRect(x: w.x, y: w.y, width: w.w, height: w.h)
    var hits: [(score: Int, web: Bool, area: CGFloat, el: AXUIElement, item: [String: Any])] = []
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var visited = 0
    while let (el, depth) = stack.popLast(), visited < 12000 {
        visited += 1
        let a = attrs(el, [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXRoleAttribute])
        let texts = a[0..<4].compactMap { strOf($0) }
        if let t = texts.first(where: { $0.lowercased().contains(q) }), let f = frameOf(a[5], a[6]), f.width > 1, f.height > 1, hidden || win.intersects(f) {
            let low = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // A whole word: no letter or digit right before or after. (\\b fails when the text starts or ends with a symbol, like "$1,250".)
            let score = matchScore(low, q)
            let role = strOf(a[7]) ?? ""
            hits.append((score, inWebPage(el), f.width * f.height, el, ["text": String(t.prefix(80)), "match": ["exact", "word", "partial"][score], "role": ROLE_NAME[role] ?? role.replacingOccurrences(of: "AX", with: "").lowercased(),
                                                     "bounds": [Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)]]))
        }
        if depth < 60, let kids = a[4] as? [AXUIElement] {
            for k in kids.reversed() { stack.append((k, depth + 1)) }
        }
    }
    // Words on the page beat the same words in the browser's own tabs and toolbar (a tab titled "Sign in").
    return hits.sorted { $0.score != $1.score ? $0.score < $1.score : $0.web != $1.web ? $0.web : $0.area < $1.area }.prefix(limit).map { ($0.el, $0.item) }
}

/// Activates what a piece of text belongs to: focuses a text field, else presses the element or the nearest
/// ancestor that can be pressed (a link around its text, a button around its label). Returns false if nothing could.
func pressText(_ e: AXUIElement) -> Bool {
    // Words inside a button or link (a web "Sign in" button holds a text "Sign in"): press the button itself. Safari
    // reports pressing the inner text as done but never submits the form, so the login silently didn't happen.
    if ["AXStaticText", "AXImage", "AXHeading", "AXGroup"].contains(str(e, kAXRoleAttribute) ?? "") {
        var up = attr(e, kAXParentAttribute).map { $0 as! AXUIElement }
        for _ in 0..<3 {
            guard let c = up else { break }
            if ["AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXTab", "AXCheckBox", "AXRadioButton"].contains(str(c, kAXRoleAttribute) ?? ""),
               AXUIElementPerformAction(c, kAXPressAction as CFString) == .success { return true }
            up = attr(c, kAXParentAttribute).map { $0 as! AXUIElement }
        }
    }
    var cur: AXUIElement? = e
    for _ in 0..<6 {
        guard let c = cur else { break }
        let role = str(c, kAXRoleAttribute) ?? ""
        if ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role) {
            AXUIElementSetAttributeValue(c, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if let f = frame(c) { click(CGPoint(x: f.midX, y: f.midY)) }
            return true
        }
        var names: CFArray?
        if AXUIElementCopyActionNames(c, &names) == .success, let n = names as? [String], n.contains(kAXPressAction as String),
           AXUIElementPerformAction(c, kAXPressAction as CFString) == .success { return true }
        cur = attr(c, kAXParentAttribute).map { $0 as! AXUIElement }
    }
    return false
}

// Clicks that delete, pay, send or sign out (in English and other common languages) run only when the sidecar
// has asked the user ("confirmed").
// Kept in sync with RISKY_CLICK in sidecar/safety.mjs.
let RISKY = try! NSRegularExpression(pattern: #"(?:^|[^\p{L}])(delete|remove|erase|destroy|wipe|reset|deactivate|close (my |your )?account|cancel (my |your |the )?(subscription|plan|membership|account|order)|unsubscribe|pay|purchase|buy|place (the |your )?order|checkout|check out|confirm (payment|order|purchase|transfer)|send|transfer|withdraw|uninstall|empty trash|discard|sign out|log out|logout|format|revoke|publish|eliminar|borrar|pagar|comprar|enviar|cerrar sesi[oó]n|supprimer|effacer|payer|acheter|envoyer|se d[eé]connecter|d[eé]connexion|l[oö]schen|entfernen|bezahlen|kaufen|senden|abmelden|excluir|apagar|terminar sess[aã]o|elimina|cancella|paga|acquista|invia|esci|verwijderen|betalen|kopen|verzenden|uitloggen|afmelden|padam|hapus|bayar|beli|hantar|kirim|log keluar|nyahlanggan)(?![\p{L}])|删除|刪除|移除|清空|支付|付款|购买|購買|发送|發送|退出登录|登出|注销|削除|消去|支払|購入|送信|ログアウト|退会|삭제|결제|구매|전송|보내기|로그아웃"#, options: .caseInsensitive)
func risky(_ s: String) -> Bool { RISKY.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

/// Text fields inside web pages (browsers, Electron apps) ignore a value set through accessibility:
/// the page never hears about it and submits an empty field. Those need real keystrokes.
func inWebPage(_ e: AXUIElement) -> Bool {
    var cur = attr(e, kAXParentAttribute).map { $0 as! AXUIElement }
    for _ in 0..<40 {
        guard let c = cur else { return false }
        if str(c, kAXRoleAttribute) == "AXWebArea" { return true }
        cur = attr(c, kAXParentAttribute).map { $0 as! AXUIElement }
    }
    return false
}

// ---------- forms ----------

let FIELD_ROLES: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField", "AXDateField", "AXTimeField", "AXDateTimeArea"]
let DROP_ROLES: Set<String> = ["AXPopUpButton", "AXComboBox", "AXMenuButton", "AXTextField", "AXButton"]
func axRole(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute) ?? "" }
func fold(_ s: String) -> String {
    s.lowercased().replacingOccurrences(of: "*", with: "").replacingOccurrences(of: ":", with: "")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The field a form label names: one whose own label or placeholder matches, else the field nearest the
/// visible label text (to its right on the same row, or just below it). Labels on many sites aren't linked
/// to their field, so clicking the label puts the cursor nowhere.
func fieldFor(_ app: AXUIElement, _ w: Win, _ controls: [(AXUIElement, [String: Any])], _ name: String, roles: Set<String>) -> (AXUIElement, [String: Any])? {
    let q = fold(name)
    guard !q.isEmpty else { return nil }
    let cands = controls.filter { roles.contains(axRole($0.0)) && ($0.1["offscreen"] as? Bool) != true } + controls.filter { roles.contains(axRole($0.0)) && ($0.1["offscreen"] as? Bool) == true }
    let names: ((AXUIElement, [String: Any])) -> [String] = { c in
        let l = (c.1["label"] as? String) ?? ""
        let base = l.range(of: " (").map { String(l[..<$0.lowerBound]) } ?? l
        return [l, base, str(c.0, "AXPlaceholderValue") ?? "", str(c.0, kAXTitleAttribute) ?? "", str(c.0, kAXDescriptionAttribute) ?? ""].map(fold).filter { !$0.isEmpty }
    }
    if let m = cands.first(where: { names($0).contains(q) }) { return m }
    if let m = cands.first(where: { names($0).contains { $0.hasPrefix(q) || q.hasPrefix($0) && $0.count >= 4 } }) { return m }
    guard let (_, lab) = findTextEls(app, w, name, hidden: true).first(where: { wholeMatch($0.1, name) }), let lb = lab["bounds"] as? [Int] else { return nil }
    let L = CGRect(x: lb[0], y: lb[1], width: lb[2], height: lb[3])
    // A field on the label's own row always beats one below it; "below" means stacked under the label
    // (same left edge), not merely lower down, which is the next row's field in a two-column form.
    var row: (CGFloat, (AXUIElement, [String: Any]))?, under: (CGFloat, (AXUIElement, [String: Any]))?
    for c in cands {
        guard let f = frame(c.0) else { continue }
        if f.minX >= L.midX, f.minY <= L.midY, f.maxY >= L.midY, f.minX - L.maxX < 500 {
            let d = f.minX - L.maxX
            if row == nil || d < row!.0 { row = (d, c) }
        } else if f.minY >= L.minY + 2, f.minY - L.maxY <= 60, abs(f.minX - L.minX) <= 60 {
            let d = f.minY - L.maxY
            if under == nil || d < under!.0 { under = (d, c) }
        }
    }
    return row?.1 ?? under?.1
}

/// The element that has keyboard focus in this app, if any.
func focusedEl(_ app: AXUIElement) -> AXUIElement? { attr(app, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement } }

/// Somewhere typing goes into text: a field, or anything whose value can be edited.
func isEditable(_ e: AXUIElement?) -> Bool {
    guard let e else { return false }
    if FIELD_ROLES.contains(axRole(e)) { return true }
    var settable: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
}

/// Whether a type step may go ahead. Typing outside a text field fires page shortcuts, so normally the focused
/// thing must be editable. Some apps (CapCut) don't show their fields to accessibility at all and report only the
/// window as focused: there, right after a click at a spot, the typing goes into what was clicked.
func mayType(editable: Bool, focusRole: String?, clickedSpot: Bool) -> Bool {
    editable || (clickedSpot && (focusRole == nil || ["AXWindow", "AXApplication"].contains(focusRole!)))
}

/// Puts the cursor in a field, replaces its text and reads back what it shows. Never types unless the field
/// really has focus, so text can't land in some other field or set off page shortcuts.
func typeInto(_ app: AXUIElement, _ e: AXUIElement, _ text: String) -> (ok: Bool, shows: String) {
    // A field further down the page: scroll it into view first, or the click lands on whatever is at its old spot.
    if let f = frame(e), let wf = axWindowFrame(e), !wf.contains(CGPoint(x: f.midX, y: min(f.midY, f.minY + 12))) {
        AXUIElementPerformAction(e, "AXScrollToVisible" as CFString); Thread.sleep(forTimeInterval: 0.3)
    }
    AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    if let f = frame(e) { click(CGPoint(x: f.midX, y: min(f.midY, f.minY + 12))) }
    Thread.sleep(forTimeInterval: 0.08)
    let role = axRole(e)
    if !inWebPage(e), !["AXDateField", "AXTimeField", "AXDateTimeArea"].contains(role),
       AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, text as CFString) == .success, str(e, kAXValueAttribute) == text {
        return (true, text)
    }
    let focusedHere: Bool = {
        if (attr(e, kAXFocusedAttribute) as? Bool) == true { return true }
        guard let f = focusedEl(app) else { return false }
        return CFEqual(f, e) || (frame(f).map { fr in frame(e).map { $0.intersects(fr) } ?? false } ?? false)
    }()
    if !focusedHere, !["AXDateField", "AXTimeField", "AXDateTimeArea"].contains(role) { return (false, str(e, kAXValueAttribute) ?? "") }
    if ["AXDateField", "AXTimeField", "AXDateTimeArea"].contains(role) {
        // Date fields are a row of segments (month, day, year): start in the first and type digits; each
        // segment moves on by itself when full.
        // The segments (month, day, year steppers) can sit a few levels down inside the field.
        var segs: [(AXUIElement, CGRect)] = []
        var stack: [(AXUIElement, Int)] = ((attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []).map { ($0, 1) }
        while let (c, d) = stack.popLast() {
            if axRole(c) == "AXIncrementor", let f = frame(c) { segs.append((c, f)) }
            else if d < 5 { stack += ((attr(c, kAXChildrenAttribute) as? [AXUIElement]) ?? []).map { ($0, d + 1) } }
        }
        segs.sort { $0.1.minX < $1.1.minX }
        // Click each segment and type its part with real number keys (segments ignore keyless characters
        // and don't always move on by themselves). Parts go in the order the segments appear.
        let digitKey: [Character: CGKeyCode] = ["0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25]
        let parts = text.split { !$0.isNumber }.map(String.init)
        var pid: pid_t = 0
        AXUIElementGetPid(e, &pid)
        let before = Set(windows().filter { $0.pid == pid }.map { $0.id })
        let pairs: [((AXUIElement, CGRect)?, String)] = segs.count == parts.count ? zip(segs, parts).map { ($0, $1) } : [(segs.first, parts.joined())]
        for (seg, part) in pairs {
            if let seg { click(CGPoint(x: seg.1.midX, y: seg.1.midY)); Thread.sleep(forTimeInterval: 0.08) }
            for ch in part {
                guard let k = digitKey[ch] else { continue }
                let d = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: true)!, u = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: false)!
                d.flags = []; u.flags = []
                send(d); send(u)
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
        Thread.sleep(forTimeInterval: 0.15)
        // Safari opens a calendar in its own little window over the form; later clicks would land on its days.
        // Tab closes it and keeps the date (Return would submit the form).
        if windows().contains(where: { $0.pid == pid && !before.contains($0.id) && $0.title.isEmpty && $0.w < 500 && $0.h < 500 }) {
            _ = pressKey("tab"); Thread.sleep(forTimeInterval: 0.2)
        }
        return (true, segs.compactMap { str($0.0, kAXValueAttribute) }.joined(separator: "/"))
    } else {
        _ = pressKey("cmd+a"); typeText(text)
    }
    Thread.sleep(forTimeInterval: 0.12)
    return (true, str(e, kAXValueAttribute) ?? "")
}

/// A menu item or list option with this text anywhere in the app: open dropdown menus and pickers often
/// live outside the window. Exact text first, then text that starts with it.
func findOption(_ app: AXUIElement, _ w: Win, _ option: String, excluding: AXUIElement? = nil) -> AXUIElement? {
    let q = fold(option)
    var roots: [AXUIElement] = (attr(app, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    if let win = axWindow(app, w) { roots.insert(win, at: 0) }
    var exact: AXUIElement?, prefix: AXUIElement?, visited = 0
    var stack: [(AXUIElement, Int)] = roots.reversed().map { ($0, 0) }
    while let (el, depth) = stack.popLast(), visited < 20000, exact == nil {
        visited += 1
        let a = attrs(el, [kAXRoleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXChildrenAttribute])
        let role = strOf(a[0]) ?? ""
        if role == "AXMenuBar" { continue }
        // The dropdown's own text (a search box shows what was typed) isn't an option.
        if let x = excluding, CFEqual(el, x) { continue }
        if ["AXMenuItem", "AXStaticText", "AXCell", "AXRow", "AXButton", "AXRadioButton", "AXLink", "AXGroup", "AXListItem", "AXOption"].contains(role) {
            for t in [strOf(a[1]), strOf(a[2]), strOf(a[3])].compactMap({ $0 }).map(fold) where !t.isEmpty {
                if t == q { exact = el; break }
                if prefix == nil, t.hasPrefix(q), t.count <= q.count + 25 { prefix = el }
            }
        }
        if depth < 60, let kids = a[4] as? [AXUIElement] { for k in kids.reversed() { stack.append((k, depth + 1)) } }
    }
    return exact ?? prefix
}

/// The frame of the window an element is in.
func axWindowFrame(_ e: AXUIElement) -> CGRect? { attr(e, kAXWindowAttribute).flatMap { frame($0 as! AXUIElement) } }

/// Of many matches (every post's "Reply" button), the one that belongs with the anchor text: the first one at
/// or below the anchor's top, nearest first; if none is below, the nearest one above.
func nearestAfter(_ anchor: CGRect, _ cands: [(AXUIElement, [String: Any])]) -> (AXUIElement, [String: Any])? {
    let placed = cands.compactMap { c in frame(c.0).map { (c, $0) } }
    let below = placed.filter { $0.1.minY >= anchor.minY - 4 }.min { ($0.1.minY - anchor.minY) + abs($0.1.minX - anchor.minX) * 0.2 < ($1.1.minY - anchor.minY) + abs($1.1.minX - anchor.minX) * 0.2 }
    return below?.0 ?? placed.min { anchor.minY - $0.1.maxY < anchor.minY - $1.1.maxY }?.0
}
/// Where the `near` text is (on screen or scrolled out of view), for nearestAfter.
func anchorFrame(_ app: AXUIElement, _ w: Win, _ near: String) -> CGRect? {
    findTextEls(app, w, near, hidden: true).first.flatMap { frame($0.0) }
}

/// The text of an option-like element: title, value or description.
func optionText(_ el: AXUIElement) -> [String] { [str(el, kAXTitleAttribute), str(el, kAXValueAttribute), str(el, kAXDescriptionAttribute)].compactMap { $0 }.map(fold) }
func isInside(_ el: AXUIElement, _ ancestor: AXUIElement) -> Bool {
    var cur: AXUIElement? = el
    for _ in 0..<12 { guard let c = cur else { return false }; if CFEqual(c, ancestor) { return true }; cur = attr(c, kAXParentAttribute).map { $0 as! AXUIElement } }
    return false
}
/// The list a dropdown opened: the on-screen list, menu or table nearest below the dropdown (or above it).
func openList(_ app: AXUIElement, _ w: Win, near: CGRect) -> AXUIElement? {
    guard let root = axWindow(app, w) else { return nil }
    let win = CGRect(x: w.x, y: w.y, width: w.w, height: w.h)
    var best: (CGFloat, AXUIElement)?, stack: [(AXUIElement, Int)] = [(root, 0)], visited = 0
    while let (el, depth) = stack.popLast(), visited < 8000 {
        visited += 1
        let a = attrs(el, [kAXRoleAttribute, kAXChildrenAttribute])
        if ["AXList", "AXMenu", "AXTable", "AXOutline", "AXListBox"].contains(strOf(a[0]) ?? ""), let f = frame(el), f.intersects(win), f.height > 20 {
            let d = abs(f.minY - near.maxY) + abs(f.minX - near.minX) * 0.5
            if best == nil || d < best!.0 { best = (d, el) }
        }
        if depth < 60, let kids = a[1] as? [AXUIElement] { for k in kids.reversed() { stack.append((k, depth + 1)) } }
    }
    return best?.1
}
/// The rows of a list that are in view right now (a virtualized list only has these).
func visibleRows(_ list: AXUIElement, _ win: CGRect) -> [AXUIElement] {
    let kids = (attr(list, "AXVisibleChildren") as? [AXUIElement]) ?? (attr(list, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    return kids.filter { frame($0).map { win.intersects($0) } ?? false }
}
func optionIn(_ list: AXUIElement, _ q: String) -> AXUIElement? {
    var stack: [(AXUIElement, Int)] = [(list, 0)], prefix: AXUIElement?, visited = 0
    while let (el, d) = stack.popLast(), visited < 3000 {
        visited += 1
        let a = attrs(el, [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXChildrenAttribute])
        let t = [strOf(a[0]), strOf(a[1]), strOf(a[2])].compactMap { $0 }.map(fold)
        if t.contains(q) { return el }
        if prefix == nil, t.contains(where: { $0.hasPrefix(q) && $0.count <= q.count + 25 }) { prefix = el }
        if d < 8, let kids = a[3] as? [AXUIElement] { for k in kids.reversed() { stack.append((k, d + 1)) } }
    }
    return prefix
}
/// Scrolls an open list a screenful at a time, down to its end and then back up, until the option shows up.
/// Works for long lists and virtualized ones, where rows out of view don't exist until scrolled to.
func scrollListFor(_ app: AXUIElement, _ w: Win, _ list: AXUIElement, _ option: String) -> AXUIElement? {
    // In the background: an option already in view needs no scrolling; finding one further down needs the wheel,
    // which only the real cursor can turn.
    if inBackground { if let o = optionIn(list, fold(option)) { return o }; return withRealCursor { scrollListFor(app, w, list, option) } ?? nil }
    let q = fold(option), win = CGRect(x: w.x, y: w.y, width: w.w, height: w.h)
    let deadline = Date().addingTimeInterval(20)
    for dir: Int32 in [-1, 1] {
        var last = "", same = 0
        while Date() < deadline {
            if let o = optionIn(list, q) { return o }
            let rows = visibleRows(list, win)
            let box = rows.compactMap(frame).reduce(CGRect.null) { $0.union($1) }.intersection(win)
            guard !box.isNull, box.height > 4 else { return nil }
            let sig = rows.map { optionText($0).first ?? "" }.joined(separator: "|")
            if sig == last { same += 1; if same >= 2 { break } } else { same = 0 }
            last = sig
            // Most of a screenful, so a virtualized list never skips rows between looks.
            let px = Int32(max(40, box.height * 0.7))
            moveTo(CGPoint(x: box.midX, y: box.midY))
            if let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1, wheel1: dir * px, wheel2: 0, wheel3: 0) { e.flags = []; sendScroll(e) }
            Thread.sleep(forTimeInterval: 0.07)
        }
    }
    return optionIn(list, q)
}

/// Presses an element, or clicks its middle if it can't be pressed. Scrolls it into view first.
func activate(_ e: AXUIElement) {
    AXUIElementPerformAction(e, "AXScrollToVisible" as CFString)
    if axRole(e) == "AXMenuItem" || AXUIElementPerformAction(e, kAXPressAction as CFString) == .success {
        if axRole(e) == "AXMenuItem" { AXUIElementPerformAction(e, kAXPressAction as CFString) }
        return
    }
    if pressText(e) { return }
    if let f = frame(e) { click(CGPoint(x: f.midX, y: f.midY)) }
}

func scrollAt(_ p: CGPoint, dy: Int32, dx: Int32) {
    moveTo(p)
    Thread.sleep(forTimeInterval: 0.03)
    if let e = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) { e.flags = []; sendScroll(e) }
}

/// What click_text may click: the words as a whole label or a whole word in one, never inside other words
/// ("Follow" must not click "Following", "Speed" not a clip called "MTLSVideoP:speed.mp4").
func clickMatch(_ m: [String: Any]) -> Bool { (m["match"] as? String) != "partial" }

/// A whole label or heading, not the same words buried in a paragraph.
func wholeMatch(_ m: [String: Any], _ q: String) -> Bool {
    (m["match"] as? String) != "partial" || ((m["text"] as? String) ?? "").count <= max(40, q.count * 3)
}

/// Visible text isn't there, but it may be further down the page: scroll the best match into view.
/// Returns true if something was scrolled.
func scrollToText(_ app: AXUIElement, _ w: Win, _ q: String) -> Bool {
    let win = CGRect(x: w.x, y: w.y, width: w.w, height: w.h)
    guard let (e, _) = findTextEls(app, w, q, hidden: true).first(where: { wholeMatch($0.1, q) && !(frame($0.0).map { win.intersects($0) } ?? false) }) else { return false }
    var cur: AXUIElement? = e
    for _ in 0..<4 {
        guard let c = cur else { break }
        if AXUIElementPerformAction(c, "AXScrollToVisible" as CFString) == .success { Thread.sleep(forTimeInterval: 0.35); return true }
        cur = attr(c, kAXParentAttribute).map { $0 as! AXUIElement }
    }
    return false
}

/// Readable text in the window (headings, paragraphs, labels), top to bottom, so pages can be read without
/// a screenshot. Visible text only, capped so a long page can't flood the reply.
/// Text on the page that's scrolled out of view, top to bottom. When it's long, the start and the end are
/// kept (headings up top, contact details and footers at the bottom), with a note for what's in between.
/// Every text and heading in the window, in one pass (role, text, place and children in one round trip each):
/// on-screen texts as (y, x, text) for pageText, and scrolled-out-of-view ones for offscreenText.
struct TextScan { var on: [(CGFloat, CGFloat, String)] = []; var off: [(CGFloat, String)] = [] }
func scanText(_ app: AXUIElement, _ w: Win, wantOn: Bool = true, wantOff: Bool = true) -> TextScan {
    var scan = TextScan()
    guard let root = axWindow(app, w) else { return scan }
    let win = CGRect(x: w.x, y: w.y, width: w.w, height: w.h)
    var seenOn = Set<String>(), seenOff = Set<String>(), visited = 0
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    // The in-view pass stopped at 8000 elements and the out-of-view one at 12000; keep both limits.
    let maxVisit = wantOff ? 12000 : 8000
    while let (el, depth) = stack.popLast(), visited < maxVisit {
        visited += 1
        let a = attrs(el, [kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute])
        let role = strOf(a[0]) ?? ""
        if role == "AXStaticText" || role == "AXHeading", let f = frameOf(a[4], a[5]) {
            let norm = { (t: String) in t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            if win.intersects(f) {
                if wantOn, visited <= 8000, let t = strOf(a[1]) ?? strOf(a[2]) ?? strOf(a[3]) {
                    let line = norm(t)
                    if line.count >= 2, seenOn.insert(line).inserted { scan.on.append((f.minY, f.minX, String(line.prefix(160)))) }
                }
            } else if wantOff, f.height > 1, let t = strOf(a[1]) ?? strOf(a[2]) {
                let line = norm(t)
                if line.count >= 2, seenOff.insert(line).inserted { scan.off.append((f.minY, String(line.prefix(160)))) }
            }
        }
        if depth < 60, let kids = a[6] as? [AXUIElement] { for k in kids.reversed() { stack.append((k, depth + 1)) } }
    }
    return scan
}

func offscreenText(_ app: AXUIElement, _ w: Win, cap: Int, scan: TextScan? = nil) -> [String] {
    let found = (scan ?? scanText(app, w, wantOn: false)).off
    let lines = found.sorted { $0.0 < $1.0 }.map { $0.1 }
    if lines.reduce(0, { $0 + $1.count + 1 }) <= cap { return lines }
    var head: [String] = [], tail: [String] = [], h = 0, t = 0
    for l in lines { if h + l.count > cap / 2 { break }; head.append(l); h += l.count + 1 }
    for l in lines.reversed() { if t + l.count > cap / 2 { break }; tail.insert(l, at: 0); t += l.count + 1 }
    return head + ["…(\(lines.count - head.count - tail.count) more lines in between; point_at or click_text with their words scrolls there)"] + tail
}

func pageText(_ app: AXUIElement, _ w: Win, cap: Int = 1800, scan: TextScan? = nil) -> [String] {
    let found = (scan ?? scanText(app, w, wantOff: false)).on
    var out: [String] = [], total = 0
    let sorted = found.sorted(by: { abs($0.0 - $1.0) > 4 ? $0.0 < $1.0 : $0.1 < $1.1 })
    for (k, (_, _, t)) in sorted.enumerated() {
        if total + t.count > cap { out.append("…(\(sorted.count - k) more lines further down this screen; read_window shows them all)"); break }
        out.append(t); total += t.count + 1
    }
    return out
}

/// After a click or key press the page may be loading: re-read until the controls stop changing (max ~1.2 s).
// ---------- precise places: a guess fitted to the pixels, and text found by reading the screen ----------

/// Grows `m` by `r` pixels (square), so nearby ink counts as one piece: a word's letters, an icon's strokes.
func dilate(_ m: [Bool], _ w: Int, _ h: Int, _ r: Int) -> [Bool] {
    guard r > 0 else { return m }
    var a = [Bool](repeating: false, count: w * h)
    for y in 0 ..< h {
        var d = r + 1
        for x in 0 ..< w { d = m[y * w + x] ? 0 : d + 1; if d <= r { a[y * w + x] = true } }
        d = r + 1
        for x in stride(from: w - 1, through: 0, by: -1) { d = m[y * w + x] ? 0 : d + 1; if d <= r { a[y * w + x] = true } }
    }
    var b = [Bool](repeating: false, count: w * h)
    for x in 0 ..< w {
        var d = r + 1
        for y in 0 ..< h { d = a[y * w + x] ? 0 : d + 1; if d <= r { b[y * w + x] = true } }
        d = r + 1
        for y in stride(from: h - 1, through: 0, by: -1) { d = a[y * w + x] ? 0 : d + 1; if d <= r { b[y * w + x] = true } }
    }
    return b
}

/// The tight box of what's drawn in `px` (RGBA, w×h, top row first) that the guessed box `g` (pixels) was meant for.
/// The background is read off the edges; whatever differs from it is ink; ink within `join` px counts as one piece;
/// the pieces centred in the guess make the box. Else the nearest piece of about the right size, else nil (nothing
/// stands out there, or the guess sits inside something big like a photo).
func fitBox(_ px: [UInt8], _ w: Int, _ h: Int, _ g: CGRect, join: Int) -> CGRect? {
    guard w >= 3, h >= 3, px.count >= w * h * 4, g.width > 0, g.height > 0 else { return nil }
    var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
    func edge(_ x: Int, _ y: Int) { let i = (y * w + x) * 4; rs.append(px[i]); gs.append(px[i + 1]); bs.append(px[i + 2]) }
    for x in 0 ..< w { edge(x, 0); edge(x, h - 1) }
    for y in 1 ..< h - 1 { edge(0, y); edge(w - 1, y) }
    func median(_ a: [UInt8]) -> Int { Int(a.sorted()[a.count / 2]) }
    let bg = (median(rs), median(gs), median(bs))
    var ink = [Bool](repeating: false, count: w * h), count = 0
    for i in 0 ..< w * h {
        let d = max(abs(Int(px[i * 4]) - bg.0), abs(Int(px[i * 4 + 1]) - bg.1), abs(Int(px[i * 4 + 2]) - bg.2))
        if d > 38 { ink[i] = true; count += 1 }
    }
    if count == 0 || Double(count) > 0.6 * Double(w * h) { return nil }
    let joined = dilate(ink, w, h, join)
    var label = [Int32](repeating: -1, count: w * h)
    var pieces: [CGRect] = [], sizes: [Int] = [], stack: [Int] = []
    for start in 0 ..< w * h where joined[start] && label[start] < 0 {
        let id = Int32(pieces.count)
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1, n = 0
        label[start] = id; stack.append(start)
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if ink[i] { x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y); n += 1 }
            for j in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1] where j >= 0 && joined[j] && label[j] < 0 {
                label[j] = id; stack.append(j)
            }
        }
        pieces.append(n > 0 ? CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1) : .null); sizes.append(n)
    }
    let area = Double(g.width * g.height), roomy = g.insetBy(dx: -g.width * 0.15, dy: -g.height * 0.15)
    var pick: CGRect?
    // Specks (anti-aliasing) and panels far bigger than the guess don't count.
    for (r, n) in zip(pieces, sizes) where n >= 3 && Double(r.width * r.height) <= 6 * area && roomy.contains(CGPoint(x: r.midX, y: r.midY)) {
        pick = pick.map { $0.union(r) } ?? r
    }
    if pick == nil {
        var best = CGFloat.greatestFiniteMagnitude
        for (r, n) in zip(pieces, sizes) where n >= 3 {
            let ratio = Double(r.width * r.height) / area, d = hypot(r.midX - g.midX, r.midY - g.midY)
            if ratio > 0.08, ratio < 6, d <= max(g.width, g.height) * 0.75, d < best { best = d; pick = r }
        }
    }
    guard let p = pick else { return nil }
    let ratio = Double(p.width * p.height) / area
    return ratio > 0.04 && ratio < 6 ? p : nil
}

/// `r` cut to the display it's on (a capture can't reach past it).
func onDisplay(_ r: CGRect) -> CGRect {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    let c = CGPoint(x: r.midX, y: r.midY)
    let d = ids.prefix(Int(n)).map { CGDisplayBounds($0) }.first { $0.contains(c) } ?? CGDisplayBounds(CGMainDisplayID())
    return r.intersection(d)
}

/// A guessed box (global points) fitted to what's drawn around it in `img`, a capture of `area` (global points).
/// Letter-sized guesses join nothing, so neighbouring letters stay apart; bigger ones join ink up to 3 points apart.
func fitRect(in img: CGImage, area: CGRect, guess g: CGRect) -> CGRect? {
    let scale = CGFloat(img.width) / max(1, area.width)
    let pad = max(12, 0.6 * max(g.width, g.height))
    let want = g.insetBy(dx: -pad, dy: -pad).intersection(area)
    guard !want.isEmpty else { return nil }
    let cut = CGRect(x: ((want.minX - area.minX) * scale).rounded(.down), y: ((want.minY - area.minY) * scale).rounded(.down),
                     width: (want.width * scale).rounded(.up), height: (want.height * scale).rounded(.up))
        .intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
    guard let crop = img.cropping(to: cut) else { return nil }
    let w = crop.width, h = crop.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let drawn: Bool = buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard drawn else { return nil }
    let ox = area.minX + cut.minX / scale, oy = area.minY + cut.minY / scale
    let gp = CGRect(x: (g.minX - ox) * scale, y: (g.minY - oy) * scale, width: g.width * scale, height: g.height * scale)
    let side = min(g.width, g.height)
    let join = side < 16 ? 0 : Int((min(3, side * 0.1) * scale).rounded())
    guard let r = fitBox(buf, w, h, gp, join: join) else { return nil }
    return CGRect(x: ox + r.minX / scale, y: oy + r.minY / scale, width: r.width / scale, height: r.height / scale)
}

/// A window's own pixels (what a screenshot of it shows, even under other windows), and the area they cover in global
/// points; or the main display when `win` is nil.
func pixelsOf(_ win: Win?) -> (CGImage, CGRect)? {
    guard let w = win else {
        let d = CGDisplayBounds(CGMainDisplayID())
        return Shot.image(d).map { ($0, d) }
    }
    let file = NSTemporaryDirectory() + "roamies-look-\(getpid()).png"
    defer { try? FileManager.default.removeItem(atPath: file) }
    guard run("/usr/sbin/screencapture", ["-x", "-o", "-t", "png", "-l", String(w.id), file]) == 0,
          let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil),
          // Decoded now: the image would otherwise be read from the file lazily, after it's deleted.
          let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
    return (img, CGRect(x: w.x, y: w.y, width: w.w, height: w.h))
}

/// Text read off a window (or the main display), with the exact box of each match: words anywhere, inside
/// paragraphs, images and canvases too, and single characters (case-sensitive). Top to bottom.
func ocrFind(_ win: Win?, _ needle: String, all: Bool) -> [[String: Any]] {
    guard let (img, area) = pixelsOf(win), !area.isEmpty else { return [] }
    // .fast: about 0.05 s for a whole Retina window, with a box per character. (.accurate took ~30 s there and only
    // gives word-sized boxes for part of a word.)
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .fast
    req.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: img).perform([req])
    let q = needle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return [] }
    let single = q.count == 1
    var found: [(CGRect, String)] = []
    for obs in req.results ?? [] {
        guard let cand = obs.topCandidates(1).first else { continue }
        let s = cand.string
        var from = s.startIndex
        while from < s.endIndex, let r = s.range(of: q, options: single ? [] : [.caseInsensitive], range: from ..< s.endIndex) {
            from = r.upperBound
            // Words match whole words only ("harbor" isn't in "harbors"); a character can sit anywhere.
            if !single {
                let before: Character = r.lowerBound > s.startIndex ? s[s.index(before: r.lowerBound)] : " "
                let after: Character = r.upperBound < s.endIndex ? s[r.upperBound] : " "
                if before.isLetter || before.isNumber || after.isLetter || after.isNumber { continue }
            }
            guard let box = (try? cand.boundingBox(for: r))?.boundingBox else { continue }
            var rect = CGRect(x: area.minX + box.minX * area.width, y: area.minY + (1 - box.maxY) * area.height,
                              width: box.width * area.width, height: box.height * area.height)
            // Vision's box for one character is loose: fit it to the glyph's own pixels.
            if single, let tight = fitRect(in: img, area: area, guess: rect) { rect = tight }
            found.append((rect, s))
        }
    }
    found.sort { abs($0.0.minY - $1.0.minY) > 4 ? $0.0.minY < $1.0.minY : $0.0.minX < $1.0.minX }
    return (all ? found : Array(found.prefix(1))).map { r, s in
        ["text": s, "role": "text", "bounds": [r.minX, r.minY, r.width, r.height].map { ($0 * 10).rounded() / 10 }]
    }
}

/// The waits (by index) that come right after a click or key, so they can end once the page has reacted.
func reactWaits(_ dos: [String]) -> Set<Int> {
    let reacts: Set<String> = ["click", "click_text", "press_button", "key", "click_at", "choose"]
    return Set(dos.indices.filter { $0 >= 1 && dos[$0] == "wait" && reacts.contains(dos[$0 - 1]) })
}

func settle(_ app: AXUIElement, _ w: Win) -> [(AXUIElement, [String: Any])] {
    var prev: [String] = [], cur = walk(app, w)
    for _ in 0..<4 {
        Thread.sleep(forTimeInterval: 0.2)
        prev = cur.map { "\($0.1["role"] ?? "")|\($0.1["label"] ?? "")" }
        cur = walk(app, w)
        if cur.map({ "\($0.1["role"] ?? "")|\($0.1["label"] ?? "")" }) == prev { break }
    }
    return cur
}

func axApp(_ w: Win) -> AXUIElement {
    let app = AXUIElementCreateApplication(w.pid)
    // Chromium and Electron only build their accessibility tree when asked to.
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    return app
}

// ---------- input ----------

// A private source: events don't pick up modifier keys still held (or just "pressed" by a cmd+a step),
// which turned typed digits into Cmd+1… and switched browser tabs.
let src = CGEventSource(stateID: .privateState)

// Background mode (the default; ROAMIES_BG=0 turns it off). BitJarvis acts in an app without the user's cursor or
// keyboard focus, so they can keep working: keys and typing go straight to that app, shortcuts like Cmd+S press the
// app's own menu item, clicks are accessibility presses on what's at the spot, scrolls are sent to the app.
// A step that only works with the real cursor (date pickers, a field that didn't take the typing, a spot with nothing
// pressable) borrows it: the app comes forward, the step runs, then the cursor goes back where it was and the user's
// app comes back to the front.
let BG = ProcessInfo.processInfo.environment["ROAMIES_BG"] != "0"
var bgPid: pid_t? = nil
var bgPoint = CGPoint.zero
var fgActive = false
var bgWin: Win? = nil
var bgApp: AXUIElement? = nil
var usedRealCursor = false
var inBackground: Bool { BG && !fgActive && bgPid != nil }
func send(_ e: CGEvent) { if inBackground { e.postToPid(bgPid!) } else { e.post(tap: .cghidEventTap) } }
func moveTo(_ p: CGPoint) {
    if inBackground { bgPoint = p; return }
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
func sendScroll(_ e: CGEvent) { if inBackground { e.location = bgPoint; e.postToPid(bgPid!) } else { e.post(tap: .cghidEventTap) } }
/// A click without the cursor: focuses the text field at that spot, or presses the nearest pressable thing there.
/// False when nothing there can be focused or pressed (then the real cursor is needed).
func bgClick(_ pid: pid_t, _ p: CGPoint) -> Bool {
    // Chromium answers hit tests late: the first answer can be the last one asked about, or a group the size of the whole
    // page (pressing that clicks the middle of the page). Ask again until it names something small that sits right here.
    let maxArea = (bgWin.map { $0.w * $0.h } ?? 1_000_000) * 0.25
    let small = { (e: AXUIElement) -> Bool in frame(e).map { $0.insetBy(dx: -1, dy: -1).contains(p) && $0.width * $0.height <= maxArea } ?? false }
    var hit: AXUIElement?
    for _ in 0..<4 {
        var el: AXUIElement?
        if AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(p.x), Float(p.y), &el) == .success, let e = el, small(e) { hit = e; break }
        Thread.sleep(forTimeInterval: 0.08)
    }
    guard var cur = hit else { return false }
    for _ in 0..<6 {
        let role = str(cur, kAXRoleAttribute) ?? ""
        if ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField"].contains(role) {
            return AXUIElementSetAttributeValue(cur, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        }
        if ["AXWebArea", "AXWindow", "AXScrollArea", "AXApplication"].contains(role) { return false }
        var names: CFArray?
        if small(cur), AXUIElementCopyActionNames(cur, &names) == .success, let n = names as? [String], n.contains(kAXPressAction as String),
           AXUIElementPerformAction(cur, kAXPressAction as CFString) == .success { return true }
        guard let up = attr(cur, kAXParentAttribute) else { return false }
        cur = up as! AXUIElement
    }
    return false
}
/// Live progress for the overlay while acting: one JSON line per event on stderr, prefixed with "@" (stdout keeps
/// the single result line). The sidecar turns these into the Sidekick's cursor, window peek and heads-up.
func progress(_ d: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: d), let line = String(data: data, encoding: .utf8) else { return }
    FileHandle.standardError.write(("@" + line + "\n").data(using: .utf8)!)
}
/// Before taking the real cursor: tell the user (the Sidekick says so), and if they're using the mouse or keyboard
/// right now give them a moment to let go. Returns what to restore afterwards.
func borrowBegin() -> (CGPoint?, NSRunningApplication?)? {
    progress(["ev": "borrow"])
    // A moment for the heads-up to show, then wait until they've stopped typing and moving the mouse for a second:
    // taking over mid-sentence sends their keystrokes into the target app. If they keep going, don't take over.
    Thread.sleep(forTimeInterval: 0.9)
    let anyInput = CGEventType(rawValue: ~0)!
    let until = Date().addingTimeInterval(8)
    while CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) < 1.0 {
        if Date() > until { progress(["ev": "return"]); return nil }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return (CGEvent(source: nil)?.location, NSWorkspace.shared.frontmostApplication)
}
/// Set when a step needed the real cursor but the user was busy, so it was skipped instead.
var userBusy = false
/// Gives the cursor and the front app back.
func borrowEnd(_ saved: (CGPoint?, NSRunningApplication?), _ w: Win) {
    if let c = saved.0 { CGWarpMouseCursorPosition(c); CGAssociateMouseAndMouseCursorPosition(1) }
    if let prev = saved.1, prev.processIdentifier != w.pid, !isRoamies(prev.processIdentifier) { prev.activate(options: []) }
    progress(["ev": "return"])
}
/// Set when a borrowed step's app didn't come forward, so nothing was pressed: why, for that step's error.
var wrongFront: String? = nil
/// After a borrowed step asked its app to come forward: nil to go ahead, else why it stops. Real keys and clicks
/// land in whichever app is in front, so with anything but the target app there nothing is pressed.
func borrowVerdict(target: String, targetPid: pid_t, frontPid: pid_t?, frontName: String?) -> String? {
    if frontPid == targetPid { return nil }
    let other = frontName.flatMap { $0.isEmpty ? nil : $0 } ?? "another app"
    return "\(other) is in front instead of \(target), so I stopped before pressing keys in the wrong app."
}
/// What to give back once this run ends, after a step took the real cursor and keyboard.
var borrowed: (CGPoint?, NSRunningApplication?)? = nil
/// Runs body with the real cursor and keyboard. They stay borrowed (the app in front) until the run ends: an app in the
/// background ignores keys sent to it, so a Return after a borrowed fill did nothing and the search never ran.
@discardableResult
func withRealCursor<T>(raise: Bool = true, _ body: () -> T) -> T? {
    guard BG, !fgActive, let w = bgWin, let app = bgApp else { return body() }
    usedRealCursor = true
    guard let saved = borrowBegin() else { userBusy = true; return nil }
    borrowed = saved; fgActive = true
    _ = bringToFront(w, app, raise: raise)
    let front = NSWorkspace.shared.frontmostApplication
    if let why = borrowVerdict(target: w.app, targetPid: w.pid, frontPid: front?.processIdentifier, frontName: front?.localizedName) {
        giveBack(); wrongFront = why; return nil
    }
    return body()
}
/// Gives the cursor and the front app back, if a step borrowed them.
func giveBack() {
    guard let saved = borrowed, let w = bgWin else { return }
    borrowed = nil; fgActive = false
    borrowEnd(saved, w)
}
/// Saves the document in that window without bringing its app forward: AppleScript's save, which document-based
/// apps (TextEdit, Pages, Numbers, Preview…) support. Only documents that already have a file (no Save dialog).
func saveInBackground(_ w: Win) -> Bool {
    guard let bundle = NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier else { return false }
    // The window's own file, from its accessibility info: matches the right document even when several share a name.
    // TextEdit saves but often never answers the save event, so don't wait for a reply: watch the file change instead.
    if let axw = axWindow(axApp(w), w), let doc = str(axw, "AXDocument"), let url = URL(string: doc), url.isFileURL {
        let path = url.path
        let esc = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let mtime = { (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil }
        let before = mtime()
        let script = """
        with timeout of 3 seconds
        tell application id "\(bundle)"
        repeat with x in documents
        set p to ""
        try
        set p to (path of x) as text
        end try
        if p is "\(esc)" or "/private" & p is "\(esc)" or p is "/private\(esc)" then
        ignoring application responses
        save x
        end ignoring
        return
        end if
        end repeat
        end tell
        end timeout
        error "not found"
        """
        if run("/usr/bin/osascript", ["-e", script]) == 0 {
            let until = Date().addingTimeInterval(3)
            while Date() < until {
                if let a = mtime(), a != before { return true }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }
    let title = w.title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
    with timeout of 8 seconds
    tell application id "\(bundle)"
    set d to missing value
    repeat with x in documents
    if name of x is "\(title)" or "\(title)" starts with (name of x) then set d to x
    end repeat
    if d is missing value then set d to document 1
    if path of d is missing value then error "no file"
    save d
    end tell
    end timeout
    """
    return run("/usr/bin/osascript", ["-e", script]) == 0
}
enum MenuShortcut { case pressed, greyedOut, notFound }
enum ShortcutRoute { case menu, realKeyboard, sendKey }
// Measured with TextEdit behind another app: Close reads greyed out there and Cmd+W sent to it does nothing, so a
// greyed-out item needs the real keyboard. Items that read enabled are still pressed in place.
let MENU_WORKS_BEHIND = true
// In front the key goes straight to the app. Behind: the menu item if it was pressed, the real keyboard (app brought
// forward, then given back) if it is greyed out or menus can't be trusted there, else the key is sent to the app.
func shortcutRoute(item: MenuShortcut, appInFront: Bool, trustMenu: Bool) -> ShortcutRoute {
    if appInFront || item == .notFound { return .sendKey }
    return item == .pressed && trustMenu ? .menu : .realKeyboard
}
/// Cmd shortcuts in the background: press the app's menu item that has that shortcut (keys sent to a background
/// app don't reach its menus, so Cmd+S typed the line but never saved). press: false only looks, so an item that
/// could be pressed still reads .pressed.
func pressMenuShortcut(_ app: AXUIElement, _ combo: String, press: Bool = true) -> MenuShortcut {
    let parts = combo.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
    guard let key = parts.last, key.count == 1, parts.contains(where: { ["cmd", "command", "meta", "super"].contains($0) }) else { return .notFound }
    let shift = parts.contains("shift"), opt = parts.contains { ["opt", "option", "alt"].contains($0) }, ctrl = parts.contains { ["ctrl", "control"].contains($0) }
    let want = (shift ? 1 : 0) | (opt ? 2 : 0) | (ctrl ? 4 : 0)
    guard let bar = attr(app, kAXMenuBarAttribute) else { return .notFound }
    var stack: [(AXUIElement, Int)] = [(bar as! AXUIElement, 0)]
    var visited = 0, greyed = false
    while let (el, d) = stack.popLast(), visited < 3000 {
        visited += 1
        let a = attrs(el, ["AXMenuItemCmdChar", "AXMenuItemCmdModifiers", kAXEnabledAttribute, kAXChildrenAttribute])
        if let ch = a[0] as? String, ch.lowercased() == key, let mods = (a[1] as? NSNumber)?.intValue, mods & 8 == 0, mods & 7 == want {
            if (a[2] as? Bool) == false { greyed = true }
            // A press that fails counts as not found, so the key is sent to the app as before.
            else { return !press || AXUIElementPerformAction(el, kAXPressAction as CFString) == .success ? .pressed : .notFound }
        }
        if d < 4, let kids = a[3] as? [AXUIElement] { for k in kids { stack.append((k, d + 1)) } }
    }
    return greyed ? .greyedOut : .notFound
}
func typeText(_ s: String) {
    for chunk in Array(s.utf16).chunked(16) {
        var u = chunk
        let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!, up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!
        d.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
        up.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
        d.flags = []; up.flags = []
        send(d); send(up)
        Thread.sleep(forTimeInterval: 0.012)
    }
}
extension Array { func chunked(_ n: Int) -> [[Element]] { stride(from: 0, to: count, by: n).map { Array(self[$0 ..< Swift.min($0 + n, count)]) } } }

let KEYS: [String: CGKeyCode] = ["return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
    "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
    "j": 38, "k": 40, "n": 45, "m": 46, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
    "f10": 109, "f11": 103, "f12": 111, "=": 24, "-": 27, "/": 44, ".": 47, ",": 43, ";": 41, "'": 39, "[": 33, "]": 30, "\\": 42, "`": 50]
/// Keys people (and models) name by symbol or word: Calculator's "*" or "multiply" is shift+8. Unknown names
/// used to fail the whole step list.
let KEY_ALIASES: [String: String] = ["*": "shift+8", "multiply": "shift+8", "times": "shift+8", "+": "shift+=", "plus": "shift+=", "add": "shift+=",
    "minus": "-", "subtract": "-", "divide": "/", "slash": "/", "equals": "=", "equal": "=", "period": ".", "dot": ".", "decimal": ".", "comma": ",",
    "%": "shift+5", "percent": "shift+5", "(": "shift+9", ")": "shift+0", "!": "shift+1", "@": "shift+2", "#": "shift+3", "$": "shift+4",
    "^": "shift+6", "&": "shift+7", "_": "shift+-", "?": "shift+/", ":": "shift+;", "\"": "shift+'", "<": "shift+,", ">": "shift+.",
    "{": "shift+[", "}": "shift+]", "|": "shift+\\", "~": "shift+`", "page_up": "pageup", "page_down": "pagedown", "pgup": "pageup", "pgdn": "pagedown",
    "del": "forwarddelete", "arrowleft": "left", "arrowright": "right", "arrowup": "up", "arrowdown": "down", "spacebar": "space", "back": "backspace",
    // Mac text has no Cmd/Ctrl+End: the end and start of a document are Cmd+Down and Cmd+Up.
    "cmd+end": "cmd+down", "cmd+home": "cmd+up", "ctrl+end": "cmd+down", "ctrl+home": "cmd+up", "command+end": "cmd+down", "command+home": "cmd+up"]
/// "cmd+a", "shift+tab", "return", "*", "cmd+end".
func pressKey(_ combo: String) -> Bool {
    var flags: CGEventFlags = []
    var key: CGKeyCode?
    var c = combo.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
    if let a = KEY_ALIASES[c] { c = a }
    // "+" alone, or "cmd++": the last + is the key itself.
    var parts = c.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
    if c.hasSuffix("++") || c == "+" { parts += ["shift", "="] }
    parts = parts.flatMap { KEY_ALIASES[$0].map { $0.split(separator: "+").map(String.init) } ?? [$0] }
    for part in parts {
        switch part {
        case "cmd", "command": flags.insert(.maskCommand)
        case "ctrl", "control": flags.insert(.maskControl)
        case "opt", "option", "alt": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift)
        default: key = KEYS[part]
        }
    }
    guard let k = key else { return false }
    let d = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: true)!, u = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: false)!
    d.flags = flags; u.flags = flags
    send(d); send(u)
    Thread.sleep(forTimeInterval: 0.05)
    return true
}
func click(_ p: CGPoint) {
    if inBackground {
        if bgClick(bgPid!, p) { return }
        withRealCursor { click(p) }
        return
    }
    for t in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
        e.flags = []
        e.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.04)
    }
}

// Apps Sidekick may point at but never type or click in: typing into a terminal would run commands
// past every check, and these others hold passwords or security settings.
let HANDS_OFF: [String: String] = [
    "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm", "dev.warp.Warp-Stable": "Warp", "dev.warp.Warp": "Warp",
    "com.mitchellh.ghostty": "Ghostty", "net.kovidgoyal.kitty": "kitty", "org.alacritty": "Alacritty", "io.alacritty": "Alacritty",
    "com.github.wez.wezterm": "WezTerm", "co.zeit.hyper": "Hyper", "org.tabby": "Tabby", "com.raphaelamorim.rio": "Rio",
    "com.apple.keychainaccess": "Keychain Access", "com.apple.Passwords": "Passwords", "com.apple.ScriptEditor2": "Script Editor",
    "com.apple.Automator": "Automator", "com.apple.systempreferences": "System Settings", "com.apple.Settings": "System Settings",
    "com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password", "com.bitwarden.desktop": "Bitwarden",
    "com.apple.dt.Xcode": "Xcode", "com.apple.Console": "Console", "com.apple.ActivityMonitor": "Activity Monitor",
    "com.apple.DiskUtility": "Disk Utility", "com.apple.MigrateAssistant": "Migration Assistant", "com.apple.installer": "Installer",
]

func handsOff(_ pid: pid_t) -> String? {
    guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
    return HANDS_OFF[id]
}

// ---------- permission guide ----------
// A small panel that sits under System Settings while a Privacy pane is open, holding BitJarvis' icon
// so it can be dragged straight into the list (macOS sometimes leaves the app out). Lives until
// stdin closes (BitJarvis quit or stopped it), Settings closes, or Accessibility is granted.

enum Pal {
    static func c(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static let bg = c(0x051214), panel = c(0x071a1c), ink = c(0xe8fffa), ink2 = c(0xb4d8d1)
    static let line = c(0x1d4a48), lineHi = c(0x2f7c74), lineHot = c(0x4fbfa9), accent = c(0x78ffe2)
}

/// The onboarding's pixel frame: corners cut in two steps of `s` points (same polygon as .px in onboarding.css).
func pixelPath(_ r: NSRect, _ s: CGFloat = 2) -> NSBezierPath {
    let (x0, y0, x1, y1) = (r.minX, r.minY, r.maxX, r.maxY)
    let pts: [(CGFloat, CGFloat)] = [
        (x0 + 2 * s, y0), (x1 - 2 * s, y0), (x1 - 2 * s, y0 + s), (x1 - s, y0 + s), (x1 - s, y0 + 2 * s), (x1, y0 + 2 * s),
        (x1, y1 - 2 * s), (x1 - s, y1 - 2 * s), (x1 - s, y1 - s), (x1 - 2 * s, y1 - s), (x1 - 2 * s, y1), (x0 + 2 * s, y1),
        (x0 + 2 * s, y1 - s), (x0 + s, y1 - s), (x0 + s, y1 - 2 * s), (x0, y1 - 2 * s), (x0, y0 + 2 * s), (x0 + s, y0 + 2 * s),
        (x0 + s, y0 + s), (x0 + 2 * s, y0 + s),
    ]
    let p = NSBezierPath()
    p.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
    for q in pts.dropFirst() { p.line(to: NSPoint(x: q.0, y: q.1)) }
    p.close()
    return p
}

func drawFrame(_ r: NSRect, frame: NSColor, fill: NSColor, width: CGFloat = 2) {
    frame.setFill(); pixelPath(r).fill()
    fill.setFill(); pixelPath(r.insetBy(dx: width, dy: width)).fill()
}

func guideEvent(_ o: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: o), let t = String(data: d, encoding: .utf8) { print(t) }
}

final class GuideBack: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { drawFrame(bounds, frame: Pal.lineHi, fill: Pal.panel) }
}

/// BitJarvis' icon and name. Dragging it hands System Settings the app bundle, like dragging it from Finder.
final class DragPill: NSView, NSDraggingSource {
    let url: URL
    let icon: NSImage
    var hot = false { didSet { needsDisplay = true } }
    var dragging = false { didSet { needsDisplay = true } }
    init(frame: NSRect, url: URL) {
        self.url = url
        icon = NSWorkspace.shared.icon(forFile: url.path)
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("BitJarvis app. Drag into the list above.")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand) }
    override func mouseEntered(with event: NSEvent) { hot = true }
    override func mouseExited(with event: NSEvent) { hot = false }
    override func draw(_ dirtyRect: NSRect) {
        drawFrame(bounds, frame: hot || dragging ? Pal.accent : Pal.lineHot, fill: Pal.bg)
        let side = bounds.height - 16
        icon.draw(in: NSRect(x: 10, y: 8, width: side, height: side), from: .zero, operation: .sourceOver, fraction: dragging ? 0.35 : 1, respectFlipped: true, hints: nil)
        let label = NSAttributedString(string: "BitJarvis", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: Pal.ink])
        let sz = label.size()
        label.draw(at: NSPoint(x: 10 + side + 8, y: (bounds.height - sz.height) / 2))
    }
    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let img = NSImage(size: NSSize(width: 64, height: 64))
        img.lockFocus(); icon.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64)); img.unlockFocus()
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - 32, y: p.y - 32, width: 64, height: 64), contents: img)
        dragging = true
        window?.invalidateCursorRects(for: self)
        guideEvent(["event": "drag_started"])
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        window?.invalidateCursorRects(for: self)
        guideEvent(["event": "drag_ended", "dropped": !operation.isEmpty])
    }
}

final class Guide: NSObject {
    static let settingsID = "com.apple.systempreferences"
    let kind: String
    let preview: Bool
    let panel: NSPanel
    let title = NSTextField(labelWithString: ""), body = NSTextField(wrappingLabelWithString: "")
    var pill: DragPill?
    var seen = false, missing = 0, done = false
    var dragging: Bool { pill?.dragging ?? false }

    init(kind: String, app: URL?, preview: Bool) {
        self.kind = kind
        self.preview = preview
        let hasPill = app != nil
        let size = NSSize(width: hasPill ? 452 : 320, height: 80)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.alphaValue = 0
        let back = GuideBack(frame: NSRect(origin: .zero, size: size))
        panel.contentView = back
        var textX: CGFloat = 16
        if let app {
            let p = DragPill(frame: NSRect(x: 12, y: 12, width: 132, height: 56), url: app)
            back.addSubview(p)
            pill = p
            textX = 12 + 132 + 14
        }
        title.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        title.textColor = Pal.ink
        body.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        body.textColor = Pal.ink2
        body.maximumNumberOfLines = 2
        let w = size.width - textX - 14
        title.frame = NSRect(x: textX, y: 14, width: w, height: 18)
        body.frame = NSRect(x: textX, y: 34, width: w, height: 34)
        for t in [title, body] { t.lineBreakMode = .byWordWrapping; back.addSubview(t) }
        // The guide opens Settings directly (no macOS dialog), so BitJarvis usually isn't in the list yet.
        title.stringValue = hasPill ? "Drag me into the list above." : "Add me to the list above."
        body.stringValue = kind == "screen"
            ? "Use Screen & System Audio Recording, not the audio-only list."
            : hasPill ? "Already there? Just switch me on." : "Press + under the list and pick BitJarvis."
        panel.setAccessibilityLabel("BitJarvis permission guide")
    }

    /// The biggest System Settings window, in AppKit coordinates (origin bottom-left of the main screen).
    func settingsFrame() -> NSRect? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: Guide.settingsID).map { $0.processIdentifier })
        guard !pids.isEmpty, let main = NSScreen.screens.first else { return nil }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let rects: [NSRect] = list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  let b = w[kCGWindowBounds as String] as? [String: Double], (b["Width"] ?? 0) > 300, (b["Height"] ?? 0) > 200 else { return nil }
            let (x, y, ww, hh) = (b["X"] ?? 0, b["Y"] ?? 0, b["Width"] ?? 0, b["Height"] ?? 0)
            return NSRect(x: x, y: main.frame.maxY - y - hh, width: ww, height: hh)
        }
        return rects.max { $0.width * $0.height < $1.width * $1.height }
    }

    /// Under the window, centred on its content side (right of the sidebar); inside its bottom edge if there's no room below.
    func place(_ win: NSRect) {
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(win) }?.visibleFrame ?? win
        let sidebar: CGFloat = win.width > 640 ? 220 : 0
        var x = win.minX + sidebar + (win.width - sidebar - size.width) / 2
        var y = win.minY - size.height - 10
        if y < screen.minY { y = win.minY + 14 }
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        y = min(max(y, screen.minY + 8), screen.maxY - size.height - 8)
        let to = NSRect(origin: NSPoint(x: x.rounded(), y: y.rounded()), size: size)
        if to != panel.frame { panel.setFrame(to, display: true) }
    }

    func show(_ on: Bool) {
        let target: CGFloat = on ? 1 : 0
        if panel.alphaValue == target { return }
        if on { panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = target
        }
    }

    func tick() {
        if done { return }
        if kind == "accessibility" && !preview && AXIsProcessTrusted() {
            done = true
            title.stringValue = "All set!"
            body.stringValue = "You can close System Settings."
            pill?.isHidden = true
            guideEvent(["event": "granted"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.show(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
            return
        }
        guard let win = settingsFrame() else {
            missing += 1
            // Settings closed after it was up (or never opened within a minute): nothing left to guide.
            if !dragging && ((seen && missing > 8) || missing > 240) { guideEvent(["event": "closed"]); exit(0) }
            if !dragging { show(false) }
            return
        }
        missing = 0
        if !seen { seen = true; guideEvent(["event": "attached"]) }
        place(win)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        show(dragging || front == Guide.settingsID || front == nil)
    }
}

func runGuide(_ rest: [String]) -> Never {
    // --preview: stay up even when already allowed, to look at the panel.
    let preview = rest.contains("--preview")
    let pos = rest.filter { $0 != "--preview" }
    let kind = pos.first ?? "accessibility"
    let app = pos.count > 1 && pos[1].hasSuffix(".app") ? URL(fileURLWithPath: pos[1]) : nil
    let nsApp = NSApplication.shared
    nsApp.setActivationPolicy(.accessory)
    let guide = Guide(kind: kind, app: app, preview: preview)
    // BitJarvis holds our stdin open; when it closes (stopped, or BitJarvis quit), go.
    Thread { while FileHandle.standardInput.availableData.count > 0 {}; exit(0) }.start()
    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in guide.tick() }
    guide.tick()
    nsApp.run()
    exit(0)
}

// ---------- secrets ----------
// The user's own API keys (Fish Audio) live in their login keychain: encrypted at rest, locked with their Mac
// login, and readable without a prompt only by this signed helper. A secret comes in on stdin and goes out on
// stdout, never in arguments (other processes can read those).
let secretService = "com.kenkai.roamies"
func secretName(_ i: Int) -> String {
    guard args.count > i, args[i].range(of: "^[a-z0-9-]{1,40}$", options: .regularExpression) != nil else { fail("bad secret name") }
    return args[i]
}
func secretQuery(_ name: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: secretService, kSecAttrAccount as String: name]
}

// ---------- commands ----------

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { fail("no command") }

switch cmd {
// --self-test checks which of an app's windows is used and when typing may go ahead, with made-up cases; exits 1 on a failure.
case "--self-test":
    var bad = 0
    func check(_ name: String, _ ok: Bool) { print("\(ok ? "ok" : "FAIL") \(name)"); if !ok { bad += 1 } }
    let win = { (id: Int, title: String, w: Double, h: Double) in Win(id: id, pid: 1, app: "App", title: title, x: 0, y: 0, w: w, h: h) }
    check("a small untitled button over the main window is passed over", mainWindow([win(1, "", 183, 88), win(2, "CapCut", 1800, 1066)])?.id == 2)
    check("even when the main window is untitled", mainWindow([win(1, "", 183, 88), win(2, "", 1800, 1066)])?.id == 2)
    check("a titled small window in front is kept", mainWindow([win(1, "Export", 300, 200), win(2, "Doc", 1800, 1066)])?.id == 1)
    check("a sizeable untitled window in front is kept", mainWindow([win(1, "", 900, 600), win(2, "Doc", 1800, 1066)])?.id == 1)
    check("an app with only a small window still has it", mainWindow([win(1, "", 183, 88)])?.id == 1)
    let main = Win(id: 2, pid: 1, app: "CapCut", title: "CapCut", x: 0, y: 39, w: 1800, h: 1066), badge = Win(id: 1, pid: 1, app: "CapCut", title: "", x: 1625, y: 1029, w: 183, h: 88)
    check("a capture that also shows a child window maps over both", shotArea(main, [badge, main], [1568, 935]) == CGRect(x: 0, y: 39, width: 1808, height: 1078))
    check("a capture of the window alone maps over the window", shotArea(main, [badge, main], [1568, 929]) == nil)
    // Regression: CapCut's Scale box is invisible to accessibility, so typing after clicking it was refused every time.
    check("typing after a click in an app that hides its fields", mayType(editable: false, focusRole: "AXWindow", clickedSpot: true))
    check("no typing in such an app without a click first", !mayType(editable: false, focusRole: "AXWindow", clickedSpot: false))
    check("no typing on a web page outside a field, even after a click", !mayType(editable: false, focusRole: "AXWebArea", clickedSpot: true))
    check("typing in a real text field", mayType(editable: true, focusRole: "AXTextField", clickedSpot: false))
    // Regression: click_text "Speed" (a tab CapCut hides from accessibility) clicked a clip named "MTLSVideoP:speed.mp4".
    check("a word inside a file name isn't a word match", matchScore("mtlsvideop:speed.mp4", "speed") == 2)
    check("so click_text won't click it", !clickMatch(["match": ["exact", "word", "partial"][matchScore("mtlsvideop:speed.mp4", "speed")]]))
    check("inside a longer word isn't clickable", !clickMatch(["match": ["exact", "word", "partial"][matchScore("following", "follow")]]))
    check("the whole label matches", matchScore("speed", "speed") == 0)
    check("a whole word in a label matches", matchScore("save changes", "save") == 1 && matchScore("speed:", "speed") == 1 && matchScore("next \u{2192}", "next") == 1)
    check("an amount with symbols matches", matchScore("total $1,250", "$1,250") == 1)
    // Waits after a click or key end early once the page reacts, wherever they are; others always run in full.
    check("wait after a click, before a screenshot, can end early", reactWaits(["click_at", "wait", "take_screenshot"]) == [1])
    check("wait at the end after a key can end early", reactWaits(["fill", "key", "wait"]) == [2])
    check("a wait first or after typing runs in full", reactWaits(["wait", "type", "wait", "read_window"]).isEmpty)
    check("each wait after a click counts", reactWaits(["click_at", "wait", "click_at", "wait", "take_screenshot"]) == [1, 3])
    // A guess fitted to the pixels: a dark page with a light square at 30,10 (20×20) and a smaller one at 70,40 (6×6).
    func canvas(_ w: Int, _ h: Int, _ rects: [CGRect]) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0 ..< w * h { b[i * 4] = 22; b[i * 4 + 1] = 24; b[i * 4 + 2] = 29; b[i * 4 + 3] = 255 }
        for r in rects { for y in Int(r.minY) ..< Int(r.maxY) { for x in Int(r.minX) ..< Int(r.maxX) { let i = (y * w + x) * 4; b[i] = 230; b[i + 1] = 230; b[i + 2] = 230 } } }
        return b
    }
    let img = canvas(100, 60, [CGRect(x: 30, y: 10, width: 20, height: 20), CGRect(x: 70, y: 40, width: 6, height: 6)])
    check("a guess a few pixels off fits the square", fitBox(img, 100, 60, CGRect(x: 25, y: 5, width: 20, height: 20), join: 0) == CGRect(x: 30, y: 10, width: 20, height: 20))
    check("a loose guess round a small dot fits the dot", fitBox(img, 100, 60, CGRect(x: 63, y: 33, width: 20, height: 20), join: 0) == CGRect(x: 70, y: 40, width: 6, height: 6))
    check("a guess on empty space fits nothing", fitBox(canvas(100, 60, [CGRect(x: 2, y: 2, width: 4, height: 4)]), 100, 60, CGRect(x: 60, y: 30, width: 20, height: 20), join: 0) == nil)
    // Two strokes 2 px apart: joined into one icon when the guess is icon-sized, kept apart for a letter-sized guess.
    let strokes = canvas(80, 40, [CGRect(x: 20, y: 10, width: 6, height: 20), CGRect(x: 28, y: 10, width: 6, height: 20)])
    check("an icon's strokes join", fitBox(strokes, 80, 40, CGRect(x: 18, y: 8, width: 18, height: 24), join: 3) == CGRect(x: 20, y: 10, width: 14, height: 20))
    check("a letter-sized guess keeps neighbours apart", fitBox(strokes, 80, 40, CGRect(x: 19, y: 9, width: 8, height: 22), join: 0) == CGRect(x: 20, y: 10, width: 6, height: 20))
    // Regression: Cmd+W to TextEdit behind another app was logged as pressed but did nothing (Close is greyed out there).
    check("an enabled menu item is pressed in place", shortcutRoute(item: .pressed, appInFront: false, trustMenu: true) == .menu)
    check("a greyed-out item behind another app gets the real key", shortcutRoute(item: .greyedOut, appInFront: false, trustMenu: true) == .realKeyboard)
    check("a shortcut with no menu item is sent to the app", shortcutRoute(item: .notFound, appInFront: false, trustMenu: true) == .sendKey)
    check("with the app in front the key is just pressed", shortcutRoute(item: .greyedOut, appInFront: true, trustMenu: true) == .sendKey)
    check("menus not trusted behind: the real key, not the menu", shortcutRoute(item: .pressed, appInFront: false, trustMenu: false) == .realKeyboard)
    // Regression: a borrowed Cmd+W was pressed whether or not its app had come forward, so it could land in another app.
    check("a borrowed key goes ahead with its app in front", borrowVerdict(target: "TextEdit", targetPid: 7, frontPid: 7, frontName: "TextEdit") == nil)
    check("another app in front stops it, by name", borrowVerdict(target: "TextEdit", targetPid: 7, frontPid: 9, frontName: "Ghostty") == "Ghostty is in front instead of TextEdit, so I stopped before pressing keys in the wrong app.")
    check("no app known in front stops it too", borrowVerdict(target: "TextEdit", targetPid: 7, frontPid: nil, frontName: nil) == "another app is in front instead of TextEdit, so I stopped before pressing keys in the wrong app.")
    // Regression: click_text "Delete" searched the window the plan started on, not the document it had opened since.
    let pw = { (id: Int, pid: pid_t) in Win(id: id, pid: pid, app: "App", title: "w\(id)", x: 0, y: 0, w: 600, h: 400) }
    check("a window in front of the plan's window is searched", newerWindows([pw(5, 1), pw(2, 1)], pinned: pw(2, 1)).map { $0.id } == [5])
    check("windows behind the plan's window are not", newerWindows([pw(2, 1), pw(1, 1)], pinned: pw(2, 1)).isEmpty)
    check("another app's window in front is not", newerWindows([pw(9, 7), pw(5, 1), pw(2, 1)], pinned: pw(2, 1)).map { $0.id } == [5])
    check("the plan's window gone: that app's windows", newerWindows([pw(9, 7), pw(5, 1), pw(4, 1)], pinned: pw(2, 1)).map { $0.id } == [5, 4])
    check("at most 3, front first", newerWindows([pw(8, 1), pw(7, 1), pw(6, 1), pw(5, 1), pw(2, 1)], pinned: pw(2, 1)).map { $0.id } == [8, 7, 6])
    // Regression: the plan's window had closed, and click_text "Delete" still looked inside its old rectangle, so it
    // picked the dialog's sentence containing "delete" over the Delete button beside it.
    let moved = Win(id: 2, pid: 1, app: "App", title: "w2", x: 40, y: 60, w: 600, h: 400)
    check("the plan's window still open: as it is now", currentWindow([pw(5, 1), moved], pinned: pw(2, 1)).map { [$0.id, Int($0.x), Int($0.y)] } == [2, 40, 60])
    check("the plan's window gone: that app's front window", currentWindow([pw(9, 7), pw(5, 1), pw(4, 1)], pinned: pw(2, 1))?.id == 5)
    check("the plan's window gone and none left: nothing", currentWindow([], pinned: pw(2, 1)) == nil)
    check("another app's windows are never taken", currentWindow([pw(9, 7), pw(8, 7)], pinned: pw(2, 1)) == nil)
    exit(bad == 0 ? 0 : 1)

case "trusted":
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: args.contains("--prompt")] as CFDictionary
    out(["ok": true, "trusted": AXIsProcessTrustedWithOptions(opts)])

case "windows":
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    out(["ok": true, "windows": windows().prefix(30).map { var i = winInfo($0); if $0.pid == front { i["frontApp"] = true }; return i }])

// Where the user is right now, for each message's live state: the app in front (never BitJarvis), its focused
// window's title, and for a browser the page's address. Accessibility for the title and address; the window list
// (title only with Screen Recording) as a fallback. Fast, read-only, never focuses anything.
case "front":
    var o: [String: Any] = ["ok": true]
    let wins = windows()
    let frontPid = NSWorkspace.shared.frontmostApplication.flatMap { isRoamies($0.processIdentifier) ? nil : $0.processIdentifier }
    guard let pid = frontPid ?? wins.first?.pid, let app = NSRunningApplication(processIdentifier: pid) else { out(o) }
    o["app"] = app.localizedName ?? "?"
    if let b = app.bundleIdentifier { o["bundle"] = b }
    let ax = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(ax, 0.25)
    var title = wins.first { $0.pid == pid }?.title ?? ""
    if let w = attr(ax, kAXFocusedWindowAttribute) {
        let win = w as! AXUIElement
        if let t = str(win, kAXTitleAttribute) { title = t }
        // Browsers put the address on the window (Safari) or on the web area inside it (Chromium browsers).
        if BROWSERS.contains(app.localizedName ?? "") {
            var url = str(win, "AXURL") ?? (attr(win, "AXURL") as? URL)?.absoluteString
            if url == nil {
                var queue: [AXUIElement] = [win], seen = 0
                while url == nil, !queue.isEmpty, seen < 400 {
                    let el = queue.removeFirst(); seen += 1
                    if str(el, kAXRoleAttribute) == "AXWebArea" { url = (attr(el, "AXURL") as? URL)?.absoluteString ?? str(el, "AXURL"); if url != nil { break } }
                    if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids.prefix(40)) }
                }
            }
            if let u = url { o["url"] = u }
        }
    }
    if !title.isEmpty { o["title"] = title }
    out(o)

case "locate":
    guard args.count >= 2 else { fail("usage: locate <target>") }
    if args[1] == "screen" { out(["ok": true, "what": "screen"]) }
    guard let w = resolve(args[1]) else { fail("No matching window is open\(args[1].hasPrefix("app:") ? " for \(args[1].dropFirst(4))" : "").") }
    out(["ok": true, "window": winInfo(w)])

case "capture":
    // capture <out> <target> [max]: with max, the image is shrunk here to at most max px on its long side
    // (in-process, no extra sips runs) and its final pixel size is returned as "pixels".
    // capture <out> <target> [max] [thumb thumbMax]: thumb is a second, smaller copy for the Sidekick to show.
    guard args.count >= 3 else { fail("usage: capture <out> <target> [max] [thumb thumbMax]") }
    let file = args[1], target = args[2], maxPx = args.count >= 4 ? Int(args[3]) : nil
    let thumb = args.count >= 5 ? args[4] : nil, thumbMax = args.count >= 6 ? Int(args[5]) ?? 900 : 900
    func makeThumb() {
        guard let thumb, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil) else { return }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: thumbMax, kCGImageSourceCreateThumbnailWithTransform: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: thumb) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        _ = CGImageDestinationFinalize(dst)
    }
    func shrink() -> [Int]? {
        guard let maxPx, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        if max(pw, ph) <= maxPx { return [pw, ph] }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPx, kCGImageSourceCreateThumbnailWithTransform: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: file) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? [img.width, img.height] : nil
    }
    if target == "screen" {
        // The main display without BitJarvis on it (shared/shot.swift); older macOS: screencapture, BitJarvis and all.
        let px = Shot.capture(nil, to: file, png: false, maxPx: maxPx)
        if px == nil { guard run("/usr/sbin/screencapture", ["-x", "-t", "jpg", file]) == 0 else { fail("Screen capture failed. BitJarvis may need Screen Recording permission.") } }
        // Its bounds (points) let the caller map pixels back.
        let d = CGDisplayBounds(CGMainDisplayID())
        var o: [String: Any] = ["ok": true, "file": file, "what": "screen", "bounds": [Int(d.minX), Int(d.minY), Int(d.width), Int(d.height)]]
        if let px = px ?? shrink() { o["pixels"] = px }
        makeThumb()
        out(o)
    }
    guard let w = resolve(target) else { fail("No matching window is open\(target.hasPrefix("app:") ? " for \(target.dropFirst(4))" : "").") }
    guard run("/usr/sbin/screencapture", ["-x", "-o", "-t", "jpg", "-l", String(w.id), file]) == 0 else { fail("Window capture failed. BitJarvis may need Screen Recording permission.") }
    var o: [String: Any] = ["ok": true, "file": file, "window": winInfo(w)]
    if let px = shrink() {
        o["pixels"] = px
        if let r = shotArea(w, windows(), px) { o["area"] = [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)] }
    }
    makeThumb()
    out(o)

case "select":
    guard args.count >= 2 else { fail("usage: select <out>") }
    // macOS's own crosshair: drag an area, or press Space to pick a window. Esc cancels (no file).
    _ = run("/usr/sbin/screencapture", ["-i", "-s", "-x", "-t", "png", args[1]])
    let ok = FileManager.default.fileExists(atPath: args[1])
    out(ok ? ["ok": true, "file": args[1]] : ["ok": false, "cancelled": true])

case "ui":
    guard AXIsProcessTrusted() else { fail("BitJarvis needs Accessibility permission to read other apps.") }
    guard args.count >= 2, let w = resolve(args[1]) else { fail("No matching window is open.") }
    let uiApp = axApp(w)
    let items = walk(uiApp, w).map { $0.1 }
    // ui <target> controls: just the controls (to re-find ids before acting), without the page's text.
    if args.count >= 3, args[2] == "controls" { out(["ok": true, "window": winInfo(w), "controls": items]) }
    let scan = scanText(uiApp, w)
    out(["ok": true, "window": winInfo(w), "controls": items, "texts": pageText(uiApp, w, cap: 5000, scan: scan), "elsewhere": offscreenText(uiApp, w, cap: 4000, scan: scan), "note": items.isEmpty ? "This app shares no controls. Use a screenshot plus click at coordinates instead." : ""])

case "locate-control":
    guard AXIsProcessTrusted() else { fail("BitJarvis needs Accessibility permission to read other apps.") }
    guard args.count >= 3, let w = resolve(args[1]), let id = Int(args[2]) else { fail("usage: locate-control <target> <id>") }
    let items = walk(axApp(w), w)
    guard id >= 1, id <= items.count else { fail("No control \(id) in \(w.app). Read the window again.") }
    out(["ok": true, "window": winInfo(w), "control": items[id - 1].1])

case "refine":
    // refine '[[x,y,w,h],…]' [window:<id>]: boxes guessed from a screenshot (global points) fitted to what's really
    // drawn there; null where nothing clear is there. With a window: its own pixels, as its screenshot showed them.
    guard args.count >= 2, let data = args[1].data(using: .utf8), let list = (try? JSONSerialization.jsonObject(with: data)) as? [[Double]] else { fail("usage: refine '[[x,y,w,h],...]' [window:<id>]") }
    let shown = args.count >= 3 ? resolve(args[2]).flatMap { pixelsOf($0) } : nil
    let fitted: [Any] = list.map { b -> Any in
        guard b.count == 4, b[2] > 0, b[3] > 0 else { return NSNull() }
        let g = CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
        if let (img, area) = shown { return fitRect(in: img, area: area, guess: g).map { r in [r.minX, r.minY, r.width, r.height].map { ($0 * 10).rounded() / 10 } } ?? NSNull() }
        let pad = max(12, 0.6 * max(g.width, g.height))
        let region = onDisplay(g.insetBy(dx: -pad, dy: -pad))
        guard !region.isEmpty, let img = Shot.image(region), let r = fitRect(in: img, area: region, guess: g) else { return NSNull() }
        return [r.minX, r.minY, r.width, r.height].map { ($0 * 10).rounded() / 10 }
    }
    out(["ok": true, "boxes": fitted])

case "ocr-find":
    // ocr-find <target> <text> [all]: the text read off a window ('screen': the main display), with exact boxes.
    guard args.count >= 3 else { fail("usage: ocr-find <target> <text> [all]") }
    let ocrWin: Win? = args[1] == "screen" ? nil : resolve(args[1])
    if args[1] != "screen" && ocrWin == nil { fail("No matching window is open.") }
    out(["ok": true, "matches": ocrFind(ocrWin, args[2], all: args.count >= 4 && args[3] == "all")])

case "find-text":
    // Looks through every window of the app ("app:X"), or every window on screen ("screen"), front to back,
    // because the text is often in a window that isn't the frontmost one.
    guard AXIsProcessTrusted() else { fail("BitJarvis needs Accessibility permission to read other apps.") }
    guard args.count >= 3 else { fail("usage: find-text <target> <text>") }
    let t = args[1]
    var wins: [Win]
    if t == "screen" { wins = windows().filter { !isRoamies($0.pid) } }
    else if t == "front", let f = resolve("front") { wins = windows().filter { $0.pid == f.pid } }
    else if t.hasPrefix("app:") { let name = String(t.dropFirst(4)); wins = windows().filter { appMatches($0.app, name) } }
    else if let w = resolve(t) { wins = [w] } else { wins = [] }
    if wins.isEmpty { fail("No matching window is open.") }
    var all: [[String: Any]] = []
    func search() {
        all = []
        for (z, w) in wins.prefix(12).enumerated() {
            for (i, m) in findText(axApp(w), w, args[2]).enumerated() {
                var m = m; m["window"] = winInfo(w); m["rank"] = z * 100 + i; all.append(m)
            }
        }
    }
    search()
    // "scroll": nothing whole on screen, so bring it into view in the frontmost window that has it, then look again.
    if args.count >= 4, args[3] == "scroll", !all.contains(where: { wholeMatch($0, args[2]) }),
       wins.prefix(12).contains(where: { scrollToText(axApp($0), $0, args[2]) }) { search() }
    // Exact text in any window beats a partial match in the front one.
    let exact = all.filter { (($0["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == args[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    let ordered = (exact + all.filter { m in !exact.contains { ($0["rank"] as? Int) == (m["rank"] as? Int) } }).prefix(8)
    out(["ok": true, "matches": Array(ordered)])

case "act":
    guard AXIsProcessTrusted() else { fail("BitJarvis needs Accessibility permission to control other apps.") }
    guard args.count >= 2, let data = args[1].data(using: .utf8),
          let plan = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let steps = plan["steps"] as? [[String: Any]] else { fail("bad plan") }
    let target = (plan["window"] as? Int).map { "window:\($0)" } ?? (plan["app"] as? String).map { "app:\($0)" } ?? "front"
    guard var w = resolve(target) else { fail("No matching window is open.") }
    var switched = false
    if let name = handsOff(w.pid) {
        fail("Blocked for safety: I can point at things in \(name), but I never type or click in it. Show the user where to click instead.")
    }
    // Bring the target app forward so keystrokes land there, not in BitJarvis (in background mode it stays behind).
    let app = axApp(w)
    bgWin = w; bgApp = app; bgPid = w.pid
    // Keys and clicks go to whichever app is in front, so the target must really be there first.
    // activate() alone is only a request since macOS 14 and is often ignored for a background helper.
    if !bringToFront(w, app) {
        out(["ok": false, "error": "Couldn't bring \(w.app) to the front, so nothing was typed or clicked. Ask the user to click its window once, then try again.", "done": []])
    }
    // With several windows of one app, keystrokes go to its main window: make that the one we read.
    if let axw = axWindow(app, w), (attr(axw, kAXMainAttribute) as? Bool) != true {
        if !BG { AXUIElementPerformAction(axw, kAXRaiseAction as CFString) }
        AXUIElementSetAttributeValue(axw, kAXMainAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.15)
    }
    var controls = walk(app, w)
    var done: [String] = []
    progress(["ev": "start", "window": winInfo(w), "steps": steps.count])
    // What a step is about to touch (global points) and what it types. Password fields only send dots.
    func emitStep(_ i: Int, _ what: String, _ e: AXUIElement?, at: CGPoint? = nil, label: String = "", text: String? = nil) {
        var d: [String: Any] = ["ev": "step", "i": i, "do": what, "label": String(label.prefix(60))]
        if let e, let f = frame(e) { d["bounds"] = [Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)] }
        else if let p = at { d["bounds"] = [Int(p.x) - 6, Int(p.y) - 6, 12, 12] }
        if let t = text {
            let secure = e.map { axRole($0) == "AXSecureTextField" || str($0, kAXSubroleAttribute) == "AXSecureTextField" } ?? false
            d["text"] = secure ? String(repeating: "•", count: min(t.count, 24)) : String(t.prefix(80))
            if secure { d["secure"] = true }
        }
        progress(d)
    }
    func el(_ s: [String: Any]) -> (AXUIElement, [String: Any])? {
        guard let id = s["id"] as? Int, id >= 1, id <= controls.count else { return nil }
        return controls[id - 1]
    }
    // A wait right after a click or key ("click Sign in, wait 2, screenshot") is there for the page to react. It ends
    // as soon as the page has changed from how it was before that action and has held still; if nothing changes it
    // waits the full time, as before.
    func pageSig() -> String {
        let cur = resolve(target) ?? w
        return "\(cur.id)|\(cur.title)#" + walk(cur.pid == w.pid ? app : axApp(cur), cur).map { "\($0.1["role"] ?? "")|\($0.1["label"] ?? "")" }.joined(separator: ";")
    }
    let earlyWaits = reactWaits(steps.map { $0["do"] as? String ?? "" })
    var sigBefore: String?
    var clickedSpot = false
    for (i, s) in steps.enumerated() {
        let what = s["do"] as? String ?? ""
        usedRealCursor = false
        userBusy = false
        wrongFront = nil
        defer { if usedRealCursor, !done.isEmpty { done[done.count - 1] += " (needed the real cursor)" } }
        defer {
            if userBusy {
                out(["ok": false, "error": "Step \(i + 1) needs the real mouse, but the user was typing or using the mouse, so I didn't take over (their keys would have gone into \(w.app)). Nothing after it ran. Tell them, and offer to finish when they're free.", "done": done])
            }
        }
        defer { if let why = wrongFront { out(["ok": false, "error": "Step \(i + 1): \(why)", "done": done]) } }
        // Earlier steps may have moved the plan's window, or closed it and opened another (cmd+n over an Open panel).
        // Text was looked for inside the old window's rectangle, so a dialog's sentence won over its Delete button.
        if what != "wait", let cur = currentWindow(windows(), pinned: w) {
            let moved = cur.id != w.id
            w = cur; bgWin = cur
            if moved { switched = true; controls = walk(app, w) }
        }
        if earlyWaits.contains(i + 1) { sigBefore = pageSig() }
        // A click at a spot only vouches for the typing that follows it (keys like cmd+a and waits in between are fine);
        // any step that moves focus elsewhere ends it.
        if !["click_at", "key", "wait", "type"].contains(what) { clickedSpot = false }
        // An earlier step may have switched apps (a click, cmd+tab, Spotlight); check before every action.
        if what != "wait", let front = NSWorkspace.shared.frontmostApplication, let name = handsOff(front.processIdentifier) {
            out(["ok": false, "error": "Blocked for safety: \(name) came to the front, and I never type or click in it.", "done": done])
        }
        // Raw keys and typing land in the front app: if another app took over, stop instead of typing into it.
        if ["key", "type", "click_at"].contains(what), frontPid() != w.pid, !bringToFront(w, app) {
            let other = NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app"
            out(["ok": false, "error": "Step \(i + 1): \(other) is in front instead of \(w.app), so I stopped before typing into the wrong app.", "done": done])
        }
        if what == "click_at", let x = s["x"] as? Double, let y = s["y"] as? Double {
            let gx = (s["global"] as? Bool ?? false) ? x : w.x + x, gy = (s["global"] as? Bool ?? false) ? y : w.y + y
            if let under = windows().first(where: { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h).contains(CGPoint(x: gx, y: gy)) }), let name = handsOff(under.pid) {
                out(["ok": false, "error": "Blocked for safety: that spot is on \(name), and I never click in it.", "done": done])
            }
        }
        switch what {
        case "focus", "click", "set", "press_button":
            guard let (e, info) = el(s) else { out(["ok": false, "error": "Step \(i + 1): no control with id \(s["id"] ?? "?"). Call read_window again.", "done": done]) }
            emitStep(i, what, e, label: (info["label"] as? String) ?? "", text: what == "set" ? s["text"] as? String : nil)
            if (what == "click" || what == "press_button"), risky((info["label"] as? String) ?? ""), (s["confirmed"] as? Bool) != true {
                out(["ok": false, "error": "Stopped before clicking \"\(info["label"] ?? "")\": it could delete, pay, send or sign out, and the user hasn't said yes to that. Tell them, and let them click it themselves.", "done": done])
            }
            if what == "set", let text = s["text"] as? String {
                // Native fields take the value directly; web page fields need real keystrokes or the page never sees it.
                if !typeInto(app, e, text).ok {
                    out(["ok": false, "error": "Step \(i + 1): couldn't put the cursor in \"\(info["label"] ?? "that field")\", so nothing was typed.", "done": done])
                }
                done.append("set \(info["label"] ?? "field \(info["id"]!)")")
            } else if what == "focus" {
                AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                if let f = frame(e) { click(CGPoint(x: f.midX, y: f.midY)) }
                done.append("focused \(info["label"] ?? "field")")
            } else if ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(str(e, kAXRoleAttribute) ?? "") {
                // "Pressing" a text box doesn't put the cursor in it; focus and click so typing lands there.
                AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                if let f = frame(e) { click(CGPoint(x: f.midX, y: f.midY)) }
                done.append("clicked \(info["label"] ?? "field")")
            } else {
                if AXUIElementPerformAction(e, kAXPressAction as CFString) != .success, let f = frame(e) { click(CGPoint(x: f.midX, y: f.midY)) }
                done.append("clicked \(info["label"] ?? "control")")
            }
            Thread.sleep(forTimeInterval: 0.15)
            if what == "click" || what == "press_button" { controls = walk(app, w) }
        case "click_text":
            // Click by the words on screen: no read_window needed first. Exact text wins over partial.
            // A whole label or heading, not words buried in a paragraph.
            let q = s["text"] as? String ?? ""
            var hit: (AXUIElement, [String: Any])?
            var opened = ""
            // A checkbox or radio by its label: press the control itself; clicking the words doesn't always tick it.
            // Browser tabs are radio buttons too (a tab titled "Sign in"), so a box inside the web page comes first, and
            // one outside it only when the words aren't found in the page.
            let boxes = controls.filter { ["AXCheckBox", "AXRadioButton"].contains(axRole($0.0)) && fold(($0.1["label"] as? String) ?? "") == fold(q) && ($0.1["offscreen"] as? Bool) != true }
            if let box = boxes.first(where: { inWebPage($0.0) }) {
                hit = (box.0, ["text": box.1["label"] ?? q])
            } else if let near = s["near"] as? String, !near.isEmpty {
                // Many matches (a "Reply" under every post): the one that goes with the near text.
                guard let a = anchorFrame(app, w, near) else {
                    out(["ok": false, "error": "Step \(i + 1): no text \"\(near)\" on this page to find \"\(q)\" near.", "done": done])
                }
                let all = findTextEls(app, w, q, hidden: true, limit: 200).filter { clickMatch($0.1) }
                let best = all.first?.1["match"] as? String
                hit = nearestAfter(a, all.filter { ($0.1["match"] as? String) == best })
                if let (e, _) = hit, let f = frame(e), !CGRect(x: w.x, y: w.y, width: w.w, height: w.h).contains(CGPoint(x: f.midX, y: f.midY)) {
                    AXUIElementPerformAction(e, "AXScrollToVisible" as CFString); Thread.sleep(forTimeInterval: 0.3)
                }
            } else {
                hit = findTextEls(app, w, q).first(where: { clickMatch($0.1) })
                if let box = boxes.first, hit == nil || !inWebPage(hit!.0) { hit = (box.0, ["text": box.1["label"] ?? q]) }
                if hit == nil, !q.isEmpty, scrollToText(app, w, q) { hit = findTextEls(app, w, q).first(where: { clickMatch($0.1) }) }
                // Not in the plan's window: an earlier step may have opened a new one (cmd+n, a dialog). Look there.
                if hit == nil, !q.isEmpty {
                    for nw in newerWindows(windows(), pinned: w) {
                        guard let h = findTextEls(app, nw, q).first(where: { clickMatch($0.1) }) else { continue }
                        hit = h; w = nw; bgWin = nw; switched = true; opened = nw.title.isEmpty ? " (in the window that opened)" : " (in the window that opened: \(nw.title))"
                        break
                    }
                }
            }
            guard !q.isEmpty, let (e, info) = hit else {
                out(["ok": false, "error": "Step \(i + 1): no visible text \"\(s["text"] ?? "")\" in \(w.app). Check the exact words with a screenshot or read_window.", "done": done])
            }
            if risky((info["text"] as? String) ?? q), (s["confirmed"] as? Bool) != true {
                out(["ok": false, "error": "Stopped before clicking \"\(info["text"] ?? q)\": it could delete, pay, send or sign out, and the user hasn't said yes to that. Tell them, and let them click it themselves.", "done": done])
            }
            emitStep(i, "click_text", e, label: (info["text"] as? String) ?? q)
            if !pressText(e) {
                guard let f = frame(e) else { out(["ok": false, "error": "Step \(i + 1): couldn't click \"\(q)\".", "done": done]) }
                let p = CGPoint(x: f.midX, y: f.midY)
                if let under = windows().first(where: { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h).contains(p) }), let name = handsOff(under.pid) {
                    out(["ok": false, "error": "Blocked for safety: that spot is on \(name), and I never click in it.", "done": done])
                }
                click(p)
            }
            done.append("clicked \"\(info["text"] ?? q)\"\(opened)")
            Thread.sleep(forTimeInterval: 0.15)
            controls = walk(app, w)
        case "type":
            // Typing outside a text field fires page shortcuts (YouTube's k pauses, Cmd-less digits switch views).
            let focus = focusedEl(app), hidden = !isEditable(focus)
            guard mayType(editable: !hidden, focusRole: focus.map { axRole($0) }, clickedSpot: clickedSpot) else {
                let opaque = focus.map { ["AXWindow", "AXApplication"].contains(axRole($0)) } ?? true
                let tip = opaque ? "This app doesn't show its fields: click_at the field (from a screenshot) as the step right before typing." : "Use {do:'fill', field, text} to fill a field by its label."
                out(["ok": false, "error": "Step \(i + 1): the cursor isn't in a text field, so typing would go nowhere. \(tip)", "done": done])
            }
            let text = s["text"] as? String ?? "", into = focusedEl(app), before = into.flatMap { str($0, kAXValueAttribute) }
            emitStep(i, "type", into, text: text)
            typeText(text)
            // Typing the app dropped (some ignore keys sent in the background) must stop here: a following
            // Return would submit whatever the field held before.
            if let into, let before, !text.isEmpty, axRole(into) != "AXSecureTextField", str(into, kAXSubroleAttribute) != "AXSecureTextField" {
                Thread.sleep(forTimeInterval: 0.12)
                let now = str(into, kAXValueAttribute) ?? before
                if now == before, !fold(now).contains(fold(text).prefix(40)) {
                    out(["ok": false, "error": "Step \(i + 1): typed, but the text field still shows \"\(now.prefix(80))\", so I stopped before the next step. Use {do:'fill', field, text} instead, or the open tool for a web address or a site's search results page.", "done": done])
                }
            }
            done.append(hidden ? "typed text (the app doesn't show its fields, so check the result on screen)" : "typed text")
        case "fill":
            // A form field by its label, placeholder or id: put the cursor in it, replace its text, check it took.
            let text = s["text"] as? String ?? ""
            var s = s
            if s["id"] == nil, let n = Int((s["field"] as? String ?? "").trimmingCharacters(in: .whitespaces)) { s["id"] = n }
            let name = (s["field"] as? String) ?? ""
            if el(s) == nil, fieldFor(app, w, controls, name, roles: FIELD_ROLES) == nil { Thread.sleep(forTimeInterval: 0.3); controls = walk(app, w) }
            // Same field under every post ("Write a reply…"): the one that goes with the near text.
            var nearField: (AXUIElement, [String: Any])?
            if let near = s["near"] as? String, !near.isEmpty {
                guard let a = anchorFrame(app, w, near) else {
                    out(["ok": false, "error": "Step \(i + 1): no text \"\(near)\" on this page to find the field near.", "done": done])
                }
                let q = fold(name)
                let fields = walk(app, w, limit: 400).filter { c in FIELD_ROLES.contains(axRole(c.0)) && (q.isEmpty || [(c.1["label"] as? String) ?? "", str(c.0, "AXPlaceholderValue") ?? ""].map(fold).contains { $0.contains(q) }) }
                nearField = nearestAfter(a, fields)
            }
            guard let (e, info) = nearField ?? el(s) ?? fieldFor(app, w, controls, name, roles: FIELD_ROLES) else {
                out(["ok": false, "error": "Step \(i + 1): no text field called \"\(name)\" here. Check its label with read_window.", "done": done])
            }
            let label = (info["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
            emitStep(i, "fill", e, label: label, text: text)
            let isDate = ["AXDateField", "AXTimeField", "AXDateTimeArea"].contains(axRole(e))
            func took(_ r: (ok: Bool, shows: String)) -> Bool {
                guard r.ok else { return false }
                let sh = r.shows.trimmingCharacters(in: .whitespacesAndNewlines)
                if axRole(e) == "AXSecureTextField" || str(e, kAXSubroleAttribute) == "AXSecureTextField" { return sh.isEmpty || sh.count == text.count }
                if ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(axRole(e)) { return (sh.isEmpty && text.isEmpty) || fold(sh).contains(fold(text).prefix(40)) }
                return true
            }
            let busy = (ok: false, shows: "")
            var r = inBackground && isDate ? withRealCursor { typeInto(app, e, text) } ?? busy : typeInto(app, e, text)
            if inBackground, !userBusy, !took(r) { r = withRealCursor { typeInto(app, e, text) } ?? busy }
            if userBusy || wrongFront != nil { break }
            if !r.ok { out(["ok": false, "error": "Step \(i + 1): couldn't put the cursor in \"\(label)\", so nothing was typed.", "done": done]) }
            let shows = r.shows.trimmingCharacters(in: .whitespacesAndNewlines)
            // Password fields show dots: the right number of them is a match. (They're secure fields, so the check
            // below never runs on them; this note is why.)
            let secure = axRole(e) == "AXSecureTextField" || str(e, kAXSubroleAttribute) == "AXSecureTextField"
            if secure, shows.count != text.count, !shows.isEmpty {
                out(["ok": false, "error": "Step \(i + 1): the password field shows \(shows.count) characters, not \(text.count). Fill it again.", "done": done])
            }
            let plain = !secure && ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(axRole(e))
            if plain, !shows.isEmpty || !text.isEmpty, !fold(shows).contains(fold(text).prefix(40)) {
                var settable: DarwinBoolean = true
                AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable)
                if shows.isEmpty, !settable.boolValue || ((attr(e, "AXReadOnly") as? Bool) == true) {
                    out(["ok": false, "error": "Step \(i + 1): \"\(label)\" can't be typed in; it opens a picker. Use click_text on it, then on the month arrows (e.g. 'Next Month') and the day (its label reads like 'Choose Monday, November 16th, 2026').", "done": done])
                }
                out(["ok": false, "error": "Step \(i + 1): typed into \"\(label)\" but it shows \"\(shows.prefix(80))\". If a cookie banner or pop-up covers the page, close it first (click_text its button), then fill again; otherwise check the field with read_window.", "done": done])
            }
            done.append("\(label) = \"\(axRole(e) == "AXSecureTextField" ? "••••" : String(shows.prefix(60)))\"")
            controls = walk(app, w)
        case "choose":
            // A dropdown (native, custom or a picker) by label or id: open it, find the option (scrolling the
            // list if needed) and pick it. Falls back to typing the option and Return, which most dropdowns accept.
            let option = s["option"] as? String ?? s["text"] as? String ?? ""
            var s = s
            if s["id"] == nil, let n = Int((s["field"] as? String ?? "").trimmingCharacters(in: .whitespaces)) { s["id"] = n }
            let name = (s["field"] as? String) ?? ""
            // No usable name and the page has exactly one dropdown in view: that's the one.
            let pageDrops = controls.filter { ["AXPopUpButton", "AXComboBox"].contains(axRole($0.0)) && ($0.1["offscreen"] as? Bool) != true && inWebPage($0.0) }
            let only = pageDrops.count == 1 ? pageDrops.first : nil
            guard !option.isEmpty, let (e, info) = el(s) ?? fieldFor(app, w, controls, name, roles: DROP_ROLES) ?? only else {
                out(["ok": false, "error": "Step \(i + 1): no dropdown called \"\(name)\" here, or no option given. Check with read_window.", "done": done])
            }
            let label = (info["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
            emitStep(i, "choose", e, label: label, text: option)
            if risky(option), (s["confirmed"] as? Bool) != true {
                out(["ok": false, "error": "Stopped before choosing \"\(option)\": it could delete, pay, send or sign out, and the user hasn't said yes to that.", "done": done])
            }
            activate(e)
            Thread.sleep(forTimeInterval: 0.35)
            let typeable = ["AXComboBox", "AXTextField", "AXSearchField"].contains(axRole(e))
            if let o = findOption(app, w, option, excluding: e) {
                activate(o)
            } else if typeable, typeInto(app, e, option).ok, { Thread.sleep(forTimeInterval: 0.5); return true }(),
                      let o = findOption(app, w, option, excluding: e) {
                // Type-to-search: the suggestions appear once there's text in the box.
                activate(o)
            } else if !typeable, let f = frame(e), let list = openList(app, w, near: f), let o = scrollListFor(app, w, list, option) {
                activate(o)
            } else if typeable {
                _ = pressKey("return")
            } else {
                // Typing only goes where focus is a field or the dropdown itself.
                if isEditable(focusedEl(app)) || (focusedEl(app).map { CFEqual($0, e) } ?? false) || axRole(e) == "AXPopUpButton" {
                    typeText(option); Thread.sleep(forTimeInterval: 0.35); _ = pressKey("return")
                } else {
                    _ = pressKey("escape")
                    if let why = wrongFront { out(["ok": false, "error": "Step \(i + 1): \(why)", "done": done]) }
                    out(["ok": false, "error": "Step \(i + 1): opened \"\(label)\" but no option \"\(option)\" showed up. Take a screenshot to see the choices.", "done": done])
                }
            }
            Thread.sleep(forTimeInterval: 0.45)
            let shows = [str(e, kAXValueAttribute), str(e, kAXTitleAttribute)].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            let took = shows.isEmpty || fold(shows).contains(fold(option).prefix(40))
            done.append(took ? "chose \"\(option)\" in \(label)\(shows.isEmpty ? "" : " (shows \"\(shows.prefix(60))\")")" : "tried to choose \"\(option)\" in \(label), but it still shows \"\(shows.prefix(60))\"")
            controls = walk(app, w)
        case "scroll":
            // Scroll the page, or a list/dropdown/panel under a control or text: direction up/down/left/right, amount in steps.
            let dir = (s["direction"] as? String ?? "down").lowercased()
            let n = max(1, min(30, (s["amount"] as? Int) ?? 5))
            var p = CGPoint(x: w.x + w.w / 2, y: w.y + w.h / 2)
            let winRect = CGRect(x: w.x, y: w.y, width: w.w, height: w.h).insetBy(dx: 4, dy: 4)
            let inWin = { (f: CGRect) -> CGPoint? in let c = CGPoint(x: f.midX, y: f.midY); return winRect.contains(c) ? c : nil }
            if let (e, _) = el(s), let f = frame(e), let c = inWin(f) { p = c }
            else if let q = s["text"] as? String, let c = findTextEls(app, w, q).compactMap({ frame($0.0).flatMap(inWin) }).first { p = c }
            let (dy, dx): (Int32, Int32) = dir == "up" ? (3, 0) : dir == "left" ? (0, 3) : dir == "right" ? (0, -3) : (-3, 0)
            emitStep(i, "scroll", nil, at: p, label: (s["to_end"] as? Bool) == true ? "\(dir) to the end" : dir)
            if (s["to_end"] as? Bool) == true, dir == "up" || dir == "down" {
                // To the very end (or top): keep scrolling, giving a feed time to load more, until nothing changes.
                let sign: Int32 = dir == "up" ? 1 : -1, deadline = Date().addingTimeInterval(25)
                var last = "", same = 0, rounds = 0
                // In the background, one quiet try first; if the page didn't move, the rest uses the real cursor.
                if inBackground {
                    let before = pageText(app, w, cap: 4000).joined(separator: "|")
                    for _ in 0..<4 { moveTo(p); if let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1, wheel1: sign * 1500, wheel2: 0, wheel3: 0) { e.flags = []; sendScroll(e) }; Thread.sleep(forTimeInterval: 0.05) }
                    Thread.sleep(forTimeInterval: 0.5)
                    last = pageText(app, w, cap: 4000).joined(separator: "|")
                    if last == before { usedRealCursor = true; fgActive = false }
                }
                if BG, usedRealCursor, !fgActive, withRealCursor({ true }) == nil { usedRealCursor = false }
                while Date() < deadline, same < 2 {
                    for _ in 0..<4 {
                        moveTo(p)
                        if let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1, wheel1: sign * 1500, wheel2: 0, wheel3: 0) { e.flags = []; sendScroll(e) }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    Thread.sleep(forTimeInterval: 0.9)
                    let sig = pageText(app, w, cap: 4000).joined(separator: "|")
                    if sig == last { same += 1 } else { same = 0; rounds += 1 }
                    last = sig
                }
                done.append("scrolled to the \(dir == "up" ? "top" : "end")\(rounds > 2 ? " (more loaded \(rounds - 1) times)" : "")")
                controls = walk(app, w)
                continue
            }
            let before = inBackground ? pageText(app, w, cap: 4000).joined(separator: "|") : ""
            for _ in 0..<n { scrollAt(p, dy: dy, dx: dx); Thread.sleep(forTimeInterval: 0.04) }
            Thread.sleep(forTimeInterval: 0.25)
            // Nothing moved in the background: scroll again with the real cursor.
            if inBackground, pageText(app, w, cap: 4000).joined(separator: "|") == before {
                withRealCursor { for _ in 0..<n { scrollAt(p, dy: dy, dx: dx); Thread.sleep(forTimeInterval: 0.04) }; Thread.sleep(forTimeInterval: 0.25) }
            }
            done.append("scrolled \(dir)")
            controls = walk(app, w)
        case "key":
            emitStep(i, "key", nil, label: s["key"] as? String ?? "")
            let combo = (s["key"] as? String ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            // Cmd+S in the background: its menu item is greyed out while the app is behind, so ask the app to save
            // its front document directly (no dialog for one that already has a file; a new one still needs the cursor).
            if inBackground, ["cmd+s", "command+s"].contains(combo), saveInBackground(w) { done.append("pressed \(s["key"]!) (saved)"); break }
            if inBackground, ["cmd+s", "command+s"].contains(combo) { if withRealCursor({ pressKey(combo) }) != nil { done.append("pressed \(s["key"]!)") }; break }
            let keyName = s["key"] as? String ?? ""
            let item = inBackground ? pressMenuShortcut(app, keyName, press: MENU_WORKS_BEHIND) : MenuShortcut.notFound
            var sent: Bool? = true
            switch shortcutRoute(item: item, appInFront: !inBackground, trustMenu: MENU_WORKS_BEHIND) {
            case .menu: break
            // Not raising the plan's window: the key goes to the window the app has in front, as it would with the app
            // in front. Raised, Cmd+W after Cmd+N closed the window the plan started on instead of the new document.
            case .realKeyboard: sent = withRealCursor(raise: false) { pressKey(keyName) }
            case .sendKey: sent = pressKey(keyName)
            }
            // nil: the user was busy, so the key was never pressed (the step ends with that error).
            guard let sent else { break }
            guard sent else { out(["ok": false, "error": "Step \(i + 1): unknown key \(s["key"] ?? "")", "done": done]) }
            done.append("pressed \(s["key"]!)")
        case "click_at":
            // Points relative to the window's top-left, or global screen points when "global" is set.
            guard let x = s["x"] as? Double, let y = s["y"] as? Double else { out(["ok": false, "error": "Step \(i + 1): click_at needs x and y", "done": done]) }
            let global = s["global"] as? Bool ?? false
            emitStep(i, "click_at", nil, at: global ? CGPoint(x: x, y: y) : CGPoint(x: w.x + x, y: w.y + y))
            click(global ? CGPoint(x: x, y: y) : CGPoint(x: w.x + x, y: w.y + y)); done.append("clicked at \(Int(x)),\(Int(y))")
            clickedSpot = true
        case "wait":
            let secs = min(5, (s["seconds"] as? Double) ?? 0.5)
            if let before = sigBefore, earlyWaits.contains(i) {
                defer { sigBefore = nil }
                let end = Date().addingTimeInterval(secs)
                var last = "", same = 0
                while Date() < end {
                    let now = pageSig()
                    if now != before { same = now == last ? same + 1 : 0; if same >= 2 { break } }
                    last = now
                    Thread.sleep(forTimeInterval: 0.15)
                }
            } else {
                Thread.sleep(forTimeInterval: secs)
            }
            done.append("waited")
        default:
            out(["ok": false, "error": "Step \(i + 1): unknown action \(what)", "done": done])
        }
    }
    // A click or key may have changed the page: hand back what's there now, so no read_window round trip is needed.
    let changing = steps.contains { ["click", "click_text", "press_button", "key", "click_at", "fill", "choose", "scroll", "set"].contains($0["do"] as? String ?? "") }
    if changing {
        // After a switch to a window the plan opened, show that one while it is still open.
        let w2 = (switched ? windows().first { $0.id == w.id } : nil) ?? resolve(target) ?? w
        let app2 = w2.pid == w.pid ? app : axApp(w2)
        let now = settle(app2, w2).map { $0.1 }
        out(["ok": true, "done": done, "window": winInfo(w2), "controls": now, "texts": pageText(app2, w2, cap: 2000)])
    }
    out(["ok": true, "done": done, "window": winInfo(w)])

case "guide":
    runGuide(Array(args.dropFirst()))

case "secret-get":
    var q = secretQuery(secretName(1))
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let st = SecItemCopyMatching(q as CFDictionary, &item)
    if st == errSecItemNotFound { out(["ok": true, "found": false]) }
    guard st == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else { fail("keychain read failed (\(st))") }
    out(["ok": true, "found": true, "value": value])

case "secret-set":
    let name = secretName(1)
    let raw = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.utf8.count <= 4096 else { fail("no secret on stdin") }
    let data = Data(text.utf8)
    var st = SecItemUpdate(secretQuery(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if st == errSecItemNotFound {
        var add = secretQuery(name)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "BitJarvis (\(name))"
        st = SecItemAdd(add as CFDictionary, nil)
    }
    guard st == errSecSuccess else { fail("keychain save failed (\(st))") }
    out(["ok": true])

case "secret-delete":
    let st = SecItemDelete(secretQuery(secretName(1)) as CFDictionary)
    guard st == errSecSuccess || st == errSecItemNotFound else { fail("keychain delete failed (\(st))") }
    out(["ok": true])

case "screencheck":
    // Screen Recording can read as allowed and still not work (say, before a relaunch), so take one real screenshot.
    guard CGPreflightScreenCaptureAccess() else { out(["ok": true, "seen": false]) }
    let file = NSTemporaryDirectory() + "roamies-screencheck-\(me).jpg"
    let code = run("/usr/sbin/screencapture", ["-x", "-t", "jpg", file])
    let size = ((try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? Int) ?? 0
    try? FileManager.default.removeItem(atPath: file)
    out(["ok": true, "seen": code == 0 && size > 0])

default:
    fail("unknown command \(cmd)")
}
