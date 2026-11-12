// Linux: which kind of session this is, and the parts of the shell that are GTK, X11 or D-Bus underneath.
//
// Every window is an X11 window, also on Wayland (through XWayland): a Wayland app can't place a window, keep it
// on top or see the cursor over other apps, and the overlay needs all three. So on a Wayland session GTK is told to
// use X11 before it starts, and the code that places windows is the same everywhere. What Wayland still takes away
// (the cursor over other apps, global shortcuts, grabbing the screen) is handled per feature below.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

use serde_json::{json, Value};
use tauri::{AppHandle, Manager};

#[derive(Clone, Copy, PartialEq, Debug)]
pub(crate) enum Session {
    X11,
    Wayland,
}

impl Session {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Session::X11 => "x11",
            Session::Wayland => "wayland",
        }
    }
}

/// Wayland when the session says so or a Wayland display is set (XWayland's DISPLAY is set there too, so it can't
/// decide). The voice helper uses the same rule (voice-win/src/keys.rs).
fn session_from(session_type: Option<&str>, wayland_display: Option<&str>) -> Session {
    let wayland = session_type.is_some_and(|s| s.eq_ignore_ascii_case("wayland")) || wayland_display.is_some_and(|s| !s.is_empty());
    if wayland { Session::Wayland } else { Session::X11 }
}

static SESSION: OnceLock<Session> = OnceLock::new();

pub(crate) fn session() -> Session {
    *SESSION.get().unwrap_or(&Session::X11)
}

/// First thing in main, before GTK starts and before any other thread exists.
pub(crate) fn init() {
    let env = |k: &str| std::env::var(k).ok();
    let s = session_from(env("XDG_SESSION_TYPE").as_deref(), env("WAYLAND_DISPLAY").as_deref());
    let _ = SESSION.set(s);
    if s == Session::Wayland {
        if env("DISPLAY").is_some_and(|d| !d.is_empty()) {
            std::env::set_var("GDK_BACKEND", "x11");
        } else {
            eprintln!("BitJarvis needs XWayland on a Wayland session (no DISPLAY is set): windows can't be placed or kept on top without it");
        }
    }
}

fn trace() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("ROAMIES_TRACE").is_some())
}

// ---------- click-through by region ----------

/// The page's click areas ([x, y, w, h, …] in CSS px) as whole-pixel rectangles: bad numbers and empty ones are
/// dropped, and a runaway list is cut off (a shape with thousands of pieces helps nobody).
fn hit_rects(flat: &[f64]) -> Vec<(i32, i32, i32, i32)> {
    const MAX: usize = 600;
    const LIMIT: f64 = 100_000.0;
    flat.chunks_exact(4)
        .filter(|r| r.iter().all(|v| v.is_finite() && v.abs() < LIMIT) && r[2] >= 1.0 && r[3] >= 1.0)
        .map(|r| (r[0].floor() as i32, r[1].floor() as i32, r[2].ceil() as i32, r[3].ceil() as i32))
        .take(MAX)
        .collect()
}

/// Makes the rectangles the overlay's input shape: clicks land on them and pass through everywhere else. No cursor
/// tracking is involved, so it works on Wayland too, where the cursor can't be seen over other apps.
pub(crate) fn set_hit_rects(window: &tauri::WebviewWindow, flat: &[f64]) {
    use gtk::cairo::{RectangleInt, Region};
    use gtk::prelude::WidgetExt;
    let rects = hit_rects(flat);
    // ROAMIES_TRACE=1: the shape goes to stderr, for checking click-through from outside (and for bug reports).
    if trace() {
        eprintln!("hit rects: {rects:?}");
    }
    let w = window.clone();
    let _ = window.run_on_main_thread(move || {
        let Some(win) = w.gtk_window().ok().and_then(|g| g.window()) else { return };
        // GDK works in the same logical pixels as the page.
        let list: Vec<RectangleInt> = rects.iter().map(|&(x, y, w, h)| RectangleInt::new(x, y, w, h)).collect();
        let region = Region::create_rectangles(&list);
        win.input_shape_combine_region(&region, 0, 0);
        // No compositor (a bare X11 window manager): the transparent parts would draw black over the whole screen,
        // so the window is cut down to the same rectangles.
        if !win.screen().is_composited() {
            win.shape_combine_region(Some(&region), 0, 0);
        }
    });
}

