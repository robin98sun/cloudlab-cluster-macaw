#!/usr/bin/env bash
# Two-layer node bootstrap. Runs as a CloudLab startup service on every boot.
#
#   Layer 1 (bake layer)  packages, k3s binary, BPF toolchain, prefetched
#                         container images. Skipped when
#                         /etc/testbed-image-version matches -- i.e. when
#                         booting from a golden image. This is the slow,
#                         network-dependent part; baking it is what makes a
#                         fast redeploy possible.
#   Layer 2 (boot layer)  per-instantiation config: clock, dirs, facts,
#                         containerd NRI, cluster formation, mesh install.
#                         Runs every boot; must stay idempotent and fast.
#
# Usage: bootstrap.sh <ctl|wk|lg> [--wk-hosts N --lg-hosts N
#                                  --istio-version V --no-istio]  (ctl only)
set -euo pipefail

ROLE="${1:?usage: bootstrap.sh <ctl|wk|lg> [opts]}"; shift || true
WK_HOSTS=1; LG_HOSTS=0; ISTIO_VERSION="1.31.0-rc.0"; INSTALL_ISTIO=1
while [ $# -gt 0 ]; do
    case "$1" in
        --wk-hosts)      WK_HOSTS="$2";      shift 2 ;;
        --lg-hosts)      LG_HOSTS="$2";      shift 2 ;;
        --istio-version) ISTIO_VERSION="$2"; shift 2 ;;
        --no-istio)      INSTALL_ISTIO=0;    shift   ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

IMAGE_LAYER=1          # bump when the bake layer's contents change, then rebake
# Private testbed on CloudLab's control network; a static token keeps cluster
# formation dependency-free. Not a pattern for anything internet-facing.
TOKEN="cloudlab-cluster-6b1e4f92"
K3S_INSTALLER=/usr/local/share/testbed/k3s-install.sh

REPO=/local/repository
STATE=/local/testbed
LOGDIR="$STATE/logs"

SUDO=""; SUDO_E="env"
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo -H"; SUDO_E="sudo -H -E"; fi

$SUDO mkdir -p "$LOGDIR" "$STATE/telemetry"
$SUDO chmod 0777 "$STATE" "$LOGDIR" "$STATE/telemetry"
exec > >(tee -a "$LOGDIR/bootstrap.log") 2>&1
echo "=== bootstrap role=$ROLE image_layer_wanted=$IMAGE_LAYER at $(date -Is) ==="

# ---------------------------------------------------------------- layer 1 ---
HAVE_LAYER="$(cat /etc/testbed-image-version 2>/dev/null || echo none)"
if [ "$HAVE_LAYER" = "$IMAGE_LAYER" ]; then
    echo "bake layer $IMAGE_LAYER present (golden image); skipping downloads"
else
    echo "bake layer: have=$HAVE_LAYER want=$IMAGE_LAYER; installing"
    export DEBIAN_FRONTEND=noninteractive
    for _ in 1 2 3; do $SUDO apt-get update -qq && break || sleep 5; done

    # Base tooling.
    $SUDO apt-get install -y -qq chrony python3 jq curl skopeo \
        iproute2 iputils-ping sysstat >/dev/null

    # BPF toolchain and kernel headers, for CPU and kernel telemetry.
    # linux-tools-$(uname -r) provides bpftool; the generic metapackage is a
    # fallback when the exact kernel package is missing from the archive.
    $SUDO apt-get install -y -qq clang llvm libbpf-dev libelf-dev \
        build-essential pkg-config \
        "linux-tools-$(uname -r)" linux-tools-common >/dev/null 2>&1 || \
    $SUDO apt-get install -y -qq clang llvm libbpf-dev libelf-dev \
        build-essential pkg-config linux-tools-generic >/dev/null 2>&1 || \
        echo "WARN: BPF toolchain incomplete; verify.py C04 will report it"

    $SUDO mkdir -p /usr/local/share/testbed /var/lib/rancher/k3s/agent/images
    # Cache the installer and fetch the k3s binary without starting anything.
    # The k3s version is thereby frozen into the golden image; facts.json
    # records it per node.
    $SUDO curl -sfL https://get.k3s.io -o "$K3S_INSTALLER"
    INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true \
        $SUDO_E sh "$K3S_INSTALLER" >/dev/null

    # istioctl, pinned. Kept in the bake layer so a redeploy needs no
    # download; the version is recorded in facts.json.
    if [ ! -x "/usr/local/bin/istioctl" ]; then
        ( cd /tmp && \
          curl -sfL https://istio.io/downloadIstio | \
              ISTIO_VERSION="$ISTIO_VERSION" sh - >/dev/null 2>&1 && \
          $SUDO install -m 0755 "/tmp/istio-$ISTIO_VERSION/bin/istioctl" \
              /usr/local/bin/istioctl ) \
        || echo "WARN: istioctl download failed; 'make istio' can retry"
    fi

    # Prefetch the mesh images as k3s auto-import tarballs so pod start needs
    # no registry. Not fatal: a failed prefetch means a slower first start.
    for img in "docker.io/istio/proxyv2:$ISTIO_VERSION" \
               "docker.io/istio/pilot:$ISTIO_VERSION"; do
        tarname="$(echo "$img" | tr '/:' '__').tar"
        $SUDO skopeo copy "docker://$img" \
            "docker-archive:/var/lib/rancher/k3s/agent/images/$tarname:$img" \
            >/dev/null 2>&1 \
            || echo "WARN: prefetch failed for $img; it will pull at run time"
    done

    echo "$IMAGE_LAYER" | $SUDO tee /etc/testbed-image-version >/dev/null
