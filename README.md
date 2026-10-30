# Debian OS Images via mkosi

Debian (trixie) images built with [mkosi](https://github.com/systemd/mkosi),
for both bare-metal deployments via UKI or VM deployments via RAW disk images.

## Building

Host dependencies: `mkosi`

A convencience script for producing IronCore bootable bare-metal or VM images is
provided in `bin/build`:

```
usage: bin/build [ -a ARCHITECTURE ] [ -d DISTRO ] [ -p ] FLAVOR [ -- MKOSI_ARGS... ]
```

It understands the flavors specified in `flavors.json` which are combinations of
profiles which should yield a functional system. It also handles some of the
quirks of mkosi around cleaning up previous builds of a specific image.

To build custom images, mkosi can also be invoked directly, see it's
documentation for details.

## Profiles

| Profile        | Purpose                                                    |
|----------------|------------------------------------------------------------|
| `metal`        | Full hardware kernel (`linux-image-amd64`), VGA console    |
| `virt`         | Cloud kernel (`linux-image-cloud-amd64`), serial console   |
| `disk-install` | Boots as initrd, installs to disk, kexecs                  |
| `users`        | Creates operator accounts (max, damyan) with SSH keys      |
| `frr`          | Adds FRRouting                                             |
| `jool`         | Adds Jool NAT64 with SMBIOS-driven network config          |
| `rescue-stick` | Builds a disk image for rescue USB sticks.                 |
| `cloud-init`   | Provisions via cloud-init user-data fetched from metaldata |
| `factorio`     | Installs the Factorio server.                              |
| `teamspeak`    | Installs the TeamSpeak3 server.                            |
| `libvirt`      | Builds the ironcore libvirt-provider + machinepoollet.     |
| `kubernetes`   | kubeadm-ready node image (IPv6, FeCNI), no metadata service needed. |

See the readme of each profile for more details.
