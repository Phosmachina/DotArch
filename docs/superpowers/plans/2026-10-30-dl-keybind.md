# `dl` — Keybind-Triggered Web Download — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken `a-yt-dl`/`yt-dl` pair with a single keybind (`Super+Shift+D`) that downloads the clipboard URL via yt-dlp/aria2c as a transient systemd user unit, with a status/history view.

**Architecture:** Three small shell scripts (`dl`, `dl-worker`, `dl-status`) in `/usr/bin`; each download runs as `systemd-run --user` transient unit (status via `systemctl --user`, history via `journalctl --user` markers); quality chosen in a `vicinae dmenu` fixed-preset menu. DotArch deploys them through the existing `system/core` role (`scripts.yml` + `packages.yml`) and the hyprland role ships the keybind in both config formats.

**Tech Stack:** bash, wl-clipboard, yt-dlp, aria2 (package `aria2`), vicinae (`vicinae dmenu`), systemd user units, swaync (`notify-send`), Ansible (DotArch conventions).

**Spec:** `docs/superpowers/specs/2026-10-30-dl-keybind-design.md`

## Global Constraints

- Ansible YAML: 2-space indent, FQCN only (`ansible.builtin.*`, `ansible.posix.*`, `community.general.*`).
- Repo lives on NFS with known quirks: use system `/usr/sbin/ansible-playbook` (not `.venv`); if a `become: true` copy to `/usr/bin` fails from NFS, stage via `/tmp`.
- The user has uncommitted edits in the working tree (incl. `packages.yml`, `main.yml`). **Commit only your own hunks**: `git add <explicit paths>` when the file is otherwise untouched; for `packages.yml` (user-modified), use `git diff -U0 -- <file>`, isolate your hunk, `git apply --cached --unidiff-zero`.
- Never commit secrets. No vault files are touched by this plan.
- Host facts (verified 2026-10-30): `yt-dlp` 2026.10.26, `wl-paste`/`wl-copy`, `vicinae` 0.29.2 (with `dmenu` subcommand), `systemctl --user show-environment` already exports `DBUS_SESSION_BUS_ADDRESS`, `WAYLAND_DISPLAY=wayland-1`, `DISPLAY=:0`; `swaync.service` runs as a user unit. `aria2`, `clipnotify`, `xclip`, `tsp` are NOT installed.
- `Super+Shift+D` is free in `keybindings.lua` (81 binds checked; `Super+D` is the video-note submap).

---

### Task 1: `dl` + `dl-worker` scripts

**Files:**
- Create: `roles/system/core/files/usr/bin/dl`
- Create: `roles/system/core/files/usr/bin/dl-worker`

**Interfaces:**
- Consumes: clipboard via `wl-paste`, menu via `vicinae dmenu`, units via `systemd-run --user`.
- Produces: `dl <no-args>` → reads clipboard, spawns unit `dl-<slug>` running `dl-worker <url> <height|audio>` with env `DL_UNIT`, `DL_TITLE`. `dl-worker` writes journal markers `DL_START <url> | <title>` and `DL_RESULT OK|FAIL <title>` (consumed by `dl-status` in Task 2).

- [ ] **Step 1: Verify the `vicinae dmenu` contract (interactive — user picks an entry)**

```bash
printf '1080p (default)\n720p\n2160p (4K)\nAudio only (m4a)\n' \
  | WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/1000 \
    vicinae dmenu -f data -n 'Download' -s 'Quality' -p 'Download quality'
echo "exit=$?"
```

Expected: window flashes; on selection prints the selected line and `exit=0`; on Escape prints nothing, `exit=1`. If `-f data` errors ("invalid format" etc.), run with `--help` variants and adjust the flag in `dl` accordingly — the script below must end up selecting on exact preset strings.

- [ ] **Step 2: Write `roles/system/core/files/usr/bin/dl`**

