# Spotify Player

A Spotify-only desktop widget for Noctalia: the album art fills the whole card,
with the progress bar, track info and the prev / play-pause / next controls
drawn straight over the cover along the bottom edge.

Only the `spotify` MPRIS player is read, so videos in Firefox/Chromium never
take over the widget.

## Requirements

`playerctl` (no Python daemon needed):

```bash
sudo pacman -S playerctl        # Arch Linux
```

## Setup

1. Install the plugin from this source and enable it.
2. Open the **desktop widget editor** and add a widget of type **Spotify Player**.
3. Resize the widget box freely: the album art covers the whole box at any size
   or aspect ratio, and the overlay's typography, spacing and controls scale with
   it. The widget reads its own box, so no manual size setting is needed.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| Fallback width | `337` | Draw width only for auto-fit widgets that have no box yet. |
| Fallback height | `518` | Draw height only for auto-fit widgets that have no box yet. |
| Corner radius | `16` | Rounding of the album art. |
| Show track info | `true` | Title and artist over the cover. |
| Colors from cover | `true` | Tint the title, artist, icons and progress bar with the album art hue, contrast-fitted over the scrim. |
| Progress color | `primary` | Progress bar color, used when cover colors are off. |
| Hide when nothing is playing | `true` | Disappear while Spotify is stopped. Paused still shows. |

## Responsive sizing

The desktop widget API exposes no box-size call, so the script reads its own
widget instance from `desktop_widgets.widget` (matched by plugin id, then by
settings) and lays out in display pixels. Noctalia fits the script's natural
size into the box with a single uniform scale and keeps a high-water mark of
that natural size; to stay exact at every size, the tree is drawn inside a fixed
`1000×1000` reference and pre-divided by the scale the host will apply. The
result is a `cover`-style fit: the art always fills the box, cropping instead of
letterboxing.

Spacing follows the box, but typography and controls stop shrinking at their
design size, so a small widget never renders 6px text.

## Controls

- Text and controls are a transparent overlay: the art stays full-bleed underneath
  them, with no background box.
- Material You dynamic color: the title, artist, time labels and icons are tints
  of the dominant cover hue (a light pastel on the dark scrim, a deep tone on
  the light one), and the progress bar keeps the same hue at full vividness.
- A static scrim fades in over the lower 70% of the cover (dark in dark mode,
  light in light mode), giving the tint a controlled backdrop without a hard
  strip or any per-track generation delay. The top of the cover stays sharp.
- Tints are contrast-fitted against the worst-case scrimmed pixel: 4.5:1 for the
  title, 3:1 for the artist, times and icons. Neutral sleeves stay near-neutral.
- With `Colors from cover` off, text/icons fall back to the theme roles and the
  progress bar uses `primary`/the configured color.
- Previous / play-pause / next call `playerctl -p spotify`.
- Progress and position come from `playerctl metadata` once per second.
- Album art is downloaded from Spotify's CDN and cached under the plugin data
  directory, one file per art URL.
