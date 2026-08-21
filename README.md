# OpenWrt for Ubiquiti EdgeRouter 12 (ER-12)

Custom OpenWrt firmware for the Ubiquiti EdgeRouter 12 — Cavium/Marvell
CN7130 (Octeon+, mips64). All 12 physical ports work: 8× GbE RJ45 LAN,
2× GbE RJ45 on the WAN side, 2× SFP+.

- Base: OpenWrt master (`r34604`), target `octeon/generic`
- Kernel: 6.18.31, toolchain mips64 octeonplus
- Package manager: apk (`.apk` packages)
- Web UI: LuCI 26.x (ucode-based)
- U-Boot: **not rebuilt** — the vendor U-Boot on eMMC is kept as-is

Images are produced as:

```
openwrt-octeon-generic-ubnt_edgerouter-12-initramfs-kernel.bin   (~34 MB)
openwrt-octeon-generic-ubnt_edgerouter-12-squashfs-sysupgrade.tar (~19 MB)
```

## Hardware

| Component | Value |
|-----------|-------|
| SoC | Cavium/Marvell CN7130 (Octeon+), mips64 |
| RJ45 ports | 10× GbE (panel labels 0–9) |
| SFP+ ports | 2× (panel labels 10, 11) |
| Serial console | front-panel RJ45, 115200 8N1 |
| Storage | eMMC (vendor U-Boot + kernel/rootfs), USB 3.0 |

## Port layout

The panel labels and the kernel interface names are **not** the same, and the
ports are distributed over three SoC Ethernet interfaces with different PHYs:

```
CN7130
├── if0 (10G SerDes) → VSC8504
│   ├── panel 8  → lan8    RJ45, WAN side
│   ├── panel 9  → lan9    RJ45, WAN side
│   ├── panel 10 → lan10   SFP+
│   └── panel 11 → lan11   SFP+
│
├── if1 (4× SGMII) → 4× AR8033
│   └── panels 0, 3, 6, 7 → lan4–lan7   (bond members, see fabric below)
│
└── if2 (4× SGMII) → VSC8514
    └── panels 1, 2, 4, 5 → lan0–lan3   (LAN access ports)
```

How the mapping was established (cable A/B tests on the real board):

- panel 1 → `lan1`: unplugging the cable drops exactly `lan1`, plugging brings it up
- panels 3, 6, 7 → if1 group: LED lights, traffic works, but the kernel shows no
  individual link state (they are bond members — carrier is always 1)
- panel 0 → if1 group: with a host on panel 0 the whole LAN works while all of
  `lan0–lan3` stay admin-down in the kernel, so the cable must sit on one of the
  four if1 (bond) MACs
- panels 2, 4, 5 → the remaining three if2 ports (by elimination)

The exact order *inside* each 4-port group is unknown and functionally
irrelevant (the if1 group is a bond, the if2 ports are symmetric access ports).

> **Important:** panels 8/9 (`lan8`/`lan9`, if0) belong to a separate L2 domain —
> the WAN side of the board. They are **not** part of the LAN fabric and are
> intended for WAN interfaces (one or two ISPs). Do not bridge them into `br-lan`.

## How the LAN fabric works

The ER-12 has no DSA-capable switch; the 8 LAN RJ45 ports are split over two
PHY groups (4× AR8033 on if1, 4× VSC8514 on if2). The firmware emulates the
stock EdgeOS fabric so that all 8 ports form a single untagged broadcast domain:

1. `etc/init.d/er12-fabric` (START=18) at boot:
   - creates a Linux bond `itf` (balance-xor, miimon) from `lan4 lan5 lan6 lan7`
     (the four if1 MACs);
   - creates VLAN sub-interfaces on top of `itf`: `eth0..eth7` = VID 4086–4093
     and `switch0` = VID 4094;
   - `switch0` is the only port of the `br-lan` bridge (default 192.168.1.1/24);
   - sets the driver module parameters
     `er12_vlan_aware=1`, `er12_vlan_base_vid=4086`,
     `er12_vlan_switch0_vid=4094`;
   - disables IPv6 on the fabric devices (`itf`, `lan4-7`, `lan0-3`, `eth0-7`),
     leaves it enabled on `switch0`.
2. The patched `octeon_ethernet` driver runs in "VLAN-aware" mode on if1:
   untagged frames received on the bond are tagged with VID 4094, and frames
   destined for VID 4094 are untagged on egress (patches 709/710/714).
   This makes the 4 if1 ports behave as untagged access ports in the 4094
   "switch" domain, exactly like the 4 if2 access ports, which are switched
   into the same domain by the CN7130 hardware fabric.
3. Result: **all eight RJ45 ports (panels 0–7) are untagged access ports of
   `br-lan`**.

