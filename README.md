# DotArch

> Personal Ansible project for automated Hyprland desktop deployment on Arch Linux

This project automates the complete setup of a modern desktop environment using Hyprland window
manager on Arch Linux.

## ✨ Features

A complete, minimalist, and visually appealing desktop experience:

* **Desktop Environment**: Full [Hyprland](https://github.com/hyprwm/Hyprland) experience with a
  focus on aesthetics and performance.
* **Tiling Experience**: Native Hyprland Dwindle layout (BSP-style auto-tiling) with native groups.
* **Wallpaper**: Automated wallpaper management
  with [Hyprpaper](https://github.com/hyprwm/hyprpaper).
* **Screen Management**: Automatic multi-monitor profiling
  with [Kanshi](https://github.com/emersion/kanshi).
* **Bar**: Fully configured [Waybar](https://github.com/Alexays/Waybar) with status modules.
* **Power Management**: Automated idle and locking
  with [Hypridle](https://github.com/hyprwm/hypridle)
  and [Hyprlock](https://github.com/hyprwm/hyprlock).
* **Display Manager**: Minimal console-based login manager
  via [Greetd](https://git.sr.ht/~kennylevinsen/greetd)
  and [Tuigreet](https://github.com/apognu/tuigreet).
* **Launcher & Clipboard**: [Vicinae](https://github.com/apps-helper/vicinae) for application
  launching and clipboard history management.
* **Terminal**: [Kitty](https://sw.kovidgoyal.net/kitty/) terminal emulator
  with [Zsh](https://www.zsh.org/).
* **Shell Toolset**: Complete modern toolset including `rg` (ripgrep), `fd`, `bat`, `eza`, and
  completion plugins.
* **File Explorer**: Terminal-based file manager [Yazi](https://github.com/sxyazi/yazi).
* **Notifications**: Beautiful notification center
  via [SwayNC](https://github.com/ErikReider/SwayNotificationCenter).
* **Screenshots**: Advanced screenshotting with annotation support
  using [Grim](https://github.com/emersion/grim), [Slurp](https://github.com/emersion/slurp),
  and [Satty](https://github.com/gabm/Satty).
* **Screen Recording**: Simple recording with `wl-screenrec`.
* **Voice Typing**: AI-powered voice-to-text with [Voxtype](https://voxtype.io), supporting local or
  remote (DeepInfra) inference.
* **Maintenance**: Automated trash cleanup and system maintenance timers.

## 🏗️ Project Structure

```
DotArch/
├── playbook.yml                 # Main playbook
├── inventory.ini                # Host definitions
├── group_vars/
│   ├── all/
│   │   ├── variables.yml        # Global variables
│   │   ├── deployment_config.yml # Feature configuration
│   │   └── vault.yml           # Encrypted secrets
│   └── arch/main.yml           # Arch-specific settings
└── roles/
    ├── apps/
    │   ├── bitwarden/           # Password manager
    │   ├── firefox/             # Web browser
    │   ├── jetbrains/           # JetBrains Toolbox (AUR)
    │   ├── mpv/                 # Media player
    │   ├── qimgv/               # Image viewer
    │   ├── zathura/             # Document viewer
    │   ├── zeditor/             # Zed code editor
    │   └── voxtype/             # Voice-to-text (AUR)
    ├── desktop/
    │   ├── filemanager/         # Yazi configuration
    │   ├── fonts/               # Font management
    │   ├── greetd/              # Display manager (Login)
    │   ├── hyprland/            # Window manager core
    │   ├── notifications/       # SwayNC configuration
    │   ├── screenshot/          # Grim/Slurp/Satty tools
    │   ├── terminal/            # Kitty configuration
    │   ├── vicinae/             # Launcher & Clipboard
    │   └── waybar/              # Status bar
    ├── profiles/
    │   └── desktop-hyprland/    # Complete desktop meta-role
    ├── system/
    │   ├── core/                # Base system configuration
    │   └── docker/              # Container runtime
    └── users/
        └── shell/               # User shell environment

```

## 🛠️ Quick Start

### Prerequisites

**On the Control Machine:**

* **uv**: Modern Python package manager (recommended).
* **OR Ansible**: System-wide installation via package manager (e.g., `pacman -S ansible`).

**On the Target Machine(s):**

* **User**: A user with `sudo` access (NOPASSWD recommended for automation). The remote user must be
  defined in your inventory (e.g., `ansible_user=your_user`).
* **SSH Access**: SSH key deployed (`ssh-copy-id user@host`).
* **Python**: Python installed on the target system.

### Setup

1. **Clone the project**
2. **Install Dependencies**:

   **Option A: Using uv (Recommended)**

   This automatically installs Ansible and all required collections in a virtual environment.
   ```bash
   uv sync
   ```

   **Option B: System Package Manager**

   If you do not use `uv`, install the full Ansible package (which includes `ansible-core` and
   community collections):
   ```bash
   # Arch Linux
   sudo pacman -S ansible
   ```
   *Note: Ensure you install `ansible`, not just `ansible-core`, to get the required collections
   automatically.*

### Configuration

1. **Configure Inventory**:
   Create an `inventory.ini` file with your target hosts.

2. **Set Deployment Variables**:
   Configuration is managed directly via YAML files. Check the following files for available
   options (variables are documented in the files):
    * Global Settings: `group_vars/all/variables.yml`
    * Feature Toggles: `group_vars/all/deployment_config.yml`
    * Secrets: `group_vars/all/vault.yml`

3. **Setup Vault** (optional):
   To secure your secrets, use the provided encryption script. It automatically detects unencrypted
   files and encrypts them using `password.sh` (or interactive password).

   **Encrypt files:**
   ```bash
   ./encrypt.sh
   ```

   **Install Git Safety Hook:** (Recommended)
   Prevents accidental commits of unencrypted secrets.
   ```bash
   ./encrypt.sh --install-hook
   ```

### Deploy

Run the playbook.

> **Note:** If you are using the system Ansible (Option B), run commands without `uv run` (e.g.,
`ansible-playbook playbook.yml`).

If you are using `uv`, it will automatically use the virtual environment:

```bash
# Test connectivity
uv run ansible all -m ping

# Deploy everything
uv run ansible-playbook playbook.yml

# Deploy specific components using tags
uv run ansible-playbook playbook.yml --tags "system"
uv run ansible-playbook playbook.yml --tags "desktop"
uv run ansible-playbook playbook.yml --tags "apps"
```

## Molecule Testing

Run tests using `molecule`:

```bash
# Test on default platform
uv run molecule test

# Test specific scenario
uv run molecule create
uv run molecule converge
```

## 📄 License

MIT License - See LICENSE file for details.
