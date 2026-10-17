# Troubleshooting

Everything here was hit on real hardware (MacBookPro13,2, Omarchy 4.0.4,
t1bridge 0.1.12). Start with `./doctor.sh` — it is read-only and produces output
you can paste into an issue.

## `omarchy setup security fingerprint` says "No fingerprint sensor detected"

Expected on a T1 Mac, not a broken reader.

`omarchy-hw-fingerprint` matches vendor IDs and product strings under
`/sys/bus/usb/devices`. Touch ID on T1 hardware is not a USB device — it is
reached through the T1 bridge — so the probe exits 1. Confirm the reader is
actually there:

```console
$ fprintd-list "$USER"
found 1 devices
Device at /net/reactivated/Fprint/Device/0
```

Do not "fix" the probe. Use this repository instead, which skips it deliberately.

## Enrollment fails in about a second, before touching the sensor

```console
$ fprintd-enroll -f right-index-finger
Enrolling right-index-finger finger.
Device reported an error during enroll: fingerprint operation failed
```

```console
$ journalctl -b -u t1-touchid-auth --no-pager | tail
t1bridge keybag: prepare device keybag failed
component=sep phase=sep-lease result=error code=-111
```

`-111` is `ECONNREFUSED`. The protected keybag could not be prepared, so there is
nowhere to store the print and no amount of finger pressure helps.

Check, in this order:

1. **Machine data imported.** `t1bridge-import.service` only starts when
   `/var/lib/t1bridge/touch-id/keybag.state` exists, and the very first run does
   not exist yet — so it is skipped at boot on a fresh install. Run it explicitly:

   ```bash
   sudo systemctl start t1bridge-import.service
   systemctl show -p ExecMainStatus --value t1bridge-import.service
   ```

   `0` means success. `21` means no preserved local Apple EFI data was found;
   see the next section.

2. **xART reachable.** Inbound IPv6 TCP 61500 must reach the host on the private
   T1 link. A running `xart` service is not evidence of that:

   ```bash
   sudo t1bridge status      # look at xart-admission
   sudo ufw status | grep 61500
   ```

   The T1Bridge package installs a peer-scoped rule. If it is missing, add an
   interface-scoped one — never a global port opening:

   ```bash
   sudo ufw allow in on <t1-iface> proto tcp to any port 61500
   ```

   The interface is the instance name of `t1-xart-storage@<iface>.service`.

## Import exits 21: "no preserved Apple EFI data"

The keybag needs this Mac's own `EFI/APPLE/EMBEDDEDOS/FDRData`. It cannot be
recreated by reinstalling packages, by re-enrolling, or by another Mac's backup.
Upstream's guidance is to restore macOS on this machine and let it complete a
first boot, which regenerates the data, then back it up before returning to Linux.

Confirm with:

```bash
sudo systemctl status t1bridge-import.service --no-pager
sudo t1bridge status
```

If `keybag:` can never leave `not-enrolled`, this is why.

## `keybag: not-enrolled` in `t1bridge status`

Normal before the first enrollment. Upstream documents this explicitly. It is not
an error and it is not why a lock screen has no icon.

## `failed to claim device ... Not Authorized: net.reactivated.fprint.device.enroll`

The caller has no live graphical session identity for polkit to authorise. This
happens when an installer or a root script runs `fprintd-enroll`/`fprintd-verify`
on your behalf, including via `runuser` or `sudo -u`.

Fix: run it yourself, in a terminal inside the desktop session:

```bash
fprintd-enroll -f right-index-finger
fprintd-verify
```

A graphical password prompt may appear — that is the `auth_self_keep` policy doing
its job. Do not bypass it with `sudo fprintd-enroll`.

## Lock screen shows no fingerprint icon

Two conditions must both hold:

```bash
test -f /etc/pam.d/omarchy-lock-fingerprint && echo "pam ok"
fprintd-list "$USER" | grep -q finger && echo "print ok"
```

The lock plugin re-checks them on every lock, so no shell restart is needed. If
the PAM file is there but no print is enrolled, enrollment failed earlier.

## Fingerprint prompt appears, then password is asked anyway

`max-tries=3 timeout=10` means a miss or a 10 second pause falls through to the
password on purpose. If the prompt does not appear at all, check the module is
present:

```bash
grep -n pam_fprintd /etc/pam.d/sudo /etc/pam.d/polkit-1
```

## Removing the setup

```bash
sudo ./uninstall.sh            # strip the lines/files this repo added
sudo ./uninstall.sh --restore  # restore the newest snapshot instead
```

Never run `omarchy remove security fingerprint` on a T1 Mac: it ends with
`omarchy-pkg-drop fprintd libfprint libfprint-git`, which can take the T1 driver
provider with it.
