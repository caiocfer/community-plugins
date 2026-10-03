# Noctalia plugins

My own Noctalia plugin source. Add it in **Settings → Plugins → Sources** to
install any of these:

```
https://github.com/caiocfer/community-plugins
```

## Plugins

| Plugin | Entries | What it does |
| --- | --- | --- |
| [`spotify-player`](spotify-player/README.md) | Desktop widget `player` | Spotify-only desktop player. Album art fills the card, progress bar above the prev/play/next controls. Talks to playerctl directly, no daemon. |
| [`spotify-lyrics`](spotify-lyrics/README.md) | Bar widget `lyrics`, panel `lyrics-panel`, desktop widget `lyrics-desktop`, service `service` | Time-synced lyrics from the Spotify player, with hide-when-idle and themeable colors. Needs its Python daemon. |

## Notes

- Both plugins are Spotify-only: other MPRIS players are ignored.
- Labels in the desktop widget editor come from each plugin's manifest name.
- `spotify-player` needs only `playerctl`. `spotify-lyrics` also needs
  `python3` and the `syncedlyrics` package, plus its background daemon.
