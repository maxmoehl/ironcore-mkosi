# libvirt

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

**machinepoollet**: Upstream version. Is started once libvirt-provider starts
listening on the unix domain socket.

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
