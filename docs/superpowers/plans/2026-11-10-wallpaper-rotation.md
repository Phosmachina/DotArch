# Wallpaper Rotation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the wallpaper rotation, theme-aware via image luminance, sourced from an NFS gold folder with a local fallback.

**Architecture:** One bash script (`dotarch-wallpaper`) owns everything: luminance measurement (ImageMagick), an incremental shared TSV cache on NFS, theme-band filtering, and the hyprpaper IPC sequence. A new Ansible role `desktop/wallpaper` deploys it with three systemd user units (oneshot service + hourly timer with jitter + path unit on the theme state file). The hyprland role keeps only the daemon autostart entries.

**Tech Stack:** bash 5, ImageMagick (`magick`), hyprpaper IPC via `hyprctl`, systemd user units, Ansible (FQCN, yay AUR pattern).

**Spec:** `docs/superpowers/specs/2026-11-10-wallpaper-rotation-design.md`

## Global Constraints

- FQCN everywhere (`ansible.builtin.copy`…), YAML 2-space indent, `snake_case`.
- AUR installs: `ansible.builtin.shell` + `become: true` + `become_user: '{{ ansible_user }}'` + `# noqa: command-instead-of-shell` (repo convention).
- Tags for role tasks: `[desktop, wallpaper]` (+ `config`/`package` variants).
- Luminance boundary 100: dark pool `luma < 100`, light pool `luma >= 100` (mid-tones are light).
- Fallback: 10 dark + 10 light, deterministic (evenly spaced by luminance rank).
- Timer: `OnCalendar=hourly`, `RandomizedDelaySec=15m`, `Persistent=true`.
- hyprpaper IPC sequence: `preload <path>` → `wallpaper ,<path>` → `unload all`.
- Shared cache: `<gold>/.luminance.tsv`, atomic write (temp + rename), best-effort `flock`, local `~/.local/state/dotarch-wallpaper/luminance-fallback.tsv` when the dir is unwritable.
- Gold dir: `/mnt/POOL_1/DATA/DESIGN/Wallpapers/themefoxx` (2056 JPG, numbering is continuous across the 8 archives so flat extraction is collision-free).
- **Env quirks:** scratch files live in the repo's `.zcode/` (sandboxed `/tmp` writes are invisible to the host); deploys use system `/usr/sbin/ansible-playbook` (`.venv` on NFS is broken); `env -u LD_LIBRARY_PATH` before diagnosing any "broken system binary"; Bash-tool commands writing to NFS may need `dangerouslyDisableSandbox`.
- **Commit hygiene:** the user edits the repo mid-session. Commit only your own files/hunks (`git add <specific paths>`; if a shared file like `deployment_config.yml` carries unrelated edits, stage with `git diff -U0` + `git apply --cached --unidiff-zero`).

## File Structure

```
roles/desktop/wallpaper/
├── tasks/main.yml                                    # deploy + units + fallback sync + legacy cleanup
└── files/home/
    ├── .local/bin/dotarch-wallpaper                  # the whole rotation engine (0755)
    ├── .config/hypr/hyprpaper.conf                   # moved from hyprland role, content unchanged
    ├── .config/systemd/user/dotarch-wallpaper.service
    ├── .config/systemd/user/dotarch-wallpaper.timer
    ├── .config/systemd/user/dotarch-wallpaper-theme.path
    └── Images/Wallpapers/1.jpg                       # git mv from hyprland role (startup image)
```

Modified: `roles/profiles/desktop-hyprland/tasks/main.yml` (include_role block),
`group_vars/all/deployment_config.yml` (toggle + gold dir var),
`roles/desktop/hyprland/tasks/hyprland-tools.yml` (remove hyprpaper tasks),
`roles/desktop/hyprland/tasks/hyprland.yml:75` (remove `random-wallpaper.sh` from the scripts loop),
`roles/desktop/hyprland/templates/home/.config/hypr/hyprland.lua.j2` (2 autostart lines).

Deleted: `roles/desktop/hyprland/files/home/.config/hypr/scripts/random-wallpaper.sh`,
`roles/desktop/hyprland/files/home/.config/hypr/hyprpaper.conf`,
`roles/desktop/hyprland/files/home/.config/systemd/user/hyprpaper.service`,
`roles/desktop/hyprland/files/home/.config/systemd/user/hyprpaper.timer`.

Scratch (never committed): `.zcode/wallpaper-fixtures/`, `.zcode/wp-state/`, `.zcode/wallpaper-fallback/`, `.zcode/wallpaper-scoped.yml`.

---

### Task 1: Extract the gold wallpaper pool on the NFS

