# shellcheck shell=bash
# Shared helpers for omarchy-touchid. Sourced, never executed.

OMARCHY_TOUCHID_BACKUP_ROOT=${OMARCHY_TOUCHID_BACKUP_ROOT:-/var/backups/omarchy-touchid}

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m' C_GREEN=$'\033[1;32m' C_YELLOW=$'\033[1;33m' C_RED=$'\033[1;31m'
else
  C_RESET='' C_GREEN='' C_YELLOW='' C_RED=''
fi

say() { printf '\n%s==>%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%swarn:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() {
  printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

is_root() { [[ ${EUID} -eq 0 ]]; }
have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  is_root && return 0
  if (($#)); then die "needs root: sudo $0 $*"; fi
  die "needs root: sudo $0"
}

# The user the PAM stacks are written for. Taken from sudo so a root shell
# cannot silently configure the wrong account.
target_user() {
  local user=${OMARCHY_TOUCHID_USER:-${SUDO_USER:-}}
  if [[ -z $user || $user == root ]]; then
    die "run this through sudo from your own account (a root shell has no target user)"
  fi
  printf '%s\n' "$user"
}

enrolled_fingers() {
  local user=$1
  fprintd-list "$user" 2>/dev/null \
    | grep -oE '(right|left)-(index|middle|ring|little|thumb)-finger' \
    | sort -u
}

fingerprint_enrolled() { [[ -n $(enrolled_fingers "$1") ]]; }

# Instance name of the device-driven xART service, i.e. the private T1 link.
t1_interface() {
  systemctl list-units --no-legend 't1-xart-storage@*.service' 2>/dev/null \
    | awk '{print $1}' \
    | sed -E 's/^t1-xart-storage@(.*)\.service$/\1/' \
    | head -n1
}

service_exit_code() {
  systemctl show -p ExecMainStatus --value "$1" 2>/dev/null
}

# The clamshell gate: when the lid is shut the reader is unreachable, so skip
# the fingerprint module (success=1 jumps over exactly the next auth line)
# instead of blocking until the timeout expires.
CLAMSHELL_GATE='/usr/bin/omarchy-hw-laptop-closed'

clamshell_gate_line() {
  printf 'auth      [success=1 default=ignore] pam_exec.so quiet %s' "$CLAMSHELL_GATE"
}

clamshell_gate_available() { [[ -x $CLAMSHELL_GATE ]]; }

# Bounded attempts and a short timeout: the pam_fprintd default is 30s, which
# makes every password-based sudo feel broken.
FPRINTD_OPTS='max-tries=3 timeout=10'
