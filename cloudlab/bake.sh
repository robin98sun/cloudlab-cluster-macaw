#!/usr/bin/env bash
# Prepare this node for golden-image capture, then STOP -- imaging happens in
# the CloudLab portal ("Create Disk Image" on this node), not here.
#
# Keeps:  packages, BPF toolchain, k3s binary, cached installer, istioctl,
#         prefetched image tarballs, /etc/testbed-image-version
# Wipes:  every trace of cluster identity and per-boot state, so the next
#         boot forms a fresh cluster no matter which node this image lands on.
set -euo pipefail
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo -H"

[ -f /etc/testbed-image-version ] || {
    echo "no /etc/testbed-image-version -- run bootstrap.sh first"; exit 1; }

echo "== stopping k3s"
$SUDO /usr/local/bin/k3s-killall.sh >/dev/null 2>&1 || true
$SUDO systemctl disable k3s >/dev/null 2>&1 || true
$SUDO systemctl disable k3s-agent >/dev/null 2>&1 || true

echo "== wiping cluster identity (keeping agent/images tarballs)"
$SUDO find /var/lib/rancher/k3s -mindepth 1 -maxdepth 1 ! -name agent \
    -exec rm -rf {} + 2>/dev/null || true
# Keep both images/ (prefetched tarballs) and etc/ (the NRI template).
$SUDO find /var/lib/rancher/k3s/agent -mindepth 1 -maxdepth 1 \
    ! -name images ! -name etc -exec rm -rf {} + 2>/dev/null || true
$SUDO rm -rf /etc/rancher/k3s /etc/rancher/node
$SUDO rm -f /etc/systemd/system/k3s.service /etc/systemd/system/k3s.service.env
$SUDO rm -f /etc/systemd/system/k3s-agent.service /etc/systemd/system/k3s-agent.service.env
$SUDO systemctl daemon-reload

echo "== wiping per-boot state"
$SUDO rm -rf /local/testbed

echo
echo "ready to image: layer version $(cat /etc/testbed-image-version)"
echo "next: portal -> this node -> Create Disk Image -> pin the URN (with"
echo "version) as GOLDEN_IMAGE in profile.py and commit."
