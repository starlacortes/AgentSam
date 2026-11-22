#!/bin/sh
# Runs Ada's browser: one Chromium window on a virtual display that is shared over VNC on
# 127.0.0.1 only. Started by ada-browser.service as the adabrowser user; stopping the service
# closes the window and erases the profile, so nothing is kept between sessions.
set -eu

HOME_DIR="${ADA_BROWSER_HOME:-/var/lib/ada-browser}"
DISPLAY_NUMBER="${ADA_BROWSER_DISPLAY:-77}"
VNC_PORT="${ADA_BROWSER_VNC_PORT:-5977}"
SIZE="${ADA_BROWSER_SIZE:-1280x800}"
PASSWORD_FILE="$HOME_DIR/vnc.passwd"
PROFILE="$HOME_DIR/profiles/public"

[ -s "$PASSWORD_FILE" ] || { echo "Missing $PASSWORD_FILE. Run install.sh first." >&2; exit 1; }

# A fresh profile every time: this window is for the public web, with no accounts.
rm -rf "$PROFILE"
mkdir -p "$PROFILE"
chmod 700 "$PROFILE"

cleanup() {
    [ -n "${CHROMIUM_PID:-}" ] && kill "$CHROMIUM_PID" 2>/dev/null || true
    [ -n "${XVNC_PID:-}" ] && kill "$XVNC_PID" 2>/dev/null || true
    rm -rf "$PROFILE"
}
trap cleanup EXIT
trap 'exit 0' TERM INT

Xvnc ":$DISPLAY_NUMBER" -geometry "$SIZE" -depth 24 -localhost -rfbport "$VNC_PORT" \
    -SecurityTypes VncAuth -PasswordFile "$PASSWORD_FILE" -AlwaysShared -nolisten tcp &
XVNC_PID=$!

# Wait for the display before starting the browser.
tries=0
while [ ! -S "/tmp/.X11-unix/X$DISPLAY_NUMBER" ]; do
    tries=$((tries + 1))
    [ "$tries" -gt 50 ] && { echo "The virtual display did not start." >&2; exit 1; }
    kill -0 "$XVNC_PID" 2>/dev/null || { echo "Xvnc exited." >&2; exit 1; }
    sleep 0.2
done

# A normal window, not headless and without automation flags: the address bar, pop-ups and file
# pickers must be visible to the person watching, and sites refuse headless browsers more often.
DISPLAY=":$DISPLAY_NUMBER" chromium \
    --user-data-dir="$PROFILE" \
    --no-first-run --no-default-browser-check \
    --password-store=basic \
    --window-position=0,0 --window-size="$(echo "$SIZE" | tr x ,)" \
    --disable-features=Translate \
    about:blank &
CHROMIUM_PID=$!

# The service lives as long as both parts do.
while kill -0 "$CHROMIUM_PID" 2>/dev/null && kill -0 "$XVNC_PID" 2>/dev/null; do
    sleep 2
done
