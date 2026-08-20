## frr

Adds [FRRouting](https://frrouting.org/) and configures BGP unnumbered
against the fabric to announce the node's prefix.

Configuration is derived from the hostname and prefix which are retrieved via
the metaldata service using an early configuration unit. The ordering is:

1. `systemd-networkd-wait-online.service`
2. `configure-frr.service`
3. `frr.service`
4. `network-online.target`

This ensures the metadata service is reachable when the configure script runs,
but it delays any other unit as much as possible until FRR is starting up. A
caveat to note is that FRR will take time to establish its peerings and populate
the route table but `network-online.target` is reached immediately.