**Files:** none in the repo (NFS content only).

- [ ] **Step 1: Extract all 8 archives flat into the gold dir**

Names are globally unique (continuous `(1)`…`(2056)` numbering), verified per
archive: 7×254 + 278 = 2056 JPG. Run from any directory (absolute paths; no
`cd`). If the sandbox refuses NFS writes (`Read-only file system` /
permission errors), retry with `dangerouslyDisableSandbox: true`.

```bash
mkdir -p /mnt/POOL_1/DATA/DESIGN/Wallpapers/themefoxx
for i in 01 02 03 04 05 06 07 08; do
  unrar x -o+ -y "/mnt/POOL_1/DATA/DESIGN/Wallpapers/2000-4K-Wallpapers-Themefoxx-$i.rar" \
    /mnt/POOL_1/DATA/DESIGN/Wallpapers/themefoxx/
done
```

Expected: 8× "All OK" from unrar. ~5.6 GB, several minutes — run in
background if needed.

- [ ] **Step 2: Verify the pool**

```bash
find /mnt/POOL_1/DATA/DESIGN/Wallpapers/themefoxx -type f -iname '*.jpg' | wc -l
find /mnt/POOL_1/DATA/DESIGN/Wallpapers/themefoxx -type f | sed 's|.*/||' | sort | uniq -d | wc -l
du -sh /mnt/POOL_1/DATA/DESIGN/Wallpapers/themefoxx
```

Expected: `2056`, `0` (no duplicate names), `~5.6G`.

- [ ] **Step 3: No commit** (NFS content is not repo material).

---

### Task 2: The `dotarch-wallpaper` script (TDD with generated fixtures)

**Files:**
- Create: `roles/desktop/wallpaper/files/home/.local/bin/dotarch-wallpaper`
- Test: `.zcode/wallpaper-fixtures/` (scratch)

**Interfaces:**
- Produces: `dotarch-wallpaper [rotate|candidates|sync-fallback DEST]`;
  env overrides `DOTARCH_WALLPAPER_GOLD`, `DOTARCH_WALLPAPER_FALLBACK`,
  `DOTARCH_WALLPAPER_THEME_STATE`, `DOTARCH_WALLPAPER_STATE`;
  TSV format `path\tmtime\tsize\tluma`.

- [ ] **Step 1: Generate deterministic fixtures**

Solid gray images have an exactly-known mean luminance. Keep test values away
from the JPEG ±2 rounding zone around the boundary (nothing between 80 and
120).

```bash
mkdir -p .zcode/wallpaper-fixtures
for v in 0 20 40 60 80; do
  magick -size 64x64 xc:"gray($v)" ".zcode/wallpaper-fixtures/dark-$(printf '%03d' "$v").jpg"
done
for v in 120 160 200 240 255; do
  magick -size 64x64 xc:"gray($v)" ".zcode/wallpaper-fixtures/light-$(printf '%03d' "$v").jpg"
done
printf 'current=dark\n'  > .zcode/wallpaper-fixtures/theme-dark
printf 'current=light\n' > .zcode/wallpaper-fixtures/theme-light
ls .zcode/wallpaper-fixtures
```

Expected: 12 files (10 jpg + 2 theme states).

- [ ] **Step 2: Write the script** — complete content:

