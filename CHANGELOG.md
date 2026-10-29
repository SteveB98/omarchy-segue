# Changelog

## 1.2.1 (2026-10-29)

- Bar label: hovering now fades to the artist even on self-titled tracks,
  where the title and artist are the same text.
- Preview image: the "g" in Segue is no longer cut off.
- README: how to bind a key that opens the panel from anywhere.

## 1.2.0 (2026-10-29)

- The plugin is now called **Segue**, with id `io.github.steveb98.segue`.
  Spotify's developer guidelines ask that app names not include "Spotify".
  If you installed an earlier version, remove it and install again; Spotify
  Connect stays logged in.
- New marketplace preview image.

## 1.1.0 (2026-10-29)

Marketplace release.

- New plugin id `io.github.steveb98.spotify` (was `steveb.spotify`). If you
  installed 1.0.0, remove it and install again; Spotify Connect stays logged in.
- Security: Spotify tokens no longer appear in process arguments, so other
  local users can't read them from `/proc`.
- Security: the token cache only uses an owner-only folder, never a shared
  `/tmp` fallback.
- Security: the login callback page escapes Spotify's error text and ignores
  stray requests instead of failing the login.
- Cover art only loads from `https://` or local files.
- `spotify-connect logout` also forgets the saved Client ID.
- README: install Spotify from the Omarchy menu, dependencies section, new
  screenshots with original artwork.

## 1.0.0 (2026-10-28)

First public release.

- Bar widget: Spotify icon and song title; hover shows the artist (or the
  podcast's show name) with a fade; new songs slide in.
- Player panel: cover art, title, artist, album, draggable progress bar,
  previous / play-pause / next, open or focus Spotify.
- Spotify Connect (optional, Premium): see the active device and move playback
  to another one. Guided setup from the panel (`spotify-connect setup`).
- Settings: `maxLabelWidth`, `brandColor`.
- Works with the AUR `spotify` package and the official `spotify-launcher`.
