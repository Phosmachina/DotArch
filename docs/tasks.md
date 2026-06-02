# Improvement Tasks Checklist

1. [ ] Set up a top-level docs/README explaining repository layout (Install vs PC) and how to run playbooks.
2. [ ] Add an Architectural Overview doc (diagram/markdown) describing roles, their responsibilities, and data flow (group_vars, vars, templates).
3. [ ] Define a versioning/release process (tags/changelog) and add CHANGELOG.md.

4. [ ] Add CI job to run ansible-playbook --syntax-check for PC/playbook.yml and Install Arch/playbook.yml.

5. [x] Obsolete: Standardize role defaults: create defaults/main.yml for each role to declare variables (e.g., username) with sane defaults.
6. [x] Done: Replace hardcoded /home/{{ username }} paths with ansible_facts['env'].HOME or ansible_facts['user_dir'] when appropriate, ensuring correct user context.
7. [ ] Ensure all file/copy/template tasks set owner and group explicitly for user files (e.g., wm-hyprland copy tasks).
8. [ ] Normalize module usage: prefer pacman for Arch-specific package management; use package only when truly generic.
9. [ ] Replace deprecated with_items with loop across all roles for consistency.
10. [ ] Ensure idempotency for shell commands (e.g., yay installs in shell-zsh role) using community.general.pacman/yay modules or check/creates patterns.
11. [ ] Abstract AUR installations behind a reusable role or module to avoid shell invocations and improve idempotency.
12. [ ] Review and fix become/become_user usage to avoid privilege leaks and ensure user tasks run as the target user.
13. [ ] Audit file permissions for sensitive files (e.g., NetworkManager .nmconnection, WireGuard keys) and set restrictive modes (0600/0640) where needed.
14. [ ] Move plain-text secrets into Ansible Vault (or sops) and document how to decrypt/use in CI and locally.
15. [ ] Ensure handlers exist and are notified for service-affecting changes (e.g., waybar reloads on config/template changes, greetd on config changes).
16. [ ] Replace copy of config files with templates where user/system variables should be parameterized.
17. [ ] Add check_mode and diff_mode compatibility: avoid non-idempotent shells; set changed_when/failed_when appropriately.
18. [ ] Add retry/backoff where network operations happen (git clones, AUR) and mark as changed only when necessary.

19. [ ] Consider moving greetd configuration to a dedicated login/greeter role under system to separate concerns from WM config.
20. [ ] Create a dedicated audio role (pipewire + wireplumber) and include it via system role for clarity and reuse.
21. [ ] Consolidate package lists into vars/defaults per role and use loops with descriptive variables (e.g., hyprland_core_packages, zsh_cli_tools).
22. [ ] Centralize environment variables: create a role or shared task set to manage /etc/environment.d and ~/.config/environment.d with templates.
23. [ ] Introduce role meta/main.yml for each role with supported platforms (Archlinux) and dependencies.
24. [ ] Add tags taxonomy documentation and ensure every task has meaningful, consistent tags (system, wm, hyprland, plugins, tools, etc.).

25. [ ] Improve inventory and variable scoping: document and simplify group_vars/host_vars; minimize magic vars in tasks.
26. [x] Obsolete: Validate variable presence with assert tasks (e.g., username) early in play to fail-fast with messages.
27. [ ] Ensure tasks support --check mode and are safe for re-runs; audit changed_when where modules lack idempotency feedback.
28. [ ] Replace pkill commands in handlers with module-based reloads where possible, or guard with when: condition to avoid errors.
29. [ ] Add systemd unit management consistency: enable/started states, user vs system scope, and add daemon-reload where unit files are deployed.
30. [ ] Use file attributes (creates/removes) or command flags to prevent repeated expensive operations (e.g., oh-my-zsh install script) and store installation markers.
31. [ ] Normalize path handling using expanduser filters or path joins in Jinja to avoid double slashes and brittle strings.
32. [ ] Ensure all created directories set mode, owner, group, and use recursive when needed.

33. [ ] Testing: add Molecule scenarios for key roles (system, shell-zsh, wm-hyprland) using Arch Linux containers or systemd-nspawn.
34. [ ] For Molecule, preconfigure container with pacman mirrors and sudo to allow role runs; cache pacman database between runs.
35. [ ] Write minimal verify tests (testinfra/ansible) to assert packages installed, services enabled, files rendered with expected content.
36. [ ] Add a makefile or task runner (justfile) to run lint, syntax-check, and molecule test locally.

37. [ ] Documentation: per-role README.md including variables, examples, tags, and expected side effects.
38. [ ] Document how target selection (laptop vs desktop) works and how roles differ; use group_vars for laptop/desktop specialization.
39. [ ] Provide guidance on secrets management (Vault), including how to store NetworkManager connection profiles securely.
40. [ ] Add a quickstart section in top-level README to run playbook against localhost or a VM safely.

41. [ ] Cleanup: remove unused or stale files (e.g., temporary backups like PC/roles/common/tasks/lf.yml~) and ignore patterns in .gitignore.
42. [ ] Harmonize file locations after recent moves (e.g., Hyprland assets from common to wm-hyprland) and update any paths referencing old locations.
43. [ ] Add consistency checks ensuring templates/files exist for all referenced items; CI should fail if a referenced src is missing.
44. [ ] Introduce Renovate/Dependabot to track GitHub Action and role dependency updates.
45. [ ] Add license headers or repo-level licensing clarity where custom scripts exist (usr/local/bin/xdph-launcher.sh, numlock).
46. [ ] Consider parameterizing wallpaper and theme selections and document how to swap themes via vars.
47. [ ] Add optional telemetry/logging of run context (Ansible callback plugin configuration) to help debug deployments.

48. [ ] Security hardening: ensure sudoers changes (if any) are explicit and safe; verify no world-writable files are created.
49. [ ] Performance: batch package installs per role; avoid updating pacman database multiple times; consider pacman -Syu cadence.
50. [ ] Reliability: fail fast on critical steps with helpful messages; use block/rescue for non-critical tools.
51. [ ] Add support for dry-run validation of templates (render locally in CI) to catch Jinja errors early.
52. [ ] Track and document known limitations (Arch-specific assumptions, Wayland/Hyprland requirements, GPU drivers).
