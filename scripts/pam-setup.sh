#!/usr/bin/env bash
# Write the three PAM stacks that make pam_fprintd usable:
#
#   /etc/pam.d/sudo                        sudo (and anything using the sudo service)
#   /etc/pam.d/polkit-1                    graphical authorisation dialogs
#   /etc/pam.d/omarchy-lock-fingerprint    Omarchy's Quickshell lock screen
#
# Every stack keeps its existing password path. Nothing here replaces pam_unix
# or system-auth; the fingerprint module only runs first.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

DRY_RUN=0
FORCE=0

usage() {
  cat <<'EOF'
usage: pam-setup.sh [options]

  --dry-run        print the planned changes, write nothing, root not required
  --user NAME      target user (default: the invoking sudo user)
  --force          write the stacks even if no fingerprint is enrolled
  -h, --help       this text
EOF
}

while (($#)); do
  case $1 in
    --dry-run) DRY_RUN=1 ;;
    --user) shift; [[ ${1:-} ]] || die "--user needs a name"; export OMARCHY_TOUCHID_USER=$1 ;;
    --force) FORCE=1 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

if ((DRY_RUN == 0)); then
  require_root
fi

have fprintd-list || die "fprintd is not installed; install fprintd-t1bridge first"

TARGET_USER=$(target_user)
info "target user: $TARGET_USER"

say "Fingerprints"
FINGERS=$(enrolled_fingers "$TARGET_USER" || true)
if [[ -z $FINGERS ]]; then
  if ((FORCE == 0)); then
    cat >&2 <<EOF

No fingerprint is enrolled for $TARGET_USER, so enabling pam_fprintd would only
add a prompt that can never match. Enroll first, in a graphical terminal:

    fprintd-enroll -f right-index-finger
    fprintd-verify

Expect enroll-completed and verify-match, then re-run this script.
Use --force only if you know a print exists on another reader.
EOF
    exit 1
  fi
  warn "no enrolled fingerprint; continuing because of --force"
else
  printf '%s\n' "$FINGERS" | sed 's/^/    /'
fi

# ---------------------------------------------------------------- backup
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="$OMARCHY_TOUCHID_BACKUP_ROOT/$TS"
if ((DRY_RUN == 0)); then
  install -d -m 0700 "$OMARCHY_TOUCHID_BACKUP_ROOT"
  install -d -m 0700 "$BACKUP"
  for f in sudo polkit-1 omarchy-lock-fingerprint; do
    [[ -f /etc/pam.d/$f ]] && cp -a "/etc/pam.d/$f" "$BACKUP/$f"
  done
  printf '%s\n' "$BACKUP" > "$OMARCHY_TOUCHID_BACKUP_ROOT/latest"
  info "backup: $BACKUP"
else
  info "backup would go to: $BACKUP"
fi

