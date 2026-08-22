#!/usr/bin/env bash
# Install the Istio control plane on ctl1 and prepare a meshed namespace.
# Runs in the background from bootstrap.sh, or by hand via `make istio`.
#
# Idempotent: istioctl install converges, and the namespace/label steps use
# apply semantics. Safe to re-run after a partial failure.
set -euo pipefail

ISTIO_VERSION="${1:-1.31.0-rc.0}"
NS="${TESTBED_NS:-testbed}"
SUDO=""; SUDO_E="env"
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo -H"; SUDO_E="sudo -H -E"; fi
KUBECTL="kubectl"

echo "=== istio install $ISTIO_VERSION at $(date -Is) ==="

if ! command -v istioctl >/dev/null 2>&1; then
    echo "istioctl missing; downloading $ISTIO_VERSION"
    cd /tmp
    curl -sfL https://istio.io/downloadIstio | \
        ISTIO_VERSION="$ISTIO_VERSION" sh -
    $SUDO install -m 0755 "/tmp/istio-$ISTIO_VERSION/bin/istioctl" \
        /usr/local/bin/istioctl
fi

echo "istioctl: $(istioctl version --remote=false 2>/dev/null || echo unknown)"

# Wait for the apiserver rather than assuming it is up: this script starts
# moments after kubeadm init returns.
export KUBECONFIG=/etc/kubernetes/admin.conf
for _ in $(seq 1 60); do
    $SUDO_E $KUBECTL get --raw /readyz >/dev/null 2>&1 && break
    sleep 5
done

export KUBECONFIG=/etc/kubernetes/admin.conf

# The default profile is the right starting point for a sidecar mesh: an
# ingress gateway plus istiod, no ambient components.
#
# ENABLE_NATIVE_SIDECARS makes istiod inject the proxy as a native sidecar --
# an initContainer with restartPolicy: Always -- instead of an ordinary
# container. That is what guarantees the proxy starts before the application
# containers and stops after them. Without it the application can serve its
# first request before the proxy is ready, and can lose its last responses on
# shutdown. Kubernetes has supported this since 1.29; Istio does not enable
# it by default on every version, so it is set explicitly rather than left to
# whatever the combination happens to default to.
#
# Retried, because image pulls on a fresh node can lose a race with the
# container runtime.
ok=0
for attempt in 1 2 3; do
    if $SUDO_E istioctl install --set profile=default \
            --set values.pilot.env.ENABLE_NATIVE_SIDECARS=true -y; then ok=1; break; fi
    echo "istioctl install attempt $attempt failed; retrying in 30s"
    sleep 30
done
[ "$ok" -eq 1 ] || { echo "ERROR: istioctl install failed three times"; exit 1; }

$SUDO_E $KUBECTL create namespace "$NS" --dry-run=client -o yaml | \
    $SUDO_E $KUBECTL apply -f -
$SUDO_E $KUBECTL label namespace "$NS" istio-injection=enabled --overwrite

echo "waiting for istiod"
$SUDO_E $KUBECTL -n istio-system rollout status deploy/istiod --timeout=300s || \
    echo "WARN: istiod rollout did not report ready in time"

echo "=== istio install complete at $(date -Is) ==="
$SUDO_E $KUBECTL -n istio-system get pods
