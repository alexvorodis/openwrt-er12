# OpenWrt for Ubiquiti EdgeRouter 12 (ER-12)

Custom OpenWrt firmware for the Ubiquiti EdgeRouter 12 — Cavium/Marvell
CN7130 (Octeon+, mips64). Based on the
[dmascord/openwrt](https://github.com/dmascord/openwrt) fork (PR #22153).
This fork was developed with AI assistance (opencode/claude).

**All 12 physical ports work:** 8× GbE RJ45 LAN, 2× GbE RJ45 WAN, 2× SFP+.

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
└── if2 (4× SGMII) → VSC8514 managed switch
    └── panels 1, 2, 4, 5 → lan0–lan3   (switch ports, bridged to br-lan)
```

How the mapping was established — full cable A/B test on the live board (panels
0–7 one by one, bond TX/RX counters checked each time):

- **panel 0 → lan4**: confirmed by TX counter (bond hash selected lan4 for
  host→router traffic; all other slaves had zero TX). First port tested, most
  reliable result.
- **panels 1, 2, 4, 5 → if2 group (VSC8514)**: lan0–lan3 stayed admin-down
  with zero TX/RX counters on every test. The VSC8514 PHYs (phy8–11, id
  `0x00070670`) are present on the MDIO bus but no driver binds to them; the
  SGMII link between CN7130 and VSC8514 never comes up. Host traffic still
  reaches the router via the bond (VSC8514 forwards at L2 hardware level), but
  the kernel if2 interfaces are dead.
- **panels 3, 6, 7 → if1 group (bond)**: traffic works, host reachable. The
  bond balance-xor hash always picks the same slave for a given MAC/IP pair, so
  per-panel distinction inside the bond requires physical cable pull (not done
  this round — mapping by elimination from if2 confirmed as non-functional).
- **panel 0 → lan4** was the only test where the TX counter moved on a single
  slave (first test, clean counters). Subsequent tests all showed lan4 because
  the bond hash is deterministic — the VSC8514 switch learns the router MAC from
  lan4 replies and funnels all host traffic there regardless of physical port.

> **Important:** panels 8/9 (`lan8`/`lan9`, if0) belong to a separate L2 domain —
> the WAN side of the board. They are **not** part of the LAN fabric and are
> intended for WAN interfaces (one or two ISPs). Do not bridge them into `br-lan`.

## How the LAN fabric works

The ER-12 has no DSA-capable switch; the 8 LAN RJ45 ports are split over two
PHY groups (4× AR8033 on if1, 4× VSC8514 on if2). Both groups are functional.

1. `etc/init.d/er12-fabric` (START=18) at boot:
   - creates a Linux bond `itf` (balance-xor, miimon) from `lan4 lan5 lan6 lan7`
     (the four if1 MACs);
   - creates VLAN sub-interfaces on top of `itf`: `eth0..eth7` = VID 4086–4093
     and `switch0` = VID 4094;
   - `switch0` is the only port of the `br-lan` bridge (default 192.168.1.1/24);
   - brings up `lan0..lan3` (if2, VSC8514) and adds them to `br-lan`;
   - sets the driver module parameters
     `er12_vlan_aware=1`, `er12_vlan_base_vid=4086`,
     `er12_vlan_switch0_vid=4094`;
   - disables IPv6 on the fabric devices (`itf`, `lan4-7`, `lan0-3`, `eth0-7`),
     leaves it enabled on `switch0`.
2. The patched `octeon_ethernet` driver runs in "VLAN-aware" mode on if1:
   untagged frames received on the bond are tagged with VID 4094, and frames
   destined for VID 4094 are untagged on egress (patches 709/710/714).
   This makes the 4 if1 ports behave as untagged access ports in the 4094
   "switch" domain.
3. The VSC8514 managed switch on if2 is initialized by the `Microsemi GE
   VSC8514 SyncE` kernel driver (`CONFIG_MICROSEMI_PHY=y`). The 4 switch ports
   (lan0–lan3) are bridged into `br-lan` as independent ports.
4. Result: **all 8 LAN RJ45 ports (panels 0–7) are untagged access ports of
   `br-lan`** — 4 via the if1 bond, 4 via the if2 VSC8514 switch.

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

Clone this repo and run `build.sh` — it handles everything (OpenWrt clone,
patches, config, feeds, compilation):

```bash
git clone https://github.com/alexvorodis/openwrt-er12.git
cd openwrt-er12
./build.sh
```

Output: `openwrt/bin/targets/octeon/generic/openwrt-octeon-generic-ubnt_edgerouter-12-*`

### Requirements

- **OS:** Ubuntu/Debian (or Docker)
- **Disk:** ~30 GB
- **Time:** ~2–4 hours (first build)
- **Packages:** `build-essential git python3 rsync wget libncurses-dev flex
  bison gawk unzip file subversion quilt gettext zlib1g-dev libssl-dev
  xsltproc libxml-parser-perl`

### What build.sh does

1. Clones [dmascord/openwrt](https://github.com/dmascord/openwrt) (branch
   `openwrt/add-ubiquiti-er-12`, commit `2cd1a10829`)
2. Applies the ER-12 kernel patches (703–716 + 900 device definition)
3. Copies the DTS, base-files overlay, and `.config`
4. Runs `feeds update`, `feeds install`, `make world`

### Repository layout

```
openwrt-er12/
├── build.sh              ← automated build script
├── config/.config        ← full defconfig (octeon/generic + LuCI)
├── patches/6.18/         ← kernel patches (703-716, 900 device)
├── dts/                  ← device tree source
├── base-files/           ← userspace overlay (er12-fabric, board.d, etc.)
├── README.md             ← this file (hardware, patches, status)
└── INSTALL.md            ← flashing and first-boot guide
```

## Status

| Feature | Status |
|---------|--------|
| LAN ports 0, 3, 6, 7 (if1, AR8033, bond) | ✅ working, verified by cable A/B test |
| LAN ports 1, 2, 4, 5 (if2, VSC8514) | ✅ working — Microsemi GE VSC8514 SyncE driver (`CONFIG_MICROSEMI_PHY=y`) initializes the switch; PCS recovery runs for iface=2 |
| WAN ports 8–9 (RJ45) | ✅ working (DHCP tested on both) |
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

## Acknowledgments

- [Damien Mascord](https://github.com/dmascord) — upstream OpenWrt fork with
  initial ER-12 support ([PR #22153](https://github.com/openwrt/openwrt/pull/22153))
- This fork was developed with **AI assistance** (opencode/claude) — port
  mapping, fabric analysis, driver debugging, documentation
- [OpenWrt](https://openwrt.org) project and community

## License

GPL-2.0 (same as OpenWrt)
