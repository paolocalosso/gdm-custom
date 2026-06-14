#!/usr/bin/env bash
#
# gdm-custom.sh — Customize the GDM login screen (greeter) on GNOME / Ubuntu.
#
# Sets the greeter font, icon theme, cursor theme and a blurred background,
# using GDM's dconf database (com.ubuntu.login-screen + org.gnome.desktop.
# interface). Optionally flattens the grey element backgrounds (user list,
# password field, "Not listed?" button) and removes the accent focus ring,
# by patching the GNOME Shell theme gresource the greeter actually loads
# (on Ubuntu this is the Yaru theme, resolved via update-alternatives).
#
# Tested on Ubuntu 26.04 / GNOME 50 / Wayland.
#
# Usage:
#   sudo ./gdm-custom.sh [options]      apply the configuration
#   sudo ./gdm-custom.sh --reset        remove customization, restore defaults
#   ./gdm-custom.sh --help              show help
#
# Run with no options on a terminal to be prompted interactively.
#
# Repository: https://github.com/<your-user>/gdm-custom
# License: MIT
#
set -euo pipefail

VERSION="1.0.0"
PROG="${0##*/}"

# ──────────────────────────────────────────────────────────────────────────
#  DEFAULTS — edit here, or override via flags / interactive prompts.
#  Empty = keep the system default for that item.
# ──────────────────────────────────────────────────────────────────────────

# Source image for the background (any readable path). Required to apply.
BACKGROUND=""

# Greeter font as "Family Size", e.g. "Cantarell 11". Empty = unchanged.
FONT_NAME=""
# Optional font file OR directory to install system-wide (the greeter cannot
# read ~/.fonts). Empty = assume the family is already installed.
FONT_SRC=""

# Icon theme: either a NAME already in /usr/share/icons, or a PATH to a theme
# directory that will be installed there. Empty = unchanged.
ICON_THEME=""

# Cursor theme: NAME in /usr/share/icons, or PATH to install. Empty = unchanged.
CURSOR_THEME=""

# Gaussian blur radius for the background (0 = none). 8–20 is a good range.
BLUR_RADIUS=12
# Brightness in % to compensate the grey overlay. 100 = unchanged.
BRIGHTNESS=95
# Background fit: zoom | cover | scaled | spanned | centered
BACKGROUND_SIZE="zoom"

# Flatten the grey element backgrounds of the greeter (1 = on, 0 = off).
PATCH_SHELL_THEME=1
# Opacity (over black) of the flattened element backgrounds. 0–1.
ELEMENT_BG_OPACITY=0.20
# Remove the accent-colored focus ring (border) around entries/buttons.
REMOVE_ACCENT_RING=1

# Assume "yes" for package installation prompts (set by --yes).
ASSUME_YES=0

# Interactive file selection via a TUI file manager (yazi preferred, then
# ranger) for background / font / icon / cursor. Disable with --no-picker;
# force one with --picker yazi|ranger.
USE_PICKER=1
PICKER_PREF=""   # "" = auto-detect (yazi, then ranger)
PICKER=""        # resolved by detect_picker(): "yazi" | "ranger" | ""

# ──────────────────────────────────────────────────────────────────────────
#  Internal paths — no need to edit.
# ──────────────────────────────────────────────────────────────────────────
DCONF_PROFILE="/etc/dconf/profile/gdm"
DCONF_KEYFILE="/etc/dconf/db/gdm.d/95-gdm-custom"
BG_DEST_DIR="/usr/share/backgrounds/gdm"
BG_DEST="${BG_DEST_DIR}/login-background.jpg"
FONT_DEST_DIR="/usr/share/fonts/gdm-custom"
ICON_DEST_BASE="/usr/share/icons"

# Colors for messages
if [[ -t 1 ]]; then
    C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_INFO=$'\e[36m'; C_OFF=$'\e[0m'
else
    C_OK=""; C_WARN=""; C_ERR=""; C_INFO=""; C_OFF=""
fi
info()  { echo "${C_INFO}→${C_OFF} $*"; }
ok()    { echo "${C_OK}✓${C_OFF} $*"; }
warn()  { echo "${C_WARN}⚠${C_OFF} $*" >&2; }
die()   { echo "${C_ERR}✗ $*${C_OFF}" >&2; exit 1; }