```bash
#!/bin/bash
# dl — download the clipboard URL (yt-dlp) at a chosen quality.
# Bound to Super+Shift+D. See docs/superpowers/specs/2026-10-30-dl-keybind-design.md

set -u

notify() { notify-send -a dl "$@"; }

url=$(wl-paste --no-newline 2>/dev/null \
  | grep -oE 'https?://[^[:space:]]+' | head -n1 \
  | sed 's/[.,;:)]*$//')
if [ -z "$url" ]; then
  notify -u critical "No URL in clipboard"
  exit 1
fi

if command -v vicinae >/dev/null 2>&1; then
  choice=$(printf '%s\n' \
    '1080p (default)' '720p' '2160p (4K)' 'Audio only (m4a)' \
    | vicinae dmenu -f data -n 'Download' -s 'Quality' -p 'Download quality')
  [ -z "$choice" ] && exit 0   # Esc
else
  choice='1080p (default)'
  notify "vicinae unavailable — using 1080p"
fi

case $choice in
  '1080p (default)') height=1080 ;;
  '720p')            height=720 ;;
  '2160p (4K)')      height=2160 ;;
  'Audio only (m4a)') height=audio ;;
  *)                 height=1080 ;;
esac

title=$(yt-dlp -e --no-warnings "$url" 2>/dev/null | head -n1)
[ -z "$title" ] && title=$url

slug=$(printf '%s' "$url" \
  | sed -e 's|https\?://||' -e 's|[^a-zA-Z0-9]\+|-|g' -e 's|^-\+\||-\+\|$||g' \
  | tr 'A-Z' 'a-z' | cut -c1-40)
[ -z "$slug" ] && slug=dl
unit="dl-${slug}"
systemctl --user is-active --quiet "$unit" 2>/dev/null && unit="dl-${slug}-$RANDOM"

systemd-run --user --collect --unit="$unit" \
  --setenv="DL_UNIT=$unit" --setenv="DL_TITLE=$title" \
  /usr/bin/dl-worker "$url" "$height"

notify "Download started" "$title"
```

- [ ] **Step 3: Write `roles/system/core/files/usr/bin/dl-worker`**

```bash
#!/bin/bash
# dl-worker — runs inside a transient systemd user unit spawned by dl.
# Streams yt-dlp output to the journal (progress lines included) and emits
# structured markers consumed by dl-status.

set -u
url=$1
height=$2
title=${DL_TITLE:-$url}
unit=${DL_UNIT:-dl-worker}

dir="$HOME/Downloads/youtube-dl"
printf 'DL_START %s | %s\n' "$url" "$title"

if [ "$height" = audio ]; then
  fmt=(-f bestaudio -x --audio-format m4a)
else
  fmt=(-f "bestvideo[height<=${height}]+bestaudio/best[height<=${height}]/best")
fi

if yt-dlp \
  --external-downloader aria2c \
  '--external-downloader-args=-c -x3 -s3 -k 1M' \
  -P "$dir" \
  -o '%(uploader|channel|Unknown)s/%(title)s [%(id)s].%(ext)s' \
  "${fmt[@]}" "$url"; then
  printf 'DL_RESULT OK %s\n' "$title"
  notify-send -a dl "Download finished" "$title"
else
  tail=$(journalctl --user -u "$unit" -o cat -n 12 2>/dev/null | grep -v '^DL_' | tail -n 3)
  printf 'DL_RESULT FAIL %s\n' "$title"
  notify-send -a dl -u critical "Download failed" "${title}\n${tail}"
fi
```

- [ ] **Step 4: Smoke-test on the host (no repo deploy yet — run from the repo copy)**

```bash
chmod +x roles/system/core/files/usr/bin/dl roles/system/core/files/usr/bin/dl-worker
wl-copy 'https://download.samplelib.com/mp4/sample-5s.mp4'
WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/1000 \
  bash roles/system/core/files/usr/bin/dl    # pick 720p in the menu
sleep 8
systemctl --user list-units 'dl-*' --no-legend
journalctl --user -u 'dl-*' -o cat -n 20
ls -R ~/Downloads/youtube-dl/Unknown/ 2>/dev/null || ls -R ~/Downloads/youtube-dl/
```