// ---------- the pointer (X11 sessions) ----------

/// One X connection for the pointer and the keys: its root window and the keycodes of the modifier keys. None on
/// Wayland, where neither can be seen over other apps (the sidecar asks for no click waits and no tap shortcut there).
struct X {
    conn: x11rb::rust_connection::RustConnection,
    root: u32,
    modifiers: Vec<u8>,
}

fn x() -> Option<&'static X> {
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::ConnectionExt;
    static X11: OnceLock<Option<X>> = OnceLock::new();
    if session() != Session::X11 {
        return None;
    }
    X11.get_or_init(|| {
        let (conn, screen) = x11rb::connect(None).ok()?;
        let root = conn.setup().roots.get(screen)?.root;
        let modifiers = conn.get_modifier_mapping().ok().and_then(|c| c.reply().ok()).map(|r| r.keycodes).unwrap_or_default();
        Some(X { conn, root, modifiers })
    })
    .as_ref()
}

/// The pointer's button and modifier state, whichever window has the keyboard (0 when it can't be read).
fn pointer_mask() -> u16 {
    use x11rb::protocol::xproto::ConnectionExt;
    x().and_then(|x| x.conn.query_pointer(x.root).ok()?.reply().ok()).map_or(0, |r| u16::from(r.mask))
}

/// Whether the left mouse button is down right now, anywhere on screen: a drawing waiting for a click polls it.
/// X11 sessions only. On Wayland the pointer can't be seen over other apps, and the sidecar asks for no such waits.
pub(crate) fn left_button_down() -> bool {
    // Button1 in the pointer's button and modifier state.
    pointer_mask() & 0x100 != 0
}

/// X11's modifier state (Shift 1, Control 4, Mod1 = Alt 8, Mod4 = Super 64) as tap.rs bits. Mod5 (AltGr) is a
/// modifier no pair uses; Lock and Num Lock (Mod2) are states, not keys held.
fn mods_from_x11(mask: u16) -> u8 {
    use crate::tap::{COMMAND, CONTROL, OPTION, OTHER_MOD, SHIFT};
    [(0x04, CONTROL), (0x08, OPTION), (0x01, SHIFT), (0x40, COMMAND), (0x80, OTHER_MOD)]
        .iter()
        .filter(|(bit, _)| mask & bit != 0)
        .fold(0, |m, (_, b)| m | b)
}

/// Any key held that isn't a modifier: X11's key bitmap (one bit per keycode), less the keycodes in its modifier map.
fn other_key(keymap: &[u8], modifiers: &[u8]) -> bool {
    (8..keymap.len() * 8).any(|k| keymap[k / 8] & (1 << (k % 8)) != 0 && !modifiers.contains(&(k as u8)))
}

/// For the type-to-ask tap (tap.rs): the modifiers held, and whether a mouse button is down or, when `keys` is
/// set (one more round trip, so only while a tap is under way), any other key. X11 sessions only.
pub(crate) fn keys_state(keys: bool) -> (u8, bool) {
    use x11rb::protocol::xproto::ConnectionExt;
    let mask = pointer_mask();
    // Buttons 1 to 5 are bits 8 to 12 of the state.
    let other = mask & 0x1f00 != 0
        || (keys && x().is_some_and(|x| x.conn.query_keymap().ok().and_then(|c| c.reply().ok()).is_some_and(|r| other_key(&r.keys, &x.modifiers))));
    (mods_from_x11(mask), other)
}

// ---------- screenshots ----------

/// Claude's own cap on a picture's long side: a bigger one is shrunk again on its way and its coordinates drift.
const SHOT_MAX: i32 = 1568;

/// A picture's size shrunk to fit `max` on its long side (never enlarged).
fn fit(w: i32, h: i32, max: i32) -> (i32, i32) {
    let long = w.max(h);
    if long <= max || long <= 0 {
        return (w, h);
    }
    let k = max as f64 / long as f64;
    (((w as f64 * k).round() as i32).max(1), ((h as f64 * k).round() as i32).max(1))
}

