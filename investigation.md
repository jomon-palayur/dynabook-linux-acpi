# Dynabook Portégé X40-K — Linux firmware interface investigation

Host: Oholiab / CachyOS / kernel 7.1.6-1-cachyos / BIOS "Version 8.70" (2026-02-24), EC FW rev 3.0
Model: Dynabook Inc. PORTEGE X40-K, SKU PMM2CG, board OK011B/0001

## STATUS: ROOT CAUSE FOUND AND FIXED (keyboard backlight + hotkey bleed both resolved, user-confirmed flawless)

---

## Root cause (VERIFIED FACT)

Dynabook is the spun-off Toshiba PC division. The Portégé X40-K firmware still implements
the **Toshiba HCI/SCI protocol** verbatim, under `\_SB.VALZ`:

    Device (VALZ)
        Name (_HID, "DNBK0001")
        Name (_CID, "DNBK0001")
        Name (_STR, "dynabook Value Added Logical and General Purpose Device")
        Method (GHCI, 6, Serialized)   <- the HCI/SCI entry point
        Method (ENAB, 0)               <- hotkey enable
        Method (INFO, 0)               <- hotkey event FIFO read

The in-tree Linux driver `drivers/platform/x86/toshiba_acpi.c` implements exactly this
protocol, but its ACPI match table only lists Toshiba-era IDs:

    {"TOS6200"}, {"TOS6207"}, {"TOS6208"}, {"TOS1900"}

`DNBK0001` is absent. **The driver therefore never binds.** That single omission causes
BOTH reported problems.

### Why keyboard backlight is missing (Problem 1)
`toshiba_acpi` is what registers `toshiba::kbd_backlight` in /sys/class/leds and drives
SCI opcode `0x015C` (SCI_KBD_ILLUM_STATUS) / HCI `0x0095` (HCI_KBD_ILLUMINATION).
The DSDT implements both:
 - DSDT.dsl:120840  `Case (0x015C)` -> sets AKBM/AKBT, calls `SKBL()`
 - DSDT.dsl:121805  `Case (0x0171)` -> sets AKBB, calls `STKB()`
 - `SKBL()`/`STKB()` (DSDT.dsl:118673, 118717) write the EC via
   `\_SB.PC00.LPCB.EC.ECSC (0xB1, <mode|brightness>, ...)` and `ECSC(0xB3, timer)`.
Guarded by `KBBL == One` (DSDT.dsl:4814) — the model does have the hardware.
Modes advertised are FNZ/AUTO/ON/OFF (SCI_KBD_MODE_*), matching kernel `kbd_type 2`.

### Why the brightness Fn keys are dead (Problem 2)
The EC does generate hotkey events. `_Q90/_Q91/_Q92..._Q97` (DSDT.dsl:138739+) each set
`HKCD` and call `WE2F(code)`, which pushes the code into the `AFIF` ring buffer and then:

    Method (WE2F, 1) {
        ... push code into AFIF FIFO ...
        If ((SYSE == One)) { SGSE (0x70) }     <-- ONLY if SYSE == 1
    }

`SGSE(0x70)` (DSDT.dsl:118415+) is what does:
    Notify (\_SB.VALZ, 0x80)               (hotkey event to the driver)
    and, for HKCD 0x40/0x41 (or 0x3C/0x3D in tablet mode),
    `BRTN(0x87)` / `BRTN(0x86)`             -> Notify on GFX0.DD1F = ACPI Video Bus
                                               brightness up/down keypress

`SYSE` is set to One in exactly one place: `VALZ.ENAB` (DSDT.dsl:116728-116729).
`ENAB` is invoked by nothing in firmware — it is invoked by the OS driver
(`toshiba_acpi_enable_hotkeys()` -> `acpi_evaluate_object(handle, "ENAB")`).

**Therefore: with no driver bound, SYSE stays 0, WE2F silently buffers keycodes into a
32-byte ring, no Notify is ever issued, and the events die inside firmware before Linux
can see them.** This is why nothing appears in evtest/libinput — verified-consistent with
the observed symptom that /sys/class/backlight/intel_backlight works fine (that path is
independent of the hotkey path).

Windows works because the "dynabook Service Station / Function Key" driver stack binds
DNBK0001 and calls ENAB.

---

## Evidence trail

