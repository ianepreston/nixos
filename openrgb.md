# OpenRGB Motherboard RGB Investigation Log

**IMPORTANT**: This document should be continuously updated as you learn more.
Each session should read this first and append findings before ending.

## Problem
- OpenRGB detects RAM, motherboard, and mouse
- RAM and mouse RGB changes work correctly
- Motherboard RGB changes have no effect

## System Info
- Kernel: Linux 6.19.9-zen1 (NixOS Zen kernel)
- Platform: AMD motherboard (Gigabyte B650M based on IT5701 detection)
- Motherboard RGB controller: IT5701 (detected via HID, NOT SMBus)

## Current State of Investigation

### Key Discovery: Motherboard Uses HID, Not SMBus

The initial theory about SMBus/i2c-nct6775 was **WRONG**.

OpenRGB `--list-devices` output shows the motherboard is detected via:
```
2: B650M C V3-Y1
  Type:           Motherboard
  Description:    IT5701-GIGABYTE V4.0.39.2
  Version:        HID: /dev/hidraw9
  Location:       HID: /dev/hidraw9
  Serial:         0x57010100
  Modes: [Direct] Static Breathing Flashing 'Color Cycle' ...
  Zones: '12V RGB Strips' 'D_LED1 Bottom' 'D_LED2 Top' Motherboard
  LEDs: 'CPU Header' LED_C1/C2 'Back I/O' PCIe
```

The motherboard uses **HID** (`/dev/hidraw9`), not SMBus. The "SMBus" in the description is misleading.

### SMBus is Already Working (But Not Relevant)

dmesg confirms the secondary SMBus IS detected:
```
piix4_smbus 0000:00:14.0: SMBus Host Controller at 0xb00, revision 0
piix4_smbus 0000:00:14.0: Auxiliary SMBus Host Controller at 0xb20
```

I2C buses visible:
```
i2c-1: SMBus PIIX4 adapter port 0 at 0b00   <-- primary (RAM)
i2c-4: SMBus PIIX4 adapter port 1 at 0b20   <-- secondary (already working!)
```

The i2c-nct6775 kernel module is **NOT needed** - the standard piix4 driver already exposes both buses.

### HID Permissions are FINE (Ruled Out)

`/dev/hidraw9` is owned by `root:root` but user has access via ACLs:
```
$ test -r /dev/hidraw9 && test -w /dev/hidraw9 && echo "User has read/write access"
User has read/write access
```

Permissions are NOT the issue.

### Device Numbering (Important!)

When running OpenRGB server vs standalone, device numbering differs. Use `--noautoconnect` for standalone mode:

```
$ openrgb --noautoconnect --list-devices
0: ENE DRAM (RAM stick 1, i2c-2 addr 0x71)
1: ENE DRAM (RAM stick 2, i2c-2 addr 0x73)
2: B650M C V3-Y1 (MOTHERBOARD - HID: /dev/hidraw9)
3: Razer Deathadder Elite (mouse)
```

**Motherboard is device 2, NOT device 1!**

### Current Issue: HID Writes ARE Occurring But No Effect

When running:
```
openrgb --noautoconnect --very-verbose --device 2 --mode static --color FF0000
```

The verbose output shows no write activity, BUT strace reveals HID ioctls ARE being sent:
```
$ sudo strace -f -e trace=ioctl openrgb --noautoconnect --device 2 --mode static --color FF0000
[pid 17122] ioctl(21, HIDIOCSFEATURE(91), 0x7ff2f97fe250) = 91
[pid 17122] ioctl(21, HIDIOCGFEATURE(91), 0x7ff2f97fe2b0) = 91
... (many more HIDIOCSFEATURE calls)
```

**HID commands ARE being sent successfully (return values show success), but they have no effect on the LEDs.**

### HID Device Mapping

```
/dev/hidraw8: HID_NAME=ITE Tech. Inc. GIGABYTE Device
/dev/hidraw9: (no HID_NAME - this is the RGB Fusion 2 USB interface)
```

Interesting: hidraw8 and hidraw9 are both related to the Gigabyte motherboard. OpenRGB uses hidraw9.

### Known Issues

