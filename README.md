# dynabook-x40k-acpi

Linux kernel support for the **Dynabook Portégé X40-K** (and likely other
dynabook laptops shipping the rebranded Toshiba HCI/SCI firmware) keyboard
backlight and Fn hotkeys.

## Problem

On a stock Linux kernel:

- `/sys/class/leds` has **no keyboard-backlight device** (only capslock,
  numlock, scrolllock, wifi).
- The Fn brightness keys and keyboard-backlight key generate no usable events.
- `intel_backlight` works fine, so the panel itself is fine — only the
  firmware hotkey interface is missing in Linux.

## Root cause

Dynabook is the spun-off Toshiba PC division. The firmware still implements
the Toshiba HCI/SCI protocol verbatim under ACPI device `\_SB.VALZ` with
`_HID = "DNBK0001"`. The in-tree driver
`drivers/platform/x86/toshiba_acpi.c` implements this protocol but its ACPI
match table only lists Toshiba-era IDs (`TOS1900`, …). `DNBK0001` is absent,
so the driver never binds. Without the driver, the EC's hotkey FIFO is never
drained and no events reach Linux.

A second, independent bug caused hotkeys to "bleed" into each other under
rapid presses: the driver's `info_supported` hotkey path read the event FIFO
only **once per Notify**, while the EC enqueues a press + release pair per key
and coalesces rapid presses. Leftover entries replayed on later keypresses.

A third issue appeared with Linux 7.3: the kernel removed `device_class` and
`device_name` from `struct acpi_device_pnp`, breaking the
`acpi_bus_generate_netlink_event()` calls in `toshiba_acpi.c`.

## Fixes

Three minimal, upstream-friendly patches (in `submission/`):

1. `0001-toshiba_acpi-add-DNBK0001.patch` — add `DNBK0001` to the driver's
   ACPI match table (one line).
2. `0002-toshiba_acpi-drain-INFO-FIFO-on-hotkey-Notify.patch` — drain the
   entire INFO FIFO per SCI Notify (loop until empty), mirroring the
   driver's existing `HCI_SYSTEM_EVENT` path.
3. `0003-toshiba_acpi-fix-device_class-removal.patch` — add kernel version
   guards for Linux 7.3+ where `acpi_device_pnp` lost `device_class`; pass
   `""` on newer kernels, preserve old member access on older kernels.

All three are bundled as a DKMS module so they survive kernel updates without
recompiling by hand. The module auto-detects clang-built kernels (CachyOS,
Fedora) via `LLVM=1` in `dkms.conf`.

## Install (as root)

**Easy way** — use the included script (reads version from `dkms.conf`):

```sh
git clone https://github.com/jomon-palayur/dynabook-linux-acpi.git
cd dynabook-linux-acpi
sudo ./install.sh
```

**Manual way:**

```sh
git clone https://github.com/jomon-palayur/dynabook-linux-acpi.git
cd dynabook-linux-acpi
sudo mkdir -p /usr/src/toshiba_acpi_dynabook-0.25
sudo cp dkms/toshiba_acpi.c /usr/src/toshiba_acpi_dynabook-0.25/
sudo cp dkms/dkms.conf     /usr/src/toshiba_acpi_dynabook-0.25/
sudo cp dkms/Makefile      /usr/src/toshiba_acpi_dynabook-0.25/
sudo dkms add    -m toshiba_acpi_dynabook -v 0.25
sudo dkms build  -m toshiba_acpi_dynabook -v 0.25
sudo dkms install -m toshiba_acpi_dynabook -v 0.25
sudo modprobe toshiba_acpi
```

## Keyboard-backlight Fn key (userspace daemon)

The kernel driver delivers `KEY_KBDILLUMTOGGLE` (scancode `0x12c`) correctly,
but GNOME only shows the on-screen indicator and does not actually toggle the
LED — and `toshiba_acpi` does not toggle the backlight itself. So a small
**passive** daemon (`daemon/dynabook-kbdbacklightd`) listens for that keycode
and cycles the backlight mode (`OFF -> ON -> AUTO`) by writing
`kbd_backlight_mode` in sysfs. It does not grab the device, so GNOME's OSD
still appears.

Install and enable (also done by `install.sh`):

```sh
sudo cp daemon/dynabook-kbdbacklightd /usr/local/bin/
sudo chmod +x /usr/local/bin/dynabook-kbdbacklightd
sudo cp daemon/dynabook-kbdbacklightd.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now dynabook-kbdbacklightd
```

Requires `python-evdev` (e.g. `sudo dnf install python3-evdev` or `sudo pacman -S python-evdev`).
The daemon runs as root (it reads `/dev/input/event*` and writes sysfs). Verify:

```sh
systemctl status dynabook-kbdbacklightd
# press the keyboard-backlight Fn key; mode should cycle:
cat /sys/devices/LNXSYSTM:00/LNXSYBUS:00/DNBK0001:00/kbd_backlight_mode
```

> **Note:** set the keyboard-backlight to **OS-controlled** in the BIOS,
> otherwise the firmware timer owns the LED and the OS writes are ignored.

> **Note for CachyOS / clang-built kernels:** the module must be built with
> `LLVM=1` (the `dkms.conf` in this repo already does this automatically). A
> plain gcc build fails with `-mstack-alignment` errors on clang kernels.

> **Secure Boot:** DKMS signs the module with `/var/lib/dkms/mok.key`. If
> Secure Boot is enabled, you must enroll the MOK certificate
> (`/var/lib/dkms/mok.pub`) in your firmware/SHIM *before* the module will
> load — otherwise it is rejected. With Secure Boot off, no action is needed.

After loading, verify:

```sh
ls /sys/class/leds/ | grep toshiba     # -> toshiba::kbd_backlight
lsmod | grep toshiba_acpi              # -> loaded
```

The keyboard backlight is now controllable via sysfs (substitute your actual
path — the `DNBK0001:00` segment is stable but the prefix may vary):

```sh
# find the node
BACKLIGHT=/sys/devices/LNXSYSTM:00/LNXSYBUS:00/DNBK0001:00

# mode: 0x2 = AUTO (with timeout), 0x8 = ON, 0x10 = OFF
echo 0x8  | sudo tee "$BACKLIGHT/kbd_backlight_mode"

# auto-off timeout in seconds (1-60), used in AUTO mode
echo 8    | sudo tee "$BACKLIGHT/kbd_backlight_timeout"
```

`AUTOINSTALL=yes` in `dkms.conf` means the module auto-rebuilds on every
kernel update.

## Files

- `dkms/` — patched `toshiba_acpi.c` + `dkms.conf` + `Makefile`
  (ready to copy to `/usr/src/toshiba_acpi_dynabook-0.25`).
- `daemon/` — `dynabook-kbdbacklightd` (passive Fn-key toggle daemon) +
  its systemd unit.
- `submission/` — *(not required to install)* the three standalone kernel
  patches + cover letter, formatted for upstream submission.
- `investigation.md` — full root-cause analysis, evidence trail, and ACPI
  disassembly notes.

## Remove

To remove everything:

```sh
sudo systemctl disable --now dynabook-kbdbacklightd
sudo rm /etc/systemd/system/dynabook-kbdbacklightd.service
sudo rm /usr/local/bin/dynabook-kbdbacklightd
dkms remove -m toshiba_acpi_dynabook -v 0.25 --all
sudo depmod -a
```