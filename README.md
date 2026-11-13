# dynabook-linux-acpi

Linux kernel driver and userspace integration for **Dynabook** laptops (including the **Portégé X40-K**, X30, and other models shipping rebranded Toshiba HCI/SCI firmware).

This project restores the **keyboard backlight**, **Fn hotkeys** (brightness, backlight toggle, mute, etc.), and eliminates keypress lag/bleed across all major Linux distributions and kernel versions (Linux 5.15 LTS through 7.x+).

---

## The Problem & Root Cause

On stock Linux kernels:
* **/sys/class/leds** lacks any keyboard backlight device (only CapsLock, NumLock, etc. are listed).
* **Fn brightness and keyboard-backlight keys are dead** and emit no usable input events.
* `intel_backlight` works fine, but firmware hotkeys and LED controls are completely inactive.

### Why this happens

Dynabook is the spun-off client PC division of Toshiba. The firmware still implements the Toshiba HCI/SCI ACPI protocol verbatim under device `\_SB.VALZ`, but rebranded the ACPI Hardware ID (`_HID`) from `TOS1900` to **`DNBK0001`**. Because the in-tree kernel driver (`drivers/platform/x86/toshiba_acpi.c`) only matched legacy Toshiba IDs, it never bound on Dynabook hardware. Without the driver, the firmware hotkey notification subsystem is never enabled (`VALZ.ENAB` is never called), causing the Embedded Controller (EC) to silently buffer key events without sending notifications to Linux.

Furthermore, an independent bug in `toshiba_acpi.c` caused hotkey functions to "bleed" into each other during rapid keypresses: the driver queried the event FIFO only **once per SCI Notify**, whereas the EC enqueues press + release companion pairs. Unconsumed scancodes accumulated in the ring buffer and were replayed on subsequent keypresses.

---

## Features

- **Driver ACPI Match**: Binds `toshiba_acpi` to `DNBK0001` devices.
- **FIFO Drain Fix**: Loops until the event ring buffer is empty, ensuring instant and accurate hotkey responses with zero lag.
- **Cross-Distro & Multi-Kernel DKMS**: Fully compatible with Linux **5.15 LTS, 6.1 LTS, 6.6 LTS, 6.12 LTS, and 7.x+** (including the Linux 7.3 `acpi_device_pnp.device_class` API change).
- **Auto-Compiler Detection**: Automatically detects Clang-built kernels (CachyOS, OpenEmbedded, custom LLVM builds) and applies `LLVM=1`, while defaulting to GCC on Fedora, Debian/Ubuntu, and Arch.
- **Passive Backlight Daemon**: A background service (`dynabook-kbdbacklightd`) that listens for `KEY_KBDILLUMTOGGLE` to cycle modes (`OFF -> ON -> AUTO`) via sysfs while preserving desktop OSD animations (GNOME, KDE Plasma).

---

## Distribution Prerequisites

Before installation, ensure your system has kernel development headers, DKMS, and Python 3:

| Distribution | Required Packages |
| :--- | :--- |
| **Fedora / RHEL / Rocky** | `sudo dnf install kernel-devel dkms python3-evdev` |
| **Debian / Ubuntu / Mint** | `sudo apt-get install linux-headers-$(uname -r) dkms python3-evdev` |
| **Arch Linux / CachyOS** | `sudo pacman -S linux-headers dkms python-evdev` |
| **openSUSE Tumbleweed / Leap** | `sudo zypper install kernel-devel dkms python3-evdev` |

> [!NOTE]
> **BIOS Setting**: Ensure the Keyboard Backlight setting in your BIOS/UEFI is configured to **OS-controlled** (or Timer). If set strictly to firmware timer, hardware overrides OS writes.

> [!IMPORTANT]
> **Secure Boot**: If Secure Boot is enabled, DKMS signs the compiled module using the system MOK key (`/var/lib/dkms/mok.key`). If this is your first DKMS module, enroll the key in your firmware MOK list before reboot:
> ```sh
> sudo mokutil --import /var/lib/dkms/mok.pub
> ```
> *(Create a one-time password when prompted, then reboot and complete the MOK enrollment dialog in your firmware screen).*

---

## Installation

### Method 1: Automatic (Recommended)

The included installer detects your distribution, verifies and installs missing prerequisites, configures DKMS, loads the kernel module, and enables the userspace daemon:

```sh
git clone https://github.com/jomon-palayur/dynabook-linux-acpi.git
cd dynabook-linux-acpi
sudo ./install.sh
```

### Method 2: Manual

