# How it works

## The stack, bottom to top

```
Apple T1 chip
  └─ t1bridge-dkms        kernel side: NCM link, xART storage, display
      └─ t1-touchid-auth  broker: talks to the Secure Enclave over the link
          └─ libfprint-t1bridge   presents a standard libfprint device
              └─ fprintd-t1bridge daemon + CLI tools
                  └─ pam_fprintd.so   PAM module used by the three consumers
```

Only the top layer is configured here. Everything below it is the T1Bridge
package set, and mixing in a distro `libfprint`/`fprintd` breaks the chain.

## The protected keybag

Fingerprints are not stored as plain files. They are sealed with keys held by the
Secure Enclave, wrapped in a keybag under `/var/lib/t1bridge/touch-id/`.

Two consequences drive most of the troubleshooting:

- **The keybag must be prepared before the first enrollment.** That needs this
  Mac's calibration data, imported from `EFI/APPLE/EMBEDDEDOS/FDRData` by
  `t1bridge-import.service`. On a fresh install the relay unit is skipped because
  its `ConditionPathExists` is not met yet — the state file only exists *after* a
  successful import, so it has to be started explicitly once.
- **`keybag: not-enrolled` is the pre-enrollment state.** Not an error.

## Why the T1 has to reach the host

libfprint drives the reader in userspace, but the keybag work happens against the
Secure Enclave across the private T1 link. The xART service listens on inbound
IPv6 TCP 61500, bound to that interface (`SO_BINDTODEVICE`). A firewall that drops
it produces `ECONNREFUSED` inside the broker, surfaced as `sep-lease code=-111`.

Because the listener is interface-bound and enforces peer admission, an
interface-scoped firewall exception is the correct scope. A global port opening is
never needed and never appropriate.

## Why enrollment is not automated

`/usr/share/polkit-1/actions/net.reactivated.fprint.device.policy` authorises
enrollment with `auth_self_keep`:

```xml
<action id="net.reactivated.fprint.device.enroll">
  <defaults>
    <allow_any>no</allow_any>
    <allow_inactive>no</allow_inactive>
    <allow_active>auth_self_keep</allow_active>
  </defaults>
</action>
```

`auth_self_keep` means polkit asks the desktop's authentication agent to
re-authenticate the caller. A process derived from `sudo`, `runuser` or a root
script has no such session identity, so the claim is refused with
`Not Authorized: net.reactivated.fprint.device.enroll` — even for a read-only
`fprintd-verify`, because claiming the device goes through the same policy.

So the installer stops, tells you to enroll, and only writes PAM afterwards. That
ordering also prevents the failure mode where PAM points at a reader that has no
print to match.

## The three PAM consumers

They are independent. Success in one proves nothing about the others.

**sudo** — `/etc/pam.d/sudo` is a thin wrapper around `include system-auth`. Two
lines go above it: the clamshell gate and `pam_fprintd.so`. `sufficient` means a
match returns success immediately; anything else continues into the original
stack, which still has the password path.

**polkit** — same idea, but the file may not exist in `/etc`. Arch also searches
`/usr/lib/pam.d`, where the polkit package ships a vendor file that does
`include system-auth`. If this repo creates an `/etc` override it must reproduce
those includes, otherwise `system-auth` — and with it `pam_faillock` — disappears
from graphical authentication.

**Lock screen** — Omarchy's Quickshell lock plugin runs two separate PAM
conversations: `omarchy-lock-password` for typing, and `omarchy-lock-fingerprint`
for the sensor. The fingerprint one is `required`, not `sufficient`: the plugin
starts it in parallel and aborts it when you type instead. That is why the two
files are independent and why the password path survives untouched.

The plugin decides whether to show the icon by checking both the file's existence
and `fprintd-list` output, and re-checks on every lock.

## The clamshell gate

```pam
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so max-tries=3 timeout=10
```

With the lid shut the sensor is physically unreachable. Without the gate, every
`sudo` on a closed laptop would wait the full timeout before falling back. The
gate returns success when the lid is closed, and `success=1` then skips exactly
the next line — which is why the two lines must stay adjacent.

## Backups and rollback

Every run copies the files it is about to change to
`/var/backups/omarchy-touchid/<timestamp>/` (mode 0700) and records the path in
`latest`. After writing, each stack is validated for both `pam_fprintd.so` and a
password path; if validation fails, the snapshot is restored and the script exits
non-zero. `uninstall.sh --restore` reuses the same snapshot.

## Deliberate non-goals

- Not replacing `libfprint`/`fprintd` — that belongs to the T1Bridge packages.
- Not touching `omarchy-lock-password` or `system-auth`.
- Not enrolling, verifying or deleting prints on your behalf.
- Not opening port 61500 beyond the private link.
