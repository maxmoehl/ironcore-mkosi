#!/bin/sh

# This script waits for FRR to assign the routed default IP address to the
# loopback interface and uses it to calculate the prefix to use for inisix for
# it. The approach is quite brittle as it makes a number of assumptions which
# may not hold. The correct solution would be to rely on the information from
# the metadata service. Unfortunately this does no longer once FRR is up as it
# will use the looback address to talk to the metadata service which only
# recognizes the DHCP addresses.

set -eu

get_primary_ip() {
    ip -j address show | \
        jq -r '.[] | select(.ifname == "lo").addr_info[] | select(.family == "inet6" and .scope == "global").local'
}

primary_ip="$(get_primary_ip || true)"
while [ -z "${primary_ip}" ]; do
    sleep 1
    primary_ip="$(get_primary_ip || true)"
done

prefix_base="${primary_ip%::1}"

/usr/local/bin/inisix init prefix "${prefix_base}:1::/80" 96
