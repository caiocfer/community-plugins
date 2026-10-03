# Spotify Lyrics

A seamless, time-synced scrolling lyrics panel for the Noctalia desktop shell. It integrates directly into your Noctalia bar and displays a beautifully formatted, auto-scrolling lyrics card — no API keys, cookies, or web scraping required.

## Plugin

| Field | Value |
| --- | --- |
| ID | `goatnath/spotify-lyrics` |
| Entries | Service: `service`; bar widget: `lyrics`; panel: `lyrics-panel`; desktop widget: `lyrics-desktop` |

## Requirements

This plugin requires `playerctl`, `python3`, and the `syncedlyrics` Python package.

```bash
# Arch Linux
sudo pacman -S playerctl python
pip install syncedlyrics
```

## Usage

### 1. Set up the Background Daemon

The daemon listens to Spotify over MPRIS and fetches the lyrics.

1. Copy the `spotify_lyrics_daemon.py` file to your preferred location (e.g., `~/.local/bin/`).
2. Set it up to run in the background. The recommended way is using a systemd user service:

```ini
# ~/.config/systemd/user/noctalia-lyrics.service
[Unit]
Description=Noctalia Lyrics Daemon
After=graphical-session.target

[Service]
ExecStart=/usr/bin/python3 /path/to/spotify_lyrics_daemon.py
Restart=always

[Install]
WantedBy=default.target
```

Start and enable the daemon:

```bash
systemctl --user daemon-reload
systemctl --user enable --now noctalia-lyrics.service
```

### 2. Enable the Plugin

1. Install this plugin from the plugin manager or download the folder to `~/.local/share/noctalia/plugins/spotify-lyrics/`.
2. Enable the plugin via CLI:

```bash
noctalia msg plugins enable goatnath/spotify-lyrics
```

3. (Optional) Add the bar widget to your bar. Declare it first, then reference the name in a lane — a plugin widget referenced without a `[widget.<name>]` block is dropped with `widget factory: unknown widget "<name>"`.

```toml
[widget.lyrics]
type = "goatnath/spotify-lyrics:lyrics"

[bar.default]
start = [ "launcher", "workspaces", "media", "lyrics" ]
```

4. (Optional) Add the desktop widget through the desktop widget editor (`noctalia msg desktop-widgets-edit`).

### 3. Toggle the Lyrics Panel

Click the `♫` bar icon to toggle the panel, or run:

```sh
noctalia msg panel-toggle goatnath/spotify-lyrics:lyrics-panel
```

## Settings

Open the desktop widget editor (`noctalia msg desktop-widgets-edit`), pick the Spotify
Lyrics widget — these sit next to its **Background** switch.

| Setting | Default | Effect |
| --- | --- | --- |
| Hide when nothing is playing | `on` | Hides the bar button, the desktop widget and closes the panel while Spotify is stopped. Turn it off to keep a static *No music playing* placeholder. |
| Accent color | `primary` | Bar icon, track glyph and artist name. |
| Active lyric color | `on_surface` | The current lyric line and the track title. |
| Inactive lyric color | `on_surface_variant` | Previous/next lines, separators and empty states. |

Colors use the same picker as Noctalia's built-in audio visualizer, so any theme color
role (`primary`, `secondary`, `tertiary`, `on_surface`, `outline`, `hover`, …) or a
custom `#RRGGBB` value works. Faded variants are derived from the color you pick.

The desktop widget owns these settings, and Noctalia scopes `getConfig` per entry, so
the desktop widget republishes what it resolved and the bar and panel read that. Add
the desktop widget if you want the panel and bar to follow these values; without it
they fall back to the defaults above.

## Notes

- **Spotify only:** the daemon ignores other MPRIS players, so a video playing in Firefox never takes over the lyrics.
- **Paused counts as playing:** the bar button and desktop widget stay put while Spotify is paused.

- **Zero Configuration:** Lyrics are pulled from public databases (LRCLIB, NetEase) automatically.
- **Caching:** The daemon caches lyrics and album art to `~/.cache/noctalia/lyrics/` so subsequent plays load instantly.
- **Network:** The daemon makes HTTPS requests to LRCLIB and NetEase for lyrics, and to the album art URL provided by MPRIS metadata.
- **Processes:** Requires a separate `spotify_lyrics_daemon.py` process running as a systemd user service.
