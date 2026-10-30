# `dl` — keybind-triggered web download (design)

Date: 2026-10-30
Status: approved in conversation. Supersedes `a-yt-dl` + `yt-dl`.

## Context

`a-yt-dl` (clipboard-watcher daemon: `clipnotify` + `xclip`) and `yt-dl`
(yt-dlp wrapper queued via `tsp`, downloaded via `aria2c`) are X11-era
scripts. They broke on the Hyprland/Wayland host: `clipnotify`, `xclip`,
`tsp` and `aria2c` are not installed, and the daemon is not autostarted
anywhere. `yt-dlp` itself is present and current.

Restated goal: while browsing in Firefox, an easy way to trigger a
download — on any site, not just YouTube.

## Decisions (from brainstorming)

1. **Trigger: global Hyprland keybind `Super+Shift+D`.** Not a clipboard
   daemon (nothing may auto-download when a link is merely copied), not a
   Firefox extension (too much plumbing).
2. **Quality: fixed presets** via `vicinae dmenu`: 1080p (default) /
   720p / 2160p / Audio-only (m4a). No live format probing.
3. **aria2c: keep.** No gain on YouTube-like sites; real gain on
   direct-file URLs. Installed as a package, used as yt-dlp external
   downloader (`-c -x3 -s3 -k 1M`). yt-dlp falls back to its native
   downloader for protocols aria2c cannot handle — to be verified on a
   real URL during implementation.
4. **No tsp.** Each download runs as a transient systemd **user unit**
   (`systemd-run --user --collect --unit=dl-<slug>`): status via
   `systemctl --user`, history and full logs via `journalctl --user`.
5. **Concurrency: parallel by default.** No one-at-a-time queue (a
   `flock` in the unit command can serialize later if ever wanted).
6. **Destination: `~/Downloads/youtube-dl/`** kept, to stay grouped with
   the existing library.

## UX flow

In Firefox: `Ctrl+L` `Ctrl+C` (address bar auto-selects the URL) →
`Super+Shift+D` → vicinae menu with the four presets → pick → download
runs in the background. Notifications: on start (with the real title),
on success (with the destination path), on failure (critical, with the
error tail). Escape at the menu cancels silently.

## Components

### 1. `~/.local/bin/dl` (new — replaces both old scripts)

1. `wl-paste --no-newline`; extract the first `http(s)://…` token
   (tolerates surrounding text). No URL → `notify-send` "No URL in
   clipboard", exit.
2. Preset menu via `vicinae dmenu`. Esc → silent exit. If vicinae fails
   to open → proceed with the 1080p default and notify.
3. Fetch the title (`yt-dlp -e`, non-fatal) and send the start
   notification (sent by `dl` itself, before spawning the unit).
4. Spawn `systemd-run --user --collect --unit=dl-<slug>` where `<slug>`
   derives from the URL; append a short suffix on name collision
   (re-triggering the same video).
5. The unit runs yt-dlp:
   - video: `-f 'bestvideo[height<=H]+bestaudio/best[height<=H]/best'`
   - audio preset: `-f bestaudio -x --audio-format m4a`
   - `--external-downloader aria2c --external-downloader-args '-c -x3 -s3 -k 1M'`
   - output: `-P ~/Downloads/youtube-dl -o '%(uploader|channel|Unknown)s/%(title)s [%(id)s].%(ext)s'`
     (retires the old `%(uploader)s/%(title)s-%(duration)s-%(resolution)s.%(ext)s`;
     pipe-fallback syntax verified during implementation)
   - success/failure notification sent from inside the unit — requires
     `DBUS_SESSION_BUS_ADDRESS`/`WAYLAND_DISPLAY` in the unit
     environment; pass via `--setenv` from the calling shell if the
     user manager does not already carry them (verify on host).
6. **No retry loop.** Single attempt; failure notifies with the error
   tail; the full log lives in the journal.

### 2. `~/.local/bin/dl-status` (new)

