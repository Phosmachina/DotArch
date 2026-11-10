# Wallpaper Rotation with Luminance-Aware Selection — Design

Date: 2026-11-10
Status: approved (design), pending implementation

## Goal

Restore the automatic wallpaper rotation and make it theme-aware: images are
classified by global luminance and the rotation picks from the pool matching
the current `dotarch-theme` state (`dark` / `light`).

## Current state

The rotation system is dead:

- hyprpaper is never launched — absent from the `hyprland.lua` autostart list
  and from any systemd unit, so `hyprctl hyprpaper` IPC fails.
- `~/Images/Wallpapers/` holds a single image; `random-wallpaper.sh` excludes
  the current wallpaper, so there is never anything to pick.
- Host/repo drift: the repo ships `random-wallpaper.sh` but the host service
  runs `hyprpaper-hourly.sh` (host-only file, same logic).
- `hyprpaper.timer` fires hourly on the host; the whole chain below it is a
  no-op.
- Source material: 8 rar archives of 254 4K JPG each (~705 MB per archive) at
  `/mnt/POOL_1/DATA/DESIGN/Wallpapers/`. Only `1.jpg` was ever committed.

## Decisions

### Provisioning

- One-time manual extraction of all 8 archives into a gold folder:
  `/mnt/POOL_1/DATA/DESIGN/Wallpapers/themefoxx/` (~2032 JPG, ~5.6 GB).
  Never an Ansible task — extracting gigabytes at every deploy is absurd.
- Default rotation source: the NFS gold folder.
- Local fallback: `~/Images/Wallpapers/` with 20 images (10 dark + 10 light),
  synchronized by Ansible at deploy time, deterministic selection.
- The rotation script probes NFS accessibility with a short timeout and falls
  back to the local directory when unreachable.

### Luminance

- Measurement: mean luminance of a 64px grayscale thumbnail via ImageMagick
  (`magick`, already installed for yazi previews) → value 0-255, ~30 ms/image.
- Single boundary, mid-tones belong to the light pool:

  | Theme  | Eligible pool |
  |--------|---------------|
  | dark   | L < 100       |
  | light  | L ≥ 100       |

- Constants at the top of the script, one-line tunables: luminance boundary,
  gold dir, fallback dir.
- Shared incremental TSV cache next to the images:
  `<gold>/.luminance.tsv`, rows keyed by (name, mtime, size).
  - First machine to see an image computes its row for everyone.
  - Atomic write (temp + rename); flock when available and tolerated on
    failure. A race between machines at worst recomputes rows, never
    corrupts.
  - If the cache is unwritable (read-only mount, permissions), the script
    silently falls back to `~/.local/state/dotarch-wallpaper/` for its cache.
  - The local fallback directory uses the same mechanism (its TSV is tiny).
- First build over 2032 images ≈ 1-2 min, runs inside the oneshot service;
  subsequent runs are instant.

### Rotation flow

`dotarch-wallpaper` (`~/.local/bin/`, same pattern as `dotarch-theme`):

1. Read theme: parse `~/.local/state/dotarch-theme/state`
   (`current=dark|light`, default `dark` on parse failure).
2. Pick source dir: NFS gold if reachable (short timeout), else
   `~/Images/Wallpapers`.
3. Load/refresh the TSV cache for that dir.
4. Filter by theme band, exclude the currently loaded wallpaper
   (`hyprctl hyprpaper listloaded`).
5. Random pick, then the correct IPC sequence:
   `preload <path>` → `wallpaper ,<path>` → `unload all`
   (the old script misused `reload ,<path>`).

Subcommand `sync-fallback <dest>`: ensures the TSV is complete, picks an
evenly-spaced-by-luminance sample (10 dark + 10 light) and copies it to
`<dest>`. Deterministic → idempotent for Ansible. Used at deploy time.

### Triggers

- `dotarch-wallpaper.timer`: `OnCalendar=hourly`, `RandomizedDelaySec=15m`
  (jitter desynchronizes machines, limiting concurrent TSV writes),
  `Persistent=true`. Replaces the old `hyprpaper.timer`.
- `dotarch-wallpaper-theme.path`: `PathModified=` on the theme state file,
  explicit `Unit=dotarch-wallpaper.service` (a `.path` unit otherwise
  activates the same-named service) → immediate rotation on every dark↔light
  switch, solar or waybar toggle.
- Both trigger the same oneshot `dotarch-wallpaper.service`.

### Hyprland integration

- hyprpaper daemon added to the `hyprland.lua` autostart list (same pattern
  as waybar/swaync — env guaranteed).
- `hyprpaper.conf` preloads `~/Images/Wallpapers/1.jpg` (already committed in
  the repo, moved into the wallpaper role) at daemon start — safe initial
  state at login even without NFS.
- Fresh wallpaper each login: autostart entry `sh -c 'sleep 3 &&
  dotarch-wallpaper'` (the sleep avoids racing the daemon's IPC socket).

### Ansible integration

- New role `roles/desktop/wallpaper/` (one component = one role):
  - installs `hyprpaper` (moved from `hyprland-tools.yml`) and `imagemagick`;
  - deploys `dotarch-wallpaper`, `hyprpaper.conf`, the systemd units
    (`dotarch-wallpaper.service`, `.timer`, `dotarch-theme.path` + trigger);
  - runs `dotarch-wallpaper sync-fallback ~/Images/Wallpapers` (gated on the
    gold dir existing — skipped with a debug message on hosts without NFS).
- Convention for optional components: `enable_wallpaper: true` default in
  `group_vars/all/deployment_config.yml` + `include_role` block in the
  meta-role `roles/profiles/desktop-hyprland/tasks/main.yml`.
- Autostart additions stay in the hyprland role's `hyprland.lua.j2`.
- Cleanup of the drift: remove from `hyprland-tools.yml` the hyprpaper
  package install, `hyprpaper.conf` copy, `random-wallpaper.sh`, the old
  `hyprpaper.service`/`hyprpaper.timer` copies, the timer activation and the
  `1.jpg` copy. Remove the host-only `hyprpaper-hourly.sh` and stale units.

## Error handling

- NFS unreachable → local fallback; fallback pool empty after exclusion →
  keep the current wallpaper, log to journal, exit 0 (no crash loop).
- hyprpaper IPC failure → script logs and exits non-zero; visible in
  `journalctl --user -u dotarch-wallpaper.service`.
- Missing TSV rows for new images → computed on demand by whichever machine
  rotates first.

## Testing

- Manual smoke on the host: run `dotarch-wallpaper` under both theme states,
  verify pool filtering and TSV growth; fire the path unit by toggling the
  theme; verify timer jitter with `systemctl --user list-timers`; simulate
  NFS loss (bogus source path) to exercise the fallback.
- `uv run ansible-lint` + `yamllint .` (molecule lint gates).
