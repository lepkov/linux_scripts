#!/bin/bash

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Update apt packages
echo "Updating package list and installed packages..."
sudo apt-get update -y && sudo apt-get upgrade -y && sudo apt-get dist-upgrade -y

# Remove unnecessary packages
echo "Cleaning up..."
sudo apt-get autoremove -y && sudo apt-get autoclean -y

# Refresh Snap packages (check if snap is installed)
if command_exists snap; then
    echo "Refreshing Snap packages..."
    sudo snap refresh
else
    echo "Snap is not installed. Skipping Snap updates."
fi

# Update Flatpak packages (check if flatpak is installed)
if command_exists flatpak; then
    echo "Updating Flatpak packages..."
    flatpak update -y
else
    echo "Flatpak is not installed. Skipping Flatpak updates."
fi

# Update Python packages (check if pip3 is installed)
if command_exists pip3; then
    echo "Updating Python packages..."
    pip3 install --upgrade pip
    pip3 list --outdated --format=freeze | cut -d'=' -f1 | xargs -n1 pip3 install --upgrade
else
    echo "pip3 is not installed. Skipping Python updates."
fi

# Firmware updates (check if fwupdmgr is installed)
if command_exists fwupdmgr; then
    echo "Checking firmware updates..."
    sudo fwupdmgr refresh && sudo fwupdmgr update
else
    echo "fwupdmgr is not installed. Skipping firmware updates."
fi

# Update Docker (check if Docker is installed)
if command_exists docker; then
    echo "Updating Docker images..."
    sudo docker system prune -f
    sudo docker pull $(sudo docker images --format '{{.Repository}}' | sort -u)
else
    echo "Docker is not installed. Skipping Docker updates."
fi

# Update Rust (check if rustup is installed)
if command_exists rustup; then
    echo "Updating Rust components..."
    rustup update
else
    echo "Rust is not installed. Skipping Rust updates."
fi

# Update Node.js and npm (check if npm is installed)
if command_exists npm; then
    echo "Updating Node.js and npm packages..."
    sudo npm install -g npm && npm update -g
else
    echo "npm is not installed. Skipping Node.js updates."
fi

# Kernel and GRUB updates
echo "Rebuilding initramfs and updating GRUB..."
sudo update-initramfs -u
sudo update-grub

# Ubuntu release upgrade
echo "Checking for new Ubuntu release..."
if sudo do-release-upgrade -c | grep -q "New release"; then
    echo "Upgrading to the new Ubuntu release..."
    sudo do-release-upgrade -f DistUpgradeViewNonInteractive
else
    echo "You are already using the latest Ubuntu release."
fi

# Reboot check
echo "Checking if reboot is required..."
if [ -f /var/run/reboot-required ]; then
    echo "Reboot is required. Please reboot your system."
else
    echo "No reboot required."
fi

echo "System is fully updated!"