Expected: unit ran and went away (`--collect`), journal shows `DL_START`/`DL_RESULT OK` + yt-dlp lines, file `sample-5s [sample-5s].mp4` under `~/Downloads/youtube-dl/Unknown/` (verifies the `%(uploader|channel|Unknown)s` pipe-fallback and generic-extractor path). Note in the journal whether the aria2c line appears (`aria2c` resumed/split output) — record the observed external-downloader behavior for the spec's open verification point.

- [ ] **Step 5: YouTube test (aria2c real-world + native-fallback check)**

```bash
wl-copy 'https://www.youtube.com/watch?v=jNQXAC9IVRw'   # "Me at the zoo", 19s
bash roles/system/core/files/usr/bin/dl                 # pick Audio only (m4a)
sleep 12
journalctl --user -u 'dl-*' -o cat -n 40
```

Expected: `DL_RESULT OK`, m4a in `~/Downloads/youtube-dl/<channel>/`. Check the journal for which downloader yt-dlp used (`[download]` lines / aria2c invocation); HLS/DASH formats must fall back to native without erroring.

- [ ] **Step 6: Failure-path test**

```bash
wl-copy 'https://example.com/definitely-not-a-video.mp4'
bash roles/system/core/files/usr/bin/dl                 # pick 720p
sleep 6
journalctl --user -u 'dl-*' -o cat -n 10
```

Expected: critical notification with the error tail, `DL_RESULT FAIL` in journal. Also test with non-URL clipboard (`wl-copy 'hello'`) → "No URL in clipboard", and Esc at the menu → nothing happens.

- [ ] **Step 7: Commit (only these two new files)**

```bash
git add roles/system/core/files/usr/bin/dl roles/system/core/files/usr/bin/dl-worker
git commit -m "feat(dl): keybind-triggered web download — dl + dl-worker scripts"
```

---

### Task 2: `dl-status` + launcher entry

**Files:**
- Create: `roles/system/core/files/usr/bin/dl-status`
- Create: `roles/system/core/files/home/.local/share/applications/dl-status.desktop`

**Interfaces:**
- Consumes: journal markers `DL_START <url> | <title>` / `DL_RESULT OK|FAIL <title>` from Task 1; `systemctl --user` for live units; `vicinae dmenu` for rendering.
- Produces: `dl-status <no-args>` → read-only vicinae list of in-progress (with live %) and last 10 finished downloads.

- [ ] **Step 1: Write `roles/system/core/files/usr/bin/dl-status`**

```bash
#!/bin/bash
# dl-status — show in-progress and recent downloads in a vicinae list.
# In-progress: live systemd user units (dl-*); history: DL_RESULT journal markers.

set -u
lines=()

while read -r unit _ state _; do
  unit=${unit%.service}
  pct=$(journalctl --user -u "$unit" -o cat -n 60 2>/dev/null \
    | grep -oE '[0-9.]+%' | tail -n1)
  [ -n "$pct" ] && pct=" ${pct}"
  lines+=("▶ ${unit#dl-} (${state}${pct})")
done < <(systemctl --user list-units 'dl-*' --type=service --no-legend --plain 2>/dev/null)

mapfile -t hist < <(journalctl --user -u 'dl-*' -o cat 2>/dev/null \
  | grep '^DL_RESULT' | tail -n 10)
for entry in "${hist[@]}"; do
  case $entry in
    'DL_RESULT OK '*)   lines+=("✓ ${entry#DL_RESULT OK }") ;;
    'DL_RESULT FAIL '*) lines+=("✗ ${entry#DL_RESULT FAIL }") ;;
  esac
done

if [ ${#lines[@]} -eq 0 ]; then
  notify-send -a dl "No downloads yet"
  exit 0
fi

printf '%s\n' "${lines[@]}" \
  | vicinae dmenu -f data -n 'dl' -s '{count} downloads' -p 'In progress & history'
```

- [ ] **Step 2: Write `roles/system/core/files/home/.local/share/applications/dl-status.desktop`**

```ini
[Desktop Entry]
Type=Application
Name=dl — download status
Comment=In-progress and recent downloads (yt-dlp)
Exec=/usr/bin/dl-status
Icon=folder-download
Categories=Utility;
Keywords=dl;download;yt-dlp;history;
```

- [ ] **Step 3: Verify on host (uses the Task 1 journal history)**

