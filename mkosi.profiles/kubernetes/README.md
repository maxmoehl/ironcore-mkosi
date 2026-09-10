## kubernetes

kubeadm node image for IPv6-only clusters with [FeCNI](../../../src/FeCNI)
networking, built for environments **without a metadata service** (no
cloud-init/user-data needed). The image contains everything except the
cluster images themselves — kubeadm and the applied manifests pull those at
bootstrap (nodes need egress to registry.k8s.io and ghcr.io during
`init`/`join`) — so all it takes on each node is a single command.

Built to be combined with `virt` and `default-user`:

```
mkosi -p debian,virt,default-user,kubernetes build
# or the flavor:
bin/build kubernetes
```

### What's in the image

* `containerd` (from Debian) plus `containernetworking-plugins`, with the
  config shipped via `mkosi.extra/etc/containerd/config.toml`: CRI enabled
  (Debian's stock config disables it), `SystemdCgroup=true` to match the
  kubelet, `sandbox_image` set to the pause tag of the installed k8s minor
  (containerd would otherwise default to an older pause than kubeadm pulls).
* `kubelet`, `kubeadm`, `kubectl`, `cri-tools` from
  [pkgs.k8s.io](https://pkgs.k8s.io) (one repo per minor), installed through
  mkosi's regular `Packages=` mechanism. The
  third-party apt repo is provided the mkosi way: `mkosi.sandbox/
  etc/apt/{sources.list.d,keyrings}` is consulted when mkosi invokes apt
  during the build (a `mkosi.skeleton/` tree would *not* work — mkosi runs
  apt outside the image, so in-image apt config is ignored), and the same two
  files are shipped via `mkosi.extra/` so the repo remains usable inside the
  image for in-cluster upgrades. To bump the kubernetes minor, edit the URL
  in both `kubernetes.list` copies.
* A hand-maintained copy of the **FeCNI DaemonSet manifest** at
  `mkosi.extra/opt/kubernetes/fecni.yaml` (→ `/opt/kubernetes/fecni.yaml`),
  pulling `ghcr.io/mkalcok/fecni:latest` — plus `imagePullPolicy: IfNotPresent`
  on all containers, because `:latest` would default to `Always` (every pod
  start would then contact GHCR and inherit whatever `latest` happens to be).
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
* Bumping versions: the k8s minor is the URL in the two
  `kubernetes.list` copies (`mkosi.sandbox/` + `mkosi.extra/`) plus the
  `sandbox_image` pause tag in `mkosi.extra/etc/containerd/config.toml`
  (check `PauseVersion` in `cmd/kubeadm/app/constants/constants.go` of the
  k8s `release-1.xx` branch); for FeCNI change the image tag in
  `mkosi.extra/opt/kubernetes/fecni.yaml`. Consider pinning the manifest to
  an immutable tag/digest once FeCNI releases stabilize.
* The built image contains the cluster toolchain frozen at build time;
  bumping `KUBERNETES_MINOR` + rebuilding is the upgrade path for the *image*.
  In-band upgrades of a running cluster (`kubeadm upgrade`, apt) work as usual.
