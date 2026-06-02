# Development Commands
- **Install Dependencies:** `uv sync`
- **Lint:** `uv run ansible-lint`
- **Test (All):** `uv run molecule test`
- **Test (Single Scenario):** `uv run molecule test -s default`
- **Deploy:** `uv run ansible-playbook playbook.yml`

# Code Style & Conventions
- **Format:** YAML with 2-space indentation. standard Ansible structure.
- **Naming:** `snake_case` for variables, roles, and tasks.
- **Secrets:** Use `ansible-vault` via `./encrypt.sh` to encrypt plaintext secrets. Never commit cleartext secrets.
- **Python:** Managed via `uv` (see `pyproject.toml`).
- **Templates:** Use `.j2` extension for Jinja2 templates in `templates/` directories.
- **Variables:** Define defaults in `defaults/main.yml`, specific vars in `vars/main.yml`.

# Architecture
- **Roles:** Modular roles in `roles/`. Group specific logic.
- **Inventory:** `inventory.ini` defines hosts.
- **Deployment:** `playbook.yml` is the main entry point, deployed via `uv run ansible-playbook playbook.yml`.
