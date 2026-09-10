#!/usr/bin/env bash
#
# k8s-join.sh — join this machine as an additional node (typically a stacked
# control-plane node) of a cluster bootstrapped with k8s-init.sh.
#
# kubeadm, kubelet, containerd and the FeCNI DaemonSet manifest are baked
# into this image; no metadata service is required. Cluster images are pulled
# from registry.k8s.io / ghcr.io at bootstrap, so the node needs egress.
#
set -euo pipefail

info() {
    echo
    echo "==> $*"
}

die() {
    echo "k8s-join: error: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
usage: sudo k8s-join.sh --pod-cidr <cidr> [options] -- <kubeadm join arguments>

required:
  --pod-cidr <cidr>       globally routable IPv6 subnet for this node's pods;
                          carved from the host prefix (e.g. 2001:db8:2::/80).
                          Patched into the node's spec.podCIDR after joining,
                          FeCNI does the rest.

options:
  --name <name>           hostname and node name
                          (default: node-<first 8 chars of machine-id>)
  --no-untaint            keep the control-plane NoSchedule taint on control-
                          plane joins (default: remove it)

join arguments:
  Everything after '--' is passed to 'kubeadm join'. Use (and adapt) the
  command that /root/k8s-join-control-plane.sh on the first node contains:

      kubeadm join [2001:db8::10]:6443 --token ... \
          --discovery-token-ca-cert-hash sha256:... \
          --control-plane --certificate-key ...

  For a control-plane join you need all of --token,
  --discovery-token-ca-cert-hash, --control-plane and --certificate-key.
EOF
}

POD_CIDR=""
NODE_NAME=""
UNTAINT=yes
JOIN_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --pod-cidr)   POD_CIDR="$2"; shift 2;;
        --name)       NODE_NAME="$2"; shift 2;;
        --no-untaint) UNTAINT=no; shift;;
        -h|--help)    usage; exit 0;;
        --)           shift; JOIN_ARGS+=("$@"); break;;
        *)            JOIN_ARGS+=("$1"); shift;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -n "$POD_CIDR" ] || die "--pod-cidr is required (see --help)"
[[ "$POD_CIDR" == *:*/* ]] || die "--pod-cidr must be an IPv6 CIDR (e.g. 2001:db8:2::/80)"
[ ${#JOIN_ARGS[@]} -gt 0 ] || die "missing kubeadm join arguments after '--' (see --help)"

# Tolerate the join command being pasted including 'kubeadm join'.
while [ "${JOIN_ARGS[0]:-}" = "kubeadm" ] || [ "${JOIN_ARGS[0]:-}" = "join" ]; do
    JOIN_ARGS=("${JOIN_ARGS[@]:1}")
done

# See k8s-init.sh: unique node names are mandatory, set before kubeadm runs.
NODE_NAME="${NODE_NAME:-node-$(cut -c1-8 /etc/machine-id)}"
info "hostname/node name: $NODE_NAME"
hostnamectl set-hostname "$NODE_NAME"
KUBE_NODE_NAME=$(hostname | tr '[:upper:]' '[:lower:]')

info "kubeadm join"
kubeadm join --cri-socket unix:///run/containerd/containerd.sock "${JOIN_ARGS[@]}"

if [ -f /etc/kubernetes/admin.conf ]; then
    # Control-plane join: kubeadm wrote an admin.conf, the node is patched
    # from here.
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

    if [ "$UNTAINT" = "yes" ]; then
        info "removing control-plane taint from $KUBE_NODE_NAME"
        kubectl taint nodes "$KUBE_NODE_NAME" node-role.kubernetes.io/control-plane- || true
    fi

    info "waiting for this node to become ready"
    kubectl wait --for=condition=ready "node/${KUBE_NODE_NAME}" --timeout=240s || true
    kubectl get nodes -o wide
else
    cat <<EOF

==> joined as a worker node

Assign this node its pod subnet from a control-plane node so FeCNI can
configure it:

    kubectl patch node ${KUBE_NODE_NAME} --type=merge \\
        -p '{"spec":{"podCIDR":"${POD_CIDR}"}}'
EOF
fi
