#!/usr/bin/env python3
"""Apply the Xiaomi/MIUI USB speed fix, in the same layers Podroid uses.

Xiaomi/MIUI's host stack reports a full-speed device as low-speed while the
device's own descriptor still says bMaxPacketSize0 = 64. A low-speed device may
not have an ep0 maxpacket above 8 (USB 2.0 section 5.5.3, table 5-6), so the
guest kernel refuses to enumerate it:

    usb 1-1: Invalid ep0 maxpacket: 64
    usb usb1-port1: unable to enumerate USB device

Podroid fixes it in two layers and so does this: correct the speed on the host
side before the guest sees the descriptor, and keep a safety net in the guest
kernel for the cases the host layer cannot cover (a stock kernel we do not
build, a device that is announced by something else, a timing edge case).

Every engine that can hand a USB device to a guest has its own host side, so
each one gets the same correction:

    kernel-hub          drivers/usb/core/hub.c      guest safety net (both
                                                    kernels: the VM kernel and
                                                    the UML kernel)
    qemu-host-libusb    hw/usb/host-libusb.c        QEMU engine, host side
    umusb               harness/umusb.c             UML engine, host side
                                                    (the USB/IP server)

Every replacement is an exact text match. A tree whose source has changed shape
stops the build with exit 2 instead of shipping an unpatched binary, and a tree
that is already patched is reported and left alone, so running this twice is a
no-op.

    images/usb-quirks.py kernel-hub   <tree>/drivers/usb/core/hub.c
    images/usb-quirks.py --check umusb <tree>/harness/umusb.c
    images/usb-quirks.py --dry-run qemu-host-libusb <tree>/hw/usb/host-libusb.c
"""

import argparse
import re
import sys

# The string each patched binary is checked for after the build. Nothing here
# repeats a marker by hand: the assertion below reads it back out of the patch
# text, so a build cannot pass its check against a string the patch no longer
# contains. Strip does not touch these -- they are .rodata, not symbols.
MARKERS = {
    "kernel-hub": "Xiaomi/MIUI: low speed reported with ep0 maxpacket 64; "
                  "believing the device is full speed",
    "qemu-host-libusb": "Xiaomi/MIUI: low speed reported for a device whose "
                        "ep0 maxpacket is 64; telling the guest it is full speed",
    "umusb": "Xiaomi/MIUI: low speed reported for a device whose ep0 "
             "maxpacket is 64; telling the guest it is full speed",
}

# --- Layer 2: the guest kernel's safety net ---------------------------------
# hub_port_init() has an else branch that rejects an ep0 maxpacket the speed
# cannot have. Turning it into an else-if chain means the Xiaomi combination
# (low speed + 64) is corrected and the device is enumerated, while every other
# invalid combination still reaches the original error path, goto fail and all.
HUB_OLD = (
    "\t} else {\n"
    "\t\t/* Initial guess is wrong and descriptor's value is invalid */\n"
    '\t\tdev_err(&udev->dev, "Invalid ep0 maxpacket: %d\\n", maxp0);\n'
    "\t\tretval = -EMSGSIZE;\n"
    "\t\tgoto fail;\n"
    "\t}\n"
)

HUB_NEW = (
    "\t} else if (udev->speed == USB_SPEED_LOW &&\n"
    "\t\t   i == 64) {\n"
    "\t\t/*\n"
    "\t\t * Xiaomi/MIUI host stack bug: a full-speed device is reported as\n"
    "\t\t * low-speed while its descriptor still says the ep0 maxpacket is\n"
    "\t\t * 64. A low-speed device may not have that (USB 2.0 section\n"
    "\t\t * 5.5.3, table 5-6), so refusing it -- which is what the else\n"
    "\t\t * branch below does -- loses a device that works perfectly well\n"
    "\t\t * once its speed is believed. Correct the speed and carry on;\n"
    "\t\t * every other invalid combination still fails below.\n"
    "\t\t *\n"
    "\t\t * The dev_info is what makes this fix visible: on a device the line\n"
    "\t\t * in dmesg says the safety net fired, and in the build it is the\n"
    "\t\t * string the kernel binary is checked for (both kernels).\n"
    "\t\t */\n"
    "\t\tdev_info(&udev->dev,\n"
    '\t\t\t "Xiaomi/MIUI: low speed reported with ep0 maxpacket '
    '64; "\n'
    '\t\t\t "believing the device is full speed\\n");\n'
    "\t\tudev->speed = USB_SPEED_FULL;\n"
    "\t\tudev->ep0.desc.wMaxPacketSize = cpu_to_le16(i);\n"
    "\t\tusb_ep0_reinit(udev);\n"
    "\t} else {\n"
    "\t\t/* Initial guess is wrong and descriptor's value is invalid */\n"
    '\t\tdev_err(&udev->dev, "Invalid ep0 maxpacket: %d\\n", maxp0);\n'
    "\t\tretval = -EMSGSIZE;\n"
    "\t\tgoto fail;\n"
    "\t}\n"
)