- GitLab Issue #4094: Other users report B650 motherboards won't show up or work in OpenRGB
- Some B650 boards only work with Gigabyte's proprietary RGB Fusion software
- IT5701 firmware may have compatibility issues
- **CONFIRMED: Protocol/firmware issue** - Both OpenRGB and liquidctl can send commands successfully (even as root), but LEDs do not respond. This is NOT a permissions issue.

### IT5701/IT5702 Firmware Bug (CRITICAL)

Tom's Hardware reports Gigabyte RGB firmware updates (IT5701/IT5702) are bricking motherboards:
- Dynamic lighting failures
- RGB malfunctions
- Rogue CPU fan behavior
- Affected boards include Z790 and B650 series

**Note**: The HID ID shows 5702 (`0000048D:00005702`) but OpenRGB detects "IT5701-GIGABYTE V4.0.39.2". This mismatch may indicate firmware issues.

### OpenRGB RGBFusion2USB Calibration Issue (GitLab #962)

OpenRGB doesn't send the "save calibration instruction" that RGB Fusion sends. Workaround:
1. Set colors in OpenRGB
2. Run RGB Fusion and do a calibration on any header
3. This forces the controller to save settings

**However**: Our issue is that colors don't change at all, not just persistence.

### Technical Detail: USB Control Endpoint Required (liquidctl #127)

The RGB Fusion 2 device (ITE 5702) has **no OUT endpoint** in the HID interface. All outgoing messages must go through the USB **CTRL endpoint**, not standard HID writes.

Device has 7 LED channels addressed via tuples:
- IOLED, LED1, PCHLED, PCILED, LED2, DLED1, DLED2

Communication sequence:
1. SET_REPORT: `[0xcc, 0x60]` padded to 0x40 bytes
2. GET_REPORT: control request
3. Response: 0x40 bytes with firmware version

**This may explain why OpenRGB's HID feature reports succeed but have no effect** - they may be going to the wrong endpoint.

### USB Descriptor Confirms No OUT Endpoints

```
$ lsusb -v -d 048d:5702
Interface 0 (hidraw8): bNumEndpoints=1, EP 2 IN (interrupt)
Interface 1 (hidraw9): bNumEndpoints=1, EP IN only

NO OUT ENDPOINTS on either interface!
```

OpenRGB uses HIDIOCSFEATURE (set feature report) which should use control endpoint, but the ioctls return success even if they have no effect. Need to verify OpenRGB is using correct interface and report IDs.

## What Was Tried (And Should Be Reverted)

The following kernel patches were tried but are **NOT the solution**:
```nix
# DON'T USE - wrong approach
boot.kernelPatches = [
  {
    name = "i2c-nct6775";
    patch = null;
    structuredExtraConfig = with lib.kernel; {
      I2C_NCT6775 = yes;  # This config option doesn't exist!
    };
  }
];
boot.kernelModules = [ "i2c-nct6775" ];  # Wrong module
```

Notes:
- `CONFIG_I2C_NCT6775` does not exist in the kernel
- The related option `SENSORS_NCT6775_I2C` is for hwmon sensors, not SMBus
- `nct6775-i2c` module is for temperature/fan monitoring, not RGB

## Current Conclusion

**The B650M C V3-Y1 motherboard with IT5701 firmware V4.0.39.2 does not respond to standard RGB Fusion 2 USB protocol commands *from Linux*.** RGB works correctly in Windows on this same hardware, so the controller, firmware, and BIOS are fine — the gap is on the Linux side.

Both OpenRGB and liquidctl can:
- Detect the device correctly
- Send HID feature reports successfully
- Receive firmware version information

But the LEDs never change. Most likely cause: OpenRGB/liquidctl's RGB Fusion 2 USB driver was written against earlier IT5702 firmware (e.g. `1.0.10.0` per liquidctl's own docs) and doesn't speak the protocol revision shipped on this board. Possible mechanisms:
1. Wrong report ID / wrong interface for HID feature reports on this firmware
2. The IT5702 control-endpoint quirk (see "Technical Detail" above) — OpenRGB's HIDIOCSFEATURE path may not be reaching the control endpoint correctly on this revision
3. A "save/apply" frame that newer firmware now requires and OpenRGB doesn't send

## Next Steps