/// The rectangle round every screen, from each one's [x, y, w, h].
fn union_bounds(screens: &[[f64; 4]]) -> [f64; 4] {
    let Some(first) = screens.first() else { return [0.0; 4] };
    let (mut x0, mut y0, mut x1, mut y1) = (first[0], first[1], first[0] + first[2], first[1] + first[3]);
    for s in &screens[1..] {
        x0 = x0.min(s[0]);
        y0 = y0.min(s[1]);
        x1 = x1.max(s[0] + s[2]);
        y1 = y1.max(s[1] + s[3]);
    }
    [x0, y0, x1 - x0, y1 - y0]
}

/// The whole desktop in the overlay's points (the units of safe_js's origin): what a screenshot covers, so the
/// sidecar can turn a pixel of the picture into a place on screen.
fn desktop_bounds(app: &AppHandle) -> [f64; 4] {
    let screens: Vec<[f64; 4]> = app
        .available_monitors()
        .unwrap_or_default()
        .iter()
        .map(|m| {
            let s = m.scale_factor();
            [m.position().x as f64 / s, m.position().y as f64 / s, m.size().width as f64 / s, m.size().height as f64 / s]
        })
        .collect();
    union_bounds(&screens)
}

/// Where the desktop portal will answer a request made with this token: the caller's bus name (":1.42") without
/// its colon and with dots as underscores, then the token.
fn portal_request_path(unique_name: &str, token: &str) -> String {
    format!("/org/freedesktop/portal/desktop/request/{}/{token}", unique_name.trim_start_matches(':').replace('.', "_"))
}

/// The file a file:// link names (the portal answers with one), percent-escapes undone. None for anything else.
fn file_uri_path(uri: &str) -> Option<PathBuf> {
    let rest = uri.strip_prefix("file://")?;
    // An empty host or "localhost", then an absolute path.
    let path = rest.strip_prefix("localhost").unwrap_or(rest);
    if !path.starts_with('/') {
        return None;
    }
    let bytes = path.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = |b: u8| (b as char).to_digit(16);
        match (bytes[i], bytes.get(i + 1).copied().and_then(hex), bytes.get(i + 2).copied().and_then(hex)) {
            (b'%', Some(a), Some(b)) => {
                out.push((a * 16 + b) as u8);
                i += 3;
            }
            (c, _, _) => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8(out).ok().map(PathBuf::from)
}

/// Shrinks the picture to Claude's cap and writes it as a JPEG. Returns its final size in pixels.
fn save_fitted(shot: &gtk::gdk_pixbuf::Pixbuf, file: &str) -> Result<(i32, i32), String> {
    let (w, h) = fit(shot.width(), shot.height(), SHOT_MAX);
    let out = if (w, h) == (shot.width(), shot.height()) { Some(shot.clone()) } else { shot.scale_simple(w, h, gtk::gdk_pixbuf::InterpType::Bilinear) };
    let out = out.ok_or("the screenshot couldn't be resized")?;
    out.savev(file, "jpeg", &[("quality", "85")]).map_err(|e| e.to_string())?;
    Ok((w, h))
}

/// X11: the root window holds the whole screen as the user sees it. Main thread only.
fn grab_root() -> Result<gtk::gdk_pixbuf::Pixbuf, String> {
    use gtk::gdk::prelude::WindowExtManual;
    let root = gtk::gdk::Window::default_root_window();
    root.pixbuf(0, 0, root.width(), root.height()).ok_or_else(|| "the X server didn't hand over the screen".to_string())
}

/// Wayland: only the desktop's own portal may read the screen. It writes a picture and answers with a link to
/// it; some desktops ask the user first, each time or once.
fn portal_screenshot() -> Result<PathBuf, String> {
    use std::collections::HashMap;
    use std::sync::atomic::{AtomicU32, Ordering};
    use zbus::blocking::{Connection, Proxy};
    use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value as V};
    static N: AtomicU32 = AtomicU32::new(0);
    const NO_PORTAL: &str = "This desktop has no screenshot portal (install xdg-desktop-portal and the one for your desktop, e.g. xdg-desktop-portal-gnome, -kde or -wlr).";
    let err = |e: zbus::Error| e.to_string();
    let conn = Connection::session().map_err(err)?;
    let token = format!("roamies_{}_{}", std::process::id(), N.fetch_add(1, Ordering::Relaxed));
    let me = conn.unique_name().map(|n| n.to_string()).ok_or("no session bus name")?;
    // Listen for the answer before asking, so a quick one isn't missed.
    let request = Proxy::new(&conn, "org.freedesktop.portal.Desktop", portal_request_path(&me, &token), "org.freedesktop.portal.Request").map_err(err)?;
    let mut answers = request.receive_signal("Response").map_err(err)?;
    let portal = Proxy::new(&conn, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Screenshot").map_err(err)?;
    let mut options: HashMap<&str, V> = HashMap::new();
    options.insert("handle_token", V::from(token.as_str()));
    options.insert("interactive", V::from(false));
    options.insert("modal", V::from(false));
    let _handle: OwnedObjectPath = portal.call("Screenshot", &("", options)).map_err(|e| match e {
        zbus::Error::MethodError(..) | zbus::Error::InterfaceNotFound => NO_PORTAL.to_string(),
        e => format!("{NO_PORTAL} ({e})"),
    })?;
    // The answer can take as long as the user takes with the desktop's "allow this?" dialog.
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(answers.next());
    });
    let msg = rx.recv_timeout(Duration::from_secs(60)).map_err(|_| "The desktop didn't answer the screenshot request.".to_string())?.ok_or("The screenshot request was dropped.")?;
    let (code, results): (u32, HashMap<String, OwnedValue>) = msg.body().deserialize().map_err(err)?;
    if code != 0 {
        return Err(if code == 1 { "The screenshot wasn't allowed (the desktop asked, and the answer was no).".into() } else { "The desktop couldn't take the screenshot.".into() });
    }
    let uri = results.get("uri").and_then(|v| v.downcast_ref::<&str>().ok()).ok_or("the portal sent no picture")?;
    file_uri_path(uri).ok_or_else(|| "the portal sent a link that isn't a file".to_string())
}

