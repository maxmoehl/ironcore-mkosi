#!/usr/bin/env bash
#
# k8s-init.sh — initialize the first control-plane node of a kubeadm cluster
# with FeCNI networking (IPv6-only, no overlays).
#
# Everything kubeadm needs is baked into this image (packages, containerd,
# pre-pulled images including FeCNI), so this works without internet access
# or a metadata service. Join further nodes with k8s-join.sh.
#
set -euo pipefail

info() {
    echo
    echo "==> $*"
}

die() {
    echo "k8s-init: error: $*" >&2
    exit 1
}

usage() {
    cat <<EOF
usage: sudo k8s-init.sh --pod-cidr <cidr> [options] [-- kubeadm init args]

required:
  --pod-cidr <cidr>       globally routable IPv6 subnet for this node's pods;
                          carved from the host prefix (e.g. 2001:db8:1::/80).
                          Written into the node's spec.podCIDR, FeCNI does the
                          rest (per-pod /127 point-to-point veth pairs).

options:
  --name <name>           hostname and node name
                          (default: node-<first 8 chars of machine-id>)
  --endpoint <host:port>  control-plane endpoint all nodes use to reach the
                          API servers, e.g. '[2001:db8::10]:6443' or
                          'k8s-api.example.net:6443'
                          (default: [<primary IPv6 of this node>]:6443)
  --service-cidr <cidr>   cluster service subnet (IPv6, default: fd00::/108)
  --no-untaint            keep the control-plane NoSchedule taint
                          (default: remove it — pods may schedule everywhere)

All further arguments (also anything after '--') are passed to kubeadm init.
EOF
}

SERVICE_CIDR="fd00::/108"
POD_CIDR=""
ENDPOINT=""
NODE_NAME=""
UNTAINT=yes
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --pod-cidr)     POD_CIDR="$2"; shift 2;;
        --service-cidr) SERVICE_CIDR="$2"; shift 2;;
        --endpoint)     ENDPOINT="$2"; shift 2;;
        --name)         NODE_NAME="$2"; shift 2;;
        --no-untaint)   UNTAINT=no; shift;;
        -h|--help)      usage; exit 0;;
        --)             shift; EXTRA_ARGS+=("$@"); break;;
        *)              EXTRA_ARGS+=("$1"); shift;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -n "$POD_CIDR" ] || die "--pod-cidr is required (see --help)"
[[ "$POD_CIDR" == *:*/* ]] || die "--pod-cidr must be an IPv6 CIDR (e.g. 2001:db8:1::/80)"
[[ "$SERVICE_CIDR" == *:*/* ]] || die "--service-cidr must be an IPv6 CIDR"

# Primary global IPv6 address, used as the apiserver advertise address and
# default control-plane endpoint.
ADV_IP=$(ip -6 -j addr show scope global up \
    | jq -r '[.[].addr_info[] | select(.scope == "global" and ((.temporary // false) | not) and ((.deprecated // false) | not))][0].local')
[ -n "$ADV_IP" ] && [ "$ADV_IP" != "null" ] || die "no global IPv6 address found on this node"
ENDPOINT="${ENDPOINT:-[$ADV_IP]:6443}"

# Nodes cloned from the same image share the hostname; kubeadm node names
# would collide. Hostname must be set before kubeadm runs, kubeadm uses it
# (lower-cased) as the node name.
NODE_NAME="${NODE_NAME:-node-$(cut -c1-8 /etc/machine-id)}"
info "hostname/node name: $NODE_NAME"
hostnamectl set-hostname "$NODE_NAME"
KUBE_NODE_NAME=$(hostname | tr '[:upper:]' '[:lower:]')

KUBE_VERSION=$(kubeadm version -o short)

info "kubeadm init $KUBE_VERSION (advertise $ADV_IP, endpoint $ENDPOINT, services $SERVICE_CIDR)"
mkdir -p /etc/kubernetes
cat > /etc/kubernetes/kubeadm-init.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${ADV_IP}
nodeRegistration:
  name: ${KUBE_NODE_NAME}
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: ${KUBE_VERSION}
controlPlaneEndpoint: "${ENDPOINT}"
networking:
  serviceSubnet: "${SERVICE_CIDR}"
  dnsDomain: cluster.local
controllerManager:
  # FeCNI reads the routable per-node prefix from spec.podCIDR; the prefixes
  # are not subsets of a common cluster CIDR, so kubeadm must not allocate
  # them itself. k8s-init/k8s-join patch each node instead.
  extraArgs:
    - name: allocate-node-cidrs
      value: "false"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
---
# The image carries no iptables binaries; kube-proxy must run pure nftables.
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: nftables
EOF

kubeadm init --config /etc/kubernetes/kubeadm-init.yaml --upload-certs "${EXTRA_ARGS[@]}"

export KUBECONFIG=/etc/kubernetes/admin.conf

install -d -m 700 /root/.kube
install -m 600 /etc/kubernetes/admin.conf /root/.kube/config
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    install -d -m 700 -o "$SUDO_USER" -g "$SUDO_USER" "$USER_HOME/.kube"
    install -m 600 -o "$SUDO_USER" -g "$SUDO_USER" /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
fi

info "assigning pod subnet $POD_CIDR to node $KUBE_NODE_NAME"
kubectl patch node "$KUBE_NODE_NAME" --type=merge \
    -p "{\"spec\":{\"podCIDR\":\"${POD_CIDR}\"}}"

info "deploying FeCNI"
kubectl apply -f /opt/kubernetes/fecni.yaml

if [ "$UNTAINT" = "yes" ]; then
    info "removing control-plane taint so workloads can schedule everywhere"
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
fi

# Pick a fresh certificate key valid for two hours; the certificates were
# already uploaded by --upload-certs.
CERT_KEY=$(kubeadm init phase upload-certs --upload-certs --kubeconfig /etc/kubernetes/admin.conf | tail -n1)
JOIN_COMMAND=$(kubeadm token create --print-join-command --kubeconfig /etc/kubernetes/admin.conf)

cat > /root/k8s-join-control-plane.sh <<EOF
#!/bin/sh
# Join an additional control-plane node to this cluster. Adjust the pod
# subnet to the node's prefix. Keep this file secret, it grants the ability
# to join the cluster and impersonate the control plane (valid: 24 h token,
# 2 h uploaded certificates).
exec k8s-join.sh --pod-cidr 'FILL-IN:e.g.2001:db8:2::/80' \\
    -- ${JOIN_COMMAND} --control-plane --certificate-key ${CERT_KEY}
EOF
chmod 700 /root/k8s-join-control-plane.sh

info "waiting for this node to become ready"
kubectl wait --for=condition=ready "node/${KUBE_NODE_NAME}" --timeout=180s || true
kubectl -n kube-system rollout status daemonset/fecni --timeout=120s || true
kubectl get nodes -o wide

cat <<EOF

==> cluster initialized

kubectl is configured for root${SUDO_USER:+ and $SUDO_USER} (admin.conf is at
/etc/kubernetes/admin.conf).

To join the remaining control-plane nodes, copy
/root/k8s-join-control-plane.sh to each node, fill in that node's pod
subnet, and run it. Afterwards each node is patched with its podCIDR and
FeCNI will configure it — no further steps needed.

The node is ready once 'kubectl get nodes' shows all nodes Ready; FeCNI pods
on freshly joined nodes retry their init step until the podCIDR is patched.
EOF
