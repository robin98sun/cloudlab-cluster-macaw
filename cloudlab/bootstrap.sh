#!/usr/bin/env bash
# Two-layer node bootstrap. Runs as a CloudLab startup service on every boot.
#
#   Layer 1 (bake layer)  packages: containerd, kubeadm/kubelet/kubectl,
#                         the BPF toolchain, istioctl. Skipped when
#                         /etc/testbed-image-version matches -- i.e. when
#                         booting from a golden image. This is the slow,
#                         network-dependent part; baking it is what makes a
#                         fast redeploy possible.
#   Layer 2 (boot layer)  per-instantiation config: clock, storage,
#                         containerd, kernel settings, cluster formation,
#                         CNI, mesh. Runs every boot; idempotent and fast.
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

IMAGE_LAYER=2          # bump when the bake layer's contents change, then rebake

# Kubernetes minor series. Pinned and held so a later apt upgrade cannot move
# the cluster underneath a run.
K8S_SERIES="${K8S_SERIES:-v1.30}"
CALICO_VERSION="${CALICO_VERSION:-v3.28.0}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"

# Fixed bootstrap token and CA key: every node forms the cluster without any
# file distribution or coordination. A private testbed on an isolated
# control network; not a pattern for anything internet-facing.
KUBE_TOKEN="ab1cd2.3ef4gh5ij6kl7mn8"
CERT_KEY="6b1e4f92a7c3d05e8f1b2a4c6d8e0f13579bdf2468ace013579bdf2468ace0135"

REPO=/local/repository
STATE=/local/testbed
LOGDIR="$STATE/logs"
SHARED=/mnt/shared-storage

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

    $SUDO apt-get install -y -qq apt-transport-https ca-certificates gpg \
        chrony python3 jq curl skopeo iproute2 iputils-ping sysstat >/dev/null

    # BPF toolchain and kernel BTF, for CPU and kernel telemetry.
    $SUDO apt-get install -y -qq clang llvm libbpf-dev libelf-dev \
        build-essential pkg-config \
        "linux-tools-$(uname -r)" linux-tools-common >/dev/null 2>&1 || \
    $SUDO apt-get install -y -qq clang llvm libbpf-dev libelf-dev \
        build-essential pkg-config linux-tools-generic >/dev/null 2>&1 || \
        echo "WARN: BPF toolchain incomplete; verify.py C04 will report it"

    # containerd from the distribution. jammy-updates carries 2.x, which is
    # well past the 1.7 release that introduced NRI.
    $SUDO apt-get install -y -qq containerd >/dev/null
    containerd --version

    # Kubernetes packages, pinned to one minor series.
    $SUDO mkdir -p /etc/apt/keyrings
    $SUDO rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    ok=0
    for _ in 1 2 3 4 5; do
        if curl -fsSL "https://pkgs.k8s.io/core:/stable:/$K8S_SERIES/deb/Release.key" \
             -o /tmp/k8s.key 2>/dev/null &&
           $SUDO gpg --dearmor --batch \
             -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg /tmp/k8s.key 2>/dev/null
        then ok=1; rm -f /tmp/k8s.key; break; fi
        sleep 3
    done
    [ "$ok" -eq 1 ] || { echo "ERROR: could not fetch the Kubernetes repo key"; exit 1; }
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_SERIES/deb/ /" \
        | $SUDO tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq kubelet kubeadm kubectl >/dev/null
    $SUDO apt-mark hold kubelet kubeadm kubectl >/dev/null
    kubeadm version -o short

    # istioctl, pinned. Kept in the bake layer so a redeploy needs no download.
    if [ ! -x /usr/local/bin/istioctl ]; then
        ( cd /tmp && \
          curl -sfL https://istio.io/downloadIstio | \
              ISTIO_VERSION="$ISTIO_VERSION" sh - >/dev/null 2>&1 && \
          $SUDO install -m 0755 "/tmp/istio-$ISTIO_VERSION/bin/istioctl" \
              /usr/local/bin/istioctl ) \
        || echo "WARN: istioctl download failed; 'make istio' can retry"
    fi

    echo "$IMAGE_LAYER" | $SUDO tee /etc/testbed-image-version >/dev/null
fi