# The same safety net for the older kernel shape (5.x through 6.1): the ep0
# check there rejects low-speed outright and then lets valid values fall through
# to the correction below, so the quirk branch has to sit in front of that first
# condition and adjust the speed as well as the maxpacket. 6.12, 6.18 and the
# 7.2 port tree use the HUB_OLD/HUB_NEW shape above.
HUB_LEGACY_OLD = (
    "\t\tif (udev->speed == USB_SPEED_LOW ||\n"
    "\t\t\t\t!(i == 8 || i == 16 || i == 32 || i == 64)) {\n"
    '\t\t\tdev_err(&udev->dev, "Invalid ep0 maxpacket: %d\\n", i);\n'
)

HUB_LEGACY_NEW = (
    "\t\t/*\n"
    "\t\t * Xiaomi/MIUI host stack bug: a device announced as low-speed whose\n"
    "\t\t * own descriptor says the ep0 maxpacket is 64 -- impossible for a\n"
    "\t\t * low-speed device (USB 2.0 section 5.5.3, table 5-6) -- used to be\n"
    "\t\t * refused right here. Believe the descriptor, correct the speed, and\n"
    "\t\t * let the fall-through below set the maxpacket, exactly as the newer\n"
    "\t\t * kernels' ep0 check does. The dev_info is what makes the fix\n"
    "\t\t * visible: dmesg on a device, a string in the kernel binary.\n"
    "\t\t */\n"
    "\t\tif (udev->speed == USB_SPEED_LOW && i == 64) {\n"
    "\t\t\tdev_info(&udev->dev,\n"
    '\t\t\t\t "Xiaomi/MIUI: low speed reported with ep0 maxpacket '
    '64; "\n'
    '\t\t\t\t "believing the device is full speed\\n");\n'
    "\t\t\tudev->speed = USB_SPEED_FULL;\n"
    "\t\t} else if (udev->speed == USB_SPEED_LOW ||\n"
    "\t\t\t\t!(i == 8 || i == 16 || i == 32 || i == 64)) {\n"
    '\t\t\tdev_err(&udev->dev, "Invalid ep0 maxpacket: %d\\n", i);\n'
)

# --- Layer 1a: the QEMU engine's host side ----------------------------------
# usb_host_req_complete_ctrl() has already copied the descriptor into r->cbuf,
# so r->cbuf[7] is the device's bMaxPacketSize0 there. The block below the
# anchor is the USB-3 ep0 fixup that was already there; the Xiaomi check goes
# right after it, in front of the guest.
QEMU_OLD = (
    "        /* Fix up USB-3 ep0 maxpacket size to allow superspeed connected devices\n"
    "         * to work redirected to a not superspeed capable hcd */\n"
    "        if (r->usb3ep0quirk && xfer->actual_length >= 18 &&\n"
    "            r->cbuf[7] == 9) {\n"
    "            r->cbuf[7] = 64;\n"
    "        }\n"
)

QEMU_NEW = QEMU_OLD + (
    "        /*\n"
    "         * Xiaomi/MIUI host stack bug: the device is announced as low-speed\n"
    "         * while its own descriptor says the ep0 maxpacket is 64, which no\n"
    "         * low-speed device may have. The guest refuses that combination\n"
    "         * (\"Invalid ep0 maxpacket: 64\"), so correct the speed here, before\n"
    "         * the guest is told what the device is. 18 is a full device\n"
    "         * descriptor, the same length the fixup above insists on, so byte 7\n"
    "         * really is bMaxPacketSize0 and not some other response's byte 7.\n"
    "         *\n"
    "         * warn_report is what makes this fix visible: on a device it says\n"
    "         * in the log that the host-layer correction fired, and in the build\n"
    "         * it is the string qemu-system-aarch64 is checked for.\n"
    "         */\n"
    "        if (udev->speed == USB_SPEED_LOW && xfer->actual_length >= 18 &&\n"
    "            r->cbuf[7] == 64) {\n"
    '            warn_report("Xiaomi/MIUI: low speed reported for a device '
    'whose "\n'
    '                        "ep0 maxpacket is 64; telling the guest it is "\n'
    '                        "full speed");\n'
    "            udev->speed = USB_SPEED_FULL;\n"
    "        }\n"
)

# --- Layer 1b: the UML engine's host side -----------------------------------
# The UML engine does not use libusb: umusb is a USB/IP server that hands the
# phone's device to the guest's vhci_hcd, and the speed it announces is the
# speed the guest's hub then checks. It reads that speed out of usbfs, so it is
# the same MISreport arriving by a different road, and it needs the same
# correction. 1 is USB_SPEED_LOW and 2 is USB_SPEED_FULL in the kernel's
# usb_device_speed, which is what this field carries.
# The correction goes *after* the if/else, not inside one of its arms: a device
# is described either by USBDEVFS_CONNINFO_EX (newer kernels) or by the older
# USBDEVFS_CONNINFO plus USBDEVFS_GET_SPEED, and either one can report the wrong
# speed. One correction, both roads.
UMUSB_OLD = (
    "\t\tspeed = ioctl(fd, USBDEVFS_GET_SPEED);\n"
    "\t\td->speed = speed > 0 ? (uint32_t)speed : 0;\n"
    "\t}\n"
)

