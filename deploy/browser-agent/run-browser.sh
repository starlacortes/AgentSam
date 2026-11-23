#!/bin/sh
# Runs Ada's browser: one Chromium window on a virtual display that is shared over VNC on
# 127.0.0.1 only, and the agent that carries out Ada's actions in it (browser-agent.mjs, on
# 127.0.0.1 only). Started by ada-browser.service as the adabrowser user.
#
# The profile is kept between starts, so the sites the person signed in to stay signed in.
# Ada's "erase sign-ins" (or deleting profiles/main) starts it fresh.
set -eu

HOME_DIR="${ADA_BROWSER_HOME:-/var/lib/ada-browser}"
DISPLAY_NUMBER="${ADA_BROWSER_DISPLAY:-77}"
VNC_PORT="${ADA_BROWSER_VNC_PORT:-5977}"
SIZE="${ADA_BROWSER_SIZE:-1280x800}"
PASSWORD_FILE="$HOME_DIR/vnc.passwd"
PROFILE="$HOME_DIR/profiles/main"
AGENT_PORT="${ADA_BROWSER_AGENT_PORT:-5978}"

[ -s "$PASSWORD_FILE" ] || { echo "Missing $PASSWORD_FILE. Run install.sh first." >&2; exit 1; }

[ -s "$HOME_DIR/vnc-password.txt" ] || { echo "Missing $HOME_DIR/vnc-password.txt. Run install.sh first." >&2; exit 1; }

# The window of step 1 used a throwaway profile; it is not needed any more.
rm -rf "$HOME_DIR/profiles/public"
mkdir -p "$PROFILE"
chmod 700 "$PROFILE"
# A browser that was killed leaves its lock behind, and would then refuse to start.
rm -f "$PROFILE/SingletonLock" "$PROFILE/SingletonSocket" "$PROFILE/SingletonCookie"

cleanup() {
    [ -n "${AGENT_PID:-}" ] && kill "$AGENT_PID" 2>/dev/null || true
    [ -n "${XVNC_PID:-}" ] && kill "$XVNC_PID" 2>/dev/null || true
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
# The agent starts Chromium itself and talks to it over a pipe, so no debugging port is open.
DISPLAY=":$DISPLAY_NUMBER" ADA_BROWSER_HOME="$HOME_DIR" ADA_BROWSER_PROFILE="$PROFILE" \
    ADA_BROWSER_SIZE="$SIZE" ADA_BROWSER_AGENT_PORT="$AGENT_PORT" \
    node "$HOME_DIR/bin/browser-agent.mjs" &
AGENT_PID=$!

# The service lives as long as both parts do.
while kill -0 "$AGENT_PID" 2>/dev/null && kill -0 "$XVNC_PID" 2>/dev/null; do
    sleep 2
done
