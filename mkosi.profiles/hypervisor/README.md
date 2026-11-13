# hypervisor

Packaging an IronCore libvirt hypervisor by shipping
[libvirt-provider](https://github.com/ironcore-dev/libvirt-provider) and the
[machinepoollet](https://github.com/ironcore-dev/ironcore/tree/main/poollet/machinepoollet).

In addition to the standard IronCore stack, this image ships an expiremental
network implementation as part of libvirt-provider:
[inisix](http://git.moehl.eu/ironcore/inisix.git). It is based on tun/tap
devices and regular kernel networking.

## Unit Ordering

To ensure the hypervisor comes online properly the profile includes a
`hypervisor.target` which is registered as the default target (instead of
`multi-user.target`). The IronCore components register themselves as
`WantedBy=hypervisor.target` and order after `cloud-init.target` to ensure the
necessary config lands before anything starts.

The following units are added by this profile (in start-order):

**inisix-init**: Initializes the inisix prefix store with a one-shot
`inisix init prefix $BASE_PREFIX $PREFIX_SIZE`. It is implemented as a script
which waits for FRR to assign the loopback address to calculate the host prefix
from it and initialize the store.

**libvirt-provider**: Upstream verison with patches to add support for the
inisix network interface plugin.

**machinepoollet@**: Upstream version, shipped as a template unit. The instance
name is the provider unit name and is used for the `--provider-id=%i://%H`
scheme as well as the runtime socket `/run/ironcore/%i.sock`. The provider
listens on its own socket and pulls in `machinepoollet@%N.path`, which starts
the poollet once the socket exists.

## Dependencies

The profile requires the following files to be provided via a bootstrapping
mechanism. Currently it assumes cloud-init and orders its units accordingly:

* `/var/lib/libvirt-provider/supported-machine-classes.yaml`: the list of
  supported machine classes to be announced by the `libvirt-provider`.
* `/var/lib/machinepoollet/bootstrap-kubeconfig`: bootstrap config
  to connect and authenticate with the cluster in which the `machinepoollet`
  should create its machine pool.
* `/var/lib/machinepoollet/env`: environment file for `machinepoollet` which can
  be used to inject `TOPOLOGY_REGION` and `TOPOLOGY_ZONE`.

## Hacking

_If you encounter problems, make sure to check the known issues section below._

This repository includes a kind (Kubernetes in Docker) setup to spin up a local
IronCore installation. Together with `bin/dev` and some preparation on the host
this can turn a single Linux machine into a cluster of IronCore hypervisors on
which machines can be scheduled. The setup has been tested as described with
rootful podman on a bare-metal Debian machine.

To ensure adequate performance it is recommended to give the executing user
write permissions to `/dev/kvm` to avoid emulation. Support for nested
virtualization is also recommended to allow the IronCore machines to perform
reasonaby well. Often it is sufficient to add the user to the `kvm` group.

By default `mkosi` allocates very little resources to the VMs it starts, this
can be overridden by adding a `mkosi.local.conf` with the following
configuration:

```
# mkosi.local.conf
[Runtime]
RuntimeNetwork=none
QemuArgs=
  -netdev tap,id=n0,ifname=tap-dev,script=no,downscript=no
  -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56
CPUs=8
RAM=32G
RuntimeSize=128G
```

You may also want to specify a root password in this file to bake into the
image, alternatively you can inject one via cloud-init.

The network configuration of this snippet references a tap device you need to
create yourself. By having a persistent tap device the network configuration can
be applied once and any manual changes persist across VMs. To configure the
network, the following configuration has been tested:

```
# /etc/systemd/network/60-tap-dev.netdev
[NetDev]
Name=tap-dev
Kind=tap

[Tap]
# TODO: replace with your own user
User=max
```

```
# /etc/systemd/network/60-tap-dev.network
[Match]
Name=tap-dev

[Network]
Address=fdfe:c02e:3534::1/64
IPv6SendRA=yes
ConfigureWithoutCarrier=yes

[IPv6SendRA]
DNS=2001:4860:4860::6464
DNS=2001:4860:4860::64

[IPv6Prefix]
Prefix=fdfe:c02e:3534::/64

[Route]
Destination=fdfe:c02e:3534:1::/64
Gateway=fe80::5054:ff:fe12:3456
GatewayOnLink=yes
```

Have `systemd-networkd` create the device and apply the configuration:

```
networkctl reload
networkctl reconfigure tap-dev
```

Now it's time to bring up the cluster which is just `bin/kind up` and generate
the bootstrap kubeconfig for the machinepoollet:

```
kubectl ironcore create token --token-type MachinePool -o yaml \
  | kubectl ironcore generate bootstrap-kubeconfig -f -
```

To bootstrap the VM we need to configure it via cloud-init. Copy the
`cloud-init/kind` directory to `cloud-init/dev` and paste the output into the
`user-data` file you just copied into `cloud-init/dev`. To serve the metadata
to cloud-init you can use an ephemeral systemd unit:

```
systemd-run --user --collect \
  --unit metadata-server python3 -m http.server \
  -b '::' -d "$PWD/cloud-init/"
```

Finally, we can boot the VM to have it join the cluster as a machinepool:

```
bin/dev virt,debian,cloud-init,hypervisor \
  --kernel-command-line 'ds=nocloud;s=http://[fdfe:c02e:3534::1]:8000/dev/'
```

### Known Issues

**Kind and rootful podman**: By default kind will invoke podman as the current
user which will result in it using rootless podman which can cause connectivity
issues when trying to connect to the kind cluster. Use the system podman instead
to set the container up with its own interface and IP that can be reached:

```
export CONTAINER_HOST=unix:///run/podman/podman.sock
```

You need to make sure the current user has the permissions needed to read and
write to this socket.

**Outbond connectivity**: Most of the components use ULA ranges which are not
routable in the internet. To be able to download OCI images for the cluster and
machines you may need to configure an outgoing SNAT so that traffic is sent out
with your machines public IP, for example via nftables:

```
table inet firewall {
        chain postrouting {
                type nat hook postrouting priority srcnat; policy accept;
                # TODO: replace interface name with real one
                ip6 saddr fc00::/7 oifname eth0 counter masquerade
        }
}
```