fi

# ---------------------------------------------------------------- layer 2 ---
$SUDO systemctl enable --now chrony >/dev/null 2>&1 || \
    $SUDO systemctl enable --now chronyd >/dev/null 2>&1 || true
$SUDO chronyc makestep >/dev/null 2>&1 || true

# containerd NRI, written before k3s starts so the first launch already has
# it. See the script for why this is a template and not an edit.
bash "$REPO/cloudlab/containerd-nri.sh" || \
    echo "WARN: NRI configuration failed; verify.py C03 will report it"

python3 - "$ROLE" "$STATE/telemetry" <<'PYFACTS' | $SUDO tee "$STATE/facts.json" >/dev/null
import json, os, socket, subprocess, sys
role, telem_dir = sys.argv[1:3]
ifaces = {}
out = subprocess.run(["ip", "-o", "-4", "addr", "show"],
                     capture_output=True, text=True).stdout
for line in out.splitlines():
    f = line.split()
    if len(f) >= 4:
        ifaces[f[1]] = f[3].split("/")[0]
def read(path):
    try:
        return open(path).read().strip()
    except OSError:
        return ""
def cmd(*a):
    try:
        return subprocess.run(a, capture_output=True, text=True).stdout.strip()
    except OSError:
        return ""
k3s_ver = cmd("/usr/local/bin/k3s", "--version")
istio_ver = cmd("/usr/local/bin/istioctl", "version", "--remote=false")
print(json.dumps({
    "role": role,
    "hostname": socket.gethostname(),
    "short_name": socket.gethostname().split(".")[0],
    "interfaces": ifaces,
    "telemetry_dir": telem_dir,
    "cpus": os.cpu_count(),
    "kernel": os.uname().release,
    "product": read("/sys/class/dmi/id/product_name"),
    "image_layer": read("/etc/testbed-image-version"),
    "cgroup_unified": os.path.exists("/sys/fs/cgroup/cgroup.controllers"),
    "btf": os.path.exists("/sys/kernel/btf/vmlinux"),
    "k3s_version": k3s_ver.splitlines()[0] if k3s_ver else "",
    "istio_version": istio_ver.splitlines()[0] if istio_ver else "",
}, indent=2))
PYFACTS

# CloudLab installs static inter-LAN routes via multi-homed nodes. Hosts with
# no interface on a LAN should not reach it; scrub the blanket route so the
# two experiment LANs stay distinguishable in measurements.
case "$ROLE" in
    ctl|lg) $SUDO ip route del 10.10.2.0/24 2>/dev/null || true ;;
esac

# Cluster formation. All control-plane traffic rides CloudLab's control
# network (the default route), keeping the experiment LANs clean.
# Resolve ctl1 from the CloudLab manifest: hostname -f can be stale during
# early boot, and /etc/hosts maps bare "ctl1" to an experiment LAN.
read -r CTL_NAME CTL_IP <<<"$(geni-get manifest 2>/dev/null | python3 -c '
import sys, xml.etree.ElementTree as ET
def t(e): return e.tag.split("}", 1)[-1]
try:
    root = ET.parse(sys.stdin).getroot()
except Exception:
    sys.exit(0)
for n in root.iter():
    if t(n) == "node" and n.get("client_id") == "ctl1":
        for s in n.iter():
            if t(s) == "host" and s.get("name"):
                print(s.get("name"), s.get("ipv4") or "")
                sys.exit(0)
' || true)"
if [ -n "${CTL_NAME:-}" ] && getent hosts "$CTL_NAME" >/dev/null 2>&1; then
    SERVER_HOST="$CTL_NAME"
elif [ -n "${CTL_IP:-}" ]; then
    SERVER_HOST="$CTL_IP"
else
    SERVER_HOST="ctl1.$(hostname -f | cut -d. -f2-)"
fi
SERVER_URL="https://${SERVER_HOST}:6443"
echo "k3s server endpoint: $SERVER_URL"

