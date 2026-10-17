#!/usr/bin/env bash
# One-shot installer.
#
#   sudo ./install.sh                 preflight, then write the PAM stacks
#   sudo ./install.sh --preflight-only   only fix the T1 prerequisites
#   sudo ./install.sh --pam-only      only write the PAM stacks
#   ./install.sh --dry-run            print the plan, change nothing
#
# Enrollment is deliberately not automated: the fingerprint service authorises
# enrollment with polkit auth_self_keep, which needs your live graphical
# session. An installer running as root cannot answer that prompt.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

PREFLIGHT=1
PAM=1
DRY_RUN=0
PASSTHRU=()

usage() {
  cat <<'EOF'
usage: install.sh [options]

  --preflight-only   run the T1 prerequisite checks and stop
  --pam-only         skip the prerequisite checks, write the PAM stacks
  --skip-preflight   same as --pam-only
  --dry-run          print what would happen, change nothing (root not required)
  --user NAME        target user (default: the invoking sudo user)
  --force            write the stacks even without an enrolled fingerprint
  -h, --help         this text
EOF
}

while (($#)); do
  case $1 in
    --preflight-only) PAM=0 ;;
    --pam-only | --skip-preflight) PREFLIGHT=0 ;;
    --dry-run)
      DRY_RUN=1
      PASSTHRU+=(--dry-run)
      ;;
    --user)
      shift
      [[ ${1:-} ]] || die "--user needs a name"
      export OMARCHY_TOUCHID_USER=$1
      PASSTHRU+=(--user "$1")
      ;;
    --force)
      PASSTHRU+=(--force)
      ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

if ((DRY_RUN == 0)); then
  require_root
fi

if ((PREFLIGHT)); then
  say "Prerequisites"
  if ((DRY_RUN)); then
    info "dry run: would run scripts/preflight.sh (needs root, edits the firewall)"
  else
    "$HERE/scripts/preflight.sh" || die "preflight failed; fix that before touching PAM"
  fi
fi

((PAM)) || {
  say "Stopping after the prerequisites (--preflight-only)"
  cat <<'EOF'

Next, enroll as yourself in a graphical terminal:

    fprintd-enroll -f right-index-finger
    fprintd-verify

Then: sudo ./install.sh --pam-only
EOF
  exit 0
}

say "PAM"
"$HERE/scripts/pam-setup.sh" "${PASSTHRU[@]}"

cat <<'EOF'

Done.

  sudo -k; sudo true     # fingerprint first, password after 10s
  Super+Ctrl+L           # lock screen, fingerprint icon on the right of the field

Keep a root shell open on another tty until both work. If anything is off:

  ./doctor.sh            # read-only report, safe to paste into an issue
  sudo ./uninstall.sh    # strip the fingerprint lines again
EOF