```bash
#!/usr/bin/env bash
# dotarch-wallpaper — theme-aware wallpaper rotation for hyprpaper.
# Spec: docs/superpowers/specs/2026-11-10-wallpaper-rotation-design.md
#
# Usage:
#   dotarch-wallpaper                    rotate once (timer / path unit / login)
#   dotarch-wallpaper candidates         print the pool for the current theme
#   dotarch-wallpaper sync-fallback DEST deterministic 10 dark + 10 light copy
set -euo pipefail

# ---- Tunables (dir paths env-overridable for testing) ----
GOLD_DIR="${DOTARCH_WALLPAPER_GOLD:-/mnt/POOL_1/DATA/DESIGN/Wallpapers/themefoxx}"
FALLBACK_DIR="${DOTARCH_WALLPAPER_FALLBACK:-$HOME/Images/Wallpapers}"
THEME_STATE="${DOTARCH_WALLPAPER_THEME_STATE:-$HOME/.local/state/dotarch-theme/state}"
STATE_DIR="${DOTARCH_WALLPAPER_STATE:-$HOME/.local/state/dotarch-wallpaper}"
LUMA_BOUNDARY=100        # dark pool: luma < BOUNDARY; light pool: luma >= BOUNDARY
NFS_TIMEOUT=2            # seconds to probe the gold dir
CACHE_NAME=".luminance.tsv"
FALLBACK_PER_BAND=10     # sync-fallback: images per band

log() { printf 'dotarch-wallpaper: %s\n' "$*" >&2; }

theme_current() {
    # dark|light from the dotarch-theme state file; dark on any failure.
    local value
    value=$(sed -n 's/^current=//p' "$THEME_STATE" 2>/dev/null | tail -n1 || true)
    if [[ "$value" == light ]]; then echo light; else echo dark; fi
}

source_dir() {
    # Gold dir when reachable within NFS_TIMEOUT, else local fallback.
    if timeout "$NFS_TIMEOUT" stat -c %s "$GOLD_DIR" >/dev/null 2>&1; then
        printf '%s\n' "$GOLD_DIR"
    else
        log "gold dir unreachable, falling back to $FALLBACK_DIR"
        printf '%s\n' "$FALLBACK_DIR"
    fi
}

luminance_of() {
    # Mean gray level 0..255 of a 64x64 thumbnail of $1.
    magick "$1"[0] -colorspace Gray -resize 64x64 \
        -format '%[fx:int(mean*255+0.5)]' info: 2>/dev/null || true
}

cache_path() {
    # Shared TSV beside the images when writable, else one in STATE_DIR.
    mkdir -p "$STATE_DIR"
    if touch "$1/$CACHE_NAME" 2>/dev/null; then
        printf '%s\n' "$1/$CACHE_NAME"
    else
        log "cache not writable in $1, using $STATE_DIR"
        printf '%s\n' "$STATE_DIR/luminance-fallback.tsv"
    fi
}

ensure_cache() {
    # $1 dir, $2 cache file. Incremental rows keyed path|mtime|size, atomic swap.
    local dir="$1" cache="$2" f mtime size luma computed=0 key
    local -A have=()
    if [[ -s "$cache" ]]; then
        while IFS=$'\t' read -r f mtime size luma; do
            have["$f|$mtime|$size"]=$luma
        done <"$cache"
    fi
    local tmp
    tmp=$(mktemp "${cache}.XXXXXX")
    while IFS= read -r -d '' f; do
        mtime=$(stat -c %Y "$f" 2>/dev/null) || continue
        size=$(stat -c %s "$f" 2>/dev/null) || continue
        key="$f|$mtime|$size"
        if [[ -n "${have[$key]:-}" ]]; then
            luma=${have[$key]}
        else
            luma=$(luminance_of "$f")
            [[ "$luma" =~ ^[0-9]+$ ]] || continue
            computed=$((computed + 1))
        fi
        printf '%s\t%s\t%s\t%s\n' "$f" "$mtime" "$size" "$luma"
    done < <(find "$dir" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) -print0 | sort -z) \
        >"$tmp"
    (
        flock -x 8 2>/dev/null || true
        mv -f "$tmp" "$cache"
    ) 8>>"$cache"
    if ((computed > 0)); then log "computed $computed luminance rows"; fi
}

pool_for() {
    # $1 theme, $2 basename to exclude (optional). stdin: TSV; stdout: paths.
    local excl="${2:-}"
    if [[ "$1" == light ]]; then
        awk -F'\t' -v b="$LUMA_BOUNDARY" -v e="$excl" \
            '{ nb=$1; sub(".*/","",nb); if ($4+0 >= b && nb != e) print $1 }'
    else
        awk -F'\t' -v b="$LUMA_BOUNDARY" -v e="$excl" \
            '{ nb=$1; sub(".*/","",nb); if ($4+0 < b && nb != e) print $1 }'
    fi
}

current_wallpaper() {
    # Path of the loaded wallpaper (empty when hyprpaper is down or idle).
    hyprctl hyprpaper listloaded 2>/dev/null \
        | sed -n 's/^[^/]*\(\/.*\)$/\1/p' | head -n1 || true
}

rotate() {
    local theme dir cache current="" current_base="" pick
    theme=$(theme_current)
    dir=$(source_dir)
    cache=$(cache_path "$dir")
    ensure_cache "$dir" "$cache"
    current=$(current_wallpaper)
    if [[ -n "$current" ]]; then current_base=$(basename "$current"); fi
    pick=$(pool_for "$theme" "$current_base" <"$cache" | shuf -n1 || true)
    if [[ -z "$pick" ]]; then
        log "theme=$theme: no candidate in $dir, keeping current wallpaper"
        return 0
    fi
    if ! hyprctl hyprpaper preload "$pick"; then
        log "hyprpaper IPC failed (daemon not running?)"
        return 1
    fi
    hyprctl hyprpaper wallpaper ",$pick"
    hyprctl hyprpaper unload all
    log "theme=$theme: $(basename "$pick")"
}

cmd_candidates() {
    local theme dir cache
    theme=$(theme_current)
    dir=$(source_dir)
    cache=$(cache_path "$dir")
    ensure_cache "$dir" "$cache"
    pool_for "$theme" "" <"$cache"
}

sync_fallback() {
    # Deterministic sample (FALLBACK_PER_BAND per band, evenly spaced by
    # luminance rank) copied from the source dir into $1.
    local dest="${1:?sync-fallback needs a destination}"
    local dir cache band tsv total step picked out copied=0 tmpdir rel dst
    dir=$(source_dir)
    cache=$(cache_path "$dir")
    ensure_cache "$dir" "$cache"
    mkdir -p "$dest"
    tmpdir=$(mktemp -d "${STATE_DIR}/sync.XXXXXX")
    for band in dark light; do
        tsv="$tmpdir/$band.tsv"
        sort -t$'\t' -k4,4n "$cache" | pool_for "$band" "" >"$tsv"
        total=$(wc -l <"$tsv")
        if ((total < 1)); then continue; fi
        step=$((total / FALLBACK_PER_BAND))
        if ((step < 1)); then step=1; fi
        picked=$(awk -v s="$step" 'NR % s == 1' "$tsv" | cut -f1)
        if [[ -z "$picked" ]]; then continue; fi
        out=$(
            while IFS= read -r src; do
                rel=${src#"$dir"/}
                dst="$dest/$(printf '%s' "$rel" | tr '/' '_')"
                if [[ ! -e "$dst" ]] || ! cmp -s -- "$src" "$dst"; then
                    cp -f -- "$src" "$dst"
                    printf 'copied %s\n' "$(basename "$dst")"
                fi
            done <<<"$picked"
        )
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out"
            copied=1
        fi
    done
    rm -rf "$tmpdir"
    if ((copied == 0)); then echo "sync-fallback: no changes"; fi
}

case "${1:-rotate}" in
    rotate)
        rotate
        ;;
    candidates)
        cmd_candidates
        ;;
    sync-fallback)
        shift
        sync_fallback "${1:-}"
        ;;
    *)
        printf 'usage: %s [rotate|candidates|sync-fallback DEST]\n' "${0##*/}" >&2
        exit 64
        ;;
esac
```

