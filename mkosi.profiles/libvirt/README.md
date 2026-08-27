# libvirt

Packaging an IronCore libvirt hypervisor by shipping [libvirt-provider] and the
[machinepoollet].

In addition to the standard IronCore stack, this image ships an expiremental
network implementation: [inisix]. It is based on tun/tap devices and regular
kernel networking.

## Unit Ordering

To ensure the hypervisor comes online properly the profile includes a
`hypervisor.target` which is registered as the default target (instead of
`multi-user.target`). The IronCore components register themselves as
`WantedBy=hypervisor.target` and order after cloud-init to ensure the necessary
config lands before anything starts.

The following units are added by this profile (in start-order):

**inisix-init**: A simple script that retrieves the prefix from the [IronCore
metaldata](metaldata) service and initializes the prefix store.

**inisixd**: The DHCPv6 server listening on all links managed by `inisix`.

**libvirt-provider**: Upstream verison with patches to support the INI interface
in it's plugin concept.

**machinepoollet**: Upstream version extended with patches to IRI to support
reporting back the prefix allocated for a given network interface.

## Dependencies

The profile requires the following files to be provided via a bootstrapping
mechanism. Currently it assumes cloud-init and orders its units accordingly:

* `/var/cfg/classes/supported-machine-classes.yaml`: the list of supported
  machine classes to be announced by the `libvirt-provider`.
* `/etc/bootstrap-kubeconfig-machinepool/bootstrap-kubeconfig`: bootstrap config
  to connect and authenticate with the cluster in which the `machinepoollet`
  should create its machine pool.

To inject topology labels, create a drop-in for the `machinepoollet` like this:

```
# /etc/systemd/system/machinepoollet.service.d/10-topology.conf
[Service]
Environment=TOPOLOGY_REGION=REGION
Environment=TOPOLOGY_ZONE=ZONE
```

and don't forget to reload systemd after this.

[libvirt-provider]: https://github.com/ironcore-dev/libvirt-provider
[machinepoollet]: https://github.com/ironcore-dev/ironcore/tree/main/poollet/machinepoollet
[inisix]: http://git.moehl.eu/ironcore/inisix.git
