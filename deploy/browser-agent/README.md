# Ada's browser on the workstation

Ada's server cannot run a browser itself, so the browser lives on her SSH workstation
(`AGENTSAM_WORKSTATION_SSH`). This folder is what runs there.

- `install.sh` installs Chromium and TigerVNC with pacman, creates the `adabrowser` user (no
  password, no sudo, no SSH keys), and installs the files below. Run it as root on the workstation.
- `ada-browser.service` runs `run-browser.sh` as `adabrowser`. It has no `[Install]` section: it
  never starts at boot. Ada's server starts it when an admin opens the live window and stops it
  after 15 minutes with nobody watching.
- `run-browser.sh` starts `Xvnc` on display `:77`, listening on `127.0.0.1:5977` only, and one
  normal Chromium window with a fresh profile. Stopping the service erases that profile.
- `chromium-policy.json` turns off Chromium's password manager, autofill, sync and browser sign-in.

## How the picture reaches the web app

Nothing here listens on a public address. Ada's server opens `ssh -W 127.0.0.1:5977` to the
workstation with the same key and pinned host key it uses for workstation commands, and relays
the VNC stream over a WebSocket (`/api/browser/live`) to admins signed in to the web app.

## Setting it up

1. Copy this folder to the workstation and run `sudo ./install.sh`.
2. The workstation user Ada logs in as must be able to run `sudo systemctl start` and
   `sudo systemctl stop` on `ada-browser.service` without a password.
3. On Ada's server set `AGENTSAM_BROWSER=1` and `AGENTSAM_BROWSER_VNC_PASSWORD` (the installer
   says where to read it), then redeploy. The startup log says "Ada's browser is on".
4. In the web app, open a chat's "⋯" menu and choose "Open Ada's browser".

## What this step does not do yet

This is the live window only. Ada has no browser tools yet, there are no accounts or saved
sign-ins, and the window is for the public web. Those come in later steps of the design.
