#!/bin/bash
# dynabook-linux-acpi installer & uninstaller
# Supports all major Linux distributions: Fedora/RHEL, Debian/Ubuntu, Arch/CachyOS, openSUSE, etc.

set -euo pipefail

# Handle help flag before root check
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Usage: sudo $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  (no arguments)   Install/upgrade DKMS driver and keyboard backlight daemon"
    echo "  --uninstall, -u  Remove DKMS driver and stop/remove backlight daemon"
    echo "  --help, -h       Display this help message"
    exit 0
fi


# Ensure script is run as root
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use: sudo $0)" >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "$0")/dkms" && pwd)"
DAEMON_SRC="$(cd "$(dirname "$0")/daemon" && pwd)"
DKMS_CONF="$SRC_DIR/dkms.conf"

if [ ! -f "$DKMS_CONF" ]; then
    echo "ERROR: Cannot find dkms.conf at $DKMS_CONF" >&2
    exit 1
fi

PACKAGE_NAME=$(grep '^PACKAGE_NAME=' "$DKMS_CONF" | cut -d'"' -f2)
PACKAGE_VERSION=$(grep '^PACKAGE_VERSION=' "$DKMS_CONF" | cut -d'"' -f2)
DEST="/usr/src/${PACKAGE_NAME}-${PACKAGE_VERSION}"

# Helper function to detect package manager and install packages
install_pkg() {
    local pkg_type="$1"
    shift
    local pkgs=("$@")

    echo "==> Installing missing dependencies: ${pkgs[*]}"
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y "${pkgs[@]}"
    elif command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --needed --noconfirm "${pkgs[@]}"
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive in "${pkgs[@]}"
    elif command -v apk >/dev/null 2>&1; then
        apk add "${pkgs[@]}"
    elif command -v xbps-install >/dev/null 2>&1; then
        xbps-install -y "${pkgs[@]}"
    else
        echo "WARNING: Could not identify supported package manager. Please ensure ${pkgs[*]} are installed." >&2
    fi
}

# Uninstall function
do_uninstall() {
    echo "==> Uninstalling $PACKAGE_NAME..."

    # Stop and remove daemon
    if systemctl is-active --quiet dynabook-kbdbacklightd 2>/dev/null; then
        echo "Stopping dynabook-kbdbacklightd service..."
        systemctl stop dynabook-kbdbacklightd || true
    fi
    if systemctl is-enabled --quiet dynabook-kbdbacklightd 2>/dev/null; then
        echo "Disabling dynabook-kbdbacklightd service..."
        systemctl disable dynabook-kbdbacklightd || true
    fi
    rm -f /etc/systemd/system/dynabook-kbdbacklightd.service
    rm -f /usr/local/bin/dynabook-kbdbacklightd
    systemctl daemon-reload || true

    # Remove DKMS module
    if command -v dkms >/dev/null 2>&1; then
        if dkms status | grep -q "$PACKAGE_NAME"; then
            echo "Removing $PACKAGE_NAME from DKMS..."
            dkms remove -m "$PACKAGE_NAME" --all || true
        fi
    fi

    # Remove /usr/src directories
    rm -rf "/usr/src/${PACKAGE_NAME}-"*

    # Reload kernel module tree
    depmod -a "$(uname -r)" 2>/dev/null || true

    echo "==> Restoring stock module..."
    modprobe -r toshiba_acpi 2>/dev/null || true
    modprobe toshiba_acpi 2>/dev/null || true

    echo "==> Uninstallation complete."
    exit 0
}

# Handle command-line arguments
if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ] || [ "${1:-}" = "uninstall" ]; then
    do_uninstall
fi



echo "=========================================================="
echo "  Installing dynabook-linux-acpi (v${PACKAGE_VERSION})"
echo "=========================================================="

# 1. Check and install core dependencies (DKMS and python-evdev)
if ! command -v dkms >/dev/null 2>&1; then
    echo "==> DKMS is not installed. Attempting installation..."
    if command -v dnf >/dev/null 2>&1; then
        install_pkg dnf dkms
    elif command -v apt-get >/dev/null 2>&1; then
        install_pkg apt-get dkms
    elif command -v pacman >/dev/null 2>&1; then
        install_pkg pacman dkms
    elif command -v zypper >/dev/null 2>&1; then
        install_pkg zypper dkms
    else
        echo "ERROR: 'dkms' is required. Please install dkms via your package manager." >&2
        exit 1
    fi
fi

