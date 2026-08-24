#!/bin/sh
# mii_watch.sh v2 — poll BMSR bit2 (0x0004) properly
LOG=/tmp/mii_map.log
: > $LOG
prev=""
i=0
while [ $i -lt 3000 ]; do
  now=""
  for p in 00 01 02 03 04 05 06 07 08 09 0a 0b; do
    v=$(/tmp/mii_rd lan9 0x$p 1 | sed "s/^0x//")
    l=$(( 0x$v & 4 ))
    if [ "$l" != "0" ]; then
      now="${now}${p}=1 "
    else
      now="${now}${p}=0 "
    fi
  done
  if [ "$now" != "$prev" ]; then
    echo "$(date +%H:%M:%S) $now" >> $LOG
    prev="$now"
  fi
  i=$((i+1))
done
