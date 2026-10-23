# libvirt

Packaging an IronCore libvirt hypervisor by shipping
[libvirt-provider](https://github.com/ironcore-dev/libvirt-provider) and the
[machinepoollet](https://github.com/ironcore-dev/ironcore/tree/main/poollet/machinepoollet).

In addition to the standard IronCore stack, this image ships an expiremental
network implementation: [inisix](http://git.moehl.eu/ironcore/inisix.git). It is
based on tun/tap devices and regular kernel networking.

## Unit Ordering

To ensure the hypervisor comes online properly the profile includes a
`hypervisor.target` which is registered as the default target (instead of
`multi-user.target`). The IronCore components register themselves as
`WantedBy=hypervisor.target` and order after `cloud-init.target` to ensure the
necessary config lands before anything starts.

The following units are added by this profile (in start-order):

**init-inisix**: Initializes the inisix prefix store with a one-shot
`inisix init prefix $BASE_PREFIX $PREFIX_SIZE`, reading both variables from
`/var/lib/inisix/init.env`. Skipped once a store exists: `inisix init` truncates
the store, re-init would wipe the allocation state of running VMs.

**inisixd**: The DHCPv6 server listening on all links managed by `inisix`.

**libvirt-provider**: Upstream verison with patches to support the INI interface
in it's plugin concept.

**machinepoollet**: Upstream version extended with patches to IRI to support
reporting back the prefix allocated for a given network interface.

The profile also ships the Cloud Hypervisor provider and its machinepoollet
path, but neither provider is enabled by default. Enable either
`libvirt-provider.service`/`machinepoollet.path` or
`cloud-hypervisor-provider.service`/`machinepoollet-cloud-hypervisor.path`
from cloud-init after writing the corresponding configuration files.

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
* `/var/lib/inisix/init.env`: store parameters for `init-inisix.service`
  (asserted to exist, read via `EnvironmentFile=`).
