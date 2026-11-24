#!/bin/sh
# Sets up Ada's browser on an Arch Linux workstation. Run as root, from this folder:
#     sudo ./install.sh
# Safe to run again: it updates the scripts and keeps the VNC password and any existing profiles.
set -eu

[ "$(id -u)" -eq 0 ] || { echo "Run this as root (sudo ./install.sh)." >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR=/var/lib/ada-browser

# --needed skips what is already installed. On Arch, refresh and upgrade the whole system first
# (pacman -Syu) if this step reports packages that can no longer be downloaded.
pacman -S --needed --noconfirm chromium tigervnc nodejs

id adabrowser >/dev/null 2>&1 || useradd --system --home-dir "$HOME_DIR" --shell /usr/bin/nologin adabrowser
install -d -o adabrowser -g adabrowser -m 0700 "$HOME_DIR" "$HOME_DIR/bin" "$HOME_DIR/profiles"
install -o adabrowser -g adabrowser -m 0700 "$HERE/run-browser.sh" "$HOME_DIR/bin/run-browser.sh"
install -o adabrowser -g adabrowser -m 0600 "$HERE/browser-agent.mjs" "$HOME_DIR/bin/browser-agent.mjs"

install -d -m 0755 /etc/chromium/policies/managed
install -m 0644 "$HERE/chromium-policy.json" /etc/chromium/policies/managed/ada-browser.json

# VNC passwords are at most 8 characters. The display listens on 127.0.0.1 only, and the only
# way in from outside is Ada's server, which hands this password to signed-in admins.
if [ ! -s "$HOME_DIR/vnc.passwd" ]; then
    password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8)"
    umask 077
    printf '%s\n' "$password" > "$HOME_DIR/vnc-password.txt"
    printf '%s\n' "$password" | vncpasswd -f > "$HOME_DIR/vnc.passwd"
    chown adabrowser:adabrowser "$HOME_DIR/vnc-password.txt" "$HOME_DIR/vnc.passwd"
    chmod 600 "$HOME_DIR/vnc-password.txt" "$HOME_DIR/vnc.passwd"
fi

# The same scripts, readable by everyone, for people's own browsers (ada-browser@<account>.service).
install -d -m 0755 /usr/local/lib/ada-browser
install -m 0755 "$HERE/run-browser.sh" /usr/local/lib/ada-browser/run-browser.sh
install -m 0644 "$HERE/browser-agent.mjs" /usr/local/lib/ada-browser/browser-agent.mjs

install -m 0644 "$HERE/ada-browser.service" /etc/systemd/system/ada-browser.service
install -m 0644 "$HERE/ada-browser@.service" /etc/systemd/system/ada-browser@.service
systemctl daemon-reload

echo "Ada's browser is installed. It is not running and will not start at boot."
echo "Set these on Ada's server, then redeploy:"
echo "    AGENTSAM_BROWSER=1"
echo "    AGENTSAM_BROWSER_VNC_PASSWORD=<the contents of $HOME_DIR/vnc-password.txt>"
echo "Read the password with: sudo cat $HOME_DIR/vnc-password.txt"