# ---------------------------------------------------------------- layer 2 ---
$SUDO systemctl enable --now chrony >/dev/null 2>&1 || \
    $SUDO systemctl enable --now chronyd >/dev/null 2>&1 || true
$SUDO chronyc makestep >/dev/null 2>&1 || true

# --- storage: the root filesystem is ~64 GB, too small for image churn ------
$SUDO mkdir -p "$SHARED"
if ! mountpoint -q "$SHARED"; then
    ROOTDISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)
    DEV=$(lsblk -rno NAME,TYPE,FSTYPE,MOUNTPOINT | \
          awk -v rd="$ROOTDISK" '($2=="disk") && $3=="" && $4=="" && $1!=rd {print $1}' | \
          while read -r d; do
              echo "$(lsblk -bdno SIZE "/dev/$d" 2>/dev/null || echo 0) $d"
          done | sort -rn | head -1 | awk '{print $2}')
    if [ -n "$DEV" ] && [ -b "/dev/$DEV" ]; then
        blkid "/dev/$DEV" >/dev/null 2>&1 || $SUDO mkfs.ext4 -q -F "/dev/$DEV"
        $SUDO mount "/dev/$DEV" "$SHARED"
        grep -q " $SHARED " /etc/fstab || \
            echo "/dev/$DEV $SHARED ext4 defaults,nofail 0 2" | $SUDO tee -a /etc/fstab >/dev/null
        echo "shared storage: /dev/$DEV -> $SHARED"
    else
        echo "WARNING: no spare disk found; $SHARED is on the root filesystem"
    fi
fi
$SUDO chmod 0777 "$SHARED"
$SUDO mkdir -p "$SHARED/k8s_cache/containerd" "$SHARED/k8s_cache/kubelet"

# --- kernel prerequisites ---------------------------------------------------
$SUDO swapoff -a || true
$SUDO sed -i '/\sswap\s/s/^/#/' /etc/fstab || true
$SUDO modprobe overlay || true
$SUDO modprobe br_netfilter || true
printf 'overlay\nbr_netfilter\n' | $SUDO tee /etc/modules-load.d/k8s.conf >/dev/null
$SUDO tee /etc/sysctl.d/99-k8s.conf >/dev/null <<'SYSCTL'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
fs.file-max                         = 2097152
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 1048576
SYSCTL
$SUDO sysctl --system >/dev/null 2>&1 || true
grep -q 'cosched-cloudlab' /etc/security/limits.conf 2>/dev/null || \
    printf '# cosched-cloudlab\n* soft nofile 1048576\n* hard nofile 1048576\n' \
    | $SUDO tee -a /etc/security/limits.conf >/dev/null

# --- containerd -------------------------------------------------------------
bash "$REPO/cloudlab/containerd-config.sh" "$SHARED/k8s_cache/containerd"

# Kubelet data on the large disk too.
$SUDO mkdir -p /etc/systemd/system/kubelet.service.d
$SUDO tee /etc/systemd/system/kubelet.service.d/20-root-dir.conf >/dev/null <<KUBELET
[Service]
Environment="KUBELET_EXTRA_ARGS=--root-dir=$SHARED/k8s_cache/kubelet"
KUBELET
$SUDO systemctl daemon-reload

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
def read(p):
    try: return open(p).read().strip()
    except OSError: return ""
def cmd(*a):
    try: return subprocess.run(a, capture_output=True, text=True).stdout.strip()
    except OSError: return ""
print(json.dumps({
    "role": role, "hostname": socket.gethostname(),
    "short_name": socket.gethostname().split(".")[0],
    "interfaces": ifaces, "telemetry_dir": telem_dir,
    "cpus": os.cpu_count(), "kernel": os.uname().release,
    "product": read("/sys/class/dmi/id/product_name"),
    "image_layer": read("/etc/testbed-image-version"),
    "cgroup_unified": os.path.exists("/sys/fs/cgroup/cgroup.controllers"),
    "btf": os.path.exists("/sys/kernel/btf/vmlinux"),
    "containerd_version": cmd("containerd", "--version"),
    "kubeadm_version": cmd("kubeadm", "version", "-o", "short"),
    "istio_version": (cmd("istioctl", "version", "--remote=false") or "").splitlines()[:1],
}, indent=2))
PYFACTS