1. ~~**Check HID access**~~: DONE - User has read/write access via ACLs
2. ~~**Trace actual HID communication**~~: DONE - strace shows HIDIOCSFEATURE calls succeed
3. ~~**Try liquidctl as root**~~: DONE - Commands succeed but LEDs don't change
4. ~~**Try all LED channels**~~: DONE - led1/led2 valid but no effect
5. ~~**Confirm Windows works on this hardware**~~: DONE (2026-05-12) — RGB worked in Windows pre-NixOS install. Rules out brick / BIOS / hardware.
6. **Skip the firmware flash.** 1.0.1.2 exists but Windows already works, so flashing only adds brick risk (also: wrong-chip flash is what bricked boards in 2024).
7. **USB packet capture from a Windows session.** Boot a Windows live USB (or spare drive), capture RGB Fusion 2 traffic to the IT5702 with Wireshark + USBPcap, then replay/compare with what OpenRGB sends on Linux. This is the highest-signal step — gives the protocol delta directly.
8. **Re-test with OpenRGB pipeline build** (post-1.0rc2) before any deeper work — confirms we're not chasing an already-fixed bug. The stable 1.0rc2 release notes don't mention this, but the master branch often has driver tweaks not in tagged releases.
9. **File a focused bug report** with: firmware version string, packet capture diff (from step 7), board model + revision. Existing #4094 is too vague to be useful.
10. **Low-effort distractor to deprioritise**: kernel/zen tweaks. Kernel side is fine — `/dev/hidraw9` exists, ioctls succeed, ACLs work. No more kernel patches.

## Current rgb.nix Configuration

The config has been simplified (kernel patches removed):
```nix
boot.kernelPackages = pkgs.linuxPackages_zen;
boot.kernelModules = [ "i2c-dev" "i2c-piix4" ];
boot.kernelParams = [ "acpi_enforce_resources=lax" ];
users.users.${hostSpec.username}.extraGroups = [ "i2c" ];
```

This is correct for SMBus access, but may need HID group additions.

## Session Notes
- 2026-05-12: **CRITICAL CONFIRMATION** — RGB worked correctly in Windows on this exact board *before* the machine was reinstalled with NixOS. That rules out:
  - Bricked IT5701/IT5702 controller (the Nov 2024 firmware-brick scenario)
  - Dead hardware
  - BIOS RGB-disable setting (would have failed in Windows too)
  This is a **Linux-side problem**, almost certainly in how OpenRGB/liquidctl talk to this specific firmware revision over HID. Working Windows = the protocol *does* work on this board, we're just not speaking it correctly from Linux.
- 2026-05-12: Research pass for new upstream developments since 2026-04-05:
  - **OpenRGB**: latest tagged release is **1.0rc2 (2025-09-14)**. Headline change is PawnIO replacing WinRing0 on Windows — Linux-irrelevant. No changelog entry for IT5701/IT5702/RGB Fusion 2 protocol fixes. GitLab #4094 (B650 support) still unresolved, template never completed.
  - **Gigabyte IT5701/5702 firmware**: a newer **1.0.1.2** package exists (vs the 1.0.0.9 brick-er from Nov 2024). Release notes call out chassis RGB compatibility fixes (Corsair, Cooler Master), RAM RGB compatibility fixes, and **an I2C conflict fix**. The "I2C conflict" item is suggestive but since RGB works in Windows, our installed firmware is not the brick variant — flashing is unnecessary and risky.
  - **Gigabyte BIOS**: no B650M C V3 BIOS changelog entry found that calls out an RGB fix. Most recent published item was an AMD APU driver dated 2026-01-16.
  - **OpenRGB note on the version string**: the `V4.0.39.2` OpenRGB reports is the controller's *internal* firmware version over HID, NOT the same numbering scheme as Gigabyte's `1.0.x.y` packaging. You can't tell from that string which Gigabyte firmware package is installed.