# Ensure kernel development headers exist
KVER="$(uname -r)"
if [ ! -d "/lib/modules/$KVER/build" ] && [ ! -d "/usr/src/kernels/$KVER" ]; then
    echo "==> Kernel headers for $KVER not found. Attempting to install..."
    if command -v dnf >/dev/null 2>&1; then
        install_pkg dnf "kernel-devel-$KVER" || install_pkg dnf kernel-devel
    elif command -v apt-get >/dev/null 2>&1; then
        install_pkg apt-get "linux-headers-$KVER" || install_pkg apt-get linux-headers-generic
    elif command -v pacman >/dev/null 2>&1; then
        install_pkg pacman linux-headers
    elif command -v zypper >/dev/null 2>&1; then
        install_pkg zypper "kernel-devel-$KVER" || install_pkg zypper kernel-devel
    fi
fi

# Ensure python-evdev is installed for daemon
if ! python3 -c "import evdev" 2>/dev/null; then
    echo "==> python-evdev not found. Attempting to install via package manager..."
    if command -v dnf >/dev/null 2>&1; then
        install_pkg dnf python3-evdev
    elif command -v apt-get >/dev/null 2>&1; then
        install_pkg apt-get python3-evdev
    elif command -v pacman >/dev/null 2>&1; then
        install_pkg pacman python-evdev
    elif command -v zypper >/dev/null 2>&1; then
        install_pkg zypper python3-evdev
    elif command -v apk >/dev/null 2>&1; then
        install_pkg apk py3-evdev
    elif command -v pip3 >/dev/null 2>&1; then
        pip3 install --break-system-packages evdev 2>/dev/null || pip3 install evdev
    else
        echo "WARNING: Could not automatically install python-evdev. Please install it manually." >&2
    fi
fi

# 2. Setup DKMS source directory
echo "==> Installing DKMS module source to $DEST"

# Remove any existing DKMS instances of this module to avoid conflicts
if dkms status | grep -q "$PACKAGE_NAME"; then
    echo "Cleaning up prior $PACKAGE_NAME registrations in DKMS..."
    dkms remove -m "$PACKAGE_NAME" --all || true
fi

rm -rf "$DEST"
mkdir -p "$DEST"
cp "$SRC_DIR/toshiba_acpi.c" "$DEST/"
cp "$SRC_DIR/dkms.conf"       "$DEST/"
cp "$SRC_DIR/Makefile"        "$DEST/"

# 3. Add, Build, and Install DKMS module
echo "==> Registering, building, and installing with DKMS..."
dkms add     -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION"
dkms build   -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION"
dkms install -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION"

# 4. Reload kernel module
echo "==> Loading toshiba_acpi kernel module..."
modprobe -r toshiba_acpi 2>/dev/null || true
modprobe toshiba_acpi

# 5. Install keyboard-backlight daemon
if [ -d "$DAEMON_SRC" ]; then
    echo "==> Installing keyboard-backlight daemon..."
    cp "$DAEMON_SRC/dynabook-kbdbacklightd" /usr/local/bin/
    chmod +x /usr/local/bin/dynabook-kbdbacklightd
    cp "$DAEMON_SRC/dynabook-kbdbacklightd.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable dynabook-kbdbacklightd
    systemctl restart dynabook-kbdbacklightd
else
    echo "==> WARNING: daemon directory not found at $DAEMON_SRC"
fi

# 6. Secure Boot note
if command -v mokutil >/dev/null 2>&1; then
    if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
        echo ""
        echo "------------------------------------------------------------------"
        echo " NOTE: Secure Boot is enabled on this system."
        echo " DKMS has signed this module using your system DKMS MOK key."
        echo " If this is your first time using DKMS on this machine, enroll the"
        echo " key in firmware MOK before reboot:"
        echo "   sudo mokutil --import /var/lib/dkms/mok.pub"
        echo "------------------------------------------------------------------"
        echo ""
    fi
fi

# 7. Verification Summary
echo ""
echo "=========================================================="
echo "  Installation complete! Status verification:"
echo "=========================================================="
echo -n "  DKMS Status:      "
dkms status -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION" || true
echo -n "  Module Loaded:    "
if lsmod | grep -q toshiba_acpi; then echo "YES (toshiba_acpi)"; else echo "NO"; fi
echo -n "  Backlight sysfs:  "
if [ -f /sys/bus/acpi/devices/DNBK0001:00/kbd_backlight_mode ]; then
    MODE=$(cat /sys/bus/acpi/devices/DNBK0001:00/kbd_backlight_mode)
    echo "Found (current mode: $MODE)"
else
    echo "Pending (check dmesg | grep toshiba_acpi)"
fi
echo -n "  Daemon Status:    "
if systemctl is-active --quiet dynabook-kbdbacklightd; then
    echo "Active (running)"
else
    echo "Inactive (check: systemctl status dynabook-kbdbacklightd)"
fi
echo "=========================================================="
echo "Press your Fn keyboard backlight key to test."
