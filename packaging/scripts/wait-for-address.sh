#!/bin/sh
# Wait for a usable interface address before starting Broadcast Box.
#
# Broadcast Box builds its ICE UDP mux during startup, and pion's
# NewMultiUDPMuxFromPort binds one socket per interface address that exists at
# that instant. It has no wildcard mode: if the interface has no address yet,
# the mux is created with zero listeners and returns no error, and the process
# never re-enumerates. Broadcast Box then serves HTTP normally (the HTTP server
# binds the wildcard when it starts) but holds no UDP port for WebRTC media, so
# every WHIP session is accepted and then dies on ICE. This is easy to hit in an
# LXC that boots with DHCP: the service starts before the lease lands.
#
# A link-local IPv6 address does not count. It would let the mux bind an IPv6
# listening socket while the IPv4 side has no socket at all, which still leaves
# the forwarded UDP port dead.
#
# Set BROADCAST_BOX_ADDRESS_WAIT_SECONDS=0 to skip the wait.
set -eu

TIMEOUT="${BROADCAST_BOX_ADDRESS_WAIT_SECONDS:-60}"
INTERVAL=1

log() {
	echo "broadcast-box wait-for-address: $*" >&2
}

case "$TIMEOUT" in
	''|*[!0-9]*)
		log "invalid BROADCAST_BOX_ADDRESS_WAIT_SECONDS='$TIMEOUT', using 60"
		TIMEOUT=60
		;;
esac

if [ "$TIMEOUT" -eq 0 ]; then
	exit 0
fi

if ! command -v ip >/dev/null 2>&1; then
	log "ip command not found, skipping address wait"
	exit 0
fi

iface="${INTERFACE_FILTER:-}"

# Count usable, non-loopback addresses: any IPv4, plus any non-link-local IPv6.
address_count() {
	if [ -n "$iface" ]; then
		ip -o addr show dev "$iface" 2>/dev/null |
			awk '$3 == "inet" || ($3 == "inet6" && $4 !~ /^fe80:/) { n++ } END { print n + 0 }'
	else
		ip -o addr show 2>/dev/null |
			awk '$2 != "lo" && ($3 == "inet" || ($3 == "inet6" && $4 !~ /^fe80:/)) { n++ } END { print n + 0 }'
	fi
}

elapsed=0
while :; do
	count="$(address_count)"
	if [ "$count" -gt 0 ]; then
		log "found $count usable interface address(es)${iface:+ on $iface} after ${elapsed}s"
		exit 0
	fi

	if [ "$elapsed" -ge "$TIMEOUT" ]; then
		log "no usable interface address after ${TIMEOUT}s; refusing to start the ICE mux with no UDP listener"
		exit 1
	fi

	sleep "$INTERVAL"
	elapsed=$((elapsed + INTERVAL))
done
