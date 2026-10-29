#!/bin/sh
# udhcpc-script.sh — what a DHCP client does with a lease. busybox udhcpc
# calls it with $1 = deconfig | bound | renew | leasefail | nak and the lease
# in environment variables (ip, mask, router, dns, serverid, lease).
case "$1" in
  deconfig)
    ip addr flush dev "$interface"; ip link set "$interface" up ;;
  bound|renew)
    ip addr flush dev "$interface"
    ip addr add "$ip/$mask" dev "$interface"
    [ -n "$router" ] && ip route replace default via "${router%% *}" dev "$interface"
    echo "lease: $ip/$mask router=$router dns=$dns server=$serverid time=${lease}s" ;;
  leasefail|nak)
    echo "dhcp: $1" ;;
esac
