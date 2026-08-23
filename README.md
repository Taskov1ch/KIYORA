<img align="left" alt="KIYORA logo" src="data/icons/hicolor/scalable/apps/app.svg" />

# KIYORA

KIYORA — Music Player. Play your music elegantly.

KIYORA is a fast, lightweight music player written in GTK4 and designed for large music libraries.

## Features

- Supports most music file types, Samba and other remote protocols through GIO and GStreamer.
- Loads and parses thousands of music files quickly and monitors local changes.
- Uses little memory even with large libraries and embedded or external album art.
- Groups and sorts by album, artist, or title, with shuffle and full-text search.
- Adapts fluidly to desktop, tablet, and mobile screen sizes.
- Uses Gaussian-blurred cover art and follows the GNOME light or dark appearance.
- Creates and edits playlists, including drag-and-drop reordering.
- Provides an audio peak visualizer, gapless playback, ReplayGain, and MPRIS controls.
- Publishes the playing track to Discord Rich Presence as a Listening activity.

## FreeBSD dependencies

```bash
pkg install vala meson libadwaita gstreamer1-plugins-all gettext gtk4 json-glib
```

## Build

1. Clone the repository.
2. Install Vala and the development packages for GTK4, Libadwaita, and GStreamer.
3. Configure and build the project:

   ```bash
   meson setup build --buildtype=release
   meson compile -C build
   ```

4. Install it:

   ```bash
   meson install -C build
   ```

The installed executable is `kiyora`, and the application ID is `io.github.Taskov1ch.KIYORA`.

## AppImage

The AppImage build script installs KIYORA into an AppDir and bundles GTK4,
Libadwaita, GStreamer, its runtime plugins, and the other required libraries.
Run it on an x86_64 Linux system with the build dependencies installed:

```bash
./scripts/build-appimage.sh
```

The resulting `KIYORA-<version>-x86_64.AppImage` is written to `dist/`.
GitHub Actions runs the same script for every push and pull request, uploads the
AppImage as a workflow artifact, and attaches it to the GitHub Release for tags.

## Credits

KIYORA is based on the GPL-3.0-or-later licensed G4Music project by Nanling.