/// Overlays go clear for a moment so the Roamie isn't in its own screenshot (macOS and Windows leave them out of
/// captures instead). Main thread only.
fn fade_overlays(app: &AppHandle, opacity: f64) {
    use gtk::prelude::WidgetExt;
    for (label, w) in app.webview_windows() {
        if crate::is_overlay(&label) {
            if let Ok(g) = w.gtk_window() {
                g.set_opacity(opacity);
            }
        }
    }
}

/// The sidecar's take_screenshot: the whole desktop into `file` (a JPEG, shrunk to Claude's cap). Replies
/// screenshot_done with the picture's size in pixels and the part of the desktop it covers (in the overlay's
/// points), or with what went wrong. Main thread only.
pub(crate) fn screenshot(app: &AppHandle, id: Value, file: String) {
    let done = |app: &AppHandle, id: &Value, r: Result<(i32, i32), String>| {
        let msg = match r {
            Ok((w, h)) => json!({ "type": "screenshot_done", "id": id, "ok": true, "pixels": [w, h], "bounds": desktop_bounds(app) }),
            Err(e) => json!({ "type": "screenshot_done", "id": id, "ok": false, "error": e }),
        };
        crate::to_sidecar(app, &msg);
    };
    // Long enough for the compositor to draw a frame without the overlays.
    const CLEAR: Duration = Duration::from_millis(150);
    fade_overlays(app, 0.0);
    let app = app.clone();
    if session() == Session::X11 {
        gtk::glib::timeout_add_local_once(CLEAR, move || {
            let shot = grab_root();
            fade_overlays(&app, 1.0);
            done(&app, &id, shot.and_then(|p| save_fitted(&p, &file)));
        });
        return;
    }
    std::thread::spawn(move || {
        std::thread::sleep(CLEAR);
        let shot = portal_screenshot();
        let app2 = app.clone();
        let _ = app.run_on_main_thread(move || fade_overlays(&app2, 1.0));
        let r = shot.and_then(|path| {
            let loaded = gtk::gdk_pixbuf::Pixbuf::from_file(&path).map_err(|e| e.to_string());
            // The portal keeps its picture (in Pictures, on most desktops): this one was only for the question asked.
            remove_portal_file(&path);
            loaded.and_then(|p| save_fitted(&p, &file))
        });
        let app2 = app.clone();
        let _ = app.run_on_main_thread(move || done(&app2, &id, r));
    });
}