# ---------------------------------------------------------------- helpers
# Add lines that are not already present, at the top of the file, preserving
# ownership and mode. Existing content is never rewritten or reordered.
prepend_missing() {
  local file=$1
  shift
  local -a add=()
  local line
  for line in "$@"; do
    grep -qxF -- "$line" "$file" 2>/dev/null || add+=("$line")
  done
  if ((${#add[@]} == 0)); then
    info "$file: already configured"
    return 0
  fi
  if ((DRY_RUN)); then
    info "$file: would prepend ${#add[@]} line(s)"
    printf '        %s\n' "${add[@]}"
    return 0
  fi
  local tmp mode
  tmp=$(mktemp)
  mode=$(stat -c '%a' "$file" 2>/dev/null || echo 644)
  { printf '%s\n' "${add[@]}"; cat "$file"; } >"$tmp"
  install -m "$mode" -o root -g root "$tmp" "$file"
  rm -f "$tmp"
  info "$file: prepended ${#add[@]} line(s)"
}

write_file() {
  local file=$1 mode=$2
  local tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [[ -f $file ]] && cmp -s "$tmp" "$file"; then
    info "$file: already configured"
    rm -f "$tmp"
    return 0
  fi
  if ((DRY_RUN)); then
    info "$file: would be written"
    sed 's/^/        /' "$tmp"
    rm -f "$tmp"
    return 0
  fi
  install -m "$mode" -o root -g root "$tmp" "$file"
  rm -f "$tmp"
  info "$file: written"
}

# A stack without a password path would lock the user out, so verify before
# leaving the change in place.
validate_stack() {
  local file=$1
  shift
  local pattern
  for pattern in "$@"; do
    grep -qE -- "$pattern" "$file" || {
      warn "$file: missing required '$pattern'"
      return 1
    }
  done
  return 0
}

restore_all() {
  ((DRY_RUN)) && return 0
  [[ -d $BACKUP ]] || return 0
  for f in sudo polkit-1 omarchy-lock-fingerprint; do
    if [[ -f $BACKUP/$f ]]; then
      install -m 0644 -o root -g root "$BACKUP/$f" "/etc/pam.d/$f"
    fi
  done
  warn "restored the previous PAM files from $BACKUP"
}

# ---------------------------------------------------------------- sudo
say "sudo"
[[ -f /etc/pam.d/sudo ]] || die "/etc/pam.d/sudo is missing; this is not a supported PAM layout"
SUDO_LINES=()
if clamshell_gate_available; then
  # success=1 skips exactly the next auth line, so this must stay adjacent.
  SUDO_LINES+=("$(clamshell_gate_line)")
else
  warn "$CLAMSHELL_GATE not found; skipping the clamshell gate"
fi
SUDO_LINES+=("auth      sufficient pam_fprintd.so $FPRINTD_OPTS")
prepend_missing /etc/pam.d/sudo "${SUDO_LINES[@]}"

# ---------------------------------------------------------------- polkit
say "polkit"
if [[ -f /etc/pam.d/polkit-1 ]]; then
  prepend_missing /etc/pam.d/polkit-1 "${SUDO_LINES[@]}"
else
  # /etc overrides the vendor file in /usr/lib/pam.d, so the vendor semantics
  # (system-auth, and with it faillock) have to be reproduced here.
  {
    printf '#%%PAM-1.0\n'
    clamshell_gate_available && printf '%s\n' "$(clamshell_gate_line)"
    printf 'auth       sufficient pam_fprintd.so %s\n' "$FPRINTD_OPTS"
    printf 'auth       include                     system-auth\n'
    printf '\n'
    printf 'account    include                     system-auth\n'
    printf 'password   include                     system-auth\n'
    printf 'session    include                     system-auth\n'
  } | write_file /etc/pam.d/polkit-1 0644
fi

# ---------------------------------------------------------------- lock screen
say "Omarchy lock screen"
write_file /etc/pam.d/omarchy-lock-fingerprint 0644 <<EOF
#%PAM-1.0
auth       required                    pam_fprintd.so $FPRINTD_OPTS
account    include                     system-local-login
EOF

# ---------------------------------------------------------------- validate
say "Validation"
if ((DRY_RUN == 0)); then
  ok=1
  validate_stack /etc/pam.d/sudo 'pam_fprintd\.so' 'system-auth|pam_unix\.so' || ok=0
  validate_stack /etc/pam.d/polkit-1 'pam_fprintd\.so' 'system-auth|pam_unix\.so' || ok=0
  validate_stack /etc/pam.d/omarchy-lock-fingerprint 'pam_fprintd\.so' 'system-local-login' || ok=0
  if ((ok == 0)); then
    restore_all
    die "validation failed; nothing was left changed"
  fi
  info "all three stacks contain pam_fprintd and a password fallback"
fi

say "Result"
if ((DRY_RUN)); then
  info "dry run: no file was modified"
  exit 0
fi

for f in sudo polkit-1 omarchy-lock-fingerprint; do
  printf '\n    --- /etc/pam.d/%s ---\n' "$f"
  sed 's/^/    /' "/etc/pam.d/$f"
done

cat <<EOF

Verify, with a second root shell already open in case something blocks:

    sudo -k; sudo true      # fingerprint prompt, password after 10s
    Super+Ctrl+L            # lock screen shows the fingerprint icon

Roll back with:

    sudo $HERE/../uninstall.sh
    # backups: $BACKUP
EOF
