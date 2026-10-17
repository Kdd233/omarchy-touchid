# omarchy-touchid

Fingerprint authentication for **sudo**, **polkit** prompts and the **Omarchy lock
screen** on an Apple T1 MacBook running [Omarchy](https://omarchy.org/).

Omarchy ships its own fingerprint wizard, `omarchy setup security fingerprint`.
On a T1 Mac it cannot work, for two reasons covered [below](#why-not-omarchy-setup-security-fingerprint).
This repository does the same job — with the T1 prerequisites checked first — and
records the failure modes so the next person does not have to rediscover them.

```console
$ sudo ./install.sh
$ sudo -k; sudo true
Place your right index finger on the fingerprint reader   # or password after 10s
```

## What this actually does

1. **Checks the T1 prerequisites** (`scripts/preflight.sh`): the private T1 link,
   inbound IPv6 TCP 61500 (xART) on that link only, and this Mac's Apple machine
   data import. Without both, enrollment fails in the driver before your finger
   reaches the sensor.
2. **Writes three PAM stacks** (`scripts/pam-setup.sh`): `sudo`, `polkit-1` and
   `omarchy-lock-fingerprint`, each keeping its existing password path.
3. **Backs everything up** to `/var/backups/omarchy-touchid/<timestamp>/` before
   the first write, and restores automatically if the result fails validation.
4. **Reports, safely** (`doctor.sh`): read-only, paste-friendly output for issues.

It does **not** install or replace `libfprint`/`fprintd`. The T1 driver pair comes
from the T1Bridge packages and must stay a matched pair.

## Requirements

| Requirement | Why |
| --- | --- |
| Apple T1 MacBook: `MacBookPro13,2` (tested), `MacBookPro13,3`, `MacBookPro14,2`, `MacBookPro14,3` | Touch ID is reached through the T1 bridge, not USB |
| Omarchy 4.x with the Quickshell lock screen | the lock screen reads `/etc/pam.d/omarchy-lock-fingerprint` |
| `t1bridge`, `t1bridge-dkms`, `libfprint-t1bridge`, `fprintd-t1bridge` | hardware stack, from the [T1Bridge repository](https://github.com/standardagents/t1bridge) |
| This Mac's original `EFI/APPLE/EMBEDDEDOS/FDRData` | calibration data for the protected keybag; it cannot be substituted |
| A working password login | always kept as the fallback |

Not supported: T2 Macs, Apple Silicon, Macs without a Touch Bar, non-Omarchy
desktops (the PAM service names differ), and machines whose Apple EFI data was
erased when Linux was installed — see [troubleshooting](docs/troubleshooting.md).

## Quick start

```bash
git clone https://github.com/Kdd233/omarchy-touchid.git
cd omarchy-touchid

# 1. Check and fix the T1 prerequisites. Re-runnable, deletes nothing.
sudo ./install.sh --preflight-only

# 2. Enroll, as yourself, in a terminal inside your graphical session.
#    polkit authorises this with auth_self_keep, so a root shell cannot do it.
fprintd-enroll -f right-index-finger     # touch, lift, repeat until enroll-completed
fprintd-verify                           # expect verify-match

# 3. Write the PAM stacks.
sudo ./install.sh --pam-only

# 4. Verify both consumers separately.
sudo -k; sudo true
```

Then lock the screen (`Super + Ctrl + L`): a fingerprint icon appears on the right
of the password field.

Keep a second terminal with `sudo -i` open until both checks pass. Nothing here
removes password authentication, but a second shell costs nothing.

## Why not `omarchy setup security fingerprint`

Two independent problems, both fatal on T1 hardware:

**1. The probe cannot see the reader.** `omarchy-hw-fingerprint` scans
`/sys/bus/usb/devices` for known fingerprint vendors and product strings. Touch ID
on a T1 Mac is reached over the T1 bridge, not USB, so the probe exits 1 and the
wizard stops with `No fingerprint sensor detected` — even though `fprintd-list`
happily lists `Apple Touch ID`.

**2. It would replace the working driver.** The wizard installs `libfprint-git`.
`libfprint-t1bridge` *provides* `libfprint` and *conflicts* with it, so the
transaction (`pacman -S --ask 4`) replaces the T1 driver with the upstream one and
Touch ID stops working entirely.

This repository reproduces the wizard's PAM logic without either problem.

## What gets changed

| File | Change | Fallback |
| --- | --- | --- |
| `/etc/pam.d/sudo` | clamshell gate + `pam_fprintd.so max-tries=3 timeout=10` above the existing `include system-auth` | password after 10s |
| `/etc/pam.d/polkit-1` | same, then `include system-auth` (created only if absent; the vendor file in `/usr/lib/pam.d` supplies the same) | password after 10s |
| `/etc/pam.d/omarchy-lock-fingerprint` | `pam_fprintd.so max-tries=3 timeout=10` + `account include system-local-login` | the lock screen's separate password conversation |

The clamshell gate is `pam_exec` on `/usr/bin/omarchy-hw-laptop-closed` with
`success=1`: when the lid is shut the sensor is unreachable, so the gate skips
exactly the next line and the password path runs immediately instead of blocking
for the whole timeout.

`max-tries=3 timeout=10` matters: `pam_fprintd` defaults to a 30 second timeout,
which makes every password-based `sudo` feel broken while the reader waits.

## Verifying

```bash
sudo -k; sudo true        # fingerprint prompt, then password if you wait or fail
```

Lock the screen and check all three paths:

1. fingerprint unlocks,
2. password still unlocks after a cancelled fingerprint,
3. password still unlocks with fprintd stopped (`sudo systemctl stop fprintd`).

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `No fingerprint sensor detected` | the Omarchy wizard's USB probe; use this repo |
| `prepare device keybag failed`, `sep-lease ... code=-111` | machine data not imported, or xART unreachable — run `--preflight-only` |
| `keybag: not-enrolled` in `t1bridge status` | normal before the first enrollment, not an error |
| `failed to claim device ... device.enroll`, `Not Authorized` | enrollment/verify ran from a root script; run it in your own session |
| Lock screen shows no icon | needs both the PAM file and an enrolled print |
| `sudo` still asks for a password | expected after 10s, or `pam_fprintd.so` is missing from `/etc/pam.d/sudo` |

Full detail, including how to read the import exit codes: [docs/troubleshooting.md](docs/troubleshooting.md).

## Uninstall

```bash
sudo ./uninstall.sh            # strip the fingerprint lines
sudo ./uninstall.sh --restore  # or restore the newest snapshot
./doctor.sh                    # confirm the password path is intact
```

Do **not** run `omarchy remove security fingerprint` on a T1 Mac: it drops the
`fprintd`/`libfprint` packages, and `libfprint-t1bridge` is what provides the
Touch ID driver. Removing only the PAM configuration is always safe.

## 中文快速开始

```bash
sudo ./install.sh --preflight-only    # 修复 T1 前置条件（可重复执行，不删东西）
fprintd-enroll -f right-index-finger  # 用你自己的账号录入，手指按下抬起约 10 次
fprintd-verify                        # 应显示 verify-match
sudo ./install.sh --pam-only          # 写入 sudo / polkit / 锁屏 三个 PAM 栈
```

常见坑：`omarchy setup security fingerprint` 在 T1 机器上一定失败（探测只认 USB
指纹设备，且会装 `libfprint-git` 顶掉 `libfprint-t1bridge`）；录入必须由你自己的
图形会话完成，root 脚本代跑会被 polkit 拒绝。

## Credits

- [standardagents/t1bridge](https://github.com/standardagents/t1bridge) — the T1
  hardware stack, and the documentation that explains the keybag and xART
  requirements this repo automates around.
- [Omarchy](https://github.com/basecamp/omarchy) — the PAM service names and the
  lock screen this integrates with.

## License

MIT — see [LICENSE](LICENSE).
