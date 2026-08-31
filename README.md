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

The 8 LAN ports (panels 0–7) sit behind a **QCA8511 switch chip** initialized
only by vendor U-Boot. The kernel sees a single PIP interface 1 with 4 SGMII
uplinks from the switch, which are bonded together for redundancy and
throughput.

```
CN7130
├── if0 (QSGMII) → VSC8504 quad PHY (MDIO 4–7)
│   ├── panel 8  → eth8   RJ45, WAN side
│   ├── panel 9  → eth9   RJ45, WAN side
│   ├── panel 10 → eth10  SFP+
│   └── panel 11 → eth11  SFP+
│
├── if1 (QSGMII) → QCA8511 (panels 0–7)
│   └── 4× SGMII uplinks → bond "itf" → VLAN subinterfaces eth0–eth7, switch0
│
└── if2 (QSGMII) → VSC8514 quad PHY (MDIO 8–11)
    └── npi0–npi3 (panels 4–7, kept admin-down like stock EdgeOS)
```

| MDIO addr | PHY id | What it is |
|-----------|--------|------------|
| 0–3 | `0x004dd074` | AR8033 (QCA8511 internal PHYs, panels 0–3) |
| 4–7 | `0x000704c2` | VSC8504 quad PHY, if0 group |
| 8–11 | `0x00070670` | VSC8514 quad PHY, if2 group |

## How the LAN fabric works

The 8 LAN ports are untagged access ports. Traffic from any panel arrives via
the QCA8511 on one of the 4 if1 uplinks, which are bonded as `itf`. VLAN
subinterfaces (`eth0–eth7`, `switch0`) sit on top of the bond, each with a
dedicated VID.

1. **Boot (er12-fabric, START=18):**
   - creates Linux bond `itf` (balance-xor, miimon 100) from `itf0–itf3`
     (the four if1 PIP ports), sets MTU **9000** on bond + slaves;
   - creates VLAN sub-interfaces on `itf`: `eth0–eth7` (VID 4086–4093) and
     `switch0` (VID 4094), MTU **1500**;
   - sets MAC addresses on `eth0–eth7` = itf MAC +1 … +8 (stock naming);
   - keeps `npi0–npi3` (if2, VSC8514) **admin-down** like stock EdgeOS;
   - enables IPv6 link-local (fe80 only, no ULA) on `eth0`, `itf`, `switch0`;
   - LAN interface configured directly on **`eth0`** (192.168.1.1/24, no bridge).

2. **Kernel patches** (vlan-aware fabric on if1):
   - **709 (RX):** untagged frames from QCA8511 are tagged with VID 4086
     (base VID). The kernel's 8021q demux delivers them to `eth0@itf` —
     the LAN device. This is how stock EdgeOS works: the tag determines which
     netdev sees the frame.
   - **710/714 (TX):** frames sent out eth0 are tagged with the correct VID
     by the vlan driver; on egress from if1 the tag is popped (714 handles
     all fabric VIDs 4086–4093 plus 4094).
   - **716:** frames reflected back by the switch with our own MAC as source
     are dropped (prevents "own address" warnings and loops).

3. **Link sync (er12-linksync):** polls the BMSR / ANLPAR of every panel PHY
   over MDIO and mirrors the link state into the admin state of the matching
   netdev:
   - panels 0–3 (QCA8511 AR8033, MDIO 0–3): BMSR link bit, reliable;
   - panels 4–7 (VSC8514, MDIO 8–11): **ANLPAR reg 10** (partner abilities
     present), because BMSR on VSC8514 is pulse-only and not steady-state;
   - panels 8–9 and SFP 10–11: BMSR via vsc8504 / SFP PHY.

4. **Result:** `eth0` receives all LAN traffic via kernel vlan demux;
   `eth1–eth7` are per-panel representors (no data path); `switch0` is the
   fabric catch-all (emergency bridging via `er12-netmode all`).

## Kernel patches

All patches live in `patches/6.18/` and are copied into the build tree by
`build.sh`:

| Patch | Purpose |
|-------|---------|
| 700-allocate_interface_by_label | netdev labels from DTS |
| 701-honor_sgmii_node_device_tree_status | respect `status="disabled"` on SGMII nodes |
| 702-qca833x-force-pcs-reset | force PCS reset for QCA SGMII parts |
| 703-ubnt-e300-if2-sgmii | ER-12 wires interface 2 via SGMII, not NPI |
| 704-ubnt-e300-qca8511-forcelink | DT property `cavium,force-link-up` for switch-backed ports |
| 705-ubnt-e300-dt-pcs-reset-on-open | PCS reset when the MDIO device is opened |
| 706-ubnt-e300-pcs-recovery-linkup | PCS recovery / link-up handling |
| 707-ubnt-e300-if2-reset-timeout-recovery | reset-timeout recovery for the if1/if2 switch path |
| 708-ubnt-e300-honor-force-link-up-in-adjust-link | honour `force-link-up` in `adjust_link` |
| 709-ubnt-e300-er12-vlan-switch0-rx-tagging | **RX:** tag untagged if1 frames with base VID (4086 → eth0) |
| 710-ubnt-e300-er12-vlan-switch0-tx-untagging | TX: pop VID 4094 on egress for switch0 |
| 711-ubnt-er12-vlan-aware-controls | module params: `er12_vlan_{aware,base_vid,switch0_vid}` |
| 714-ubnt-e300-er12-switch0-pop-single-tag | **TX:** pop all fabric VIDs (4086–4093 + 4094) on egress |
| 715-ubnt-e300-er12-early-fixed-link | stable 1G/full link state on if1 |
| 716-ubnt-e300-er12-drop-switch0-reflected-self-src | drop frames with our own MAC as source |

## Userspace additions (`base-files/`)

| File | Purpose |
|------|---------|
| `etc/init.d/er12-fabric` | sets up the LAN fabric: bond itf (MTU 9000), VLAN devs eth0–7 + switch0 (MTU 1500), MAC assignment, IPv6 policy |
| `etc/board.d/01_network` | first boot: LAN = eth0 direct (192.168.1.1/24, no br-lan) |
| `etc/hotplug.d/button/20-reset` | factory reset (≥ 5 s hold), removes board.json for re-detection |
| `usr/sbin/er12-netmode` | switch between `stock` (eth0 LAN), `safe` (same), and `all` (emergency bridge switch0+WAN) |
| `usr/sbin/mii_rd` | MDIO read utility for linksync |
| `etc/config/linksync` + init script | per-port link sync daemon (procd-managed, respawn) |

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
   `openwrt/add-ubiquiti-er-12`)
2. Applies our kernel patches (700–716)
3. Copies the DTS, base-files overlay, and `.config`
4. Runs `feeds update`, `feeds install`, `make world`

### Repository layout

```
openwrt-er12/
├── build.sh              ← automated build script
├── config/.config        ← full defconfig (octeon/generic + LuCI)
├── patches/6.18/         ← kernel patches (700–716)
├── dts/                  ← device tree source
├── base-files/           ← userspace overlay (er12-fabric, board.d, etc.)
├── pkg/mii-rd/           ← MDIO read utility + linksync daemon
├── README.md             ← this file
└── INSTALL.md            ← flashing and first-boot guide
```

## Status

| Feature | Status |
|---------|--------|
| LAN ports 0–7 (QCA8511 → if1 bond) | ✅ all working, verified live |
| WAN ports 8–9 (RJ45) | ✅ working (DHCP tested) |
| SFP 10–11 | ⚠️ DTS-defined, untested (no transceivers available); labels swapped to match stock EdgeOS naming |
| LuCI (web UI) | ✅ working |
| Serial console (115200) | ✅ working |
| USB 3.0 | ✅ working |
| LEDs | ✅ port LEDs work via PHY hardware |
| Reset button | ✅ working (≥ 5 s hold = factory reset) |
| DHCP (odhcpd) | ✅ working on eth0 via kernel vlan demux |

## Known differences from stock EdgeOS

| Item | Stock EdgeOS | Our OpenWrt | Notes |
|------|-------------|-------------|-------|
| LAN interface | eth0@itf (192.168.1.1) | eth0@itf (192.168.1.1) | ✅ byte-for-byte match |
| eth0 MTU | 1500 | 1500 | ✅ |
| itf (bond) MTU | 9000 | 9000 | ✅ |
| eth1–7 state | UP + NO-CARRIER (empty) | DOWN (empty) | We reflect honest admin state; data path unaffected |
| eth8/9 qdisc | noqueue | fq_codel | netifd default, cosmetic |
| imq0 | present (mtu 16000) | absent | IMQ removed from kernel 6.18; QoS only |
| npi0–3 | admin-DOWN, random MAC | admin-DOWN, deterministic MAC | from DTS nvmem, more stable |
| ULA (IPv6) | none on eth0 | none on eth0 | ✅ no ULA, fe80 only |
| br-lan | none on eth0 | none | ✅ removed |

## Acknowledgments

- [Damien Mascord](https://github.com/dmascord) — upstream OpenWrt fork with
  initial ER-12 support ([PR #22153](https://github.com/openwrt/openwrt/pull/22153))
- This fork was developed with **AI assistance** (opencode) — port
  mapping, fabric analysis, driver debugging, documentation
- [OpenWrt](https://openwrt.org) project and community

## License

GPL-2.0 (same as OpenWrt)