usage() {
    cat <<EOF
$PROG $VERSION — customize the GDM login screen.

USAGE:
  sudo $PROG [options]        apply configuration
  sudo $PROG --reset          restore the default greeter
  $PROG --help                show this help

OPTIONS:
  -b, --background PATH    source image for the (blurred) background
  -f, --font "NAME SIZE"   greeter font family and size, e.g. "Cantarell 11"
      --font-src PATH      font file/dir to install system-wide
  -i, --icon-theme NAME    icon theme name (in /usr/share/icons) or path to install
  -c, --cursor NAME        cursor theme name (in /usr/share/icons) or path to install
      --blur N             gaussian blur radius (default: $BLUR_RADIUS)
      --brightness N       background brightness %% (default: $BRIGHTNESS)
      --size MODE          background fit: zoom|cover|scaled|spanned|centered
      --opacity F          flattened element background opacity 0-1 (default: $ELEMENT_BG_OPACITY)
      --no-shell-patch     do not flatten grey element backgrounds
      --keep-accent-ring   keep the accent focus ring around entries/buttons
  -y, --yes                assume "yes" for package install prompts
      --picker NAME        file manager for interactive selection: yazi|ranger|none
      --no-picker          type paths manually instead of opening a file manager
      --reset              remove customization and restore defaults
  -h, --help               show this help
  -V, --version            show version

With no configuration options, $PROG prompts interactively (on a terminal).
In interactive mode you can press Enter at the background/font/icon/cursor
prompts to pick a file or folder with yazi or ranger, if installed.

REQUIREMENTS: imagemagick, glib (gresource, glib-compile-resources), dconf,
fontconfig. Missing packages are detected and you'll be offered to install them.
EOF
}

require_root() {
    [[ $EUID -eq 0 ]] || die "Run as root (use sudo)."
}

# ──────────────────────────────────────────────────────────────────────────
#  Dependency detection / installation
# ──────────────────────────────────────────────────────────────────────────
# Detect ImageMagick 7 (magick) or 6 (convert).
im_cmd() {
    if command -v magick >/dev/null 2>&1; then echo "magick"
    elif command -v convert >/dev/null 2>&1; then echo "convert"
    else echo ""; fi
}

