# Hyprsunset

Night light controls for the Omarchy Quattro bar. Toggle hyprsunset on or off and set the screen color temperature with a slider.

Requires [hyprsunset](https://github.com/hyprwm/hyprsunset), which ships with Omarchy.

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
- Right click the icon to toggle night light
- Scroll the icon to change temperature
- In the panel, use the switch to turn night light on or off
- Drag the slider between 2000K (warm) and 5500K (neutral)
- Press Escape to close the panel

Turning night light off restores daylight (6500K), matching Omarchy’s built-in night light. Turning it back on restores your last slider value.

This plugin talks to the same hyprsunset instance as `omarchy toggle nightlight` and the bar’s night light indicator. It does not overwrite Hyprland config.

## Configure

The last night temperature is stored on the bar widget entry in `~/.config/omarchy/shell.json`:

```sh
omarchy bar set io.github.marioxabel.hyprsunset nightTemperature 3500
```

## Remove

```sh
omarchy plugin remove io.github.marioxabel.hyprsunset
```

Removal only deletes the plugin files under `~/.config/omarchy/plugins/` and takes the widget out of the bar. It does not change hyprsunset, Hyprland config, or your current screen temperature.

## License

MIT
