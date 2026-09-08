## cloud-init

Provisions the machine with real cloud-init as an alternative to the `ironcore`
profile's custom services.

Ships a small out-of-tree datasource (`DataSourceIronCore` in
`/usr/lib/python3/dist-packages/ironcore_cloudinit/`, registered via
`datasource_pkg_list` in `/etc/cloud/cloud.cfg.d/99-ironcore.cfg`) which fetches
the metaldata document (URL from the `ic.metaldata=` kernel cmdline parameter)
on every boot with the `Metadata-Flavor: IronCore Metal` header in cloud-init's
network stage, after systemd-networkd has acquired a lease.

### Datasource selection

The active datasource is pinned per platform on the kernel command line,
baked into the platform profiles (`mkosi.profiles/{metal,virt}/mkosi.conf`;
visible in every built image's cmdline):

- `metal` -> `ds=IronCore ic.metaldata=http://metaldata.ironcore.dev/v1/`
- `virt` -> `ds=NoCloud`

`ds=<name>` is cloud-init's built-in single-datasource override (the
`ci.ds=`/`ci.datasource=` spellings are deprecated since 23.2), honored by
both selection layers:

- ds-identify records it verbatim without running any platform probing,
  writes `datasource_list: [ <name>, None ]` to /run/cloud-init/cloud.cfg
  and enables cloud-init unconditionally.
- cloud-init itself matches it in `DataSource.override_ds_detect()` and
  skips runtime datasource detection for the named datasource.

If the pinned datasource finds no data, cloud-init deterministically falls
through to the empty `None` datasource. A `;`-suffix in a `ds=nocloud`
token is NoCloud line configuration (`;s=`, `;h=`, `;i=`) and ignored by the
pin parsers; NoCloud uses it to locate its seed (see below).

The IronCore datasource has no built-in metadata URL: `ic.metaldata=` on the
kernel cmdline is the source of truth, baked into the metal profile. To point
a machine elsewhere, append another `ic.metaldata=<url>` token (dev builds,
PXE, bootloader edit) — the last occurrence wins — or set
`datasource.IronCore.metadata_url` in cloud.cfg.d at lower precedence. With
no URL at all the datasource declines and cloud-init falls through to `None`.
The `ic.` namespace is unused by the kernel, systemd, dracut and cloud-init,
and the kernel does not export dotted `key=value` params into PID 1's
environment, so the token stays readable via /proc/cmdline only.

### User Data

Supply the `cloud-init` key in the metaldata `user-data` object. Its value is
used verbatim as cloud-init user-data, i.e. standard formats that any cloud user
already knows: `#cloud-config`, `#!` scripts, `#include`, or MIME multipart. The
value must start with the type header on the very first byte (no leading blank
line).

```json
{
  "user-data": {
    "cloud-init": "#cloud-config\nusers:\n  - name: max\n    groups: [sudo]\n    ssh_authorized_keys:\n      - ssh-ed25519 AAAA...\npackages:\n  - htop\n"
  },
  "server-name": "web1"
}
```

If the key is absent, the datasource reports "not found" and cloud-init does
nothing (falls through to the `None` datasource).

### Meta-Data

Synthesized on the client side; metaldata needs no changes:

- `server-name` becomes `local-hostname` (cloud-init sets the hostname).
- `instance-id` is the DMI product UUID, with `/etc/machine-id` as fallback.
  Per-instance modules re-run when it changes, for the machine-id fallback that
  happens automatically on reinstall; when two machines share a product UUID,
  per-instance state follows the install.

### Notes

- cloud-init's network rendering is disabled (`network: {config: disabled}`);
  systemd-networkd owns the network via 99-default.network.
- The distribution default user is disabled (`users: []`); define users in the
  supplied cloud-config instead.
- All cloud-init units carry `ConditionPathExists=!/etc/initrd-release` so
  nothing runs during the `disk-install` installer boot; cloud-init only starts
  in the installed system after kexec.
- The datasource hooks cloud-init's internal datasource API. It is pinned
  against the distro-shipped cloud-init; review on major upgrades.

### Usage

```
mkosi -p debian,metal,disk-install,cloud-init build
```

Or via bin/build with the `metal-cloudinit` flavor.

### Development with QEMU

