#!/usr/bin/env bash
#
# gdm-reset.sh — Reset GDM to factory defaults, undoing gdm-settings AND
# gdm-custom.sh leftovers. Run: sudo bash gdm-reset.sh
#
# Callers: none (standalone, run manually).
# Touches: /etc/dconf/db/gdm.d/{95-gdm-custom,99-bar-enhanced-gdm} (delete),
#   gdm-theme alternative (auto), reinstall gnome-shell-common +
#   yaru-theme-gnome-shell, remove our bg/font/.orig leftovers. No data files.
#
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

echo "→ Removing customization dconf keyfiles (keeping 00-gaze-defaults)…"
rm -f /etc/dconf/db/gdm.d/95-gdm-custom
rm -f /etc/dconf/db/gdm.d/99-bar-enhanced-gdm

echo "→ Restoring shell-theme alternative to auto (→ Yaru)…"
update-alternatives --auto gdm-theme.gresource || true

echo "→ Reinstalling pristine theme gresources…"
apt-get update -qq || true
apt-get install --reinstall -y gnome-shell-common yaru-theme-gnome-shell

echo "→ Removing our leftover backups / generated files…"
rm -f /usr/share/gnome-shell/gnome-shell-theme.gresource.orig
rm -f /usr/share/backgrounds/gdm/login-background.jpg
rm -rf /usr/share/fonts/gdm-custom
command -v fc-cache >/dev/null 2>&1 && fc-cache -f >/dev/null 2>&1 || true

echo "→ dconf update…"
dconf update

echo "✓ GDM reset to defaults. Restart greeter: sudo systemctl restart gdm3"
echo "  NOTE: gdm-settings app + BarEnhancedGdm theme files left on disk"
echo "  but no longer applied. Excalifont in /usr/share/fonts/excalifont kept."