```sh
git clone https://github.com/jomon-palayur/dynabook-linux-acpi.git
cd dynabook-linux-acpi

# 1. Register and build DKMS module
sudo mkdir -p /usr/src/toshiba_acpi_dynabook-0.25
sudo cp dkms/toshiba_acpi.c /usr/src/toshiba_acpi_dynabook-0.25/
sudo cp dkms/dkms.conf     /usr/src/toshiba_acpi_dynabook-0.25/
sudo cp dkms/Makefile      /usr/src/toshiba_acpi_dynabook-0.25/

sudo dkms add    -m toshiba_acpi_dynabook -v 0.25
sudo dkms build  -m toshiba_acpi_dynabook -v 0.25
sudo dkms install -m toshiba_acpi_dynabook -v 0.25

# 2. Reload kernel driver
sudo modprobe -r toshiba_acpi 2>/dev/null || true
sudo modprobe toshiba_acpi

# 3. Install keyboard backlight daemon
sudo cp daemon/dynabook-kbdbacklightd /usr/local/bin/
sudo chmod +x /usr/local/bin/dynabook-kbdbacklightd
sudo cp daemon/dynabook-kbdbacklightd.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now dynabook-kbdbacklightd
```

---

## Verification

Once installed, verify that the module and devices are active:

```sh
# 1. Verify kernel module is loaded
lsmod | grep toshiba_acpi

# 2. Check LED class device
ls /sys/class/leds/ | grep toshiba
# Expected output: toshiba::kbd_backlight

# 3. Verify sysfs node
cat /sys/bus/acpi/devices/DNBK0001:00/kbd_backlight_mode

# 4. Verify background daemon
systemctl status dynabook-kbdbacklightd
```

---

## Keyboard Backlight Control & Sysfs Interface

The keyboard backlight can be toggled using your laptop's **Fn + Backlight** key, or controlled directly via sysfs:

```sh
# Stable sysfs path across all distributions
BACKLIGHT="/sys/bus/acpi/devices/DNBK0001:00"

# Modes:
#   0x10 (16) = OFF
#   0x8  (8)  = ON
#   0x2  (2)  = AUTO (turns on with keystrokes, shuts off after timeout)

# Set mode to ON:
echo 0x8 | sudo tee "$BACKLIGHT/kbd_backlight_mode"

# Set mode to AUTO with an 8-second timeout:
echo 0x2 | sudo tee "$BACKLIGHT/kbd_backlight_mode"
echo 8   | sudo tee "$BACKLIGHT/kbd_backlight_timeout"

# Turn backlight OFF:
echo 0x10 | sudo tee "$BACKLIGHT/kbd_backlight_mode"
```

---

## Project Structure

- **[`dkms/`](file:///home/jomon/Documents/GitHub/dynabook-linux-acpi/dkms)**: DKMS packaging files (`toshiba_acpi.c`, `dkms.conf`, `Makefile`) with multi-kernel compatibility and Clang/LLVM detection.
- **[`daemon/`](file:///home/jomon/Documents/GitHub/dynabook-linux-acpi/daemon)**: `dynabook-kbdbacklightd` passive Python evdev daemon and systemd service unit.
- **[`submission/`](file:///home/jomon/Documents/GitHub/dynabook-linux-acpi/submission)**: Linux kernel upstream patch series and cover letter formatted for `platform-driver-x86@vger.kernel.org`.
- **[`install.sh`](file:///home/jomon/Documents/GitHub/dynabook-linux-acpi/install.sh)**: Cross-distro installer and uninstaller script.
- **[`investigation.md`](file:///home/jomon/Documents/GitHub/dynabook-linux-acpi/investigation.md)**: Reverse-engineering documentation, ACPI DSDT disassembly, and EC register analysis.

---

## Uninstallation

To completely remove the DKMS module, daemon, and restore stock behavior:

```sh
# Automated removal
sudo ./install.sh --uninstall
```

Or manually:

```sh
sudo systemctl disable --now dynabook-kbdbacklightd
sudo rm -f /etc/systemd/system/dynabook-kbdbacklightd.service
sudo rm -f /usr/local/bin/dynabook-kbdbacklightd
sudo systemctl daemon-reload

sudo dkms remove -m toshiba_acpi_dynabook --all
sudo rm -rf /usr/src/toshiba_acpi_dynabook-*
sudo depmod -a
sudo modprobe -r toshiba_acpi 2>/dev/null || true
sudo modprobe toshiba_acpi 2>/dev/null || true
```

---

## License

GPL-2.0-or-later. See [`LICENSE`](file:///home/jomon/Documents/GitHub/dynabook-linux-acpi/LICENSE) for details.
