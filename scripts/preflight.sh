#!/usr/bin/env bash
# Fix the T1 prerequisites Touch ID needs before any enrollment can work.
#
# Covers the two upstream requirements people hit in practice:
#   1. inbound IPv6 TCP 61500 (xART) reachable on the private T1 link
#   2. this Mac's Apple machine data imported (EFI/APPLE/EMBEDDEDOS/FDRData)
#
# Safe to re-run: every step is conditional and nothing is deleted.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

require_root

say "1/4  Packages"
have t1bridge || die "t1bridge is not installed. Install the T1Bridge packages first."
have fprintd-list || die "fprintd tools are missing."
info "t1bridge: $(pacman -Q t1bridge 2>/dev/null || echo unknown)"

MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
info "model:   $MODEL"
case $MODEL in
  MacBookPro13,* | MacBookPro14,2 | MacBookPro14,3) ;;
  *) warn "this project targets Apple T1 MacBooks; '$MODEL' was not verified" ;;
esac

say "2/4  Private T1 link"
T1_IF=${OMARCHY_TOUCHID_T1_IF:-$(t1_interface)}
[[ -n $T1_IF ]] || die "no t1-xart-storage@<iface> instance is running; the T1 stack is not up"
info "interface: $T1_IF"
ip -6 addr show "$T1_IF" 2>/dev/null | grep -E 'inet6' | sed 's/^/    /' || warn "no IPv6 address on $T1_IF"

say "3/4  xART firewall (inbound IPv6 TCP 61500, this interface only)"
if ! systemctl is-active --quiet ufw; then
  info "ufw is not active; nothing to do"
elif ufw status 2>/dev/null | grep -q '61500'; then
  info "a 61500 rule already exists:"
  ufw status 2>/dev/null | grep '61500' | sed 's/^/    /'
else
  # Scoped to the private link: never open 61500 globally.
  if ufw allow in on "$T1_IF" proto tcp to any port 61500 comment 'omarchy-touchid xART' >/dev/null; then
    info "added: in on $T1_IF tcp/61500"
  else
    warn "could not add the ufw rule"
  fi
fi
ss -lntp 2>/dev/null | grep -q '61500' && info "listener is up" || warn "nothing is listening on 61500"

say "4/4  Apple machine-data import"
info "source: this Mac's EFI/APPLE/EMBEDDEDOS/FDRData"
systemctl start t1bridge-import.service 2>/dev/null
IMPORT_RC=$(service_exit_code t1bridge-import.service)
systemctl status t1bridge-import.service --no-pager -n 12 2>&1 | sed 's/^/    /'

case ${IMPORT_RC:-x} in
  0)  info "import: success (exit 0)" ;;
  20) warn "import: sensor unavailable (exit 20) - retry while the reader is idle" ;;
  21) warn "import: no preserved Apple EFI data found (exit 21)" ;;
  22) warn "import: source unreadable (exit 22) - a mount or permission problem, not data loss" ;;
  23 | 24 | 25) warn "import: invalid, non-matching or conflicting data (exit ${IMPORT_RC})" ;;
  26 | 27 | 28 | 29 | 30) warn "import: protected-storage failure (exit ${IMPORT_RC})" ;;
  *)  warn "import: exit ${IMPORT_RC:-unknown}" ;;
esac

say "t1bridge status"
if have t1bridge; then
  t1bridge status 2>&1 | sed 's/^/    /'
fi

cat <<'EOF'

Interpretation
  keybag: not-enrolled      normal before the first enrollment, not a failure
  keybag: ready             a keybag exists; prints are stored
  xart-admission: no ...    no evidence this boot that the T1 reached the host;
                            only meaningful after an enrollment attempt

Next
  exit 0  -> enroll as yourself in a graphical terminal:
               fprintd-enroll -f right-index-finger
               fprintd-verify
             then run: sudo ./install.sh --pam-only
  exit 21 -> this Mac's Apple EFI data is gone. Touch ID cannot be provisioned
             until macOS is restored on this machine and booted once, which
             regenerates it. Back up your data first: restoring macOS can erase.
EOF

exit 0
