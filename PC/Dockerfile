# Start from the latest Archlinux base image
FROM archlinux:latest

# Update the repository and upgrade packages
RUN pacman -Syu --noconfirm

# Install Python, pip, SSH, Ansible and rsync
RUN pacman -S --noconfirm openssh python python-pip ansible rsync

WORKDIR /ansible

CMD [ "./run.sh" ]
