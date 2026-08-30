# Proton Drive Omarchy Widget

Native Omarchy bar widget for Proton Drive, modeled on the first-party
Dropbox/Tailscale widgets and this config's own ProtonVPN widget.

Proton Drive's CLI (`proton-drive`, from AUR `proton-drive-cli-bin`) is
command-driven file access, not a background sync daemon — there's no
"paused/running" state to toggle, so this widget only tracks and controls
**login state**.

## Features

- Shows Proton Drive sign-in state in the bar (signed in / signed out /
  not installed)
- Left click opens a keyboard-friendly panel
- Right click refreshes status
- Middle click signs in (or out, if already signed in)
- Sign in or out from the panel's account row

## Keyboard shortcuts

Inside the panel:

- `j` / `k` or arrows: focus the sign-in/sign-out row
- `enter` / `space`: activate it
- `esc`: close

## Requirements

- `proton-drive` CLI on `PATH` (package `proton-drive-cli-bin`)

## How login state is detected

The CLI has no `status`/`whoami` subcommand, so this widget infers login
state from `proton-drive filesystem list /` — a fast, read-only, always
side-effect-free call that lists the ten fixed virtual root sections
(`/my-files`, `/devices`, `/shared-by-me`, ...) when signed in.

Observed on this machine: when signed out, the CLI prints
`You need to login first` to stdout **and still exits 0** — it does not use
a non-zero exit code for this — so the exit code alone isn't a reliable
signal and `Model.js` checks the printed text instead. This probe is the
only thing the refresh timer, right-click, and status IPC call are wired
to; it never touches `auth login` or `auth logout`.

## Signing in

`proton-drive auth login` prints a sign-in URL and blocks until the browser
flow completes, then exits 0. Unlike Tailscale/ProtonVPN's CLIs, Proton
Drive's CLI **also opens that URL itself** (it shells out to `xdg-open`
internally before printing the URL) — so this widget does not additionally
open a browser tab itself, which would just produce a duplicate tab. The
panel only watches the process output to know when the flow finishes and
shows a "Check your browser…" status line while it waits.

## Signing out

"Sign out" runs `proton-drive auth logout` directly — per its `--help` text
("Signs out and clears local credentials and caches.") it's headless and
non-interactive, so it's wired the same way as a normal action button.

## Icon

A 3.5" diskette, drawn with straight-edged `QtQuick.Shapes` paths (the same
technique the built-in Dropbox icon uses) — chamfered square body, a shutter
window at the top, a label window near the bottom held off the edge by a
rim. Two tones only, both the theme foreground color differing by alpha:
signed in is the solid body with dim-filled windows; signed out is the whole
body dimmed with the windows left as real cut-outs. No slash/cross-out —
an earlier version tried that and it swallowed both windows into a smudge
at real bar-icon size.

## Add to the bar

Install this plugin under `~/.config/omarchy/plugins/antouank.protondrive/`,
then run `omarchy-shell shell rescanPlugins` and
`omarchy plugin enable antouank.protondrive --section right`.
