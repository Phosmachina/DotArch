# DotArch

**Store and Manage my Arch Linux Configuration with Ease 💻**

Welcome to DotArch, a project to store and manage my Arch Linux configuration using
an Ansible playbook.
This project is divided into three parts: `common`, `desktop`,
and `laptop`, allowing to customize the setup according to my needs.

## Common Tasks 📋

Currently implemented common tasks:

- **yay.yml:** Task for setting up the yay AUR helper. 📦
- **doas.yml:** Task for setting up doas as the privileged command runner. 🔒
- **system.yml:** Task for configuring global system settings (i.e., locale, timezone,
  etc.). 🌍
- **keymap.yml:** Task for configuring custom keyboard layout. ⌨️
- **wm.yml:** Task for setting up window managers, herbstluftwm. 🛠️
- **zsh.yml:** Task for installing and configuring zsh as the default shell. 🐚
- **lf.yml:** Task for setting up lf, a terminal file manager. 🗂️
- **apps.yml:** Task for installing base software applications with yay. 📦
- **fonts.yml:** Task for managing system fonts. 📚
- **pipewire.yml:** Task for setting up PipeWire for audio processing and device
  management. 🔊
- **firefox.yml:** Task for configuring Firefox OneBar `userChrome.css`. 🔥

## Docker Integration 🐳

To avoid installing Python and Ansible on the local machine, I provide a Dockerfile
and docker-compose setup.
This allows you to run your Ansible playbook inside a container,
making it easy to deploy the Arch Linux configuration
without polluting the local environment.

## Getting Started 🚀

To use DotArch, follow these steps:

1. You need a fresh installation of Arch Linux with:
    - sudo configured,
    - network configured,
    - ssh enabled.
2. Clone this repository to your local machine.
3. Customize the `common`, `desktop`, and `laptop` tasks according to your needs and
   select `laptop` or `desktop` in the playbook.
4. Run the Ansible playbook using Docker (see `docker-compose.yml`).
5. Enjoy your fully configured Arch Linux system.

## Contribute and Learn 🤝

Feel free to contribute to DotArch by submitting issues, pull requests, or suggestions.
This project is open-source, and your input is valuable to us.

## License 📜

DotArch is available under the MIT License.