```bash
chmod +x roles/system/core/files/usr/bin/dl-status
bash roles/system/core/files/usr/bin/dl-status
```

Expected: vicinae list shows at least the `✓ Me at the zoo` history entry from Task 1 (and a `▶` entry if a download is running). Trigger `dl` on the sample URL, then run `dl-status` while it downloads to confirm the `▶ … (running NN%)` line appears.

- [ ] **Step 4: Commit**

```bash
git add roles/system/core/files/usr/bin/dl-status \
        roles/system/core/files/home/.local/share/applications/dl-status.desktop
git commit -m "feat(dl): dl-status — in-progress + history view with launcher entry"
```

---

### Task 3: Hyprland keybind (both config formats)

**Files:**
- Modify: `roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua` (after the `transcript` bind, ~line with `hl.bind(mainMod .. " + a", ...)`)
- Modify: `roles/desktop/hyprland/files/home/.config/hypr/keybindings.conf` (after the transcript bind, before the video submap)

**Interfaces:**
- Consumes: `/usr/bin/dl` from Task 1 (must be deployable before the keybind is pressed).
- Produces: `Super+Shift+D` executes `dl`.

- [ ] **Step 1: Add to `keybindings.lua`**

```lua
-- Web download (clipboard URL → yt-dlp)
hl.bind(mainMod .. " + SHIFT + D", hl.dsp.exec_cmd("dl"))
```

- [ ] **Step 2: Add to `keybindings.conf`**

```ini
# Web download (clipboard URL → yt-dlp)
bind = SUPER SHIFT, d, exec, dl
```

- [ ] **Step 3: Verify Lua config validity**

```bash
env -u LD_LIBRARY_PATH hyprctl --config-verify 2>/dev/null || true
# If the Lua path supports a verify flag, run it; otherwise reload on deploy (Task 5)
# and watch `hyprctl errors` / notifications for bind errors.
```

- [ ] **Step 4: Commit (user may have uncommitted edits in these files — stage only your hunks if so)**

```bash
git diff --stat -- roles/desktop/hyprland/   # confirm whether files were already dirty
git add roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua \
        roles/desktop/hyprland/files/home/.config/hypr/keybindings.conf
git commit -m "feat(hyprland): Super+Shift+D triggers dl"
```

---

### Task 4: Role wiring — packages, script install, cleanup

**Files:**
- Modify: `roles/system/core/tasks/packages.yml` (Arch package list — **user-dirty file, stage only your hunk**)
- Modify: `roles/system/core/tasks/scripts.yml` (add 3 names to the `/usr/bin` loop; add desktop-entry copy; add absent-task for old scripts)

**Interfaces:**
- Consumes: script files from Tasks 1–2.
- Produces: idempotent deployment of `dl`, `dl-worker`, `dl-status` to `/usr/bin`, the `.desktop` entry, packages `aria2`/`yt-dlp`/`wl-clipboard`, removal of `a-yt-dl` + `yt-dl`.

- [ ] **Step 1: `packages.yml` — add to the Arch `name:` list (after `handlr-regex`)**

```yaml
      - aria2 # multi-connection downloads for yt-dlp external downloader
      - yt-dlp
      - wl-clipboard
```

- [ ] **Step 2: `scripts.yml` — extend the `/usr/bin` loop**

```yaml
  loop:
    - sound
    - play-pause
    - transcript
    - xdg-open
    - dl
    - dl-worker
    - dl-status
```

- [ ] **Step 3: `scripts.yml` — append two tasks at the end of the file**

```yaml
- name: Copy dl-status launcher entry
  ansible.builtin.copy:
    src: home/.local/share/applications/dl-status.desktop
    dest: '{{ ansible_facts["user_dir"] }}/.local/share/applications/dl-status.desktop'
    mode: '0644'
  tags: [system, config]

- name: Remove superseded download scripts
  ansible.builtin.file:
    path: '{{ ansible_facts["user_dir"] }}/.local/bin/{{ item }}'
    state: absent
  loop:
    - a-yt-dl
    - yt-dl
  tags: [system, config]
```

- [ ] **Step 4: Delete superseded repo files**

