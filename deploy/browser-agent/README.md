# Ada's browser on the workstation

Ada's server cannot run a browser itself, so the browser lives on her SSH workstation
(`AGENTSAM_WORKSTATION_SSH`). This folder is what runs there.

- `install.sh` installs Chromium, TigerVNC and Node.js with pacman, creates the `adabrowser` user (no
  password, no sudo, no SSH keys), and installs the files below. Run it as root on the workstation.
- `ada-browser.service` runs `run-browser.sh` as `adabrowser`. It has no `[Install]` section: it
  never starts at boot. Ada's server starts it when an admin opens the live window and stops it
  after 15 minutes with nobody watching.
- `run-browser.sh` starts `Xvnc` on display `:77`, listening on `127.0.0.1:5977` only, and the
  browser agent.
- `browser-agent.mjs` (Node, no packages) starts one normal Chromium window and carries out Ada's
  browser actions in it. It talks to Chromium over `--remote-debugging-pipe`, so no debugging port
  is open, and listens for Ada's server on `127.0.0.1:5978` only. Each request must carry the VNC
  password, the same secret that already gives full control of the window. It keeps who is in
  control (Ada, paused, or the person), refuses to type into password and one-time-code fields,
  never reports what they hold, opens only http and https addresses, and has no way to read
  cookies or run arbitrary scripts.
- The profile (`profiles/main`) is kept between starts, so sites the person signed in to stay
  signed in. "Erase sign-ins" in the live window deletes it and opens a fresh window.
- `chromium-policy.json` turns off Chromium's password manager, autofill, sync and browser sign-in.

## People's own browsers

Admins use the browser above. A person an admin gave a workstation (People page, "Workstation")
gets a browser of their own, `ada-browser@<account>.service`, running as their own workstation
account (`adau…`, see `deploy/workstation`):

- Everything it keeps is in `~/.ada-browser` in that account's home (mode 700): the profile with
  their sign-ins, their own VNC password (made by Ada's server on first use, as the account), and
  caches. The unit hides every home folder except that one and gives the browser its own `/tmp`.
- Its display and ports come from the account's numeric ID n = uid mod 10000: display `:1000+n`,
  VNC on `127.0.0.1:30000+2n`, the agent on the port after it. The VNC password guards both, so
  another account on the machine that reaches the port still cannot see or drive the window.
- Ada's server starts and stops it as the operator account (`sudo systemctl start|stop
  ada-browser@<account>.service`), and relays the picture and Ada's requests as the person's own
  account. At most three people's browsers run at once (each may use up to 1.5 GB of memory), and
  each stops after 15 minutes unused. They never start at boot.
- Nothing new is needed on Ada's server; `install.sh` installs the template unit and a copy of the
  scripts in `/usr/local/lib/ada-browser`.

## How the picture reaches the web app

Nothing here listens on a public address. Ada's server opens `ssh -W 127.0.0.1:5977` to the
workstation with the same key and pinned host key it uses for workstation commands, and relays
the VNC stream over a WebSocket (`/api/browser/live`) to the person signed in to the web app: admins
see Ada's browser, everyone else with a workstation sees only their own.

## Setting it up

1. Copy this folder to the workstation and run `sudo ./install.sh`.
2. The workstation user Ada logs in as must be able to run `sudo systemctl start` and
   `sudo systemctl stop` on `ada-browser.service` without a password.
3. On Ada's server set `AGENTSAM_BROWSER=1` and `AGENTSAM_BROWSER_VNC_PASSWORD` (the installer
   says where to read it), then redeploy. The startup log says "Ada's browser is on".
4. In the web app, open a chat's "⋯" menu and choose "Open Ada's browser".

## Ada's browser tools

Ada drives the window with the `browser_*` tools (open, look, click, type, paste, select, key,
scroll, go, tabs, wait, screenshot, click_at, drag, hover), and admins watch every step live.

- **Frames.** The outline reads every frame of the page, also frames from other sites (embedded
  editors such as CryptPad's). Their elements are listed after the page and numbered `[frame.n]`,
  for example `[3.2]`, and every tool that takes a number works on them.
- **The mouse.** `mouse` moves, clicks (left, right, double) and drags at page pixels, the same
  coordinates as a screenshot, and `scroll` can scroll whatever is under a point. Before a click,
  `describe_point` says what is there, followed into frames from other sites, so Ada's server applies
  the same approval rules as for numbered clicks.
- **Seeing.** `screenshot` can draw a labelled 100-pixel grid over the page for the picture only.
  Ada's server shows the picture to the vision model (Settings, Providers, "Vision model") and
  gives Ada its answer.
- **Pasting.** `paste` puts Ada's text on the browser's clipboard and presses Ctrl+V, so rich
  editors keep its lines; where a page has no clipboard it inserts the text in one step. Ada
  cannot press Ctrl+V herself, so she never pastes what the person copied. Typing and pasting
  without a number go to the element with the focus, followed into frames, and are refused in
  password and code fields there too.
- **Files and pictures.** `upload` gives files to a file field, or catches the file chooser that
  clicking an upload button opens. `paste` with a picture puts it on the clipboard as PNG and
  presses Ctrl+V, or offers it to the editor as a paste event. Files come from Ada's server (the
  chat's files) or are downloaded by the agent from a public http or https address, at most 15 MB,
  into a private temporary folder of the browser's own. Signing in, submitting a form,
paying, sending, deleting and security settings create an approval card on Ada's server; the
approved action runs once, and the agent refuses it if the page or element changed meanwhile.
To sign in to a site, the person presses **Take over** in the live window, signs in, and presses
**Hand back**. While the person is in control, the agent refuses all of Ada's requests.

Updating an existing install: copy this folder to the workstation, run `sudo ./install.sh` again,
then `sudo systemctl restart ada-browser.service` (or let it stop for idleness). Nothing new is
needed on Ada's server: the agent uses the VNC password it already has.

Run the agent's tests with `node --test deploy/browser-agent/browser-agent.test.mjs`; set
`ADA_BROWSER_CHROMIUM` to a Chromium or Chrome binary to include the real-browser test.

## Not done yet

One profile per person (not one per site account), no per-site grants or daily limits, and Ada's
cursor is not drawn on the picture. Clicking a bare canvas by position cannot be checked for risk
(there is no label to read), so approvals there rely on what the page says around it. The profile sits on the workstation, where Ada's own `sudo pacman` could reach it:
keep `workstation_run` on approval until the browser has a machine of its own.