## Kernel patches

All patches live in `target/linux/octeon/patches-6.18/` of the build fork:

| Patch | Purpose |
|-------|---------|
| 700-allocate_interface_by_label | netdev labels from DTS (`lan0`…`lan11`) |
| 701-honor_sgmii_node_device_tree_status | respect `status="disabled"` on SGMII nodes |
| 702-qca833x-force-pcs-reset | force PCS reset for QCA SGMII parts (backport from U-Boot) |
| 703-ubnt-e300-if2-sgmii | ER-12 wires interface 2 via SGMII, not NPI |
| 704-ubnt-e300-qca8511-forcelink | DT property `cavium,force-link-up` for switch-backed ports |
| 705-ubnt-e300-dt-pcs-reset-on-open | PCS reset when the MDIO device is opened |
| 706-ubnt-e300-pcs-recovery-linkup | PCS recovery / link-up handling |
| 707-ubnt-e300-if2-reset-timeout-recovery | reset-timeout recovery for the if1/if2 switch path |
| 708-ubnt-e300-honor-force-link-up-in-adjust-link | honour `force-link-up` in `adjust_link` |
| 709-ubnt-e300-er12-vlan-switch0-rx-tagging | RX on if1: untagged → tag VID 4094 |
| 710-ubnt-e300-er12-vlan-switch0-tx-untagging | TX on if1: pop VID 4094 on egress |
| 714-ubnt-e300-er12-switch0-pop-single-tag | pop the tag even for single-tagged frames |
| 715-ubnt-e300-er12-early-fixed-link-before-deprecated-warn | stable fixed 1G/full link state on if1 |
| 716-ubnt-e300-er12-drop-switch0-reflected-self-src | drop frames reflected back by switch0 with our own MAC as source |

Note: the upstream pull request also contained four **empty** patches
(711, 712, 713, 999_add_npi_for_cn7xxxx) — they break patch application and were
removed.

## Userspace additions (`target/linux/octeon/base-files`)

| File | Purpose |
|------|---------|
| `etc/init.d/er12-fabric` | sets up the stock-style fabric described above |
| `etc/board.d/01_network` | first boot: LAN = `br-lan`/`switch0`. **WAN is deliberately not preconfigured** — configure it for your own upstream |
| `etc/uci-defaults/99-luci-ucode` | LuCI 26.x needs the uhttpd ucode prefix (`/cgi-bin/luci=/usr/share/ucode/luci/uhttpd.uc`); `luci-base` postinst is skipped during image builds, so it is applied on first boot instead |

## Building

The build tree is a fork of `openwrt/openwrt` (master) with the `octeon`
target changes committed on top. Standard OpenWrt flow:

```bash
./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig     # target: octeon/generic, + LuCI, your packages
make -j$(nproc) world
# → bin/targets/octeon/generic/openwrt-octeon-generic-ubnt_edgerouter-12-*
```

Requirements: Ubuntu/Debian (or Docker), ~30 GB disk, 2–4 h build time.
Dependencies: `build-essential git python3 rsync wget libncurses-dev flex
bison gawk unzip file subversion quilt gettext zlib1g-dev libssl-dev
xsltproc libxml-parser-perl`.

## Status

| Feature | Status |
|---------|--------|
| LAN ports 0–7 (8× RJ45) | ✅ working, 0% loss (A/B tested port by port) |
| WAN ports 8–9 (RJ45) | ✅ working (DHCP tested on port 8; port 9 = second WAN slot) |
| SFP 10–11 | ⚠️ defined in DTS, untested (no transceivers available) |
| LuCI (web UI) | ✅ working |
| Serial console (115200) | ✅ working |
| USB 3.0 | ✅ working |
| LEDs | ⚠️ power only, port LEDs not driven |
| Reset button | ⚠️ untested |

## Known limitations

- WAN is not preconfigured on purpose (different upstreams per deployment).
- Ports 8/9 are on the WAN-side L2 domain; bridging them into `br-lan` causes
  ~20% random frame loss (the fabric does not mix the two domains).
- IPv6 is disabled on the fabric interfaces by the fabric script (kept on
  `switch0`/`br-lan`).
- Port/SFP LEDs and the reset button are not wired into the kernel yet.

## References

- [openwrt/openwrt PR #22153](https://github.com/openwrt/openwrt/pull/22153) — initial ER-12 support (base for this work)
- [OpenWrt forum: Support possible for the new Ubiquiti EdgeRouter 12?](https://forum.openwrt.org/t/support-possible-for-the-new-ubiquiti-edgerouter-12/32982)
- [OpenWrt Octeon target](https://openwrt.org/docs/techref/targets/octeon)

## License

GPL-2.0 (same as OpenWrt)
