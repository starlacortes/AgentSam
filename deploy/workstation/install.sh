#!/bin/bash
# Run once on the workstation as root (sudo bash install.sh) to let Ada give people their own
# workstation accounts. Safe to run again.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
operator="${ADA_OPERATOR:-ada}"

install -m 755 -o root -g root "$here/ada-user-add" /usr/local/bin/ada-user-add

rule="/etc/sudoers.d/ada-user-add"
printf '%s ALL=(root) NOPASSWD: /usr/local/bin/ada-user-add\n' "$operator" > "$rule.tmp"
chmod 440 "$rule.tmp"
visudo -cf "$rule.tmp"
mv "$rule.tmp" "$rule"

# The operator's home (keys, git token, notes) and the browser's state are private to the operator,
# so people's own accounts cannot read them. Other homes on the machine are left as they are.
operator_home="$(getent passwd "$operator" | cut -d: -f6)"
[ -n "$operator_home" ] && [ -d "$operator_home" ] && chmod 700 "$operator_home"
[ -d /var/lib/ada-browser ] && chmod -R go-rwx /var/lib/ada-browser
# New accounts start private too.
if grep -q '^HOME_MODE' /etc/login.defs; then
  sed -i 's/^HOME_MODE.*/HOME_MODE\t0700/' /etc/login.defs
else
  printf 'HOME_MODE\t0700\n' >> /etc/login.defs
fi

echo "Installed /usr/local/bin/ada-user-add and the sudo rule for $operator."