check_and_install_deps() {
    # command -> apt package
    local -a missing_cmds=() missing_pkgs=()
    local need_im=1
    [[ -n "$(im_cmd)" ]] && need_im=0

    if [[ $need_im -eq 1 ]]; then missing_cmds+=("magick/convert"); missing_pkgs+=("imagemagick"); fi
    command -v gresource              >/dev/null 2>&1 || { missing_cmds+=("gresource");              missing_pkgs+=("libglib2.0-bin"); }
    command -v dconf                  >/dev/null 2>&1 || { missing_cmds+=("dconf");                  missing_pkgs+=("dconf-cli"); }
    command -v fc-cache               >/dev/null 2>&1 || { missing_cmds+=("fc-cache");               missing_pkgs+=("fontconfig"); }
    if [[ "$PATCH_SHELL_THEME" == "1" ]]; then
        command -v glib-compile-resources >/dev/null 2>&1 || { missing_cmds+=("glib-compile-resources"); missing_pkgs+=("libglib2.0-dev-bin"); }
    fi

    [[ ${#missing_pkgs[@]} -eq 0 ]] && { ok "All required tools are present."; return; }

    warn "Missing tools: ${missing_cmds[*]}"
    if ! command -v apt-get >/dev/null 2>&1; then
        die "This system is not apt-based. Please install: ${missing_pkgs[*]}"
    fi

    # De-duplicate packages
    local -A seen=(); local -a pkgs=()
    local p; for p in "${missing_pkgs[@]}"; do [[ -n "${seen[$p]:-}" ]] || { seen[$p]=1; pkgs+=("$p"); }; done

    if [[ "$ASSUME_YES" != "1" ]]; then
        local reply
        read -r -p "Install missing packages with apt (${pkgs[*]})? [Y/n] " reply
        case "${reply,,}" in n|no) die "Cannot continue without the required tools." ;; esac
    fi
    info "Installing: ${pkgs[*]}"
    apt-get update -qq
    apt-get install -y "${pkgs[@]}"
    ok "Dependencies installed."
}

# ──────────────────────────────────────────────────────────────────────────
#  Interactive prompts
# ──────────────────────────────────────────────────────────────────────────
# ask VAR "Prompt" "default"
ask() {
    local __var="$1" __prompt="$2" __def="${3:-}" __ans
    if [[ -n "$__def" ]]; then
        read -r -p "$__prompt [$__def]: " __ans || true
        __ans="${__ans:-$__def}"
    else
        read -r -p "$__prompt: " __ans || true
    fi
    printf -v "$__var" '%s' "$__ans"
}

# Home directory of the invoking user (not /root when run under sudo).
user_home() {
    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        getent passwd "$SUDO_USER" | cut -d: -f6
    else
        printf '%s' "${HOME:-/}"
    fi
}

# Resolve which TUI file manager to use (once). Honors --picker / --no-picker.
detect_picker() {
    [[ "$USE_PICKER" == "1" ]] || { PICKER=""; return; }
    [[ -n "$PICKER" ]] && return   # already resolved
    if [[ -n "$PICKER_PREF" ]]; then
        command -v "$PICKER_PREF" >/dev/null 2>&1 && PICKER="$PICKER_PREF" \
            || warn "Requested picker '$PICKER_PREF' not found — using text input."
        return
    fi
    if   command -v yazi   >/dev/null 2>&1; then PICKER="yazi"
    elif command -v ranger >/dev/null 2>&1; then PICKER="ranger"
    fi
}

# Launch the file manager to pick a path. mode=file|dir. Writes the choice to
# $out. Runs as the invoking user so it starts in their $HOME and can read
# their files (the script itself runs as root).
run_picker() {
    local mode="$1" start="$2" out="$3"
    local -a cmd
    case "$PICKER" in
        yazi)
            if [[ "$mode" == "dir" ]]; then cmd=(yazi "$start" --cwd-file="$out")
            else                            cmd=(yazi "$start" --chooser-file="$out"); fi ;;
        ranger)
            if [[ "$mode" == "dir" ]]; then cmd=(ranger --choosedir="$out" "$start")
            else                            cmd=(ranger --choosefile="$out" "$start"); fi ;;
        *) return 1 ;;
    esac
    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        sudo -u "$SUDO_USER" -- "${cmd[@]}"
    else
        "${cmd[@]}"
    fi
}

# pick_path VAR "Prompt" mode(file|dir) "default"
# Lets the user type a value, or press Enter to browse with the file manager.
# Falls back to a plain prompt when no picker is available.
pick_path() {
    local __var="$1" __prompt="$2" __mode="${3:-file}" __def="${4:-}"
    detect_picker
    if [[ -z "$PICKER" || ! -t 0 ]]; then
        ask "$__var" "$__prompt" "$__def"
        return
    fi

    local __hint __ans
    if [[ "$__mode" == "dir" ]]; then __hint="Enter to browse a folder with $PICKER"
    else                              __hint="Enter to browse with $PICKER"; fi
    read -r -p "$__prompt — $__hint, or type a value${__def:+ [$__def]}: " __ans || true

    if [[ -z "$__ans" ]]; then
        if [[ -n "$__def" ]]; then
            __ans="$__def"
        else
            local __out; __out="$(mktemp)"
            if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
                chown "$SUDO_USER" "$__out" 2>/dev/null || true
            fi
            if run_picker "$__mode" "$(user_home)" "$__out"; then
                __ans="$(< "$__out")"
                __ans="${__ans%%$'\n'*}"   # first line only (multi-select safety)
            else
                warn "Picker exited without a selection."
            fi
            rm -f "$__out"
        fi
    fi
    printf -v "$__var" '%s' "$__ans"
}