fn remove_portal_file(path: &Path) {
    if path.is_file() {
        let _ = std::fs::remove_file(path);
    }
}

// ---------- clipboard ----------

/// Copies text through GTK (no xclip or wl-copy needed; XWayland hands it on to Wayland apps). Main thread only.
pub(crate) fn set_clipboard(text: &str) {
    let clipboard = gtk::Clipboard::get(&gtk::gdk::SELECTION_CLIPBOARD);
    clipboard.set_text(text);
    clipboard.store();
}

// ---------- Open at Login, updates ----------

/// The AppImage this copy runs from (the AppImage runtime sets APPIMAGE to the file), if it is one.
pub(crate) fn appimage() -> Option<PathBuf> {
    std::env::var_os("APPIMAGE").map(PathBuf::from).filter(|p| p.is_file())
}

/// A program path as one quoted argument of a desktop entry's Exec line. Inside the quotes, `"`, `` ` ``, `$` and
/// `\` take a backslash, and every backslash is doubled again because Exec is a string value; `%` starts a field
/// code, so it's doubled too. None for a path a desktop entry can't hold (a line break).
fn exec_quoted(path: &str) -> Option<String> {
    if path.is_empty() || path.contains(['\n', '\r']) {
        return None;
    }
    let mut out = String::from("\"");
    for c in path.chars() {
        match c {
            '"' | '`' | '$' => {
                out.push_str("\\\\");
                out.push(c);
            }
            '\\' => out.push_str("\\\\\\\\"),
            '%' => out.push_str("%%"),
            c => out.push(c),
        }
    }
    out.push('"');
    Some(out)
}

/// The XDG autostart entry that starts BitJarvis when the user logs in.
fn autostart_entry(program: &str) -> Option<String> {
    let exec = exec_quoted(program)?;
    Some(format!("[Desktop Entry]\nType=Application\nName=BitJarvis\nComment=AI desktop companions\nExec={exec}\nIcon=roamies\nTerminal=false\nX-GNOME-Autostart-enabled=true\n"))
}

/// Whether an autostart entry is switched on: desktops' own "startup apps" settings switch one off by adding
/// Hidden=true (or GNOME's own key) rather than deleting it.
fn autostart_on(entry: &str) -> bool {
    !entry.lines().map(|l| l.trim().to_ascii_lowercase().replace(' ', "")).any(|l| l == "hidden=true" || l == "x-gnome-autostart-enabled=false")
}

fn autostart_file() -> Option<PathBuf> {
    let config = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).filter(|p| p.is_absolute()).or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(config.join("autostart").join("roamies.desktop"))
}

/// Open at Login: an entry in ~/.config/autostart, which GNOME, KDE and the other XDG desktops all run. It starts
/// the AppImage file when this is one (its inner binary lives in a mount that's gone after it quits), else this
/// binary. `set`: None just reports. Returns (supported, on).
pub(crate) fn login_item(set: Option<bool>, installed: bool) -> (bool, bool) {
    let program = appimage().or_else(|| std::env::current_exe().ok());
    let (Some(file), Some(entry)) = (autostart_file(), program.and_then(|p| autostart_entry(&p.to_string_lossy()))) else { return (false, false) };
    if !installed {
        return (false, false);
    }
    match set {
        Some(true) => {
            if let Some(dir) = file.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            if let Err(e) = std::fs::write(&file, entry) {
                eprintln!("open at login: {e}");
            }
        }
        Some(false) => {
            let _ = std::fs::remove_file(&file);
        }
        None => {}
    }
    (true, std::fs::read_to_string(&file).is_ok_and(|e| autostart_on(&e)))
}

/// The program as a shell word, for commands people bind to keys (`<this> --talk`): plain `roamies` when that's
/// what the package installed on PATH, else the AppImage or binary's full path, single-quoted if it needs it.
fn launch_word(program: &str) -> String {
    if program == "/usr/bin/roamies" || program == "/usr/local/bin/roamies" {
        return "roamies".into();
    }
    if program.chars().all(|c| c.is_ascii_alphanumeric() || "/._-+".contains(c)) {
        return program.into();
    }
    format!("'{}'", program.replace('\'', "'\\''"))
}