Save exactly this content to
`roles/desktop/wallpaper/files/home/.local/bin/dotarch-wallpaper`, then
`chmod +x` it.

- [ ] **Step 3: Test — dark pool**

```bash
DOTARCH_WALLPAPER_GOLD=$PWD/.zcode/wallpaper-fixtures \
DOTARCH_WALLPAPER_THEME_STATE=$PWD/.zcode/wallpaper-fixtures/theme-dark \
DOTARCH_WALLPAPER_STATE=$PWD/.zcode/wp-state \
bash roles/desktop/wallpaper/files/home/.local/bin/dotarch-wallpaper candidates | sort
```

Expected: exactly 5 lines, `dark-000.jpg` … `dark-080.jpg` (nothing ≥ 100).

- [ ] **Step 4: Test — light pool**

Same command with `theme-light` instead of `theme-dark`.

Expected: exactly 5 lines, `light-120.jpg` … `light-255.jpg`.

- [ ] **Step 5: Test — cache behavior**

```bash
wc -l .zcode/wallpaper-fixtures/.luminance.tsv        # 10 rows
# second run computes nothing: stderr must NOT contain "computed"
DOTARCH_WALLPAPER_GOLD=$PWD/.zcode/wallpaper-fixtures \
DOTARCH_WALLPAPER_THEME_STATE=$PWD/.zcode/wallpaper-fixtures/theme-dark \
DOTARCH_WALLPAPER_STATE=$PWD/.zcode/wp-state \
bash roles/desktop/wallpaper/files/home/.local/bin/dotarch-wallpaper candidates >/dev/null
touch .zcode/wallpaper-fixtures/dark-040.jpg
# third run: stderr contains "computed 1 luminance rows"
```

- [ ] **Step 6: Test — sync-fallback determinism**

```bash
export DOTARCH_WALLPAPER_GOLD=$PWD/.zcode/wallpaper-fixtures \
       DOTARCH_WALLPAPER_THEME_STATE=$PWD/.zcode/wallpaper-fixtures/theme-dark \
       DOTARCH_WALLPAPER_STATE=$PWD/.zcode/wp-state
bash roles/desktop/wallpaper/files/home/.local/bin/dotarch-wallpaper \
  sync-fallback "$PWD/.zcode/wallpaper-fallback"
ls .zcode/wallpaper-fallback | wc -l                  # 10
bash roles/desktop/wallpaper/files/home/.local/bin/dotarch-wallpaper \
  sync-fallback "$PWD/.zcode/wallpaper-fallback"      # prints "sync-fallback: no changes"
```

