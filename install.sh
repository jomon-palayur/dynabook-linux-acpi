#!/bin/bash
# Example install script (run as root). Copies the DKMS source and builds/installs.
# Also installs the keyboard-backlight daemon and enables the service.

set -e

SRC_DIR="$(cd "$(dirname "$0")/dkms" && pwd)"
DKMS_CONF="$SRC_DIR/dkms.conf"
PACKAGE_NAME=$(grep '^PACKAGE_NAME=' "$DKMS_CONF" | cut -d'"' -f2)
PACKAGE_VERSION=$(grep '^PACKAGE_VERSION=' "$DKMS_CONF" | cut -d'"' -f2)
DEST="/usr/src/${PACKAGE_NAME}-${PACKAGE_VERSION}"

echo "==> Installing DKMS source to $DEST"
# Remove any existing version to avoid DKMS add errors
if dkms status | grep -q "$PACKAGE_NAME"; then
    echo "Removing existing $PACKAGE_NAME module from DKMS..."
    dkms remove -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION" --all || true
fi

mkdir -p "$DEST"
cp "$SRC_DIR/toshiba_acpi.c" "$DEST/"
cp "$SRC_DIR/dkms.conf"       "$DEST/"
cp "$SRC_DIR/Makefile"        "$DEST/"

echo "==> dkms add/build/install"
dkms add    -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION"
dkms build  -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION"
dkms install -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION"

echo "==> Loading module"
modprobe toshiba_acpi || true

# Install daemon
DAEMON_SRC="$(dirname "$0")/daemon"
if [ -d "$DAEMON_SRC" ]; then
    echo "==> Installing keyboard-backlight daemon"
    cp "$DAEMON_SRC/dynabook-kbdbacklightd" /usr/local/bin/
    chmod +x /usr/local/bin/dynabook-kbdbacklightd
    cp "$DAEMON_SRC/dynabook-kbdbacklightd.service" /etc/systemd/system/
    # Reload systemd to pick up new unit
    systemctl daemon-reload
    # Enable and start the service
    systemctl enable --now dynabook-kbdbacklightd
else
    echo "==> WARNING: daemon directory not found at $DAEMON_SRC"
fi

# Check for python-evdev (python3-evdev on Fedora)
if ! python3 -c "import evdev" 2>/dev/null; then
    echo "==> python-evdev not found. Attempting to install via package manager..."
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y python3-evdev
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --needed python-evdev
    else
        echo "==> Please install python-evdev manually (e.g., 'dnf install python3-evdev' or 'pacman -S python-evdev')"
    fi
fi

echo "==> Done. Verify:"
echo "    ls /sys/class/leds/ | grep toshiba"
echo "    lsmod | grep toshiba_acpi"
echo "    systemctl status dynabook-kbdbacklightd"
echo "    # Test backlight toggle:"
echo "    cat /sys/devices/LNXSYSTM:00/LNXSYBUS:00/DNBK0001:00/kbd_backlight_mode"