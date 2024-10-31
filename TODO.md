## TODO

### Feature

- Make laptop specific tasks (e.g.: system/app packages).
- Maybe add another user to run yay with sudo.
- Add an ansible task to configure sudo NOPASSWD for the current user. 
- Maybe using docker is a bad idea: python is already a required dependency.
- Autoconfigure the ssh key with the run.sh script or something. 
- Clean the pacman.conf file.
- In place of history, make function, scripts and a cheatsheet: history should not be
  stored.
- Review script files and upgrade it. e.g.:
    - pandoc helper: Is there already a better tool for this?
    - yt-dl can purpose a streaming mode.
    - many scripts miss dependency check and don't have usage/help.

## Bug

- lf previewer doesn't work for archives.
- It could be great if handlr opens a rofi program selector when nothing is configured.

## Done

- Take into account double configuration for polybar.
- Add cifs mount in fstab for remote data.
- Fix `ERROR! 'target_role' is undefined`.
- Split into three parts (system/wm/app) and make corresponding subtasks.
- Maybe move `onedark.rasi` in rofi config folder.
- Take into account double configuration for polybar.
- Add a way to encrypt files with ansible.