prompt_config() {
    [[ -t 0 ]] || die "No configuration provided and not running interactively. See --help."
    echo
    echo "── Interactive setup (press Enter to keep the shown default) ──"
    pick_path BACKGROUND "Background image" file "$BACKGROUND"
    ask FONT_NAME      "Greeter font (\"Family Size\", empty=keep)" "$FONT_NAME"
    [[ -n "$FONT_NAME" ]] && pick_path FONT_SRC "  Font file to install (empty=already installed)" file "$FONT_SRC"
    pick_path ICON_THEME   "Icon theme name (empty=keep)"   dir "$ICON_THEME"
    pick_path CURSOR_THEME "Cursor theme name (empty=keep)" dir "$CURSOR_THEME"

    local adv
    read -r -p "Customize advanced options (blur/brightness/opacity)? [y/N] " adv || true
    if [[ "${adv,,}" =~ ^y ]]; then
        ask BLUR_RADIUS        "Blur radius"                 "$BLUR_RADIUS"
        ask BRIGHTNESS         "Brightness %"                "$BRIGHTNESS"
        ask BACKGROUND_SIZE    "Background fit"              "$BACKGROUND_SIZE"
        ask ELEMENT_BG_OPACITY "Element background opacity"  "$ELEMENT_BG_OPACITY"
    fi
    echo
}

