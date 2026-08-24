#!/bin/sh
# er12-linksync — per-port link sync for Ubiquiti EdgeRouter 12
#
# Polls the BMSR link bit of every panel-port PHY over MDIO and keeps
# the admin state of the matching OpenWrt netdev in sync:
#   link up   -> ip link set <dev> up
#   link down -> ip link set <dev> down (unless KEEPUP)
#
# This reproduces what the stock EdgeOS userspace does: `ip a` shows a
# port as UP only when a cable/module is actually present.
#
# Port -> MDIO address map verified live 2026-08-24 (PORT_PHY_MAP.md):
#   lan0..lan3  = phy 08..0b (VSC8514, panels 4-7)
#   lan8        = phy 06     (panel 8)
#   lan9        = phy 07     (panel 9)
#   lan10       = phy 04     (SFP+ #1, panel 10)
#   lan11       = phy 05     (SFP+ #2, panel 11)
#
# Settings (UCI):
#   linksync.enabled=1      enable daemon (default 1 on ER-12)
#   linksync.poll_ms=1000   poll interval
#   linksync.keepup=<list>  netdevs never forced down (default "lan9")
#                           lan9 must stay up: it hosts the MDIO ioctl.

PROG=/usr/sbin/mii_rd
HOST_DEV=lan9

MAP="lan0:0x08 lan1:0x09 lan2:0x0a lan3:0x0b lan8:0x06 lan9:0x07 lan10:0x04 lan11:0x05"

poll_ms() {
	config_get v general poll_ms 1000
	case "$v" in *[!0-9]*|"") echo 1000;; *) [ "$v" -lt 200 ] && echo 200 || echo "$v";; esac
}

load_config() {
	local enabled
	config_get enabled general enabled 1
	[ "$enabled" = "1" ] || exit 0
	KEEPUP="$(config_get general keepup lan9)"
}

link_bit() {
	# link_bit <phy_addr> -> 0/1 ; reads via HOST_DEV's phydev ioctl
	v="$($PROG "$HOST_DEV" "$1" 1 2>/dev/null)" || { echo 0; return; }
	case "$v" in
		*[048cC]) # low nibble has bit2 set
			n=${v##*0x}
			n=${n#${n%?}}
			case "$n" in 4|5|6|7|c|C|d|D) echo 1;; *) echo 0;; esac
			;;
		*) echo 0 ;;
	esac
}

sync_once() {
	state=""
	for pair in $MAP; do
		dev=${pair%%:*}; phy=${pair##*:}
		l=$(link_bit "$phy")
		cur=$(cat "/sys/class/net/$dev/flags" 2>/dev/null) || cur=""
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
	logger -t er12-linksync "state:$state"
}

start_service() {
	[ -x "$PROG" ] || exit 0
	. /lib/functions.sh
	config_load linksync 2>/dev/null || true
	load_config
	INTERVAL=$(poll_ms)

	echo "$$" > /var/run/er12-linksync.pid
	logger -t er12-linksync "started (poll=${INTERVAL}ms keepup='$KEEPUP')"

	while :; do
		sync_once >/dev/null 2>&1
		sleep "$(awk "BEGIN{printf \"%.2f\", $INTERVAL/1000}")"
	done
}
