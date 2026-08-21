# EdgeRouter 12 — OpenWrt Installation Guide

Flashing OpenWrt onto the Ubiquiti EdgeRouter 12 (ER-12). The router keeps its
vendor U-Boot on eMMC; only the kernel + rootfs (the OpenWrt image) are
replaced.

## What you need

| Item | Notes |
|------|-------|
| ER-12 | powered, reachable over serial |
| Serial console cable | RJ45 (front panel CONSOLE port) → USB |
| USB flash drive | ≥ 256 MB, FAT32 |
| Terminal app | minicom / PuTTY / screen — **115200 8N1**, no flow control |
| The two images | see below |

Images (from a build of this project, or from a maintainer):

```
openwrt-octeon-generic-ubnt_edgerouter-12-initramfs-kernel.bin   (~34 MB)
openwrt-octeon-generic-ubnt_edgerouter-12-squashfs-sysupgrade.tar (~19 MB)
```

### Connect the serial console

```bash
# find the port
ls /dev/ttyUSB*
# user must be in the dialout group:  sudo usermod -aG dialout $USER  (re-login)
sudo minicom -D /dev/ttyUSB0 -b 115200
```

## Method 1: initial install from stock EdgeOS (U-Boot + USB)

### Step 1 — prepare the USB stick

Format the USB stick as FAT32 and copy both images (**wipes all data**):

```bash
sudo umount /dev/sdX*
sudo mkfs.vfat -F 32 /dev/sdX1
sudo mount /dev/sdX1 /mnt/usb
sudo cp openwrt-octeon-generic-ubnt_edgerouter-12-initramfs-kernel.bin \
        openwrt-octeon-generic-ubnt_edgerouter-12-squashfs-sysupgrade.tar /mnt/usb/
sudo umount /mnt/usb
```

### Step 2 — interrupt U-Boot

1. Insert the USB stick into the router.
2. Power-cycle the router and watch the serial console.
3. Press any key during the short autoboot countdown to stop it. You should
   get the U-Boot prompt:

   ```
   Octeon ubnt_e300(ram)#
   ```

   If you miss the window, power-cycle again. (After OpenWrt is installed the
   U-Boot env may have `bootdelay=0` — in that case use Method 2 to upgrade.)

### Step 3 — boot the initramfs from USB

```
Octeon ubnt_e300(ram)# usb start
Octeon ubnt_e300(ram)# fatload usb 0:1 0x20000000 openwrt-octeon-generic-ubnt_edgerouter-12-initramfs-kernel.bin
Octeon ubnt_e300(ram)# bootoctlinux 0 numcores=1 endbootargs mem=0
```

> **`fatload` takes ~2–3 minutes** for the ~34 MB image over USB. This is
> normal — do not press any keys, do not power-cycle, just wait.
> Do not press Enter during the Linux boot either; it only produces extra
> console noise.

You will boot into a temporary OpenWrt (initramfs) with a `root@OpenWrt:~#`
prompt.

### Step 4 — flash the sysupgrade image

```sh
root@OpenWrt:~# mkdir -p /tmp/sda
root@OpenWrt:~# mount /dev/sda1 /tmp/sda
root@OpenWrt:~# sysupgrade /tmp/sda/openwrt-octeon-generic-ubnt_edgerouter-12-squashfs-sysupgrade.tar
```

The router reboots automatically into the new system (eMMC). The first boot
takes another couple of minutes (watch it on serial if you like).

## Method 2: upgrade between OpenWrt versions (no U-Boot needed)

If OpenWrt is already running, just sysupgrade:

1. Copy the new `...-squashfs-sysupgrade.tar` to the router (SCP/USB/HTTP) or
   mount the USB stick.
2. On the router:

   ```sh
   sysupgrade /path/to/openwrt-octeon-generic-ubnt_edgerouter-12-squashfs-sysupgrade.tar
   ```

3. Wait for the automatic reboot.

## Recovery (bricked / unbootable router)

1. Connect serial console + USB stick with the **initramfs** image.
2. Power-cycle, stop U-Boot (any key), then the Step 3 commands above.
3. You are back in a working temporary system — flash again (Step 4), or
   `firstboot -y && reboot` to wipe to defaults.

## Returning to stock EdgeOS

1. Download the ER-12 recovery image from
   <https://www.ui.com/download/edgemax/edgerouter-12>.
2. In U-Boot (see Method 1, Step 2), serve the file via TFTP:

   ```
   setenv ipaddr 192.168.1.1
   setenv serverip 192.168.1.2
   tftpboot 0x20000000 <recovery-file>
   bootoctlinux 0 numcores=1 endbootargs mem=0
   ```

3. Follow Ubiquiti's instructions to write the stock image back to eMMC.

## First boot / configuration

1. Connect a PC to a working LAN port (**panel 0, 3, 6, or 7**), IP 192.168.1.2/24.
2. Open `http://192.168.1.1` (LuCI) or `ssh root@192.168.1.1`.
   Default credentials: **root / (empty password)** — LuCI will ask you to set
   a password.
3. **Configure your WAN** — it is deliberately not preconfigured. Typical
   static example for interface `lan8` (panel 8):

   ```
   uci set network.wan='interface'
   uci set network.wan.device='lan8'
   uci set network.wan.proto='static'
   uci add_list network.wan.ipaddr='192.168.35.122/24'
   uci set network.wan.gateway='192.168.35.1'
   uci commit network
   ifup wan
   ```

   …or use DHCP in LuCI. A second WAN (second ISP) can use `lan9` (panel 9).
   Both fit the existing `wan` firewall zone.
4. Verify the fabric (all 8 LAN ports, bond `itf`, `switch0` in `br-lan`):

   ```sh
   ip -br link show
   cat /proc/net/bonding/itf
   /etc/init.d/er12-fabric status
   ```

### Port quick reference

```
panels 0,3,6,7 → LAN  (br-lan, 192.168.1.1/24, untagged, bond itf)
panels 1,2,4,5 → LAN  (NOT WORKING — VSC8514 driver missing)
panels 8-9     → WAN  (configure as WAN interfaces)
panels 10-11   → SFP+ (configure as needed)
```

## Troubleshooting

| Symptom | What to do |
|---------|-----------|
| Nothing on serial | Check 115200 8N1, cable, `dialout` group; try another port |
| U-Boot prompt not reachable | Missed the autoboot window — power-cycle again and press keys faster; on a running OpenWrt system use Method 2 instead |
| `fatload` seems stuck | Normal: ~2–3 min for the initramfs. Do not interrupt |
| Router boots but no LAN | Check `/etc/init.d/er12-fabric status` and `dmesg \| grep -iE "bond\|vlan\|lan"`; run `/etc/init.d/er12-fabric start` |
| No internet, LAN works | WAN interface not configured / wrong upstream; check `ifstatus wan`, `ip route`, cable on panel 8/9 |
| LuCI unreachable | `netstat -tlnp \| grep :80`; `/etc/init.d/uhttpd restart`; check the firewall zone |
| Need a clean state | `firstboot -y && reboot` |

## References

- [OpenWrt Octeon target](https://openwrt.org/docs/techref/targets/octeon)
- [openwrt/openwrt PR #22153](https://github.com/openwrt/openwrt/pull/22153)
- [Forum thread](https://forum.openwrt.org/t/support-possible-for-the-new-ubiquiti-edgerouter-12/32982)
