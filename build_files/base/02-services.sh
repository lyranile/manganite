#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

dnf5 remove -y fedora-flathub-remote 2>/dev/null || true
dnf5 remove -y firefox htop nvtop 2>/dev/null || true
mkdir -p /etc/flatpak/remotes.d/
curl --retry 3 -Lo /etc/flatpak/remotes.d/flathub.flatpakrepo https://dl.flathub.org/repo/flathub.flatpakrepo
mv -f /usr/lib/systemd/system/flatpak-add-flathub-repos.service /usr/lib/systemd/system/flatpak-add-fedora-repos.service 2>/dev/null || true

systemctl set-default graphical.target &&
	systemctl disable getty@tty1 2>/dev/null || true
systemctl mask rpm-ostree-countme.timer rpm-ostree-countme.service 2>/dev/null || true
systemctl mask systemd-update-utmp.service systemd-update-utmp-shutdown.service 2>/dev/null || true
systemctl preset-all
systemctl --global preset-all
systemctl enable flatpak-nuke-fedora.service flatpak-preinstall.service rpm-ostreed-automatic.timer 2>/dev/null || true
systemctl --global enable flatpak-user-update.timer bazaar.service ublue-user-setup.service 2>/dev/null || true
systemctl mask systemd-remount-fs.service 2>/dev/null || true
flatpak preinstall -y --noninteractive

echo "::endgroup::"
