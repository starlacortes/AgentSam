# Personal workstation accounts

Admins' Ada works on the workstation as the operator account set in `AGENTSAM_WORKSTATION_SSH`
(usually `ada@host`). A member an admin gives a workstation (People page, Workstation checkbox)
gets an account of their own, `adau<12 hex>`, created on first use:

- its own SSH key (kept in Ada's data folder, one per person), home folder (mode 700), background
  jobs and job list;
- `umask 077` on every command, so files in `/tmp` are private too;
- no sudo, no password (key login only), no agent or X11 forwarding;
- limits for everything it runs: 2 GB memory, 256 tasks, one CPU.

Disk space is not capped per account. Check with `sudo du -sh /home/adau*` now and then.

## Install (once, as root on the workstation)

    sudo bash install.sh

It installs `/usr/local/bin/ada-user-add`, a sudo rule that lets the operator account run only that
script, makes the operator's home and `/var/lib/ada-browser` private, and sets new homes to 0700.

Personal accounts can still reach services that listen on the machine's loopback address (for
example the browser's VNC port, which needs its password). Keep such services password-protected.

## Remove a person's account

    sudo pkill -u adauXXXXXXXXXXXX; sudo userdel -r adauXXXXXXXXXXXX
    sudo rm -rf /etc/systemd/system/user-<uid>.slice.d && sudo systemctl daemon-reload
