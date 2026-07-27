# DotArch
Personal Ansible project that automates a full Hyprland desktop deployment on Arch Linux.

# Development Commands
- **Install Dependencies:** `uv sync` (creates `.venv` with ansible, ansible-lint, molecule, yamllint)
- **Connectivity check:** `uv run ansible all -m ping`
- **Lint:** `uv run ansible-lint` (also `yamllint .` — both run during molecule lint)
- **Test (All):** `uv run molecule test`
- **Test (Single Scenario):** `uv run molecule test -s default`
- **Deploy (full):** `uv run ansible-playbook playbook.yml --vault-password-file password.sh`
- **Deploy by tag:** append `--tags "system"`, `"desktop"`, or `"apps"`

# Architecture
- **Entry point:** `playbook.yml` loads `group_vars/all/variables.yml` and `deployment_config.yml`, then runs the single meta-role `profiles/desktop-hyprland`. `vault.yml` is auto-loaded via group_vars.
- **Meta-role pattern (critical):** `roles/profiles/desktop-hyprland/tasks/main.yml` orchestrates every component via `include_role`. **To add, remove, reorder, or gate a component, edit this file** — do not edit `playbook.yml`.
- **Role categories under `roles/`:**
  - `system/` — `core` (base OS: packages, hostname, locale, audio, bluetooth, fstab, DNS, VPN, virtualization), `docker`
  - `desktop/` — `hyprland`, `waybar`, `terminal`, `greetd`, `fonts`, `vicinae`, `notifications`, `filemanager`, `screenshot`, `handlr`
  - `apps/` — `firefox`, `bitwarden`, `mpv`, `zathura`, `qimgv`, `zeditor`, `jetbrains`, `voxtype`
  - `users/shell/` — shell environment
- **Hardware detection:** `playbook.yml` pre_tasks detect a battery and set fact `target: laptop|desktop`. `variables.yml` derives `hostname` from `target`. Some tasks gate on `target == 'laptop'` (e.g. NetworkManager).
- **Inventory:** `inventory.ini` has `[arch]` and `[ubuntu]` groups; localhost local connection is uncommented by default. Toggle local vs remote by commenting the relevant host line.

# Conventions
- **Format:** YAML, 2-space indent. Standard Ansible structure.
- **FQCN required:** always use `ansible.builtin.<module>` fully-qualified names (e.g. `ansible.builtin.copy`, `ansible.builtin.include_tasks`).
- **Naming:** `snake_case` for variables, roles, tasks, files.
- **Tags:** three top-level tags — `system`, `desktop`, `apps`. Add a role-specific tag alongside the category tag (e.g. `tags: [apps, qimgv]`). Config-copy tasks add `config`.
- **Feature toggles:** gate optional components with `enable_<name>` booleans (defaults live in `group_vars/all/deployment_config.yml`). New optional roles must be added both to the meta-role (with a `when: enable_<name>`) and a default in `deployment_config.yml`.
- **Templates:** `.j2` files in a role's `templates/`. Static configs in `files/` (often mirroring `files/home/.config/...` target paths).
- **Variables:** defaults in `defaults/main.yml`, role-specific vars in `vars/main.yml`, global vars in `group_vars/all/`.
- **AUR packages:** `system/core` installs `yay`. AUR install tasks use `ansible.builtin.shell` with `become: true` + `become_user: '{{ ansible_user }}'` and `# noqa: command-instead-of-shell`.

# Secrets & Vault
- **Never commit cleartext secrets.** Use `./encrypt.sh` to encrypt plaintext files with `ansible-vault`.
- **`encrypt.sh`** enumerates `FILES_TO_ENCRYPT` (currently `group_vars/all/vault.yml`, voxtype secret, two wireguard peer configs). When you add a new secret file, **add its path to `FILES_TO_ENCRYPT`** so the check catches it.
  - `./encrypt.sh` — encrypt any plaintext files in the list.
  - `./encrypt.sh --install-hook` — install a git pre-commit hook that blocks commits of unencrypted secrets.
  - `./encrypt.sh --check` — pre-commit scan.
- **`password.sh`** (gitignored) echoes the vault password; deploy/test commands pass `--vault-password-file password.sh`.
- **`deploy_without_passwords: true`** skips tasks requiring the become password (uses `plain_ansible_become_pass`).

# Testing (Molecule)
- Driver is **vagrant + libvirt** with the `generic/arch` box and KVM — not Docker. Requires libvirt + KVM on the host.
- Scenario `default` converges `molecule/common/playbook.yml`; lint step runs `yamllint .` then `ansible-lint`.
- `ANSIBLE_ROLES_PATH` is set to `../../roles/` by the provisioner.
- `.ansible-lint` skips: `role-name[path]`, `yaml[empty-lines]`, `latest[git]`, `var-naming[no-role-prefix]`; excludes `molecule/common/vars.yml` and `prepare.yml`.

# Gotchas
- The playbook **requires** `--vault-password-file password.sh` (or equivalent) at deploy time.
- New optional components need three coordinated edits: the role itself, an `include_role` block in `roles/profiles/desktop-hyprland/tasks/main.yml`, and an `enable_*` default in `group_vars/all/deployment_config.yml`.
- `password.sh` and `.venv/` are gitignored; `vault.yml.example` is the template for the encrypted `vault.yml`.
- Docs in `docs/` (`TODO.md`, `tasks.md`, `wayland specs.md`) are working notes, not authoritative specs.
