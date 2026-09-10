## kubernetes

Self-contained kubeadm node image for IPv6-only clusters with
[FeCNI](../../../src/FeCNI) networking, built for environments **without a
metadata service** (no cloud-init/user-data needed). The image contains
everything required to bootstrap a cluster; on each node a single command is
enough.

Built to be combined with `virt` and `default-user`:

```
mkosi -p debian,virt,default-user,kubernetes build
# or the flavor:
bin/build kubernetes
```

### What's in the image

* `containerd` (from Debian, CRI enabled, `SystemdCgroup=true`, `sandbox_image`
  pinned to the matching pause image) plus `containernetworking-plugins`.
* `kubelet`, `kubeadm`, `kubectl`, `cri-tools` from
  [pkgs.k8s.io](https://pkgs.k8s.io) (one repo per minor; the minor is set via
  `KUBERNETES_MINOR` in `mkosi.prepare.chroot`), held via `apt-mark hold`.
* **All cluster images pre-pulled** into containerd's `k8s.io` namespace during
  the build: the full `kubeadm config images pull` set (apiserver,
  controller-manager, scheduler, proxy, etcd, coredns, pause) and the FeCNI
  image, so `kubeadm init`/`join` run with zero internet egress on the nodes.
* The **FeCNI image** `ghcr.io/mkalcok/fecni:latest`, pulled from GHCR at build
  time, plus a hand-maintained copy of the DaemonSet manifest at
  `mkosi.extra/opt/kubernetes/fecni.yaml` (→ `/opt/kubernetes/fecni.yaml`) with
  the image tag replaced to match, and `imagePullPolicy: IfNotPresent` so
  nodes use the pre-pulled copy instead of hitting the registry (`:latest`
  would default to `Always`).
* Two helpers:
  * `k8s-init.sh` — run on the first control-plane node
  * `k8s-join.sh` — run on every further node
* A `crictl` config pointed at containerd.

**nftables only: no iptables binaries exist in this image.** kube-proxy runs
in `mode: nftables` (set by `k8s-init.sh`), the conntrack kernel module is
preloaded, and neither `iptables` nor the `conntrack` tool are installed.
`br_netfilter` is also not loaded — FeCNI uses routed point-to-point veth
pairs, there are no bridges.

### FeCNI addressing

FeCNI implements flat L3 networking without overlays or tunnels: every node
owns one **globally routable IPv6 subnet carved from the host prefix** and
pods get point-to-point (`/127`) veth links (see the FeCNI
[README](../../../src/FeCNI/README.md)). Because the per-node subnets are not
subsets of a common cluster CIDR, kubeadm's automatic podCIDR allocation is
disabled (`allocate-node-cidrs=false`) and instead `k8s-init.sh`/`k8s-join.sh`
patch each node's `spec.podCIDR` from the `--pod-cidr` you pass. FeCNI reads
it from the API and renders its CNI config; pods on nodes whose podCIDR is
not set yet retry until it is patched.

### Bootstrapping a 3-node control-plane cluster

Boot three VMs from the same disk. On the **first** node:

```
sudo k8s-init.sh --name node-1 \
    --pod-cidr 2001:db8:1::/80 \
    --endpoint '[2001:db8::10]:6443'
```

This sets the hostname (node names must be unique), runs `kubeadm init
--upload-certs`, installs the kubeconfig for root and the calling user,
patches the node's podCIDR, applies the FeCNI manifest, removes the
control-plane taint (`--no-untaint` keeps it) and writes a ready-to-use join
command to `/root/k8s-join-control-plane.sh`.

On the **remaining nodes**: copy `/root/k8s-join-control-plane.sh` over, fill
in the node's subnet, run it — or directly:

```
sudo k8s-join.sh --name node-2 --pod-cidr 2001:db8:2::/80 -- \
    kubeadm join [2001:db8::10]:6443 --token <token> \
        --discovery-token-ca-cert-hash sha256:<hash> \
        --control-plane --certificate-key <key>
```

The join patches the node's podCIDR using the admin.conf kubeadm leaves on
control-plane nodes; the FeCNI DaemonSet then configures the node and it turns
Ready. `--certificate-key` is only valid for 2h after init; `kubeadm init
phase upload-certs --upload-certs` on the first node mints a fresh one.

### Notes and defaults

* `--endpoint` defaults to the node's own primary IPv6. For a real HA
  control plane you want an endpoint that does not die with the first node —
  pass a load-balancer VIP or DNS name. All nodes' kubelets/etcd only ever
  talk to the endpoint.
* Default service CIDR is `fd00::/108` (`--service-cidr` to change);
  advertise address is the node's primary global IPv6.
* Nodes clone `localhost` as hostname — the helpers set the hostname to
  `node-<machine-id-8>` unless `--name` is given. Do this *before* kubeadm
  runs, the node name is derived from it.
* kubelet is enabled and crash-loops until `init`/`join` — normal kubeadm
  behavior.
* Building requires network access (normal for this repo); the pulled images
  land inside the node image, deployment afterwards is offline.
* Bumping versions: `KUBERNETES_MINOR` for kubeadm & friends; for FeCNI
  replace `FECNI_IMAGE` in `mkosi.prepare.chroot` *and* the tag in
  `mkosi.extra/opt/kubernetes/fecni.yaml` (they must match). Consider pinning
  the manifest to an immutable tag/digest once FeCNI releases stabilize.
* The built image contains the cluster toolchain frozen at build time;
  bumping `KUBERNETES_MINOR` + rebuilding is the upgrade path for the *image*.
  In-band upgrades of a running cluster (`kubeadm upgrade`, apt) work as usual.
