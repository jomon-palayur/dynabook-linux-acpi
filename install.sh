# Example install script (run as root). Copies the DKMS source and builds/installs.

set -e

SRC_DIR="$(cd "$(dirname "$0")/dkms" && pwd)"
DEST="/usr/src/toshiba_acpi_dynabook-0.24"

echo "==> Installing DKMS source to $DEST"
mkdir -p "$DEST"
cp "$SRC_DIR/toshiba_acpi.c" "$DEST/"
cp "$SRC_DIR/dkms.conf"       "$DEST/"
cp "$SRC_DIR/Makefile"        "$DEST/"

echo "==> dkms add/build/install"
dkms add    -m toshiba_acpi_dynabook -v 0.24
dkms build  -m toshiba_acpi_dynabook -v 0.24
dkms install -m toshiba_acpi_dynabook -v 0.24

echo "==> Loading module"
modprobe toshiba_acpi || true

echo "==> Done. Verify:"
echo "    ls /sys/class/leds/ | grep toshiba"
echo "    lsmod | grep toshiba_acpi"
