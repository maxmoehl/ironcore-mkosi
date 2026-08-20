#!/usr/bin/env bash
# Provisions the inisix prefix store (INI.md §6) via the one-time
# 'inisix init <base-prefix> <prefix-size>', from the node prefix of the
# metaldata service (same contract as configure-frr.sh):
#
# The metaldata "prefix" (the node's VM address space, announced to the
# fabric by FRR) is assumed to be a /64. The store is based on its first
# /80 (<prefix>:1::/80) and delegates one /96 per VM NIC, i.e. 65536
# interfaces per node; the rest of the /64 stays free for other purposes.
set -Eeuo pipefail

# inisix init is NOT idempotent: it overwrites prefixes.json, wiping the
# allocation state of running VMs — never re-init an existing store (also
# protects against manual 'systemctl start init-inisix' re-runs).
if [ -e /var/inisix/prefix-store/prefixes.json ]; then
    exit 0
fi

metadata=$(curl --retry 5 --retry-delay 2 -sf \
    -H 'Metadata-Flavor: IronCore Metal' \
    http://metaldata.ironcore.dev/v1/)

PREFIX=$(jq -r '.prefix // empty' <<< "$metadata")

if [ -z "$PREFIX" ]; then
    echo "error: prefix is empty" >&2
    exit 1
elif [ "${PREFIX#*/}" != 64 ]; then
    echo "error: prefix $PREFIX is not a /64" >&2
    exit 1
fi

# <prefix>:1::/80 — every /96 delegated from it falls inside the /64
# that FRR announces to the fabric for this node. A /64's lower bits are
# all zero, so its textual form ends in '::': strip that and append
# '1::/80'.
BASE_PREFIX="${PREFIX%%/*}"
BASE_PREFIX="${BASE_PREFIX%::}:1::/80"

/usr/local/bin/inisix init "$BASE_PREFIX" 96
