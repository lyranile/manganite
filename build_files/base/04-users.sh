#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

systemd-sysusers

# Ensure zsh is a valid login shell
grep -q '^/usr/bin/zsh$' /etc/shells || echo '/usr/bin/zsh' >>/etc/shells

usermod -s /usr/bin/zsh root
if [ -f /etc/default/useradd ]; then
	sed -i 's|^SHELL=.*|SHELL=/usr/bin/zsh|' /etc/default/useradd
	grep -q '^SHELL=' /etc/default/useradd || echo 'SHELL=/usr/bin/zsh' >>/etc/default/useradd
fi

echo "::endgroup::"