- 2026-04-05: Initial investigation. Found CONFIG_I2C_NCT6775 missing from kernel config. Proposed fix.
- 2026-04-05: **CORRECTION** - Discovered motherboard uses HID (IT5701 via /dev/hidraw9), NOT SMBus. Secondary SMBus already working. Issue likely HID permissions. Session crashed while checking `/dev/hidraw9` access.
- 2026-04-05: **HID Permissions are FINE** - User has read/write access to `/dev/hidraw9` via ACLs. OpenRGB verbose output confirms device detected correctly. OpenRGB has `--very-verbose` flag for debug output. Issue is NOT permissions - need to investigate further.
- 2026-04-05: **Device numbering clarified** - Running server was confusing things. Standalone mode shows motherboard is device 2. Setting color on device 2 exits successfully but NO HID write activity visible in verbose output. GitLab #4094 shows other B650 users with similar problems. Need to investigate why writes aren't happening.
- 2026-04-05: **HID writes ARE happening** - strace shows HIDIOCSFEATURE ioctl calls succeeding. Commands are being sent but LEDs don't change. Also discovered hidraw8="ITE Tech. Inc. GIGABYTE Device" and hidraw9 has no name - both are motherboard-related.
- 2026-04-05: **Key technical finding from liquidctl#127** - RGB Fusion 2 requires USB control endpoint (CTRL) requests, NOT standard HID endpoint transfers. The device "has no OUT endpoint in the HID interface". This may explain why OpenRGB commands have no effect. hidraw9 is on interface 1 (bInterfaceNumber=01).
- 2026-04-05: **liquidctl also fails** - `liquidctl initialize` sends feature report 0xcc but gets "OSError: read error" on get_feature_report. The device doesn't respond to HID feature report reads. This may be firmware-specific behavior.
- 2026-04-05: **BREAKTHROUGH: liquidctl works as ROOT** - `sudo liquidctl --pick 1 initialize` successfully reads firmware version "IT5701-GIGABYTE V4.0.39.2". `sudo liquidctl --pick 1 set led1 color fixed ff0000` sends color commands successfully. Need to verify if LED actually changes. The ACL permissions may not be sufficient for HID feature reports.
- 2026-04-05: **NO LED CHANGES even with liquidctl as root** - Cycled through blue→green→red with liquidctl, commands sent successfully but NO visible LED changes. This confirms the issue is NOT permissions - it's either firmware, wrong LED channel, or protocol incompatibility with this specific board/firmware version.
- 2026-04-05: **Tried all LED channels** - Only `led1` and `led2` are valid for this device (others give KeyError). Neither channel causes visible LED changes. Commands being sent: `0x20`/`0x21` (set channel) + `0x28` (apply). Firmware V4.0.39.2 may not be compatible with standard RGB Fusion 2 protocol.

## References
- [NixOS Discourse: OpenRGB kernel patch with options](https://discourse.nixos.org/t/openrgb-kernel-patch-with-options/40682)
- [Zen Kernel Issue #176: OpenRGB piix4 duplicated](https://github.com/zen-kernel/zen-kernel/issues/176)
- [OpenRGB SMBusAccess.md](https://gitlab.com/CalcProgrammer1/OpenRGB/-/blob/master/Documentation/SMBusAccess.md)
- [OpenRGB Wiki](https://openrgb-wiki.readthedocs.io/)
- [OpenRGB releases](https://openrgb.org/releases.html) — latest tagged 1.0rc2 (2025-09-14)
- [GitLab #4094: B650 Aorus Elite AX not working](https://gitlab.com/CalcProgrammer1/OpenRGB/-/issues/4094)
- [GitLab #962: RGBFusion2USB calibration save instruction](https://gitlab.com/CalcProgrammer1/OpenRGB/-/issues/962)
- [liquidctl #127: RGB Fusion 2 driver - USB control endpoint details](https://github.com/liquidctl/liquidctl/issues/127)
- [liquidctl Gigabyte RGB Fusion 2 guide](https://github.com/liquidctl/liquidctl/blob/main/docs/gigabyte-rgb-fusion2-guide.md) — references ITE 5702 firmware `1.0.10.0`
- [Tom's Hardware: IT5701/IT5702 firmware bricking](https://www.tomshardware.com/pc-components/motherboards/gigabytes-latest-rgb-firmware-upgrade-is-bricking-some-motherboards-including-z790-series)
- [Techspark IT5701/5702 firmware archive (1.0.0.4, 1.0.0.7, 1.0.0.9, 1.0.1.2)](https://www.techspark.de/gigabyte-ite-it5701-5702-firmware-archive/)
