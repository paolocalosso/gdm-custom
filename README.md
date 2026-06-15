# gdm-custom

Customize the **GDM login screen** (greeter) on GNOME / Ubuntu: set the font,
icon theme, cursor theme and a blurred background, and optionally flatten the
grey element backgrounds (user list, password field, *Not listed?* button) and
remove the accent-colored focus ring.

Tested on **Ubuntu 26.04 / GNOME 50 / Wayland**.

## Features

- Blurred, brightness-adjusted login background from any image.
- Greeter font, icon theme and cursor theme via GDM's dconf database.
- Installs themes/fonts system-wide automatically when you pass a path (the
  greeter runs as the `gdm` user and **cannot** read `~/.fonts` or
  `~/.local/share/icons`).
- Optional flattening of the greeter's grey element backgrounds and removal of
  the orange/accent focus ring, by patching the GNOME Shell theme gresource the
  greeter actually loads.
- Fully reversible with `--reset`.
- Interactive prompts **and** scriptable CLI flags.
- Optional **file-manager picker** (`yazi` preferred, then `ranger`) in
  interactive mode: press Enter at the background/font/icon/cursor prompts to
  browse for a file or folder instead of typing the path. `yazi` even previews
  images, so you can choose the background by sight.

## Requirements

`imagemagick`, GLib tools (`gresource`, `glib-compile-resources`), `dconf` and
`fontconfig`. The script detects what is missing and offers to install it via
`apt` (use `--yes` to skip the prompt). On non-apt systems it prints the
package list and exits.

The interactive file-manager picker is **optional**: install `yazi` or
`ranger` to use it. Without either, the prompts fall back to typing paths by
hand (equivalent to `--no-picker`).

## Usage

```bash
# Interactive (prompts for background, font, icon theme, cursor;
# press Enter at a prompt to browse with yazi/ranger if installed):
sudo ./gdm-custom.sh

# Interactive but always type paths by hand:
sudo ./gdm-custom.sh --no-picker

# Non-interactive with flags:
sudo ./gdm-custom.sh \
  --background ~/Pictures/wall.jpg \
  --font "Cantarell 11" \
  --icon-theme Papirus-Dark \
  --cursor Qogir

# Install a theme/font from a path (copied into the system directories):
sudo ./gdm-custom.sh -b ~/wall.jpg \
  -i ~/themes/Fluent-yellow-dark \
  -c ~/icons/Qogir-Ubuntu \
  --font "Excalifont 11" --font-src ~/.fonts/Excalifont-Regular.otf

# Restore the default greeter:
sudo ./gdm-custom.sh --reset
```

Apply the changes by restarting the greeter (this closes your session):

```bash
sudo systemctl restart gdm3   # or: sudo systemctl restart gdm
```

### Options

| Option | Description |
| --- | --- |
| `-b, --background PATH` | Source image for the blurred background (required to apply). |
| `-f, --font "NAME SIZE"` | Greeter font family and size, e.g. `"Cantarell 11"`. |
| `--font-src PATH` | Font file or directory to install system-wide. |
| `-i, --icon-theme NAME\|PATH` | Icon theme name (in `/usr/share/icons`) or a path to install. |
| `-c, --cursor NAME\|PATH` | Cursor theme name or a path to install. |
| `--blur N` | Gaussian blur radius (default `12`). |
| `--brightness N` | Background brightness % (default `95`). |
| `--size MODE` | Background fit: `zoom\|cover\|scaled\|spanned\|centered`. |
| `--opacity F` | Flattened element background opacity, `0`–`1` (default `0.20`). |
| `--no-shell-patch` | Do not flatten grey element backgrounds. |
| `--keep-accent-ring` | Keep the accent focus ring around entries/buttons. |
| `-y, --yes` | Assume "yes" for package install prompts. |
| `--picker NAME` | File manager for interactive selection: `yazi`, `ranger` or `none`. |
| `--no-picker` | Type paths manually instead of opening a file manager. |
| `--reset` | Remove customization and restore defaults. |
| `-h, --help` / `-V, --version` | Help / version. |

Defaults can also be edited directly in the `DEFAULTS` section at the top of
the script.

## How it works

The font, icon and cursor settings are written to GDM's dconf database
(`/etc/dconf/db/gdm.d/`), together with `com.ubuntu.login-screen`'s
`background-picture-uri`. The script also creates `/etc/dconf/profile/gdm` if
it is missing — without that profile **none** of the greeter settings take
effect (a common pitfall).

The grey-background flattening patches the GNOME Shell theme **gresource that
the greeter actually loads**. On Ubuntu this is the *Yaru* theme, selected
through the `gdm-theme.gresource` `update-alternatives` link — **not** the
upstream Adwaita `gnome-shell-theme.gresource`. The script resolves the real
file with `readlink -f`, rewrites the relevant `background-color` values and
the accent focus-ring `box-shadow` inside every stylesheet in the gresource,
and recompiles it. Because this gresource is GDM-specific, the logged-in
desktop session is left unchanged. The original is backed up to
`<gresource>.orig` and restored by `--reset`.

## Caveats

- A `gnome-shell` / `yaru-theme` package update may overwrite the patched
  gresource. Just re-run the script.
- The shell-theme patch is best-effort: color values differ between theme
  versions. If a new GNOME/Yaru release changes them, the flattening may need
  updated values (PRs welcome).
- `--reset` restores the dconf keys, the background, installed fonts and the
  theme gresource; manually copied icon/cursor themes are left in place.

## License

MIT — see [LICENSE](LICENSE).