- [ ] **Step 7: Commit**

```bash
git add roles/desktop/wallpaper/files/home/.local/bin/dotarch-wallpaper
git commit -m "feat(wallpaper): add dotarch-wallpaper rotation script"
```

---

### Task 3: systemd units + hyprpaper.conf

**Files:**
- Create: `roles/desktop/wallpaper/files/home/.config/systemd/user/dotarch-wallpaper.service`
- Create: `roles/desktop/wallpaper/files/home/.config/systemd/user/dotarch-wallpaper.timer`
- Create: `roles/desktop/wallpaper/files/home/.config/systemd/user/dotarch-wallpaper-theme.path`
- Create: `roles/desktop/wallpaper/files/home/.config/hypr/hyprpaper.conf`

**Interfaces:**
- Produces: units all named `dotarch-wallpaper*`, all targeting
  `Unit=dotarch-wallpaper.service`; conf preloading `~/Images/Wallpapers/1.jpg`.

- [ ] **Step 1: Write the three units**

`dotarch-wallpaper.service` (follows the `dotarch-theme.service` style):

```ini
[Unit]
Description=Theme-aware wallpaper rotation (hyprpaper)

[Service]
Type=oneshot
ExecStart=%h/.local/bin/dotarch-wallpaper
```

`dotarch-wallpaper.timer`:

```ini
[Unit]
Description=Hourly wallpaper rotation with jitter

[Timer]
OnCalendar=hourly
RandomizedDelaySec=15m
Persistent=true
Unit=dotarch-wallpaper.service

[Install]
WantedBy=timers.target
```

`dotarch-wallpaper-theme.path` (explicit `Unit=` — a `.path` unit otherwise
activates the same-named service):

```ini
[Unit]
Description=Rotate wallpaper when the dotarch-theme state changes

[Path]
PathModified=%h/.local/state/dotarch-theme/state
Unit=dotarch-wallpaper.service

[Install]
WantedBy=paths.target
```

- [ ] **Step 2: Write hyprpaper.conf** (content unchanged, moved from the hyprland role):

```ini
# Hyprpaper configuration
preload = ~/Images/Wallpapers/1.jpg
wallpaper = ,~/Images/Wallpapers/1.jpg
ipc = on
splash = false
```

- [ ] **Step 3: Syntax-check the units**

```bash
systemd-analyze verify \
  roles/desktop/wallpaper/files/home/.config/systemd/user/dotarch-wallpaper.service \
  roles/desktop/wallpaper/files/home/.config/systemd/user/dotarch-wallpaper.timer \
  roles/desktop/wallpaper/files/home/.config/systemd/user/dotarch-wallpaper-theme.path
```

Expected: no output (or only warnings about the `%h` home being unknown at
verify time — those are fine; real loading is verified in Task 5).

- [ ] **Step 4: Commit**

```bash
git add roles/desktop/wallpaper/files/home/.config/systemd/user/ \
        roles/desktop/wallpaper/files/home/.config/hypr/hyprpaper.conf
git commit -m "feat(wallpaper): systemd units and hyprpaper config"
```

---

### Task 4: Ansible role wiring + hyprland cleanup

**Files:**
- Create: `roles/desktop/wallpaper/tasks/main.yml`
- Create: `roles/desktop/wallpaper/files/home/Images/Wallpapers/1.jpg` (git mv)
- Modify: `roles/profiles/desktop-hyprland/tasks/main.yml` (after the theming block)
- Modify: `group_vars/all/deployment_config.yml` (theme section)
- Modify: `roles/desktop/hyprland/tasks/hyprland-tools.yml`
- Modify: `roles/desktop/hyprland/tasks/hyprland.yml:75`
- Modify: `roles/desktop/hyprland/templates/home/.config/hypr/hyprland.lua.j2` (autostart list)
- Delete: the 4 legacy hyprpaper files listed in File Structure

**Interfaces:**
- Consumes: script from Task 2 (`sync-fallback` prints `copied …` lines or
  `sync-fallback: no changes`), units from Task 3.
