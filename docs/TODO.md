## TODO

### Feature

- Make laptop specific tasks (e.g.: system/app packages).
- Maybe add another user to run yay with sudo.
- Add an ansible task to configure sudo NOPASSWD for the current user. 
- Clean the pacman.conf file.
- In place of history, make function, scripts and a cheatsheet: history should not be
  stored.
- Review script files and upgrade it. e.g.:
    - pandoc helper: Is there already a better tool for this?
    - yt-dl can purpose a streaming mode.
    - many scripts miss dependency check and don't have usage/help.
- Make a task for the wallpaper cron.
- Add a molecule configuration to test through a VM.
- Add power-profiles-daemon or similar solution for power management.

Looks interesting:
- [Atuin - Shell History & Executable Runbooks](https://atuin.sh/#cli-section)
- [zed-industries/zed: Code at the speed of thought – Zed is a high-performance, multiplayer code editor from the creators of Atom and Tree-sitter.](https://github.com/zed-industries/zed)
- [Setup Instructions - Markdown-Oxide Wiki](https://oxide.md/Setup+Instructions)

## Bug

- lf previewer doesn't work for archives.
- It could be great if handlr opens a rofi program selector when nothing is configured.

## Done

- Add task to deploy qemu environment
- Take into account double configuration for polybar.
- Add cifs mount in fstab for remote data.
- Fix `ERROR! 'target_role' is undefined`.
- Split into three parts (system/wm/app) and make corresponding subtasks.
- Maybe move `onedark.rasi` in rofi config folder.
- Take into account double configuration for polybar.
- Add a way to encrypt files with ansible.
