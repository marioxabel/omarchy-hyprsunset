# Hyprsunset Night Light

Night light for the Omarchy bar, with control for each monitor on its own. Warm one display and leave the others alone, or pick All and change every screen together.

Omarchy ships hyprsunset, which can only tint every monitor at once, and Hyprland allows only one color manager. This plugin runs a small helper that takes that role and still answers the hyprsunset socket, so `omarchy toggle nightlight` and the bar indicator keep working. Nothing else to install.

Keywords: hyprsunset, night light, nightlight, red light, blue light filter, color temperature.

## Install

```sh
omarchy plugin add https://github.com/marioxabel/omarchy-hyprsunset.git --enable
```

The widget lands on the right side of the bar. Move it if you want:

```sh
omarchy bar move io.github.marioxabel.hyprsunset --section right
```

## Usage

- Left click the bar icon to open or close the panel
- With more than one display, pick **All** or a single display. One slider follows that choice
- The header switch turns the selected target on or off
- Right click the icon, or scroll it, to do the same for the current target
- The slider runs from 2000K (warm) to 5500K (neutral)
- Press Escape to close the panel

**All** sets every display to the same temperature. A single display leaves the others alone. Turning a display off restores its real colors. Turning it back on restores that display’s last slider value. `omarchy toggle nightlight` still sets every display together.

The helper does not overwrite Hyprland config. It replaces a running `hyprsunset` process when it starts, because the compositor can only host one color manager, and it keeps serving `hyprctl hyprsunset`.

The first time the panel runs, it compiles that helper with `gcc` and `wayland-scanner`. Install `base-devel` and `wayland` if that compile fails. No other packages are required.

## Configure

The last night temperature for a new display is stored on the bar widget entry in `~/.config/omarchy/shell.json`. Per-display values are stored beside it.

```sh
omarchy bar set io.github.marioxabel.hyprsunset nightTemperature 3500
```

## Remove

```sh
omarchy plugin remove io.github.marioxabel.hyprsunset
```

Removal deletes the plugin files under `~/.config/omarchy/plugins/` and takes the widget out of the bar. It does not change Hyprland config. If the helper is still tinting the screens, stop it with `~/.config/omarchy/plugins/io.github.marioxabel.hyprsunset/bin/sunset-ctm stop`.

## License

MIT
