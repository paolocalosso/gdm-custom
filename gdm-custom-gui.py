#!/usr/bin/env python3
# gdm-custom-gui.py — GTK4/Adwaita front-end for gdm-custom.sh
#
# Runs as your user; applies changes by invoking gdm-custom.sh through pkexec
# (graphical password prompt). Requires: python3-gi, gir1.2-gtk-4.0, gir1.2-adw-1.
#
# Run: python3 gdm-custom-gui.py
#
import os
import sys
import threading
import subprocess

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, GLib, Gio  # noqa: E402

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(SCRIPT_DIR, "gdm-custom.sh")
SIZE_MODES = ["zoom", "cover", "scaled", "spanned", "centered"]


class Win(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="GDM Custom")
        self.set_default_size(560, 720)

        toolbar = Adw.ToolbarView()
        header = Adw.HeaderBar()
        toolbar.add_top_bar(header)

        self.toast = Adw.ToastOverlay()
        page = Adw.PreferencesPage()
        self.toast.set_child(page)
        toolbar.set_content(self.toast)
        self.set_content(toolbar)

        # ── Appearance ────────────────────────────────────────────────
        g1 = Adw.PreferencesGroup(title="Appearance")
        page.add(g1)

        self.bg_path = ""
        self.bg_row = Adw.ActionRow(title="Background image", subtitle="(none selected)")
        bg_btn = Gtk.Button(label="Choose…", valign=Gtk.Align.CENTER)
        bg_btn.connect("clicked", self._pick_background)
        self.bg_row.add_suffix(bg_btn)
        g1.add(self.bg_row)

        self.font_row = Adw.EntryRow(title='Font ("Family Size")')
        g1.add(self.font_row)

        self.fontsrc_path = ""
        self.fontsrc_row = Adw.ActionRow(title="Font file to install", subtitle="(optional)")
        fs_btn = Gtk.Button(label="Choose…", valign=Gtk.Align.CENTER)
        fs_btn.connect("clicked", self._pick_fontsrc)
        self.fontsrc_row.add_suffix(fs_btn)
        g1.add(self.fontsrc_row)

        self.icon_row = Adw.EntryRow(title="Icon theme (name in /usr/share/icons)")
        g1.add(self.icon_row)
        self.cursor_row = Adw.EntryRow(title="Cursor theme")
        g1.add(self.cursor_row)

        # ── Background options ────────────────────────────────────────
        g2 = Adw.PreferencesGroup(title="Background options")
        page.add(g2)

        self.multi_row = Adw.SwitchRow(title="Repeat on every monitor",
                                       subtitle="Composite per-monitor, forces 'spanned'")
        g2.add(self.multi_row)

        self.size_row = Adw.ComboRow(title="Fit mode",
                                     model=Gtk.StringList.new(SIZE_MODES))
        g2.add(self.size_row)

        self.blur_row = self._spin("Blur radius", 0, 40, 1, 12)
        g2.add(self.blur_row)
        self.bright_row = self._spin("Brightness %", 10, 200, 1, 95)
        g2.add(self.bright_row)

        # ── Greeter elements ──────────────────────────────────────────
        g3 = Adw.PreferencesGroup(title="Greeter elements")
        page.add(g3)

        self.flatten_row = Adw.SwitchRow(title="Flatten grey element backgrounds", active=True)
        g3.add(self.flatten_row)
        self.ring_row = Adw.SwitchRow(title="Remove accent focus ring", active=True)
        g3.add(self.ring_row)
        self.opacity_row = self._spin("Element opacity", 0.0, 1.0, 0.05, 0.20, digits=2)
        g3.add(self.opacity_row)

        # ── Actions ───────────────────────────────────────────────────
        g4 = Adw.PreferencesGroup()
        page.add(g4)
        box = Gtk.Box(spacing=12, halign=Gtk.Align.CENTER, margin_top=8)
        apply_btn = Gtk.Button(label="Apply")
        apply_btn.add_css_class("suggested-action")
        apply_btn.connect("clicked", self._apply)
        reset_btn = Gtk.Button(label="Reset to default")
        reset_btn.add_css_class("destructive-action")
        reset_btn.connect("clicked", self._reset)
        box.append(apply_btn)
        box.append(reset_btn)
        g4.add(box)

    # ── helpers ───────────────────────────────────────────────────────
    def _spin(self, title, lo, hi, step, val, digits=0):
        row = Adw.SpinRow(title=title,
                          adjustment=Gtk.Adjustment(lower=lo, upper=hi,
                                                    step_increment=step, value=val))
        row.set_digits(digits)
        return row

    def _pick(self, title, callback):
        dialog = Gtk.FileDialog(title=title)
        dialog.open(self, None, callback)

    def _pick_background(self, _btn):
        self._pick("Select background image", self._on_bg)

    def _on_bg(self, dialog, result):
        try:
            f = dialog.open_finish(result)
        except GLib.Error:
            return
        self.bg_path = f.get_path()
        self.bg_row.set_subtitle(self.bg_path)

    def _pick_fontsrc(self, _btn):
        self._pick("Select font file", self._on_fontsrc)

    def _on_fontsrc(self, dialog, result):
        try:
            f = dialog.open_finish(result)
        except GLib.Error:
            return
        self.fontsrc_path = f.get_path()
        self.fontsrc_row.set_subtitle(self.fontsrc_path)

    def _notify(self, text):
        self.toast.add_toast(Adw.Toast(title=text))

    def _build_args(self):
        if not self.bg_path:
            self._notify("Pick a background image first.")
            return None
        args = ["-b", self.bg_path, "-y"]
        font = self.font_row.get_text().strip()
        if font:
            args += ["--font", font]
        if self.fontsrc_path:
            args += ["--font-src", self.fontsrc_path]
        icon = self.icon_row.get_text().strip()
        if icon:
            args += ["-i", icon]
        cursor = self.cursor_row.get_text().strip()
        if cursor:
            args += ["-c", cursor]
        args += ["--blur", str(int(self.blur_row.get_value()))]
        args += ["--brightness", str(int(self.bright_row.get_value()))]
        args += ["--opacity", f"{self.opacity_row.get_value():.2f}"]
        if self.multi_row.get_active():
            args += ["--multi-monitor"]
        else:
            args += ["--size", SIZE_MODES[self.size_row.get_selected()]]
        if not self.flatten_row.get_active():
            args += ["--no-shell-patch"]
        if not self.ring_row.get_active():
            args += ["--keep-accent-ring"]
        return args

    def _apply(self, _btn):
        args = self._build_args()
        if args is None:
            return
        self._run(["pkexec", SCRIPT] + args, "Applied. Restart GDM to see it.")

    def _reset(self, _btn):
        self._run(["pkexec", SCRIPT, "--reset"], "Reset to default. Restart GDM.")

    def _run(self, cmd, ok_msg):
        self._notify("Running… (enter your password in the prompt)")

        def worker():
            try:
                p = subprocess.run(cmd, capture_output=True, text=True)
                if p.returncode == 0:
                    msg = ok_msg
                else:
                    tail = (p.stderr or p.stdout or "Failed.").strip().splitlines()
                    msg = tail[-1] if tail else "Failed."
            except Exception as e:  # noqa: BLE001
                msg = f"Error: {e}"
            GLib.idle_add(self._notify, msg)

        threading.Thread(target=worker, daemon=True).start()


class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id="io.github.paolocalosso.GdmCustom",
                         flags=Gio.ApplicationFlags.DEFAULT_FLAGS)

    def do_activate(self):
        if not os.path.isfile(SCRIPT):
            print(f"gdm-custom.sh not found next to GUI: {SCRIPT}", file=sys.stderr)
        Win(self).present()


if __name__ == "__main__":
    sys.exit(App().run(sys.argv))
