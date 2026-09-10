# Debian OS Images via mkosi

Debian (trixie) images built with [mkosi](https://github.com/systemd/mkosi),
for both bare-metal deployments via UKI or VM deployments via raw disks.

## Building

Host dependencies: `mkosi`

Profiles are combined to produce the desired image variant. A platform profile
(`metal` or `virt`) is always required:

```
mkosi -p metal,users,frr build
mkosi -p virt,jool build
mkosi -p metal,disk-install build
```

Output is placed in `mkosi.output/`, the UKI is the `.efi` file, the `.raw` file
is the raw disk.

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