pub(crate) fn launch_command() -> String {
    let program = appimage().or_else(|| std::env::current_exe().ok()).map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|| "roamies".into());
    launch_word(&program)
}

/// Where a copy installed from a .deb or .rpm gets its update: the package manager owns those files, so the app
/// can't swap itself as an AppImage can.
pub(crate) fn open_releases_page() {
    let _ = std::process::Command::new("xdg-open").arg("https://github.com/rajivyshah/Roamies-LocalAI/releases/latest").stdin(std::process::Stdio::null()).spawn();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn x11_key_state_maps_to_the_tap_bits() {
        use crate::tap::{COMMAND, CONTROL, OPTION, OTHER_MOD, SHIFT};
        assert_eq!(mods_from_x11(0x04 | 0x01), CONTROL | SHIFT);
        assert_eq!(mods_from_x11(0x08 | 0x40), OPTION | COMMAND);
        assert_eq!(mods_from_x11(0x04 | 0x80), CONTROL | OTHER_MOD, "AltGr is a modifier no pair uses");
        // Caps Lock (2), Num Lock (16) and the mouse buttons (0x100 and up) are not modifiers held.
        assert_eq!(mods_from_x11(0x02 | 0x10 | 0x100), 0);
        // Keycode 37 (left Control) is in the modifier map; keycode 38 ("a") is not.
        let mut keymap = [0u8; 32];
        keymap[37 / 8] |= 1 << (37 % 8);
        assert!(!other_key(&keymap, &[37, 50]));
        keymap[38 / 8] |= 1 << (38 % 8);
        assert!(other_key(&keymap, &[37, 50]));
    }

    #[test]
    fn the_autostart_entry_quotes_the_program() {
        let e = autostart_entry("/home/kai/Apps/Roamies 0.1.33.AppImage").expect("an entry");
        assert!(e.starts_with("[Desktop Entry]\nType=Application\nName=BitJarvis\n"));
        assert!(e.contains("\nExec=\"/home/kai/Apps/Roamies 0.1.33.AppImage\"\n"), "{e}");
        assert_eq!(exec_quoted("/usr/bin/roamies").as_deref(), Some("\"/usr/bin/roamies\""));
        // Characters a shell or the desktop would act on stay literal.
        assert_eq!(exec_quoted("/opt/a$b/50%/q\"t/b`t").as_deref(), Some("\"/opt/a\\\\$b/50%%/q\\\\\"t/b\\\\`t\""));
        assert_eq!(exec_quoted("/opt/back\\slash").as_deref(), Some("\"/opt/back\\\\\\\\slash\""));
        assert_eq!(exec_quoted("/opt/two\nlines"), None);
        assert_eq!(autostart_entry(""), None);
    }

    #[test]
    fn the_command_to_bind_names_this_copy() {
        assert_eq!(launch_word("/usr/bin/roamies"), "roamies", "the package's own command");
        assert_eq!(launch_word("/home/kai/Apps/Roamies_0.1.33_amd64.AppImage"), "/home/kai/Apps/Roamies_0.1.33_amd64.AppImage");
        assert_eq!(launch_word("/home/kai/My Apps/Roamies.AppImage"), "'/home/kai/My Apps/Roamies.AppImage'");
        assert_eq!(launch_word("/home/kai/it's/Roamies"), "'/home/kai/it'\\''s/Roamies'");
    }

    #[test]
    fn an_entry_the_desktop_switched_off_counts_as_off() {
        assert!(autostart_on(&autostart_entry("/usr/bin/roamies").unwrap()));
        assert!(!autostart_on("[Desktop Entry]\nExec=roamies\nHidden=true\n"));
        assert!(!autostart_on("[Desktop Entry]\nExec=roamies\nX-GNOME-Autostart-enabled=false\n"));
        assert!(!autostart_on("[Desktop Entry]\nHidden = True\n"));
        assert!(autostart_on("[Desktop Entry]\nHidden=false\n"));
    }

    #[test]
    fn screenshots_shrink_to_the_cap_and_never_grow() {
        assert_eq!(fit(1920, 1080, 1568), (1568, 882));
        assert_eq!(fit(3840, 2160, 1568), (1568, 882));
        assert_eq!(fit(1080, 2400, 1568), (706, 1568), "a tall one is capped by its height");
        assert_eq!(fit(1568, 900, 1568), (1568, 900));
        assert_eq!(fit(800, 600, 1568), (800, 600), "small ones stay as they are");
        assert_eq!(fit(5000, 1, 1568), (1568, 1), "never down to nothing");
        assert_eq!(fit(0, 0, 1568), (0, 0));
    }

    #[test]
    fn the_desktop_is_the_rectangle_round_every_screen() {
        assert_eq!(union_bounds(&[[0.0, 0.0, 1920.0, 1080.0]]), [0.0, 0.0, 1920.0, 1080.0]);
        assert_eq!(union_bounds(&[[0.0, 0.0, 1920.0, 1080.0], [1920.0, 0.0, 2560.0, 1440.0]]), [0.0, 0.0, 4480.0, 1440.0]);
        assert_eq!(union_bounds(&[[0.0, 0.0, 1920.0, 1080.0], [-1280.0, 56.0, 1280.0, 1024.0]]), [-1280.0, 0.0, 3200.0, 1080.0], "a screen to the left");
        assert_eq!(union_bounds(&[]), [0.0; 4]);
    }

    #[test]
    fn the_portal_answers_on_a_path_made_from_the_bus_name_and_token() {
        assert_eq!(portal_request_path(":1.42", "roamies_7_0"), "/org/freedesktop/portal/desktop/request/1_42/roamies_7_0");
        assert_eq!(portal_request_path(":1.1024", "t"), "/org/freedesktop/portal/desktop/request/1_1024/t");
    }

    #[test]
    fn only_file_links_become_paths() {
        assert_eq!(file_uri_path("file:///home/kai/Pictures/Screenshot%20from%202026.png"), Some(PathBuf::from("/home/kai/Pictures/Screenshot from 2026.png")));
        assert_eq!(file_uri_path("file://localhost/tmp/a.png"), Some(PathBuf::from("/tmp/a.png")));
        assert_eq!(file_uri_path("file:///tmp/100%.png"), Some(PathBuf::from("/tmp/100%.png")), "a stray percent sign stays");
        assert_eq!(file_uri_path("file:///tmp/caf%C3%A9.png"), Some(PathBuf::from("/tmp/café.png")));
        assert_eq!(file_uri_path("https://example.com/a.png"), None);
        assert_eq!(file_uri_path("file://otherhost/tmp/a.png"), None);
        assert_eq!(file_uri_path("/tmp/a.png"), None);
    }

    #[test]
    fn click_areas_become_whole_pixel_rectangles() {
        assert_eq!(hit_rects(&[10.4, 20.6, 30.2, 40.0, 0.0, 0.0, 5.0, 5.0]), vec![(10, 20, 31, 40), (0, 0, 5, 5)]);
        assert_eq!(hit_rects(&[]), vec![]);
        // A trailing partial rectangle, an empty one and bad numbers are dropped.
        assert_eq!(hit_rects(&[1.0, 2.0, 3.0, 4.0, 9.0, 9.0]), vec![(1, 2, 3, 4)]);
        assert_eq!(hit_rects(&[1.0, 2.0, 0.0, 4.0, f64::NAN, 0.0, 5.0, 5.0, 0.0, 0.0, f64::INFINITY, 5.0, 0.0, 0.0, 1e9, 5.0]), vec![]);
        assert_eq!(hit_rects(&[-8.0, -8.0, 40.0, 40.0]), vec![(-8, -8, 40, 40)], "a pad can reach past the edge");
        assert_eq!(hit_rects(&[1.0; 4 * 1000]).len(), 600);
    }

    #[test]
    fn the_session_is_wayland_when_either_sign_says_so() {
        assert_eq!(session_from(Some("x11"), None), Session::X11);
        assert_eq!(session_from(None, None), Session::X11, "Xvfb and bare X servers set nothing");
        assert_eq!(session_from(Some("x11"), Some("")), Session::X11);
        assert_eq!(session_from(Some("wayland"), Some("wayland-0")), Session::Wayland);
        assert_eq!(session_from(None, Some("wayland-1")), Session::Wayland);
        assert_eq!(session_from(Some("Wayland"), None), Session::Wayland);
        assert_eq!(session_from(Some("tty"), Some("wayland-0")), Session::Wayland, "a compositor started from a console");
    }
}
