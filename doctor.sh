#!/usr/bin/env bash
# Read-only diagnostics. Changes nothing, safe to paste into an issue.
#
#   ./doctor.sh          # as yourself
#   sudo ./doctor.sh     # includes t1bridge status and the live firewall rules

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

# The report is meant to be copied out of a terminal, so drop the escape codes.
C_RESET='' C_GREEN='' C_YELLOW='' C_RED=''

section() { printf '\n## %s\n' "$*"; }

section "omarchy-touchid doctor"
printf 'date:    %s\n' "$(date -Is)"
printf 'user:    %s (uid %s)\n' "${USER:-?}" "$(id -u)"
printf 'root:    %s\n' "$(is_root && echo yes || echo no)"
printf 'os:      %s\n' "$( ( . /etc/os-release && printf '%s %s' "$NAME" "$VERSION_ID" ) 2>/dev/null)"
printf 'model:   %s\n' "$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
printf 'kernel:  %s\n' "$(uname -r)"
printf 'session: %s / %s\n' "${XDG_CURRENT_DESKTOP:-?}" "${XDG_SESSION_TYPE:-?}"

section "packages"
pacman -Q t1bridge t1bridge-dkms libfprint-t1bridge fprintd-t1bridge fprintd libfprint polkit 2>/dev/null \
  | sort -u | sed 's/^/    /' || echo "    (pacman query failed)"

section "fingerprints"
if have fprintd-list; then
  fprintd-list "${USER:-$(id -un)}" 2>&1 | sed 's/^/    /'
else
  echo "    fprintd-list not installed"
fi

section "PAM"
for f in sudo polkit-1 omarchy-lock-fingerprint omarchy-lock-password; do
  path=/etc/pam.d/$f
  if [[ -f $path ]]; then
    printf '    --- %s ---\n' "$path"
    sed 's/^/    /' "$path"
  else
    printf '    --- %s: missing ---\n' "$path"
  fi
done
if [[ ! -f /etc/pam.d/polkit-1 && -f /usr/lib/pam.d/polkit-1 ]]; then
  echo "    (no /etc override; the vendor /usr/lib/pam.d/polkit-1 is in use)"
fi

section "T1 units"
systemctl list-units 't1*' --all --no-legend --no-pager 2>/dev/null | sed 's/^/    /'

section "T1 state"
T1_IF=$(t1_interface)
printf '    private link: %s\n' "${T1_IF:-none}"
if [[ -n $T1_IF ]]; then
  ip -6 addr show "$T1_IF" 2>/dev/null | grep inet6 | sed 's/^/    /'
fi

if is_root; then
  printf '\n    t1bridge status:\n'
  t1bridge status 2>&1 | sed 's/^/        /'
  printf '\n    ufw 61500 rules:\n'
  ufw status 2>/dev/null | grep 61500 | sed 's/^/        /' || echo "        none"
else
  echo "    (run as root for t1bridge status and live firewall rules)"
fi

section "recent fingerprint errors"
if have journalctl; then
  # Scoped to the units that matter: a plain journal grep also matches
  # whatever unrelated commands happen to mention fprintd.
  journalctl -b --no-pager 2>/dev/null \
    -u fprintd -u t1-touchid-auth -u t1bridge-keybag -u t1bridge-fingerprint \
    | grep -iE 'error|fail|denied|timeout|retry|no-match' \
    | tail -n 12 | sed 's/^/    /'
  echo "    (end)"
fi

cat <<'EOF'

## what to look for

  keybag: not-enrolled      normal before the first enrollment
  sep-lease ... code=-111   the T1 never reached the host: xART or machine-data
  Authorization denied      polkit refused; enrollment must run in your own
                            graphical session, not from a root script
  no icon on the lock screen  both /etc/pam.d/omarchy-lock-fingerprint and an
                            enrolled print are required
EOF