case "$ROLE" in
    ctl|lg) $SUDO ip route del 10.10.2.0/24 2>/dev/null || true ;;
esac

# --- cluster formation ------------------------------------------------------
# Resolve ctl1 from the CloudLab manifest: hostname -f can be stale during
# early boot, and /etc/hosts maps bare "ctl1" to an experiment LAN. All
# Kubernetes traffic belongs on the control network.
read -r CTL_NAME CTL_IP <<<"$(geni-get manifest 2>/dev/null | python3 -c '
import sys, xml.etree.ElementTree as ET
def t(e): return e.tag.split("}", 1)[-1]
try: root = ET.parse(sys.stdin).getroot()
except Exception: sys.exit(0)
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
ENDPOINT="${SERVER_HOST}:6443"
echo "control plane endpoint: $ENDPOINT"

$SUDO systemctl enable kubelet >/dev/null 2>&1 || true

case "$ROLE" in
    ctl)
        if [ ! -f /etc/kubernetes/admin.conf ]; then
            $SUDO kubeadm init \
                --control-plane-endpoint "$ENDPOINT" \
                --pod-network-cidr "$POD_CIDR" \
                --token "$KUBE_TOKEN" --token-ttl 0 \
                --certificate-key "$CERT_KEY" --upload-certs \
                --node-name "$(hostname -s)" \
                --ignore-preflight-errors=NumCPU,Mem
        else
            echo "control plane already initialised"
        fi

        export KUBECONFIG=/etc/kubernetes/admin.conf
        # Readable by every local account: kubectl then works for any user on
        # the node without copying files around.
        $SUDO chmod 0644 /etc/kubernetes/admin.conf
        for u in "$(logname 2>/dev/null || echo root)" ubuntu; do
            h=$(getent passwd "$u" | cut -d: -f6 || true)
            [ -n "$h" ] && [ -d "$h" ] || continue
            $SUDO mkdir -p "$h/.kube"
            $SUDO cp -f /etc/kubernetes/admin.conf "$h/.kube/config"
            $SUDO chown -R "$u" "$h/.kube" 2>/dev/null || true
        done

        $SUDO -E kubectl apply -f \
            "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml" \
            || echo "WARN: Calico apply failed; retry with 'make cni'"

        EXPECTED=$((1 + WK_HOSTS + LG_HOSTS))
        echo "waiting for $EXPECTED Ready nodes"
        READY=0
        for _ in $(seq 1 120); do
            READY=$($SUDO -E kubectl get nodes --no-headers 2>/dev/null \
                    | awk '$2 == "Ready" {n++} END {print n+0}' || true)
            READY=${READY:-0}
            [ "$READY" -ge "$EXPECTED" ] && break
            sleep 5
        done
        echo "ready nodes: ${READY}/$EXPECTED"

        if [ "$INSTALL_ISTIO" -eq 1 ]; then
            echo "starting Istio $ISTIO_VERSION install in the background"
            nohup bash "$REPO/cloudlab/install-istio.sh" "$ISTIO_VERSION" \
                >>"$LOGDIR/istio.log" 2>&1 &
        else
            echo "Istio install skipped by profile parameter"
        fi
        ;;
    wk|lg)
        if [ ! -f /etc/kubernetes/kubelet.conf ]; then
            # The API server may not be up yet; retry rather than fail the
            # startup service.
            joined=0
            for attempt in $(seq 1 60); do
                if $SUDO kubeadm join "$ENDPOINT" \
                        --token "$KUBE_TOKEN" \
                        --discovery-token-unsafe-skip-ca-verification \
                        --node-name "$(hostname -s)" \
                        --ignore-preflight-errors=NumCPU,Mem
                then joined=1; break; fi
                echo "join attempt $attempt failed; retrying in 10s"
                $SUDO kubeadm reset -f >/dev/null 2>&1 || true
                sleep 10
            done
            [ "$joined" -eq 1 ] || { echo "ERROR: could not join the cluster"; exit 1; }
        else
            echo "already joined"
        fi
        ;;
    *)
        echo "unknown role: $ROLE" >&2; exit 2 ;;
esac

echo "$IMAGE_LAYER" | $SUDO tee "$STATE/boot.done" >/dev/null
echo "=== bootstrap complete role=$ROLE at $(date -Is) ==="
