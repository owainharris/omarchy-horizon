# Span Wallpaper for Omarchy

Span one image continuously across any group of monitors in Omarchy. Each
selected output receives the part of the image that belongs at its real
Hyprland position, while unselected displays keep the normal Omarchy theme
wallpaper.

## Features

- Visual monitor picker based on the active Hyprland layout
- Any combination of connected monitors can form the wallpaper canvas
- Three scaling modes: **Fill**, **Show whole**, and **Stretch**
- One-click access from an Omarchy bar widget
- Automatic recropping when the monitor layout changes
- Persistent source image and selection across shell restarts
- Compatible with Omarchy theme changes and wallpaper cycling
- Out-of-process GTK file chooser, keeping portal failures outside Quickshell

## Requirements

- Omarchy Quattro with third-party shell plugin support
- ImageMagick (`magick`)
- `jq`
- Python GObject bindings with GTK 4 (`python-gobject` on Omarchy)

All dependencies must be available on `PATH` before the plugin is used.

## Install

```sh
omarchy plugin add https://github.com/owainharris/omarchy-span-wallpaper.git --enable
```

The widget defaults to the right side of the bar. To place it immediately
before the power button:

```sh
omarchy bar put kudos.span-wallpaper --section right --before omarchy.power
```

## Usage

Click the image icon in the bar, or open the controls from a terminal:

```sh
omarchy-shell shell summon kudos.span-wallpaper
```

Then:

1. Select the monitor rectangles that should share the wallpaper.
2. Pick an Omarchy background or choose another local image.
3. Select a scaling mode.
4. Click **Apply**.

The scaling modes map the source image onto the bounding rectangle of the
selected monitors:

| Mode | Result |
| --- | --- |
| **Fill** | Preserves the image proportions and crops overflow. |
| **Show whole** | Preserves the image proportions and adds black padding. |
| **Stretch** | Uses the full image and may change its proportions. |

Physical gaps and offsets in the compositor layout remain part of the virtual
canvas, so the visible portions align correctly across display edges. Click
**Clear span** to reveal Omarchy's current theme wallpaper again.

## How it works

Omarchy normally paints the same wallpaper independently on every display.
Span Wallpaper instead creates one virtual canvas from the selected monitor
geometry, prepares that image with ImageMagick, and saves one exact crop per
output. Lightweight layer-shell windows display those crops above Omarchy's
stock background and below normal application windows.

Generated crops and a retained copy of the selected source are stored in:

```text
~/.local/state/omarchy/span-wallpaper/
```

Keeping the source lets the plugin regenerate crops after a display is plugged
in, removed, moved, or resized. Image processing has bounded memory, disk, and
execution-time limits to protect the long-running shell from oversized files.

## Privacy and permissions

Span Wallpaper works locally and makes no network requests. It reads active
monitor geometry and the image you select, runs `magick` and `jq`, and writes
only to its state directory. It needs no elevated permissions and does not
replace Omarchy's built-in background plugin.

Like all Omarchy shell plugins, it runs unsandboxed inside Quickshell. Review
the source before installing third-party plugins.

## Remove

Clear the active span first if you want the normal wallpaper to reappear
immediately, then remove the plugin:

```sh
omarchy-shell kudos.span-wallpaper clear
omarchy plugin remove kudos.span-wallpaper
```

Removing the plugin intentionally leaves its state and retained source image
under `~/.local/state/omarchy/span-wallpaper/`. Delete that directory manually
if you do not want to keep them.

## Development

From an existing checkout, validate the plugin with Omarchy and run the
complete test suite:

```sh
./test.sh
```

Install the working tree for local iteration:

```sh
omarchy plugin add "$PWD" --enable
```

The tests validate the manifest and scripts, exercise monitor geometry and
state parsing, compare generated crops pixel-for-pixel, and parse both QML
entry points.

## License

[MIT](LICENSE)
