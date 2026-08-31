# Proton Drive Omarchy Widget

Native Omarchy bar widget for Proton Drive: on-demand browse, download, and
upload against the official `proton-drive` CLI. There is no local sync
daemon for Proton Drive on Linux, so this widget never syncs anything in
the background — it only reflects sign-in state and lets you act on it.

## Features

- Shows sign-in state in the bar (signed in / signed out / not installed)
- Left click opens a keyboard-friendly panel
- Right click refreshes status
- Middle click signs in (or out, if already signed in)
- Browse folders via `proton-drive filesystem list`
- Download a file to `~/Downloads`
- Open a file in its default app (fetches a fresh copy, then hands it to `xdg-open`)
- Open a folder's location in the Proton Drive web app / installed PWA
- Upload a file via a `zenity` picker (inside `/my-files` only)
- Sign in / sign out from the panel's account row

## Keyboard shortcuts

Inside the panel:

- `j` / `k` or arrows: move the cursor
- `l` / Right (in the file list): open the highlighted folder, or download the highlighted file
- `h` / Left (in the file list): go up one folder
- `enter` / `space`: activate the current row (sign in/out, open folder, download file)
- `esc`: close

## Requirements

- `proton-drive` CLI on `PATH` (AUR package `proton-drive-cli-bin`)
- `zenity`, for the upload file picker
- Opening a folder's location looks for an installed Proton Drive PWA
  (browser "Install app") and launches that; if none is found, it falls
  back to a plain browser tab at drive.proton.me

## Icon

A 3.5" diskette, drawn natively with `QtQuick.Shapes` (no image assets) —
a chamfered square body, a shutter window near the top, a label window
near the bottom. Two tones only, both derived from the theme foreground
color by alpha: signed in is the solid body with dimmed windows; signed
out is the whole body dimmed with the windows left as real cut-outs.

## Install

```
omarchy plugin add https://github.com/AntouanK/omarchy-protondrive.git --enable --yes
```

## Files

- `manifest.json` - plugin metadata, bar-widget registration
- `Service.qml` - drives the `proton-drive` CLI: login state, browse, download, upload, open
- `Panel.qml` - the popup UI, file browser, and keyboard navigation
- `Icon.qml` - the bar icon (native QtQuick.Shapes, no image assets)
- `Model.js` - pure CLI-output parsing, no side effects