Phase 1 — logs/phase1-firmware.txt (dmidecode, hostnamectl, kernel)
Phase 2 — logs/phase2-leds-wmi.txt (only capslock/numlock/scrolllock/phy0-led; 22 WMI
          GUIDs, all Intel/standard PNP0C14 — wmi_bmof loaded, no vendor hotkey GUID.
          `323030314B424E44` decodes to ASCII "2001KBND" but is the I2C touchpad
          (PNP0C50 compat, \_SB.PC00.I2C0.TPD0) — RED HERRING, not keyboard backlight.)
Phase 5 — acpi/*.dsl (DSDT 682 KB + SSDT1-14, decompiled with iasl). Key hits above.
Phase 6 — WMI dead end: no vendor GUID relates to hotkeys or LEDs. Not the interface.
Phase 7 — EC path exists (ECSC 0xB1/0xB3) but is reachable through ACPI, so direct EC
          poking is unnecessary and was deliberately NOT used (higher risk, lower
          priority per the constraint ordering).
Phase 8 — Windows RE NOT REQUIRED. Protocol was fully recovered from ACPI + existing
          kernel source.
Phase 9 — drivers/platform/x86/toshiba_acpi.c: protocol matches 1:1; only the model ID
          is missing. This is a pure "new model ID" gap, exactly as hypothesised.

---

## Fix (implemented, Priority 1: existing kernel support)

patches/0001-toshiba_acpi-add-DNBK0001.patch

    --- a/drivers/platform/x86/toshiba_acpi.c
    +++ b/drivers/platform/x86/toshiba_acpi.c
    @@ -242,6 +242,7 @@
     	{"TOS6207", 0},
     	{"TOS6208", 0},
     	{"TOS1900", 0},
    +	{"DNBK0001", 0},	/* dynabook (Portege X40-K etc.) rebranded TOS1900 */
     	{"", 0},
     };

One line. No new code paths.

### Result after loading the patched module (VERIFIED)

    toshiba_acpi: Toshiba Laptop ACPI Extras version 0.24
    toshiba_acpi: Supported laptop features: hotkeys fan keyboard-backlight
                  usb-sleep-charge usb-rapid-charge panel-power-on cooling-method
    input: Toshiba input device as .../DNBK0001:00/input/input49

    /sys/class/leds/toshiba::kbd_backlight        <-- NEW, works
    /sys/devices/.../DNBK0001:00/kbd_backlight_mode      = 2 -> settable to 0x8/0x10
    /sys/devices/.../DNBK0001:00/available_kbd_modes     = 0x2 0x8 0x10
    /sys/devices/.../DNBK0001:00/kbd_backlight_timeout   = 8 (seconds, AUTO mode)
    /sys/devices/.../DNBK0001:00/kbd_type                = 2
    plus: fan, cooling_method, panel_power_on, usb_sleep_charge, usb_rapid_charge

Note on the LED node: `brightness` reads back 255 because kbd_type 2 reports state via
mode, not level. Writing 0/1 toggles the illumination (HCI 0x0095). For multi-level /
timeout behaviour use `kbd_backlight_mode` (0x2=AUTO w/ timeout, 0x8=ON, 0x10=OFF) and
`kbd_backlight_timeout` (1-60 s) — this is the same control surface Windows exposes.

Known cosmetic warning: `toshiba_acpi: Unable to query Hotkey Event Type` — the X40-K
does not implement HCI_SYSTEM_INFO subcode 0x03; the driver falls back correctly and
hotkeys still register. Harmless.

---

## Installation (permanent, survives kernel updates)

DKMS module installed:

    /usr/src/toshiba_acpi_dynabook-0.24/{toshiba_acpi.c,Makefile,dkms.conf}
    dkms status -> toshiba_acpi_dynabook/0.24, 7.1.6-1-cachyos, x86_64: installed
    installs to /usr/lib/modules/<kver>/updates/dkms/toshiba_acpi.ko.zst
    (overrides the in-tree module; AUTOINSTALL=yes rebuilds on every kernel bump)

IMPORTANT build note: the CachyOS kernel is built with **clang**, so the module must be
built with `make LLVM=1`. A plain gcc build fails with
`unrecognized command-line option '-mstack-alignment=8'`.

To remove:
    dkms remove -m toshiba_acpi_dynabook -v 0.24 --all
    depmod -a

---

## Risk analysis

LOW.
- The change is a device-ID addition to an in-tree, long-maintained driver; no new
  register writes were invented.
- The driver feature-probes every capability via SCI/HCI and disables what returns
  TOS_NOT_SUPPORTED, so unsupported opcodes on this model degrade gracefully (as seen
  with the Hotkey Event Type probe).