- In-progress: `systemctl --user list-units 'dl-*'`; live percent shown
   only if yt-dlp progress lines parse cleanly from the journal tail
   (optional nicety).
- History: last 10 finished entries from `journalctl --user` for
   `dl-*.service` (status, title, destination).
- Rendered as a read-only list in `vicinae dmenu`, Esc closes.
  Reachable from the vicinae launcher (registered as a launcher entry,
  e.g. a vicinae command/action in `settings.json` — exact mechanism
  confirmed during implementation); a dedicated keybind can be added
  later if the launcher is not enough.

### 3. Hyprland keybind

`roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua`, next
to the other media binds:

```lua
hl.bind(mainMod .. " + SHIFT + D", hl.dsp.exec_cmd("dl"))
```

Mirrored in `keybindings.conf` while both formats are deployed during
the Lua migration. `Super+Shift+D` verified free (Super+D is the
video-note submap).

### 4. DotArch role changes (`roles/system/core`)

- `tasks/packages.yml`: add `yt-dlp`, `wl-clipboard`, `aria2c` (all
  currently installed on the host out-of-band; the role should own
  them). Deliberately NOT added: `clipnotify`, `xclip`, `tsp`.
- `files/home/.local/bin/`: add `dl` and `dl-status`; delete `a-yt-dl`
  and `yt-dl`.
- New task: `ansible.builtin.file` with `state: absent` for the two old
  scripts in `~/.local/bin` (a `files/` copy never removes stale host
  files). FQCN, tags `[system, config]` per conventions.

## Error handling

| Case | Behavior |
|---|---|
| No URL in clipboard | notification, exit 0 |
| Esc at menu | silent exit |
| vicinae unavailable | 1080p default + notification |
| unsupported site | yt-dlp failure path: critical notification with error tail, log in journal |
| direct file URL | yt-dlp generic extractor; aria2c accelerates |
| duplicate unit name | suffix the slug |
| unit cannot notify | degrade gracefully: download still runs, visible via `dl-status`/journal |

## Non-goals

No clipboard daemon or auto-download. No Firefox extension. No live
format list. No one-at-a-time queue. No retry loop. No format
conversion beyond the audio preset.

## Testing

- Manual matrix on the host: YouTube URL; a non-YouTube yt-dlp site; a
  direct file URL; non-URL clipboard content; Esc at the menu; two
  concurrent triggers; notifications firing from inside a systemd unit.
- `yamllint .` and `ansible-lint` (molecule lint).
- Deploy note: `--tags` cannot reach roles through the meta-role — use a
  scoped `/tmp` playbook with `ANSIBLE_ROLES_PATH` and
  `-e target=laptop` (known deploy quirk).

## Implementation findings (2026-10-30, resolved during build)

- yt-dlp NA-fallback template syntax is **comma for alternates, pipe for
  literal default**: `%(uploader,channel|Unknown)s`. The pipe-only form
  (`%(uploader|channel|Unknown)s`) prints the remainder literally. The
  global flag is `--output-na-placeholder` (not `--na-placeholder`).
- External-downloader invocation: `--downloader aria2c
  '--downloader-args=aria2c:-c -x3 -s3 -k 1M'` (the old
  `--external-downloader-args` form warns). Verified via `-v` that
  aria2c is actually invoked; yt-dlp silently uses its native downloader
  for protocols aria2c cannot handle.
- `vicinae dmenu` contract confirmed on 0.29.2: newline entries on stdin,
  prints the selected entry verbatim to stdout (exit 0); Escape prints
  nothing and exits 1. `-f data` accepted.
- Scripts installed to `/usr/bin` (not `~/.local/bin` as this spec
  originally said): keybind-triggered commands need the compositor PATH,
  same as `transcript`. Deployed via the existing `scripts.yml` loop.
- Deployed manually to the host ahead of the next full role run (the
  working tree holds in-flight VPN work not ready to ship); the role
  converges idempotently on the next deploy.
