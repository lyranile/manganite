#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

systemd-sysusers

# Ensure zsh is a valid login shell
for shell in /usr/bin/zsh /bin/zsh; do
	echo "$shell" >>/etc/shells
done

usermod -s /usr/bin/zsh root
if [ -f /etc/default/useradd ]; then
	sed -i 's|^SHELL=.*|SHELL=/usr/bin/zsh|' /etc/default/useradd
	grep -q '^SHELL=' /etc/default/useradd || echo 'SHELL=/usr/bin/zsh' >>/etc/default/useradd
fi

while IFS=: read -r name _ uid _ _ _ shell; do
	case "$shell" in
		/bin/sh|/bin/bash|/usr/bin/sh|/usr/bin/bash)
			if [ "$uid" -ge 1000 ] || [ "$name" = "root" ]; then
				usermod -s /usr/bin/zsh "$name"
			fi
			;;
	esac
done < /etc/passwd

echo "::endgroup::"
