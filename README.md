# DotArch

**Store and Manage my Arch Linux Configuration with Ease 💻**

Welcome to DotArch, a project to store and manage my Arch Linux configuration using
an Ansible playbook.
This project is divided into three parts: `common`, `desktop`,
and `laptop`, allowing to customize the setup according to my needs.

## Common Tasks 📋

Currently implemented common tasks:

- **System:** Core components, install and configure base packages, configuring global
  system settings (i.e., locale, timezone, etc.). 🌍
    - **yay:** Setting up the yay AUR helper. 📦
    - **zsh:** Installing and configuring zsh as the default shell. 🐚
    - **pipewire:** Setting up PipeWire for audio processing and device
      management. 🔊


- **WM:** Setting up a window manager, [herbstluftwm](https://herbstluftwm.org/), and some
  useful programs. 🛠️
    - **lf:** Setting up lf, a terminal file manager. 🗂️
    - **keymap:** Configuring a custom keyboard layout. ⌨️
    - **fonts:** Task for managing system fonts. 📚


- **Apps** Installing and configure desktop software applications. 📦
    - **firefox:** Configuring Firefox OneBar `userChrome.css`. 🔥

## Docker Integration 🐳

Currently, I want to avoid installing Python and Ansible on the local machine,
then I provide a Dockerfile and docker-compose setup.
This allows you to run your Ansible playbook inside a container,
making it easy to deploy the Arch Linux configuration without polluting the local
environment.

## Getting Started 🚀

To use DotArch, follow these steps:

1. You need a fresh installation of Arch Linux with:
    - network configured,
    - sudo configured to allow user with no pass (for seamless yay execution),
    - ssh enabled and properly configured (with the key of ansible host).
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
