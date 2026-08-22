#!/usr/bin/env bash
# Prepare this node for golden-image capture, then STOP -- imaging happens in
# the CloudLab portal ("Create Disk Image" on this node), not here.
#
# Keeps:  packages, BPF toolchain, containerd, kubeadm/kubelet/kubectl,
#         istioctl, /etc/testbed-image-version
# Wipes:  every trace of cluster identity and per-boot state, so the next
#         boot forms a fresh cluster no matter which node this image lands on.
set -euo pipefail
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo -H"

[ -f /etc/testbed-image-version ] || {
    echo "no /etc/testbed-image-version -- run bootstrap.sh first"; exit 1; }

echo "== tearing down the cluster"
$SUDO kubeadm reset -f >/dev/null 2>&1 || true
$SUDO rm -rf /etc/kubernetes /var/lib/etcd /etc/cni/net.d
$SUDO rm -rf /var/lib/kubelet/* /mnt/shared-storage/k8s_cache/kubelet/* 2>/dev/null || true
$SUDO systemctl stop kubelet >/dev/null 2>&1 || true
$SUDO iptables -F 2>/dev/null || true

echo "== wiping per-boot state"
$SUDO rm -rf /local/testbed

echo
echo "kept: packages, BPF toolchain, kubeadm/kubelet/kubectl (held), containerd,"
echo "      istioctl, /etc/testbed-image-version"
echo "ready to image: layer version $(cat /etc/testbed-image-version)"
echo "next: portal -> this node -> Create Disk Image -> pin the URN (with"
echo "version) as GOLDEN_IMAGE in profile.py and commit."
