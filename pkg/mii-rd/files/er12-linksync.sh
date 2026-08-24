#!/bin/sh
# er12-linksync — per-port link sync for Ubiquiti EdgeRouter 12
#
# Polls the BMSR link bit of every panel-port PHY over MDIO and keeps
# the admin state of the matching OpenWrt netdev in sync:
#   link up   -> ip link set <dev> up
#   link down -> ip link set <dev> down (unless KEEPUP)
#
# Port -> MDIO address map verified live 2026-08-24 (PORT_PHY_MAP.md):
#   npi0..npi3 = phy 08..0b (VSC8514, panels 4-7)
#   eth8        = phy 06     (panel 8)
#   eth9        = phy 07     (panel 9)
#   eth10       = phy 04     (SFP+ #1, panel 10)
#   eth11       = phy 05     (SFP+ #2, panel 11)
#
# NOTE: a PHY whose netdev is admin-down gets put into power-down by
# phylib and never reports link. So before trusting BMSR we clear the
# BMCR power-down bit via the netdev itself (SIOCSMIIREG through the
# generic phy ioctl of the MDIO host phydev works for any MDIO address).

PROG=/usr/sbin/mii_rd
HOST_DEV=eth9

# Standalone netdevs (panel ports with own PHY), stock EdgeOS naming:
#   eth8/eth9  = panels 8/9 (RJ45 WAN)
#   eth10/11   = SFP+ slots
#   itf0..itf3 = bond trunks (panels n/a)
#   npi0..npi3 = VSC8514 (panels 4-7, unused in stock)
MAP="npi0:0x08 npi1:0x09 npi2:0x0a npi3:0x0b eth8:0x06 eth9:0x07 eth10:0x04 eth11:0x05"

# QCA8511 internal PHYs behind the switch -> per-port VLAN devs eth0..eth3
# (panels 0-3 only; panels 4-7 are the npi ports above)
SMAP="eth0:0x00 eth1:0x01 eth2:0x02 eth3:0x03"

poll_ms() {
	config_get v general poll_ms 1000
	case "$v" in *[!0-9]*|"") echo 1000;; *) [ "$v" -lt 200 ] && echo 200 || echo "$v";; esac
}

append_keepup() {
	KEEPUP="$KEEPUP $1"
}

load_config() {
	local enabled
	config_get enabled general enabled 1
	[ "$enabled" = "1" ] || exit 0
	KEEPUP=""
	config_list_foreach general keepup append_keepup
	KEEPUP="${KEEPUP:-eth9}"
}

hexval() {
	n=${1##*[!0-9a-fA-F]}
	[ -z "$n" ] && n=0
	echo "$n"
}

link_bit() {
	# link_bit <phy_addr> -> 0/1 ; BMSR bit2, majority of 3 reads.
	# First read discards the IEEE latched-low status, then vote 2-of-3
	# so a marginal/flapping link does not bounce the admin state.
	local p=$1 u=0 i n v
	$PROG "$HOST_DEV" "$p" 1 >/dev/null 2>&1 || true
	for i in 1 2 3; do
		v=$($PROG "$HOST_DEV" "$p" 1 2>/dev/null) || continue
		n=$(hexval "$v")
		[ $(( 0x$n & 4 )) -ne 0 ] && u=$((u + 1))
	done
	[ $u -ge 2 ] && echo 1 || echo 0
}

assign_eth_macs() {
	# Stock EdgeOS gives eth0..eth7 unique MACs: itf + 1 .. itf + 8.
	# Reproduce that (itf itself is base+4).
	local b o1 o2 o3 o4 o5 o6 v i m
	b=$(cat /sys/class/net/itf/address 2>/dev/null) || return 0
	o1=${b%%:*}; b=${b#*:}
	o2=${b%%:*}; b=${b#*:}
	o3=${b%%:*}; b=${b#*:}
	o4=${b%%:*}; b=${b#*:}
	o5=${b%%:*}; o6=${b#*:}
	v=$(printf "%d" "0x$o6") || return 0
	i=0
	while [ $i -lt 8 ]; do
		m=$(printf "%s:%s:%s:%s:%s:%02x" "$o1" "$o2" "$o3" "$o4" "$o5" \
			$(( (v + i + 1) % 256 )))
		ip link set dev "eth$i" address "$m" 2>/dev/null
		i=$((i + 1))
	done
	logger -t er12-linksync "eth0-7 MACs assigned (itf+1..+8)"
}

powered_down() {
	# BMCR bit11 — an admin-down netdev's PHY is powered down and mute
	v="$($PROG "$HOST_DEV" "$1" 0 2>/dev/null)" || { echo 0; return; }
	n=$(hexval "$v")
	[ $(( 0x$n & 0x800 )) -ne 0 ] && { echo 1; return; } || echo 0
}

wake_phy() {
	# Clear BMCR power-down on <phy> so it can report link again.
	# Done through the target netdev so phylib re-attaches cleanly:
	# simply bringing the netdev up makes phylib resume the PHY.
	ip link set dev "$1" up 2>/dev/null
}

sync_once() {
	state=""

	for pair in $SMAP $MAP; do
		dev=${pair%%:*}; phy=${pair##*:}
		if [ "$(powered_down "$phy")" = "1" ]; then
			wake_phy "$dev"
			sleep 1
		fi
	done

	for pair in $MAP; do
		dev=${pair%%:*}; phy=${pair##*:}
		l=$(link_bit "$phy")
		if [ "$l" = "1" ]; then
			ip link set dev "$dev" up 2>/dev/null
			state="$state ${dev}=up"
		else
			keep=0
			for k in $KEEPUP; do [ "$k" = "$dev" ] && keep=1; done
			if [ "$keep" = "0" ]; then
				ip link set dev "$dev" down 2>/dev/null
				state="$state ${dev}=down"
			else
				ip link set dev "$dev" up 2>/dev/null
				state="$state ${dev}=up*"
			fi
		fi
	done

	# QCA8511 switch ports: mirror panel link into eth0..eth3 admin state.
	for pair in $SMAP; do
		dev=${pair%%:*}; phy=${pair##*:}
		if [ "$(link_bit "$phy")" = "1" ]; then
			ip link set dev "$dev" up 2>/dev/null
			state="$state ${dev}=up"
		else
			ip link set dev "$dev" down 2>/dev/null
			state="$state ${dev}=down"
		fi
	done

	logger -t er12-linksync "state:$state"
}

start_service() {
	[ -x "$PROG" ] || exit 0
	. /lib/functions.sh
	config_load linksync
	load_config
	INTERVAL=$(poll_ms)

	assign_eth_macs

	logger -t er12-linksync "started (poll=${INTERVAL}ms keepup='$KEEPUP')"

	while :; do
		sync_once >/dev/null 2>&1
		sleep "$((INTERVAL / 100))"
	done
}

start_service