- No direct EC port I/O was performed at any point — all access goes through the
  firmware's own ACPI methods, i.e. the same path Windows uses.
- The DKMS module shadows the in-tree one. If it ever breaks, `dkms remove` restores
  stock behaviour immediately; worst case is returning to today's situation.
- Secure Boot: DKMS signs with /var/lib/dkms/mok.key. If Secure Boot is enabled the MOK
  must be enrolled, otherwise the module will refuse to load.

## Upstream

YES — appropriate and should be submitted. This is precisely the kind of patch upstream
accepts: dynabook is Toshiba's successor brand shipping the identical HCI/SCI firmware
interface under a renamed _HID. Send to platform-driver-x86@vger.kernel.org
(Ilpo Järvinen / Hans de Goede) with the DSDT evidence above.

---

## SECOND ROOT CAUSE — hotkey functions "bleed"/persist across presses (FIXED)

After the DNBK0001 bind, keycodes were correct and single per press (verified via
dynabook-capture: 224=BrightDown, 225=BrightUp, 228=KbdBacklightToggle, 113=Mute,
each arriving exactly once, correct direction). Yet rapid consecutive presses showed a
2-3 press lag: pressing Up was interpreted as Down for the next couple of presses, and
the same persistence hit the keyboard-backlight toggle.

### Mechanism (VERIFIED from DSDT + driver source)

The EC enqueues a PRESS entry and a COMPANION/RELEASE entry per physical key:

    _Q84 -> 0x0140 (KEY_BRIGHTNESSDOWN, press)
    _Q85 -> 0x01C0 (companion, has 0x80 bit -> treated as release)
    _Q86 -> 0x0141 (KEY_BRIGHTNESSUP,   press)
    _Q87 -> 0x01C1 (companion)
    _Q8E -> 0x012C (KEY_KBDILLUMTOGGLE, press)
    _Q8F -> 0x01AC (companion)

All FIFO codes are UNIQUE (49 _Qxx handlers -> 49 distinct codes, no collision). The
driver drops the 0x1Cx companions correctly (scancode & 0x80 -> release, ignored).

The bug is in `toshiba_acpi_process_hotkeys()`: the `info_supported` branch calls
`toshiba_acpi_query_hotkey()` (INFO method) EXACTLY ONCE per SCI Notify, then returns.
It does NOT drain the ring. The `system_event_supported` branch, by contrast, loops
`while (... != TOS_FIFO_EMPTY)`.

When keys are pressed rapidly the EC coalesces presses + companions into the AFIF ring
and may fire fewer SCI Notify events than there are entries. The driver reads one entry
per Notify, leaving the rest in the ring. Those leftover entries are replayed on the
NEXT keypress's Notify -> exactly the reported "thinks I pressed the other key for 2-3
presses" / persistence on all hotkeys.

### Fix (implemented)

Drain the INFO FIFO fully on each Notify — loop until INFO returns 0 (ring empty),
mirroring the HCI_SYSTEM_EVENT path. This guarantees no stale entry survives to bleed
into a later press.

    patches/0001-toshiba_acpi-drain-INFO-FIFO-on-hotkey-Notify.patch

User testing (rapid mixed brightness Up/Down + kbd-backlight toggle): CONFIRMED FLAWLESS.
No bleed, no persistence, correct direction under fast presses.

### Why brightness_switch_enabled / acpi_video was a dead end (ruled out)

- /sys/class/backlight shows ONLY intel_backlight; no acpi_video0 device exists, so
  acpi_video is not a second writer.
- dynabook-brightmon logs (both brightness_switch_enabled=Y and =N) showed: uniform
  ~4420 steps (GNOME's 5%-of-88320 scale), correct direction on every slow press, ZERO
  phantom changes. So no firmware/ACPI double-writer.
- The EC has NO NTFY method, so the driver's i8042 NTFY filter path is never installed
  on this model (rules out TOS1900 double-delivery).

### Are the brightness keycodes delivered via "Video Bus" or "Toshiba input device"?

Via the "Toshiba input device" (input49/50/52), code 0x140/0x141 -> KEY_BRIGHTNESSDOWN/UP.
The firmware also calls BRTN() but only when HKCD is 0x40/0x41; in practice the
Toshiba input device is what GNOME consumes, and GNOME animates the step. With the FIFO
drain fix the keys are now immediate and correct.
