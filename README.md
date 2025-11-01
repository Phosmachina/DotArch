# DotArch

**Store and Manage my Arch Linux Configuration with Ease 💻**

Welcome to DotArch, a project to store and manage my Arch Linux configuration using
an Ansible playbook.
This project is divided into three parts: `common`, `desktop`,
and `laptop`, allowing you to customize the setup according to your needs.

## Common Tasks 📋

Currently implemented common tasks:

- **System:** Core components to install and configure base packages, configuring global
  system settings (i.e., locale, timezone, etc.). 🌍
    - **yay:** Setting up the yay AUR helper. 📦
    - **zsh:** Installing and configuring zsh as the default shell. 🐚
    - **pipewire:** Setting up PipeWire for audio processing and device management. 🔊

- **WM:** Setting up a window manager, [herbstluftwm](https://herbstluftwm.org/), and some
  useful programs. 🛠️
    - **lf:** Terminal file manager configuration. 🗂️
    - **keymap:** Custom keyboard layout. ⌨️
    - **fonts:** System fonts management. 📚

- **Apps:** Installing and configuring desktop software applications. 📦
    - **firefox:** OneBar `userChrome.css` configuration for Firefox. 🔥
    
## Getting started

[//]: # (TODO write the section)

## Contribute and Learn 🤝

Feel free to contribute to DotArch by submitting issues, pull requests, or suggestions.
This project is open-source, and your input is valuable.

## License 📜

DotArch is available under the MIT License.