- Produces: role `desktop/wallpaper`, toggle `enable_wallpaper`, var
  `wallpaper_gold_dir` (must equal the script's `GOLD_DIR` default).

- [ ] **Step 1: Move the startup image**

```bash
mkdir -p roles/desktop/wallpaper/files/home/Images/Wallpapers
git mv roles/desktop/hyprland/files/home/Images/Wallpapers/1.jpg \
       roles/desktop/wallpaper/files/home/Images/Wallpapers/1.jpg
rmdir roles/desktop/hyprland/files/home/Images/Wallpapers \
      roles/desktop/hyprland/files/home/Images 2>/dev/null || true
```

- [ ] **Step 2: Write `roles/desktop/wallpaper/tasks/main.yml`** — complete content:

```yaml
---
# Wallpaper role — theme-aware rotation via hyprpaper + luminance pools.
# Spec: docs/superpowers/specs/2026-11-10-wallpaper-rotation-design.md

- name: Install hyprpaper from AUR (Arch)
  ansible.builtin.shell: 'yay -Sy --noconfirm hyprpaper'  # noqa: command-instead-of-shell
  become: true
  become_user: '{{ ansible_user }}'
  changed_when: true
  when: ansible_facts.distribution == 'Archlinux'
  tags: [desktop, wallpaper, package]

- name: Install imagemagick (Arch)
  become: true
  community.general.pacman:
    name: imagemagick
    state: present
  when: ansible_facts.distribution == 'Archlinux'
  tags: [desktop, wallpaper, package]

- name: Create wallpaper directories
  ansible.builtin.file:
    path: '{{ ansible_facts["user_dir"] }}/{{ item }}'
    state: directory
    mode: '0755'
  loop:
    - '.local/bin'
    - '.local/state/dotarch-wallpaper'
    - 'Images/Wallpapers'
    - '.config/hypr'
    - '.config/systemd/user'
  tags: [desktop, wallpaper, config]

- name: Install dotarch-wallpaper
  ansible.builtin.copy:
    src: 'home/.local/bin/dotarch-wallpaper'
    dest: '{{ ansible_facts["user_dir"] }}/.local/bin/dotarch-wallpaper'
    mode: '0755'
  tags: [desktop, wallpaper, config]

- name: Copy hyprpaper configuration
  ansible.builtin.copy:
    src: 'home/.config/hypr/hyprpaper.conf'
    dest: '{{ ansible_facts["user_dir"] }}/.config/hypr/hyprpaper.conf'
    mode: '0644'
  tags: [desktop, wallpaper, config]

- name: Copy startup wallpaper
  ansible.builtin.copy:
    src: 'home/Images/Wallpapers/1.jpg'
    dest: '{{ ansible_facts["user_dir"] }}/Images/Wallpapers/1.jpg'
    mode: '0644'
  tags: [desktop, wallpaper, config]

- name: Install systemd user units
  ansible.builtin.copy:
    src: 'home/.config/systemd/user/{{ item }}'
    dest: '{{ ansible_facts["user_dir"] }}/.config/systemd/user/{{ item }}'
    mode: '0644'
  loop:
    - dotarch-wallpaper.service
    - dotarch-wallpaper.timer
    - dotarch-wallpaper-theme.path
  tags: [desktop, wallpaper, config]

- name: Check the gold wallpaper dir on the NFS
  ansible.builtin.stat:
    path: '{{ wallpaper_gold_dir }}'
  register: wallpaper_gold
  tags: [desktop, wallpaper, config]

- name: Synchronize local fallback wallpapers (10 dark + 10 light)
  ansible.builtin.shell: >-  # noqa: command-instead-of-shell
    {{ ansible_facts["user_dir"] }}/.local/bin/dotarch-wallpaper
    sync-fallback {{ ansible_facts["user_dir"] }}/Images/Wallpapers
  register: wallpaper_sync
  changed_when: "'no changes' not in (wallpaper_sync.stdout | default(''))"
  when: wallpaper_gold.stat.exists | default(false)
  tags: [desktop, wallpaper, config]

- name: Skip note when the gold dir is absent
  ansible.builtin.debug:
    msg: >
      Gold dir {{ wallpaper_gold_dir }} not found — fallback sync skipped
      (host without the NFS pool).
  when: not (wallpaper_gold.stat.exists | default(false))
  tags: [desktop, wallpaper, config]

- name: Remove legacy hyprpaper rotation units and scripts
  ansible.builtin.file:
    path: '{{ ansible_facts["user_dir"] }}/{{ item }}'
    state: absent
  loop:
    - '.config/systemd/user/hyprpaper.service'
    - '.config/systemd/user/hyprpaper.timer'
    - '.config/hypr/scripts/hyprpaper-hourly.sh'
    - '.config/hypr/scripts/random-wallpaper.sh'
  tags: [desktop, wallpaper, config]

- name: Resolve ansible_user uid
  ansible.builtin.command: id -u {{ ansible_user }}
  register: wallpaper_uid
  changed_when: false
  tags: [desktop, wallpaper, config]

- name: Activate wallpaper units (and drop the legacy timer)
  ansible.builtin.shell: |
    systemctl --user daemon-reload
    systemctl --user disable --now hyprpaper.timer 2>/dev/null || true
    systemctl --user enable --now dotarch-wallpaper.timer
    systemctl --user enable --now dotarch-wallpaper-theme.path
  environment:
    XDG_RUNTIME_DIR: "/run/user/{{ wallpaper_uid.stdout }}"
  register: wallpaper_units_activate
  failed_when: false
  changed_when: true
  # noqa: command-instead-of-shell command-instead-of-module
  tags: [desktop, wallpaper, config]

- name: Warn when the user manager was unreachable
  ansible.builtin.debug:
    msg: >
      Could not reach the systemd user manager (deploy from a pure SSH
      context?). The units will activate at next graphical login, or re-run
      this role logged in.
  when: wallpaper_units_activate.rc | default(0) != 0
  tags: [desktop, wallpaper, config]
```

- [ ] **Step 3: Wire the meta-role** — in
`roles/profiles/desktop-hyprland/tasks/main.yml`, insert right after the
"Include day/night theme switching" block:

```yaml
- name: Include wallpaper rotation
  ansible.builtin.include_role:
    name: desktop/wallpaper
  tags: [desktop, wallpaper]
  when: enable_wallpaper | default(true)
```

- [ ] **Step 4: Add the toggle + gold dir var** — in
`group_vars/all/deployment_config.yml`, right after the theme block:

```yaml
# Wallpaper rotation (desktop/wallpaper)
enable_wallpaper: true
wallpaper_gold_dir: "/mnt/POOL_1/DATA/DESIGN/Wallpapers/themefoxx"   # NFS source pool (must match the script default)
```

- [ ] **Step 5: Clean up `hyprland-tools.yml`** — remove exactly these tasks:
"Install Hyprland tools from AUR (Arch)" keeps the loop minus `hyprpaper`
(keep `hyprpicker`, `hyprsunset`, `hypridle`, `hyprlock`); "Configure Hyprland
tools" keeps the loop minus `hyprpaper` (keep `hyprsunset`, `hyprlock`);
delete whole tasks "Ensure required directories exist", "Copy wallpaper",
"Copy the hyprpaper rotation script", "Create systemd user directory", "Copy
hyprpaper systemd service file", "Copy hyprpaper systemd timer file",
"Enable and start hyprpaper timer". KEEP "Create hypr scripts directory" and
"Copy workspace cycler script" (still used).

- [ ] **Step 6: Clean up `hyprland.yml`** — in the "Copy hyprland scripts"
loop (line ~75), delete the `- 'random-wallpaper.sh'` entry.

- [ ] **Step 7: Delete legacy repo files**

```bash
git rm roles/desktop/hyprland/files/home/.config/hypr/scripts/random-wallpaper.sh \
       roles/desktop/hyprland/files/home/.config/hypr/hyprpaper.conf \
       roles/desktop/hyprland/files/home/.config/systemd/user/hyprpaper.service \
       roles/desktop/hyprland/files/home/.config/systemd/user/hyprpaper.timer
```

- [ ] **Step 8: Add the autostart entries** — in
`roles/desktop/hyprland/templates/home/.config/hypr/hyprland.lua.j2`, extend
the autostart list (lines 9-21) with two entries after `"voxtype daemon",`:

```lua
        "hyprpaper",
        "sh -c 'sleep 3 && $HOME/.local/bin/dotarch-wallpaper'",
```

- [ ] **Step 9: Lint**

```bash
yamllint . && ansible-lint
```

Expected: clean (existing skips in `.ansible-lint` cover
`role-name[path]`, `yaml[empty-lines]`; noqa comments cover shell tasks). If
`yamllint`/`ansible-lint` only exist in the broken venv, try
`env -u LD_LIBRARY_PATH $(command -v ansible-lint)` — the system binaries
have worked in recent sessions.

- [ ] **Step 10: Commit** (only the paths of this task):

```bash
git add roles/desktop/wallpaper/ \
        roles/profiles/desktop-hyprland/tasks/main.yml \
        group_vars/all/deployment_config.yml \
        roles/desktop/hyprland/
git commit -m "feat(wallpaper): ansible role, meta-role wiring and hyprpaper cleanup"
```

---

### Task 5: Deploy + verify on the host

**Files:**
- Create: `.zcode/wallpaper-scoped.yml` (scratch, never committed)

**Interfaces:**
- Consumes: role from Task 4; `--tags` cannot reach through the meta-role, so
  a scoped playbook with `import_role` is required (repo quirk).

- [ ] **Step 1: Write the scoped playbook**

```yaml
# Scoped deploy: wallpaper role + hyprland template re-render, bypassing the
# meta-role tag trap via import_role (role context + defaults still apply)
- hosts: arch
  connection: local
  vars_files:
    - /mnt/POOL_1_DATA/CONFIGURATION/DotArch/group_vars/all/variables.yml
    - /mnt/POOL_1_DATA/CONFIGURATION/DotArch/group_vars/all/deployment_config.yml
  tasks:
    - name: Deploy wallpaper rotation (scoped)
      ansible.builtin.import_role:
        name: desktop/wallpaper
    - name: Re-render hyprland config (autostart additions)
      ansible.builtin.import_role:
        name: desktop/hyprland
        tasks_from: hyprland.yml
```

- [ ] **Step 2: Deploy**

```bash
cd /mnt/POOL_1_DATA/CONFIGURATION/DotArch
ANSIBLE_ROLES_PATH=roles /usr/sbin/ansible-playbook .zcode/wallpaper-scoped.yml \
  --vault-password-file password.sh
```

Expected: all tasks ok/changed; "Warn when the user manager was unreachable"
NOT triggered.

- [ ] **Step 3: Units verification**

```bash
systemctl --user list-timers dotarch-wallpaper.timer   # scheduled within the hour, jitter column populated
systemctl --user is-active dotarch-wallpaper-theme.path  # active
systemctl --user list-unit-files | grep hyprpaper.timer  # no output (legacy gone)
ls ~/.config/hypr/scripts/                                # no hyprpaper-hourly.sh / random-wallpaper.sh
ls ~/Images/Wallpapers | wc -l                            # 21 (20 synced + 1.jpg)
```

- [ ] **Step 4: Start hyprpaper now (no relogin needed) and rotate once**

```bash
hyprctl dispatch exec hyprpaper
sleep 2
hyprctl hyprpaper listloaded                             # shows 1.jpg
~/.local/bin/dotarch-wallpaper                           # builds the 2056-row TSV (~1-2 min), then rotates
hyprctl hyprpaper listloaded                             # shows a NEW image
wc -l /mnt/POOL_1/DATA/DESIGN/Wallpapers/themefoxx/.luminance.tsv  # 2056
```

Run the rotation a second time — it must be instant (cache hit) and pick a
different image than before.

- [ ] **Step 5: Theme-switch trigger**

```bash
touch ~/.local/state/dotarch-theme/state
sleep 2
journalctl --user -u dotarch-wallpaper.service -n 3 --no-pager   # a fresh run logged
```

- [ ] **Step 6: Fallback drill (simulated NFS loss)**

```bash
DOTARCH_WALLPAPER_GOLD=/mnt/nonexistent ~/.local/bin/dotarch-wallpaper candidates | head -3
```

Expected: 3 paths under `~/Images/Wallpapers` and a stderr note about the
fallback.

- [ ] **Step 7: No repo commit** (scratch playbook only). Report results to
the user; live behavior (timer over hours, relogin autostart) is theirs to
confirm.

---

### Task 6: Spec status + final checks

**Files:**
- Modify: `docs/superpowers/specs/2026-11-10-wallpaper-rotation-design.md`

- [ ] **Step 1: Flip the spec status** — `Status: implemented (2026-11-10)`.

- [ ] **Step 2: Full lint pass**

```bash
yamllint . && ansible-lint
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-11-10-wallpaper-rotation-design.md
git commit -m "docs(wallpaper): mark spec implemented"
```

---

## Self-Review Notes

- Spec coverage: provisioning (Task 1), luminance + shared TSV (Task 2),
  rotation flow + correct IPC (Task 2/5), sync-fallback (Task 2/4), triggers
  incl. jitter + path unit (Task 3), hyprland autostart + daemon (Tasks 4/5),
  ansible wiring + toggle + cleanup (Task 4), verification incl. NFS-loss
  drill (Task 5).
- Known accepted deviation: the path unit fires on ANY rewrite of the theme
  state file (daily sun-cache refresh included), not only on dark↔light
  flips — extra rotations are harmless by design.
- `set -e` pitfalls checked: no bare `cond && action` at statement level in
  the script (all wrapped in `if`).