case "$ROLE" in
    ctl)
        # Static admin token (the join token, reused) so every agent can write
        # its own admin kubeconfig locally -- kubectl works on all nodes with
        # zero file distribution. Testbed trade-off, deliberate.
        $SUDO mkdir -p /etc/rancher/k3s
        echo "$TOKEN,admin,admin,system:masters" | \
            $SUDO tee /etc/rancher/k3s/admin-token.csv >/dev/null
        $SUDO chmod 600 /etc/rancher/k3s/admin-token.csv
        INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_SKIP_START=true \
        INSTALL_K3S_SKIP_ENABLE=true K3S_TOKEN="$TOKEN" \
        INSTALL_K3S_EXEC="server --disable traefik --disable servicelb \
--write-kubeconfig-mode 644 \
--kube-apiserver-arg=token-auth-file=/etc/rancher/k3s/admin-token.csv \
--node-name $(hostname -s) --node-label testbed/role=ctl" \
            $SUDO_E sh "$K3S_INSTALLER" >/dev/null
        # Never block bootstrap on service readiness; the wait loop below and
        # orchestrator/verify.py check convergence instead.
        $SUDO systemctl enable k3s >/dev/null 2>&1 || true
        $SUDO systemctl restart --no-block k3s

        EXPECTED=$((1 + WK_HOSTS + LG_HOSTS))
        echo "waiting for $EXPECTED Ready nodes"
        READY=0
        for _ in $(seq 1 90); do
            READY=$(/usr/local/bin/k3s kubectl get nodes --no-headers 2>/dev/null \
                    | awk '$2 == "Ready" {n++} END {print n+0}' || true)
            READY=${READY:-0}
            [ "$READY" -ge "$EXPECTED" ] && break
            sleep 5
        done
        echo "ready nodes: ${READY}/$EXPECTED"

        if [ "$INSTALL_ISTIO" -eq 1 ]; then
            # Non-blocking: a mesh install that stalls must not wedge the
            # startup service. Progress and failures land in the log.
            echo "starting Istio $ISTIO_VERSION install in the background"
            nohup bash "$REPO/cloudlab/install-istio.sh" "$ISTIO_VERSION" \
                >>"$LOGDIR/istio.log" 2>&1 &
        else
            echo "Istio install skipped by profile parameter"
        fi
        ;;
    wk|lg)
        INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_SKIP_START=true \
        INSTALL_K3S_SKIP_ENABLE=true K3S_URL="$SERVER_URL" K3S_TOKEN="$TOKEN" \
        INSTALL_K3S_EXEC="agent --node-name $(hostname -s) --node-label testbed/role=${ROLE}-host" \
            $SUDO_E sh "$K3S_INSTALLER" >/dev/null
        # Non-blocking: a systemctl start that waits for join would hang
        # bootstrap forever if the server is unreachable.
        $SUDO systemctl enable k3s-agent >/dev/null 2>&1 || true
        $SUDO systemctl restart --no-block k3s-agent
        echo "k3s agent joining via $SERVER_URL (non-blocking)"

        # Local admin kubeconfig: token auth against the apiserver. The CA
        # comes from the server's public /cacerts endpoint (the agent's own
        # copy is root-only). Makes plain `kubectl` work on every node.
        $SUDO mkdir -p /etc/rancher/k3s
        for _ in $(seq 1 30); do
            curl -sfk "$SERVER_URL/cacerts" | \
                $SUDO tee /etc/rancher/k3s/server-ca.crt >/dev/null || true
            [ -s /etc/rancher/k3s/server-ca.crt ] && break
            sleep 2
        done
        $SUDO chmod 644 /etc/rancher/k3s/server-ca.crt || true
        $SUDO tee /etc/rancher/k3s/k3s.yaml >/dev/null <<KCFG
apiVersion: v1
kind: Config
clusters:
- name: default
  cluster:
    server: ${SERVER_URL}
    certificate-authority: /etc/rancher/k3s/server-ca.crt
users:
- name: admin
  user:
    token: ${TOKEN}
contexts:
- name: default
  context:
    cluster: default
    user: admin
current-context: default
KCFG
        $SUDO chmod 644 /etc/rancher/k3s/k3s.yaml

        # Rejoin after bake/wipe: the server still holds this node's old
        # password secret and rejects the fresh agent as a duplicate
        # hostname. Token auth works before the join completes, so clear the
        # stale secret; the agent's retry loop then succeeds. No-op on first
        # join.
        kubectl delete secret -n kube-system \
            "$(hostname -s).node-password.k3s" --ignore-not-found \
            >/dev/null 2>&1 || true
        ;;
    *)
        echo "unknown role: $ROLE" >&2; exit 2 ;;
esac

echo "$IMAGE_LAYER" | $SUDO tee "$STATE/boot.done" >/dev/null
echo "=== bootstrap complete role=$ROLE at $(date -Is) ==="
