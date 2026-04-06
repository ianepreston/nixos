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

**The B650M C V3-Y1 motherboard with IT5701 firmware V4.0.39.2 does not respond to standard RGB Fusion 2 USB protocol commands.**

Both OpenRGB and liquidctl can:
- Detect the device correctly
- Send HID feature reports successfully
- Receive firmware version information

But the LEDs never change. This is likely one of:
1. **Firmware incompatibility** - V4.0.39.2 may use a different protocol
2. **Hardware issue** - The RGB controller may be malfunctioning
3. **BIOS setting** - RGB control may need to be enabled in BIOS

## Next Steps

1. ~~**Check HID access**~~: DONE - User has read/write access via ACLs
2. ~~**Trace actual HID communication**~~: DONE - strace shows HIDIOCSFEATURE calls succeed
3. ~~**Try liquidctl as root**~~: DONE - Commands succeed but LEDs don't change
4. ~~**Try all LED channels**~~: DONE - led1/led2 valid but no effect
5. **Check BIOS for RGB settings**: Look for RGB Fusion or LED control options
6. **Check if RGB Fusion 2 works on Windows**: Determine if it's Linux-specific
7. **Research IT5701 firmware V4.0.39.2**: This specific version may have known issues
8. **File bug report with liquidctl/OpenRGB**: Include firmware version and board model

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
- [GitLab #4094: B650 Aorus Elite AX not working](https://gitlab.com/CalcProgrammer1/OpenRGB/-/issues/4094)
- [GitLab #962: RGBFusion2USB calibration save instruction](https://gitlab.com/CalcProgrammer1/OpenRGB/-/issues/962)
- [liquidctl #127: RGB Fusion 2 driver - USB control endpoint details](https://github.com/liquidctl/liquidctl/issues/127)
- [Tom's Hardware: IT5701/IT5702 firmware bricking](https://www.tomshardware.com/pc-components/motherboards/gigabytes-latest-rgb-firmware-upgrade-is-bricking-some-motherboards-including-z790-series)
