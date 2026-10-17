#!/usr/bin/env bash
# Remove what this project added. Password authentication is never touched.
#
#   sudo ./uninstall.sh             strip the fingerprint lines/files
#   sudo ./uninstall.sh --restore   copy the newest backup back instead
#   ./uninstall.sh --dry-run        show what would go

set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

DRY_RUN=0
RESTORE=0

usage() {
  cat <<'EOF'
usage: uninstall.sh [options]

  --restore      restore the newest /var/backups/omarchy-touchid snapshot
  --dry-run      print what would change, write nothing (root not required)
  -h, --help     this text
EOF
}

while (($#)); do
  case $1 in
    --restore) RESTORE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

if ((DRY_RUN == 0)); then
  require_root
fi

if ((RESTORE)); then
  latest="$OMARCHY_TOUCHID_BACKUP_ROOT/latest"
  [[ -s $latest ]] || die "no backup recorded at $latest"
  SRC=$(head -n1 "$latest")
  [[ -d $SRC ]] || die "backup directory $SRC is missing"
  say "Restoring from $SRC"
  for f in sudo polkit-1 omarchy-lock-fingerprint; do
    if [[ -f $SRC/$f ]]; then
      info "/etc/pam.d/$f"
      ((DRY_RUN)) || install -m 0644 -o root -g root "$SRC/$f" "/etc/pam.d/$f"
    fi
  done
  say "Done"
  exit 0
fi

TS=$(date +%Y%m%d-%H%M%S)
SNAP="$OMARCHY_TOUCHID_BACKUP_ROOT/pre-uninstall-$TS"

say "Snapshot before removal"
if ((DRY_RUN)); then
  info "would copy the current files to $SNAP"
else
  install -d -m 0700 "$SNAP"
  for f in sudo polkit-1 omarchy-lock-fingerprint; do
    [[ -f /etc/pam.d/$f ]] && cp -a "/etc/pam.d/$f" "$SNAP/$f"
  done
  info "$SNAP"
fi

# The gate line is only ever inserted as the neighbour of pam_fprintd, so both
# patterns are removed together, exactly like Omarchy's own remover.
strip() {
  local file=$1
  [[ -f $file ]] || return 0
  grep -qE 'pam_fprintd\.so|omarchy-hw-laptop-closed' "$file" || {
    info "$file: nothing to remove"
    return 0
  }
  if ((DRY_RUN)); then
    info "$file: would drop the pam_fprintd/gate lines"
    return 0
  fi
  sed -i -e '/pam_fprintd\.so/d' -e '/omarchy-hw-laptop-closed/d' "$file"
  info "$file: cleaned"
}

say "Removing fingerprint lines"
strip /etc/pam.d/sudo
strip /etc/pam.d/polkit-1

LOCK=/etc/pam.d/omarchy-lock-fingerprint
if [[ -f $LOCK ]]; then
  if grep -q 'pam_fprintd\.so' "$LOCK"; then
    if ((DRY_RUN)); then
      info "$LOCK: would be removed"
    else
      rm -f "$LOCK"
      info "$LOCK: removed"
    fi
  else
    info "$LOCK: does not reference pam_fprintd, left alone"
  fi
fi

say "Done"
cat <<EOF

Fingerprints stay enrolled. To remove them as well:

    fprintd-delete '<your-user>'      # run this as yourself, not with sudo

Do not run Omarchy's own remover on a T1 Mac: it drops fprintd/libfprint
packages, and libfprint-t1bridge is what provides the Touch ID driver.
EOF
