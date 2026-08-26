# libvirt

IronCore machine provider based on libvirt/qemu. Builds the following
binaries from the git submodules in `src/` during the image build and
installs them to `/usr/local/bin`, together with systemd units:

| Binary               | Source                                                    |
|----------------------|-----------------------------------------------------------|
| `libvirt-provider`   | `src/libvirt-provider` ([ironcore-dev/libvirt-provider])  |
| `machinepoollet`     | `src/ironcore` ([ironcore-dev/ironcore], `poollet/machinepoollet`) |
| `inisix`             | `src/inisix` (reference INI plugin, used via the provider's `ini` network interface plugin) |
| `inisixd`            | `src/inisix` (DHCPv6 server for inisix taps)                          |

The binaries are static (pure Go), the build uses the distro's Go and
automatically fetches the newer toolchain required by the projects'
`go.mod`. Build the flavor with:

```
bin/build libvirt
```

which expands to the mkosi profiles `debian,metal,disk-install,cloud-init,frr,libvirt`
(see `flavors.json`). To build a custom variant, pass the full profile list
to mkosi:

```
mkosi -i -p debian,metal,disk-install,cloud-init,frr,libvirt build
```

Fetch/update the sources with:

```
git submodule update --init src/libvirt-provider src/ironcore src/inisix
```

The systemd units replicate the upstream libvirt-provider DaemonSet
(minus its apinet networking; NICs are set up by the `ini` network
interface plugin, which execs `inisix` per machine interface):

- `libvirt-provider.service` has `AmbientCapabilities=CAP_NET_ADMIN` so
  the plugin's inisix invocations survive the exec with the cap needed
  for tap/address/route setup. inisix needs its prefix store provisioned
  once via `inisix init prefix <base-prefix> <prefix-size>`:
  `init-inisix.service` derives the base prefix from the metaldata
  "prefix" key (assuming a /64: `<prefix>:1::/80` as base, one /96 per
  NIC, i.e. 65536 interfaces) and is ordered before
  `inisixd.service`, `libvirt-provider.service` and
  `machinepoollet.service` (the store is the file
  `/var/inisix/prefixes.json` — its lock is an flock on the file itself —
  in `/var/inisix`, which is pre-created via tmpfiles.d).

- `inisixd.service` runs the DHCPv6 server for inisix taps: it watches
  rtnetlink and serves stateful DHCPv6 on every `isx-*` tap from the
  prefix store, so it is ordered `After=init-inisix.service` (the store
  init) and `libvirt-provider.service` is ordered `After=inisixd.service`,
  keeping guests from attaching before DHCPv6 is up. The
  `50-inisix.network` networkd file matches `isx-*` and enables IPv6 RA
  with the managed flag so guests use DHCPv6. Runs persistently
  (`Restart=on-failure`, `WantedBy=hypervisor.target`) as the
  `libvirt-provider` user with `AmbientCapabilities=CAP_NET_ADMIN
  CAP_NET_BIND_SERVICE CAP_NET_RAW` (rtnetlink tap watch, DHCPv6 port
  547, SO_BINDTODEVICE) — never root, so the prefix store lock is always
  owned by the same user as the provider's inisix invocations (a
  root-owned lock would lock them out; `inisix init` saves lock-free and
  never creates it).

- `libvirt-provider.service` runs as the `libvirt-provider` user (created
  via sysusers.d, uid 65532; member of `libvirt`, while `libvirt-qemu` is
  a member of `libvirt-provider` so qemu can read
  `/var/lib/libvirt-provider`, created via tmpfiles.d). It uses the
  socket-activated libvirtd (`Requires=libvirtd.socket`), hugepages and the
  writeback volume cache policy like the DaemonSet.
- `machinepoollet.service` talks to the provider via
  `/var/run/libvirt-provider/libvirt-provider.sock`. It is not pulled in by
  the boot target directly: `machinepoollet.path` watches the provider
  socket and starts the poollet only once it exists, so the poollet
  doesn't crash-loop (and hit the systemd start limit) while the provider
  is still setting up. It bootstraps/rotates its kubeconfig
  client cert from `/etc/bootstrap-kubeconfig-machinepool/bootstrap-kubeconfig`.
  Machine pool name and provider-id are the hostname (%H, which cloud-init
  sets from the metaldata server-name); the topology region/zone are
  injected via cloud-init as a drop-in at
  `/etc/systemd/system/machinepoollet.service.d/`.

`libvirt-provider.service` and `machinepoollet.path` are hooked into
`hypervisor.target` (shipped by this profile, modeled after
`graphical.target`: `Requires=`/`After=multi-user.target`,
`AllowIsolate=yes`) instead of `multi-user.target` directly, and
`default.target` points at it. This keeps `multi-user.target` free of
units that order against `cloud-init.target`, breaking the boot ordering
loop between cloud-init and multi-user.

### Provisioning via cloud-init

Everything the DaemonSet got from Secrets/ConfigMaps is expected from
cloud-init (`write_files`) when the `cloud-init` profile is included —
both units are ordered `After=cloud-final.service` (and `runcmd` runs
`systemctl daemon-reload` there to pick up the drop-in):

| Path | Mirrors |
|------|---------|
| `/etc/bootstrap-kubeconfig-machinepool/bootstrap-kubeconfig` | `bootstrap-kubeconfig-machinepool` Secret |
| `/var/cfg/classes/supported-machine-classes.yaml` | `supported-machine-classes` ConfigMap |
| `/etc/systemd/system/machinepoollet.service.d/10-topology.conf` | `$(NODE_NAME)` env / topology labels (name itself is `%H`) |

The inisix prefix store provisioning that the DaemonSet did out-of-band
is image-local instead: `init-inisix.service` runs `inisix init` from the
metaldata prefix before provider/poollet (see above).

Note: with `--enable-hugepages=true` the provider reports pool memory from
`/proc/meminfo` `HugePagesTotal`, so hugepages are reserved on the kernel
command line in `mkosi.conf`: `hugepagesz=1G hugepages=1800
default_hugepagesz=1G`, matching the existing hypervisors. The default
size matters — meminfo only tracks the default pool.

[ironcore-dev/libvirt-provider]: https://github.com/ironcore-dev/libvirt-provider
[ironcore-dev/ironcore]: https://github.com/ironcore-dev/ironcore