```bash
git rm roles/system/core/files/home/.local/bin/a-yt-dl roles/system/core/files/home/.local/bin/yt-dl
```

- [ ] **Step 5: Lint**

```bash
cd /mnt/POOL_1_DATA/CONFIGURATION/DotArch
yamllint roles/system/core/tasks/packages.yml roles/system/core/tasks/scripts.yml
ansible-lint roles/system/core   # via system install if .venv is broken (NFS quirk)
```

Expected: no new findings from these files.

- [ ] **Step 6: Commit — packages.yml is user-dirty; stage only your hunk**

```bash
git diff -U0 -- roles/system/core/tasks/packages.yml > /tmp/dl-pkgs.diff
# Edit /tmp/dl-pkgs.diff to keep ONLY the aria2/yt-dlp/wl-clipboard hunk
git apply --cached --unidiff-zero /tmp/dl-pkgs.diff
git add roles/system/core/tasks/scripts.yml \
        roles/system/core/files/usr/bin/dl \
        roles/system/core/files/usr/bin/dl-worker \
        roles/system/core/files/usr/bin/dl-status \
        roles/system/core/files/home/.local/share/applications/dl-status.desktop
git add roles/system/core/files/home/.local/bin/a-yt-dl roles/system/core/files/home/.local/bin/yt-dl  # staged deletions
git commit -m "feat(dl): role wiring — packages, /usr/bin install, old script cleanup"
```

(If the scripts were already committed in Tasks 1–2, only stage what remains.)

---

### Task 5: Deploy + end-to-end matrix

**Files:** none new (deployment only).

- [ ] **Step 1: Deploy the changed roles to localhost (scoped playbook — meta-role tag quirk)**

```bash
cat > /tmp/dl-deploy.yml <<'EOF'
---
- name: Deploy dl feature
  hosts: localhost
  connection: local
  roles:
    - role: system/core
    - role: desktop/hyprland
EOF
ANSIBLE_ROLES_PATH=/mnt/POOL_1_DATA/CONFIGURATION/DotArch/roles \
  /usr/sbin/ansible-playbook /tmp/dl-deploy.yml \
  -e target=laptop --vault-password-file password.sh
```

(If `become` copies to `/usr/bin` fail from NFS root-squash, stage the three scripts via `/tmp` with a manual `install -m 0755` and re-run for the rest.)

- [ ] **Step 2: Reload Hyprland config**

```bash
hyprctl reload
```

- [ ] **Step 3: Manual acceptance matrix**

For each: copy URL in Firefox (`Ctrl+L` `Ctrl+C`), press `Super+Shift+D`, choose preset:

1. YouTube video, 1080p → starts, lands in `~/Downloads/youtube-dl/<uploader>/`, finish notification.
2. Non-YouTube yt-dlp site → same.
3. Direct file URL → downloads, aria2c visible in journal.
4. Non-URL clipboard → "No URL in clipboard".
5. Esc at menu → nothing.
6. Two triggers back-to-back → both units run concurrently.
7. Notifications arrive from inside the unit (swaync shows start/finish/fail).
8. vicinae launcher: search "dl" → `dl — download status` entry opens the list.
9. `systemctl --user list-units 'dl-*'` empty when idle; `journalctl --user -u 'dl-*'` keeps history.

- [ ] **Step 4: Final report**

Summarize: aria2c/native downloader behavior observed, anything deviating from the spec, remaining nits.

---

## Self-Review (done)

- Spec coverage: presets menu ✓ (T1), aria2c ✓ (T1/T4), systemd units + markers ✓ (T1), dl-status + launcher ✓ (T2), keybind both formats ✓ (T3), packages + cleanup ✓ (T4), deployment quirks ✓ (T5), failure paths ✓ (T1 S6, T5 S3).
- Known deviation from spec: scripts install to `/usr/bin` (compositor PATH) instead of `~/.local/bin`; spec said `~/.local/bin` — this is a deployment-correctness fix, same content.
- Open verification points intentionally embedded as steps: `vicinae dmenu -f data` contract, `%(uploader|channel|Unknown)s` fallback, aria2c native fallback, unit-context notifications.