# ──────────────────────────────────────────────────────────────────────────
#  Theme/font installation helpers
# ──────────────────────────────────────────────────────────────────────────
# True if the argument looks like a path (contains a slash or is a directory).
is_path() { [[ "$1" == */* || -e "$1" ]]; }

# install_theme SRC -> prints the theme NAME to use; copies it to /usr/share/icons
# if SRC is a path, otherwise returns SRC unchanged (assumed already installed).
install_theme() {
    local src="$1" name dest
    if is_path "$src"; then
        [[ -d "$src" ]] || die "Theme path not found or not a directory: $src"
        name="$(basename "${src%/}")"
        dest="${ICON_DEST_BASE}/${name}"
        if [[ "$(readlink -f "$src")" != "$(readlink -f "$dest" 2>/dev/null || echo)" ]]; then
            info "Installing theme '$name' into $ICON_DEST_BASE…" >&2
            rm -rf "$dest"
            cp -a "$src" "$dest"
        fi
        printf '%s' "$name"
    else
        printf '%s' "$src"
    fi
}

install_font() {
    local src="$1"
    [[ -e "$src" ]] || die "Font source not found: $src"
    info "Installing font(s) into ${FONT_DEST_DIR}…"
    mkdir -p "$FONT_DEST_DIR"
    if [[ -d "$src" ]]; then
        find "$src" -type f \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.woff2' \) \
            -exec install -m 0644 {} "$FONT_DEST_DIR/" \;
    else
        install -m 0644 "$src" "$FONT_DEST_DIR/"
    fi
    fc-cache -f "$FONT_DEST_DIR" >/dev/null 2>&1 || true
}

# ──────────────────────────────────────────────────────────────────────────
#  GNOME Shell theme patch (flatten grey backgrounds + remove accent ring)
# ──────────────────────────────────────────────────────────────────────────
# Resolve the gresource the greeter actually loads. On Ubuntu it is the Yaru
# theme, selected through the 'gdm-theme.gresource' update-alternatives link.
gdm_gresource() {
    local p=""
    if [[ -e /usr/share/gnome-shell/gdm-theme.gresource ]]; then
        p="$(readlink -f /usr/share/gnome-shell/gdm-theme.gresource 2>/dev/null)"
    fi
    [[ -n "$p" && -f "$p" ]] || p="/usr/share/gnome-shell/gnome-shell-theme.gresource"
    printf '%s' "$p"
}

patch_shell_theme() {
    local GRES; GRES="$(gdm_gresource)"
    info "Greeter gresource: $GRES"
    [[ -f "$GRES" ]] || { warn "Theme gresource not found — skipping element patch."; return; }
    command -v glib-compile-resources >/dev/null 2>&1 || {
        warn "glib-compile-resources missing — skipping element patch."; return; }

    # Back up the original once; every run re-patches from this clean copy.
    if [[ ! -f "${GRES}.orig" ]]; then
        cp -a "$GRES" "${GRES}.orig"
        info "Saved original theme: ${GRES}.orig"
    fi

    local WORK PREFIX res rel
    WORK="$(mktemp -d)"; PREFIX="/org/gnome/shell/theme"

    info "Extracting GNOME Shell theme…"
    for res in $(gresource list "${GRES}.orig"); do
        rel="${res#"${PREFIX}"/}"
        mkdir -p "$WORK/$(dirname "$rel")"
        gresource extract "${GRES}.orig" "$res" > "$WORK/$rel"
    done

    # The greeter loads gdm.css OR (in dark mode) a dark variant which is a
    # separate resource with identical content. We patch ALL .css files in this
    # gresource; it is GDM-specific, so the logged-in desktop stays unchanged.
    local RGBA="rgba(0,0,0,${ELEMENT_BG_OPACITY})"
    local CSS hits=0
    info "Flattening grey element backgrounds → ${RGBA}…"
    while IFS= read -r CSS; do
        # Real base greys: Yaru (dark) + Adwaita (fallback) + light variant.
        sed -i \
            -e "s/st-mix(white, #36363a, 9%)/${RGBA}/g" \
            -e "s/st-mix(#ffffff, #36363a, 9%)/${RGBA}/g" \
            -e "s/st-mix(#f2f2f2, #222222, 9%)/${RGBA}/g" \
            -e "s/background-color: #353535;/background-color: ${RGBA};/g" \
            -e "s/background-color: #36363a;/background-color: ${RGBA};/g" \
            -e "s/background-color: #404045;/background-color: ${RGBA};/g" \
            -e "s/background-color: #48484c;/background-color: ${RGBA};/g" \
            "$CSS"

        if [[ "$REMOVE_ACCENT_RING" == "1" ]]; then
            sed -i \
                -e "s/box-shadow: inset 0 0 0 2px st-transparentize(st-mix(-st-accent-color, #ffffff, 60%), 0.2) !important;/box-shadow: none !important;/g" \
                -e "s/box-shadow: inset 0 0 0 2px st-transparentize(st-lighten(-st-accent-color, 30%), 0.2) !important;/box-shadow: none !important;/g" \
                -e "s/box-shadow: inset 0 0 0 2px st-transparentize(-st-accent-color, 0.2);/box-shadow: none;/g" \
                -e "s/box-shadow: inset 0 0 0 2px st-transparentize(-st-accent-color, 0.65);/box-shadow: none;/g" \
                "$CSS"
        fi

        # Targeted overrides for elements with their own rules / shared greys
        # (e.g. "Not listed?" uses #222222, which is also the dialog/lock-screen
        # background and must NOT be replaced globally). !important wins without
        # touching those full-screen backgrounds.
        local RING=""
        [[ "$REMOVE_ACCENT_RING" == "1" ]] && RING="  box-shadow: none !important;
  border: 0 !important;"
        cat >> "$CSS" <<EOF

/* ── gdm-custom: flatten login elements ─────────────────────────────── */
.login-dialog-not-listed-button,
.login-dialog-not-listed-button:focus,
.login-dialog-not-listed-button:hover,
.login-dialog-not-listed-button:active,
.login-dialog .login-dialog-prompt-entry,
.login-dialog .login-dialog-prompt-entry:focus,
.login-dialog .login-dialog-prompt-entry:hover,
.login-dialog-prompt-entry,
.login-dialog-prompt-entry:focus,
.login-dialog-prompt-entry:hover,
.login-dialog .login-dialog-auth-list-item,
.login-dialog .login-dialog-auth-list-item:focus,
.login-dialog .login-dialog-auth-list-item:selected,
.login-dialog .login-dialog-auth-list-item:hover,
.login-dialog .login-dialog-auth-list-item:active,
.login-dialog-auth-list-item,
.login-dialog-auth-list-item:focus,
.login-dialog-auth-list-item:selected,
.login-dialog-user-list-view .login-dialog-user-list .login-dialog-user-list-item,
.login-dialog-user-list-view .login-dialog-user-list .login-dialog-user-list-item:focus,
.login-dialog-user-list-view .login-dialog-user-list .login-dialog-user-list-item:selected,
.login-dialog-user-list-view .login-dialog-user-list .login-dialog-user-list-item:hover,
.login-dialog-user-list-view .login-dialog-user-list .login-dialog-user-list-item:active,
StEntry, StEntry:focus, StEntry:hover, StEntry:active {
  background-color: ${RGBA} !important;
${RING}
}
EOF
        echo "    • patched: ${CSS#"$WORK"/}"
        hits=$((hits+1))
    done < <(find "$WORK" -type f -name '*.css')
    [[ $hits -gt 0 ]] || { warn "No .css found in theme — skipping."; rm -rf "$WORK"; return; }

    local XML="$WORK/gnome-shell-theme.gresource.xml"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<gresources>'
        echo "  <gresource prefix=\"${PREFIX}\">"
        for res in $(gresource list "${GRES}.orig"); do
            echo "    <file>${res#"${PREFIX}"/}</file>"
        done
        echo '  </gresource>'
        echo '</gresources>'
    } > "$XML"

    if glib-compile-resources --sourcedir="$WORK" "$XML" --target="${GRES}.new"; then
        mv -f "${GRES}.new" "$GRES"
        ok "Theme patched (${hits} stylesheet(s))."
    else
        warn "gresource compilation failed — theme left unchanged."
        rm -f "${GRES}.new"
    fi
    rm -rf "$WORK"
}

# ──────────────────────────────────────────────────────────────────────────
#  Apply / reset
# ──────────────────────────────────────────────────────────────────────────
do_apply() {
    require_root
    check_and_install_deps

    [[ -n "$BACKGROUND" ]] || die "No background image set. Use --background PATH or run interactively."
    [[ -f "$BACKGROUND" ]] || die "Background image not found: $BACKGROUND"
    local IM; IM="$(im_cmd)"
    [[ -n "$IM" ]] || die "ImageMagick not available."

    # Install / resolve themes (name-or-path)
    if [[ -n "$ICON_THEME" ]]; then ICON_THEME="$(install_theme "$ICON_THEME")"; fi
    if [[ -n "$CURSOR_THEME" ]]; then CURSOR_THEME="$(install_theme "$CURSOR_THEME")"; fi
    [[ -n "$ICON_THEME"   && ! -d "${ICON_DEST_BASE}/${ICON_THEME}" ]]   && warn "Icon theme '$ICON_THEME' not in $ICON_DEST_BASE (greeter cannot read ~/.local/share/icons)."
    [[ -n "$CURSOR_THEME" && ! -d "${ICON_DEST_BASE}/${CURSOR_THEME}" ]] && warn "Cursor theme '$CURSOR_THEME' not in $ICON_DEST_BASE."

    # Install font if a source was given
    [[ -n "$FONT_SRC" ]] && install_font "$FONT_SRC"

    # Process background (blur + brightness)
    info "Processing background with ${IM} (blur=${BLUR_RADIUS}, brightness=${BRIGHTNESS}%)…"
    mkdir -p "$BG_DEST_DIR"
    "$IM" "$BACKGROUND" -blur "0x${BLUR_RADIUS}" -modulate "${BRIGHTNESS},100,100" "$BG_DEST"
    chmod 0644 "$BG_DEST"

    # Ensure the gdm dconf profile exists (without it, nothing applies)
    if [[ ! -f "$DCONF_PROFILE" ]]; then
        info "Creating $DCONF_PROFILE (missing)…"
        mkdir -p "$(dirname "$DCONF_PROFILE")"
        cat > "$DCONF_PROFILE" <<'EOF'
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
EOF
    fi

    # Write the dconf keyfile (only include keys that are set)
    info "Writing $DCONF_KEYFILE…"
    mkdir -p "$(dirname "$DCONF_KEYFILE")"
    {
        echo "# Generated by ${PROG} — do not edit by hand"
        echo "[org/gnome/desktop/interface]"
        [[ -n "$FONT_NAME"    ]] && echo "font-name='${FONT_NAME}'"
        [[ -n "$ICON_THEME"   ]] && echo "icon-theme='${ICON_THEME}'"
        [[ -n "$CURSOR_THEME" ]] && echo "cursor-theme='${CURSOR_THEME}'"
        echo ""
        echo "[com/ubuntu/login-screen]"
        echo "background-picture-uri='file://${BG_DEST}'"
        echo "background-size='${BACKGROUND_SIZE}'"
    } > "$DCONF_KEYFILE"

    [[ "$PATCH_SHELL_THEME" == "1" ]] && patch_shell_theme

    info "Running dconf update…"
    dconf update

    echo
    ok "Configuration applied."
    echo "  Background : ${BG_DEST}"
    [[ -n "$FONT_NAME"    ]] && echo "  Font       : ${FONT_NAME}"
    [[ -n "$ICON_THEME"   ]] && echo "  Icons      : ${ICON_THEME}"
    [[ -n "$CURSOR_THEME" ]] && echo "  Cursor     : ${CURSOR_THEME}"
    echo
    echo "Restart the greeter to see the result (this closes your session!):"
    echo "    sudo systemctl restart gdm3   # or gdm"
}

do_reset() {
    require_root
    info "Removing greeter customization…"
    rm -f "$DCONF_KEYFILE"
    rm -f "$BG_DEST"
    rm -rf "$FONT_DEST_DIR"
    command -v fc-cache >/dev/null 2>&1 && fc-cache -f >/dev/null 2>&1 || true
    # Restore any patched gresource (Yaru and/or the Adwaita fallback).
    local g
    for g in "$(gdm_gresource)" "/usr/share/gnome-shell/gnome-shell-theme.gresource"; do
        if [[ -f "${g}.orig" ]]; then
            mv -f "${g}.orig" "$g"
            ok "Restored original theme: $g"
        fi
    done
    command -v dconf >/dev/null 2>&1 && dconf update || true
    ok "Default greeter restored. Restart: sudo systemctl restart gdm3"
}

# ──────────────────────────────────────────────────────────────────────────
#  Argument parsing
# ──────────────────────────────────────────────────────────────────────────
ACTION="apply"
GOT_CONFIG=0   # whether any config-providing flag was passed

while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--background)   BACKGROUND="$2"; GOT_CONFIG=1; shift 2 ;;
        -f|--font)         FONT_NAME="$2";  GOT_CONFIG=1; shift 2 ;;
        --font-src)        FONT_SRC="$2";   GOT_CONFIG=1; shift 2 ;;
        -i|--icon-theme)   ICON_THEME="$2"; GOT_CONFIG=1; shift 2 ;;
        -c|--cursor)       CURSOR_THEME="$2"; GOT_CONFIG=1; shift 2 ;;
        --blur)            BLUR_RADIUS="$2"; GOT_CONFIG=1; shift 2 ;;
        --brightness)      BRIGHTNESS="$2"; GOT_CONFIG=1; shift 2 ;;
        --size)            BACKGROUND_SIZE="$2"; GOT_CONFIG=1; shift 2 ;;
        --opacity)         ELEMENT_BG_OPACITY="$2"; GOT_CONFIG=1; shift 2 ;;
        --no-shell-patch)  PATCH_SHELL_THEME=0; GOT_CONFIG=1; shift ;;
        --keep-accent-ring) REMOVE_ACCENT_RING=0; GOT_CONFIG=1; shift ;;
        -y|--yes)          ASSUME_YES=1; shift ;;
        --no-picker)       USE_PICKER=0; shift ;;
        --picker)
            case "${2:-}" in
                none|off) USE_PICKER=0 ;;
                yazi|ranger) PICKER_PREF="$2" ;;
                *) die "Invalid --picker '${2:-}' (use yazi|ranger|none)." ;;
            esac
            shift 2 ;;
        --reset)           ACTION="reset"; shift ;;
        -h|--help)         usage; exit 0 ;;
        -V|--version)      echo "$PROG $VERSION"; exit 0 ;;
        *)                 die "Unknown option: $1 (see --help)" ;;
    esac
done

case "$ACTION" in
    reset) do_reset ;;
    apply)
        # Prompt only when no config flags were passed.
        [[ "$GOT_CONFIG" -eq 0 ]] && prompt_config
        do_apply
        ;;
esac