UMUSB_NEW = UMUSB_OLD + (
    "\n"
    "\t/*\n"
    "\t * Xiaomi/MIUI host stack bug: a full-speed device is announced as\n"
    "\t * low-speed while its own descriptor (buf, read above) still says the\n"
    "\t * ep0 maxpacket is 64 -- impossible for a low-speed device, and the\n"
    "\t * guest's hub refuses it with \"Invalid ep0 maxpacket: 64\". USB/IP\n"
    "\t * carries our number straight to vhci_hcd (and the app passes it on\n"
    "\t * to usb-attach.sh as --speed), so correct it here, for both of the\n"
    "\t * paths above. 1 is USB_SPEED_LOW and 2 is USB_SPEED_FULL; the guest\n"
    "\t * kernel carries the same check as a safety net\n"
    "\t * (drivers/usb/core/hub.c).\n"
    "\t */\n"
    "\tif (d->speed == 1 && n >= 8 && buf[7] == 64) {\n"
    '\t\tmsg("Xiaomi/MIUI: low speed reported for a device whose ep0 "\n'
    '\t\t    "maxpacket is 64; telling the guest it is full speed");\n'
    "\t\td->speed = 2;\n"
    "\t}\n"
)

def _joined_literals(source):
    """The C string literals in source, concatenated the way the compiler does."""
    parts = re.findall(r'"((?:[^"\\]|\\.)*)"', source)
    return "".join(p.replace('\\"', '"') for p in parts)


# Every engine, and the shape each one's source has. A patch is a list of
# variants because the same fix has to land in kernel versions whose ep0 check
# was written differently; the first variant that matches uniquely is the one
# used, and a source that matches none of them stops the build.
PATCHES = {
    "kernel-hub": (
        "the guest kernel's ep0 maxpacket check (drivers/usb/core/hub.c)",
        [(HUB_OLD, HUB_NEW), (HUB_LEGACY_OLD, HUB_LEGACY_NEW)],
    ),
    "qemu-host-libusb": (
        "QEMU's host-libusb completion handler (hw/usb/host-libusb.c)",
        [(QEMU_OLD, QEMU_NEW)],
    ),
    "umusb": (
        "the USB/IP server's speed announcement (harness/umusb.c)",
        [(UMUSB_OLD, UMUSB_NEW)],
    ),
}

# Fails at import, i.e. before any build starts, if a patch no longer carries
# the marker its engine is verified with.
for _name, (_what, _variants) in PATCHES.items():
    for _old, _new in _variants:
        assert MARKERS[_name] in _joined_literals(_new), (
            f"MARKERS[{_name!r}] is not in the patched text — the marker and "
            f"the patch have drifted apart, so the build check would look for "
            f"a string the binary cannot contain")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("patch", choices=sorted(PATCHES))
    ap.add_argument("file", nargs="?", help="the source file to patch")
    ap.add_argument("--marker", action="store_true",
                    help="print the string the patched binary is checked for")
    ap.add_argument("--check", action="store_true",
                    help="only report whether the fix is present (0 = present)")
    ap.add_argument("--dry-run", action="store_true",
                    help="say what would change and write nothing")
    args = ap.parse_args()

    what, variants = PATCHES[args.patch]

    if args.marker:
        print(MARKERS[args.patch])
        return 0

    if not args.file:
        print("usb-quirks: give a file to patch, or --marker to print the "
              "string the patched binary is checked for", file=sys.stderr)
        return 2

    try:
        with open(args.file, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        print(f"usb-quirks: cannot read {args.file}: {exc}", file=sys.stderr)
        return 2

    applied = [v for v in variants if v[1] in text]
    if applied:
        print(f"usb-quirks: {args.patch}: already applied to {args.file}")
        return 0

    if args.check:
        print(f"usb-quirks: {args.patch}: NOT applied to {args.file} — "
              f"expected {what}", file=sys.stderr)
        return 1

    found = [(o, n) for o, n in variants if text.count(o) == 1]
    if not found:
        counts = ", ".join(str(text.count(o)) for o, _ in variants)
        print(f"usb-quirks: {args.patch}: none of the {len(variants)} known "
              f"shapes of the text to replace is in {args.file} exactly once "
              f"(found {counts}). {what} has changed shape — patch it by hand "
              f"and add that shape to this script rather than shipping a "
              f"binary without the Xiaomi/MIUI fix.", file=sys.stderr)
        return 2

    old, new = found[0]
    patched = text.replace(old, new, 1)
    if args.dry_run:
        print(f"usb-quirks: {args.patch}: would patch {args.file} ({what})")
        return 0

    with open(args.file, "w", encoding="utf-8") as fh:
        fh.write(patched)
    variant = variants.index((old, new)) + 1
    shape = f" (shape {variant} of {len(variants)})" if len(variants) > 1 else ""
    print(f"usb-quirks: {args.patch}: patched {args.file}{shape} ({what})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