For generic cloud-init testing use a NoCloud seed served from the host,
wired into the image via its kernel cmdline (virt images pin `ds=NoCloud`,
and the `ds=nocloud` line-config token is how NoCloud finds the seed). In
QEMU user networking the host is reachable as `10.0.2.2`.

```console
# Host: seed dir (adjust user-data to taste; keep out of git)
$ mkdir -p dev/seed
$ cat > dev/seed/meta-data <<EOF
instance-id: dev-01
local-hostname: dev1
EOF
$ cat > dev/seed/user-data <<'EOF'
#cloud-config
users:
  - name: max
    groups: [sudo]
EOF

# Host: seed server (re-reads the files on every request)
$ python3 -m http.server 8000 --directory dev/seed &

# Host: ssh credentials for `mkosi ssh` (once; keep out of git)
$ mkosi genkey

# Host: build (seed baked into the cmdline) & boot (serial console)
$ mkosi -p debian,virt,cloud-init \
    --kernel-command-line='ds=nocloud;s=http://10.0.2.2:8000/' build
$ mkosi -p debian,virt,cloud-init vm
```

`ds=nocloud;...` is NoCloud's line configuration as a single kernel cmdline
token: cloud-init fetches `<s>/user-data`, `meta-data`, `vendor-data` and
`network-config` from the seed URL (trailing slash on `s=` is required;
absent files other than `user-data`/`meta-data` are fine). The bare
`ds=NoCloud` pin from the virt profile and this token coexist: the pin
parsers stop at `;`. To avoid retyping on every build, put the same token
into a local `mkosi.local.conf` instead:

```ini
[Content]
KernelCommandLine=ds=nocloud;s=http://10.0.2.2:8000/
```

Modern mkosi does not forward a TCP port for ssh; instead the guest's sshd is
exposed over vsock (via systemd-ssh-generator, systemd v256+) and mkosi
provisions the mkosi.crt certificate as root's authorized_keys when the VM
starts. Log in from a second terminal with the same config:

```console
$ mkosi -p debian,virt,cloud-init ssh
```

If vsock ssh does not work on your setup, fall back to manual qemu with
`-netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0`
and your pubkey in the seed's user-data (`ssh_authorized_keys`), then
`ssh -p 2222 root@localhost`.

Fast inner loop (build the image once):

- user-data/meta-data changes: edit the files in `dev/seed` (no server restart
  needed) and in the VM: `cloud-init clean --logs && reboot`. A boot takes
  seconds, so a full apply cycle is ~30s.
- `cloud-init status --long`, `/var/log/cloud-init.log` and `cloud-init query
  ds` inside the VM tell you what the datasource saw.

#### Testing the IronCore datasource

The NoCloud path above does not exercise `DataSourceIronCore`. When iterating
on the datasource itself, run `bin/metaldata-mock` on the host and re-pin
the datasource and point it at the mock — both via the kernel cmdline at
build time (ds-identify accepts `ds=<name>` from the cmdline, last
occurrence wins, so it overrides the virt profile's `ds=NoCloud` pin):

```console
# Host: mock metaldata (re-reads the file on every request)
$ bin/metaldata-mock &

# Host: build re-pinned to IronCore with the mock as metaldata & boot
$ mkosi -p debian,virt,cloud-init \
    --kernel-command-line='ds=IronCore ic.metaldata=http://10.0.2.2:8080/v1/' build
$ mkosi -p debian,virt,cloud-init vm
```

No seed or overlay is needed in this mode; the mock serves the metaldata JSON
described under "User Data" above.

- datasource code changes: push the file into the running VM and re-apply:

  ```console
  $ mkosi -p debian,virt,cloud-init ssh -- \
        tee /usr/lib/python3/dist-packages/ironcore_cloudinit/sources/DataSourceIronCore.py \
        < mkosi.profiles/cloud-init/.../DataSourceIronCore.py
  ```

  (or scp over the forwarded port with the manual-qemu fallback)

End-to end check without a server: with `bin/metaldata-mock` running, build
`-p debian,metal,disk-install,cloud-init` with
`--kernel-command-line=ic.metaldata=http://10.0.2.2:8080/v1/` (no re-pin
needed, the metal profile pins IronCore), boot the UKI in QEMU with a blank
disk attached; the installer picks the first PCI disk, installs, kexecs, and
cloud-init runs against the mock in the installed system.
