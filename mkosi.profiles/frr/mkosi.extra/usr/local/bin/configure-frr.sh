#!/usr/bin/env bash
# Renders /etc/frr/frr.conf from the frr-template.conf placeholders using
# the metaldata service, and (re)starts frr if the config changed.
#
# Metadata contract (v1): GET http://metaldata.ironcore.dev/v1/ with the
# "Metadata-Flavor: IronCore Metal" header. Only two keys are used:
#   server-name  hostname, e.g. cn-wdf4f-1-system-0
#                (<type>-<zone>-<index>[-<kind>-<instance>])
#   prefix       the node's IPv6 prefix (top-level, not in user-data),
#                announced to the fabric and delegated to VMs by inisix
set -Eeuo pipefail

metadata=$(curl --retry 5 --retry-delay 2 -sf \
    -H 'Metadata-Flavor: IronCore Metal' \
    http://metaldata.ironcore.dev/v1/)

HOSTNAME=$(jq -r '.["server-name"] // empty' <<< "$metadata")
PREFIX=$(jq -r '.prefix // empty' <<< "$metadata")

if [ -z "$HOSTNAME" ]; then
    echo "error: hostname is empty"
    exit 1
elif [ -z "$PREFIX" ]; then
    echo "error: prefix is empty"
    exit 1
fi

# <type>-<zone>-<index>[-<kind>-<instance>], e.g. cn-wdf4f-1-system-0.
# The older short format (cn-wdf4f-1) parses the same way; zone, kind and
# instance do not feed the AS number / router-id derivation.
IFS=- read -r HOST_TYPE HOST_ZONE HOST_IDX _ <<< "$HOSTNAME"
case "$HOST_TYPE" in
    rtr)  typeoff=0 ;;
    mgmt) typeoff=1 ;;
    cn)   typeoff=2 ;;
    sn)   typeoff=3 ;;
    swi1) typeoff=4 ;;
    swi2) typeoff=5 ;;
    swo1) typeoff=6 ;;
    swo2) typeoff=7 ;;
    jn)   typeoff=8 ;;
    ai)   typeoff=9 ;;
    *) echo "error: unknown host type '$HOST_TYPE' in hostname '$HOSTNAME'" >&2; exit 1 ;;
esac

AS_NUMBER=$((4200000000 + typeoff * 1000 + 10#$HOST_IDX))
ROUTER_ID="10.$typeoff.0.$((10#$HOST_IDX))"
LOOPBACK_IP="${PREFIX%%/*}1"

# Fabric-facing NICs: 100G ports that are up.
nics=()
for nic in /sys/class/net/en*; do
    name=$(basename "$nic")
    state=$(cat "$nic/operstate" 2>/dev/null) || continue
    speed=$(cat "$nic/speed" 2>/dev/null) || continue
    if [ "$state" = "up" ] && [ "$speed" = "100000" ]; then
        nics+=("$name")
    fi
done

if [ "${#nics[@]}" -lt 2 ]; then
    echo "error: expected at least 2 NICs, found ${#nics[@]}" >&2
    exit 1
fi

sed \
    -e "s|__HOSTNAME__|$HOSTNAME|g" \
    -e "s|__LOOPBACK_IP__|$LOOPBACK_IP|g" \
    -e "s|__PREFIX__|$PREFIX|g" \
    -e "s|__AS_NUMBER__|$AS_NUMBER|g" \
    -e "s|__ROUTER_ID__|$ROUTER_ID|g" \
    -e "s|__NIC1__|${nics[0]}|g" \
    -e "s|__NIC2__|${nics[1]}|g" \
    /etc/frr/frr-template.conf > /etc/frr/frr.conf
