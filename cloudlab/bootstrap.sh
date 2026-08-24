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
#                         CNI, service mesh. Runs every boot; idempotent
#                         and fast.
#
# Usage: bootstrap.sh <ctl|wk|st|ng|qs|dp> [--wk-hosts N --st-hosts N
#                                           --ng-hosts N --qs-hosts N
#                                           --dp-hosts N
#                                           --istio-version V --no-istio]  (ctl only)
#
# Roles: ctl control plane + private registry; wk worker; st standby;
#        ng gateway; qs query scheduler; dp dispatcher.
#
# wk/st/ng/qs join the cluster. dp does NOT -- it drives load over ssh, and a
# load generator that is also schedulable can end up hosting the workload it
# is measuring.
set -euo pipefail

ROLE="${1:?usage: bootstrap.sh <ctl|wk|st|ng|qs|dp> [opts]}"; shift || true
WK_HOSTS=1; ST_HOSTS=0; NG_HOSTS=0; QS_HOSTS=0; DP_HOSTS=0; LG_HOSTS=0
ISTIO_VERSION="1.31.0-rc.0"; INSTALL_ISTIO=1
while [ $# -gt 0 ]; do
    case "$1" in
        --wk-hosts)      WK_HOSTS="$2";      shift 2 ;;
        --st-hosts)      ST_HOSTS="$2";      shift 2 ;;
        --ng-hosts)      NG_HOSTS="$2";      shift 2 ;;
        --qs-hosts)      QS_HOSTS="$2";      shift 2 ;;
        --dp-hosts)      DP_HOSTS="$2";      shift 2 ;;
        # Retained so an older portal profile pinned to a previous commit
        # still instantiates instead of failing on an unknown argument.
        --lg-hosts)      LG_HOSTS="$2";      shift 2 ;;
        --istio-version) ISTIO_VERSION="$2"; shift 2 ;;
        --no-istio)      INSTALL_ISTIO=0;    shift   ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

IMAGE_LAYER=4          # bump when the bake layer's contents change, then rebake

# Kubernetes minor series. Pinned and held so a later apt upgrade cannot move
# the cluster underneath a run.
K8S_SERIES="${K8S_SERIES:-v1.30}"
CALICO_VERSION="${CALICO_VERSION:-v3.28.0}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"

# Fixed bootstrap token and CA key: every node forms the cluster without any
# file distribution or coordination. A private testbed on an isolated
# control network; not a pattern for anything internet-facing.
KUBE_TOKEN="ab1cd2.3ef4gh5ij6kl7mn8"
CERT_KEY="3191a54ae43f472b9c8460f2bca1838d7d18afcbb41f408eba50dc1083264c18"   # 32 bytes, hex; kubeadm rejects any other length

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

    # helm: install-monitoring.sh runs on this node and needs it.
    if ! command -v helm >/dev/null 2>&1; then
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
            | $SUDO bash >/dev/null 2>&1 || echo "WARN: helm install failed"
    fi

    # istioctl, pinned. Kept in the bake layer so a redeploy needs no download.
    if [ ! -x /usr/local/bin/istioctl ]; then
        ( cd /tmp && \
          curl -sfL https://istio.io/downloadIstio | \
              ISTIO_VERSION="$ISTIO_VERSION" sh - >/dev/null 2>&1 && \
          $SUDO install -m 0755 "/tmp/istio-$ISTIO_VERSION/bin/istioctl" \
              /usr/local/bin/istioctl ) \
        || echo "WARN: istioctl download failed; 'make istio' can retry"
    fi

    # Image cache. Every redeploy would otherwise pull calico + istio-proxy on
    # every node from Docker Hub, whose rate limits refuse exactly the
    # "instantiate, test, tear down, repeat" pattern this testbed lives by.
    # Tarballs go on the SYSTEM disk (captured by "Create Disk Image"); the
    # blockstore is blank on every re-instantiation, so caching there is a
    # no-op across deployments. Imported into containerd in layer 2.
    IMG_CACHE=/usr/local/share/testbed/images
    $SUDO mkdir -p "$IMG_CACHE"
    PREFETCH_IMAGES="$( (kubeadm config images list \
            --kubernetes-version "$(kubeadm version -o short)" 2>/dev/null; \
        echo "docker.io/calico/cni:$CALICO_VERSION"; \
        echo "docker.io/calico/node:$CALICO_VERSION"; \
        echo "docker.io/calico/kube-controllers:$CALICO_VERSION"; \
        echo "docker.io/istio/pilot:$ISTIO_VERSION"; \
        echo "docker.io/istio/proxyv2:$ISTIO_VERSION"; \
        grep -vE "^\s*(#|$)" "$REPO/cloudlab/prefetch-extra.images" 2>/dev/null) | sort -u )"
    # manifest.txt maps tarball -> image name; the boot layer reads it back.
    # Reconstructing the name from the filename is not reliable (underscores
    # are legal in image names), so it is recorded, not derived.
    $SUDO rm -f "$IMG_CACHE/manifest.txt.new"
    for img in $PREFETCH_IMAGES; do
        tarname="$(echo "$img" | tr '/:' '__').tar"
        echo "$tarname $img" | $SUDO tee -a "$IMG_CACHE/manifest.txt.new" >/dev/null
        if $SUDO test -s "$IMG_CACHE/$tarname"; then
            echo "cached: $img"
            continue
        fi
        echo "prefetching $img"
        $SUDO skopeo copy "docker://$img" \
            "docker-archive:$IMG_CACHE/$tarname:$img" >/dev/null 2>&1 \
            || { echo "WARN: prefetch failed for $img (will pull at run time)"; \
                 $SUDO rm -f "$IMG_CACHE/$tarname"; }
    done
    $SUDO mv -f "$IMG_CACHE/manifest.txt.new" "$IMG_CACHE/manifest.txt"
    echo "image cache: $($SUDO du -sh "$IMG_CACHE" 2>/dev/null | cut -f1) in $IMG_CACHE"

    echo "$IMAGE_LAYER" | $SUDO tee /etc/testbed-image-version >/dev/null
fi

# ---------------------------------------------------------------- layer 2 ---
$SUDO systemctl enable --now chrony >/dev/null 2>&1 || \
    $SUDO systemctl enable --now chronyd >/dev/null 2>&1 || true
$SUDO chronyc makestep >/dev/null 2>&1 || true

# --- storage: the root filesystem is ~64 GB, too small for image churn ------
# Returns non-zero rather than exiting: a disk problem must not take down
# cluster formation. set -e is suspended inside a function used as a
# condition, so every step checks its own result.
setup_shared_storage() {
    local rootdisk dev fstype
    $SUDO mkdir -p "$SHARED"
    if mountpoint -q "$SHARED"; then
        echo "shared storage already mounted at $SHARED"
        return 0
    fi
    rootdisk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1 || true)
    dev=$(lsblk -rno NAME,TYPE,FSTYPE,MOUNTPOINT | \
          awk -v rd="$rootdisk" '($2=="disk") && $3=="" && $4=="" && $1!=rd {print $1}' | \
          while read -r d; do
              echo "$(lsblk -bdno SIZE "/dev/$d" 2>/dev/null || echo 0) $d"
          done | sort -rn | head -1 | awk '{print $2}')
    if [ -z "$dev" ] || [ ! -b "/dev/$dev" ]; then
        echo "no spare disk found"
        return 1
    fi

    # Probe as root. Unprivileged blkid cannot open the device and exits 0
    # with no output, which reads as "filesystem present" and silently skips
    # the mkfs below -- the mount then fails on a raw disk.
    fstype=$($SUDO blkid -o value -s TYPE "/dev/$dev" 2>/dev/null || true)
    case "$fstype" in
        ext2|ext3|ext4|xfs)
            echo "/dev/$dev already carries $fstype" ;;
        *)
            echo "formatting /dev/$dev (found ${fstype:-no filesystem})"
            $SUDO mkfs.ext4 -q -F "/dev/$dev" || return 1 ;;
    esac

    if ! $SUDO mount "/dev/$dev" "$SHARED"; then
        # A leftover signature blkid recognises but the kernel will not
        # mount. Reformat once, then give up.
        echo "mount failed; reformatting /dev/$dev and retrying"
        $SUDO mkfs.ext4 -q -F "/dev/$dev" || return 1
        $SUDO mount "/dev/$dev" "$SHARED" || return 1
    fi
    grep -q " $SHARED " /etc/fstab || \
        echo "/dev/$dev $SHARED ext4 defaults,nofail 0 2" | $SUDO tee -a /etc/fstab >/dev/null
    echo "shared storage: /dev/$dev -> $SHARED"
    return 0
}

if ! setup_shared_storage; then
    echo "WARNING: no shared storage; $SHARED stays on the root filesystem"
    echo "         (about 64 GB). Expect DiskPressure under image churn."
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

# Import the baked image tarballs before kubeadm or the kubelet can trigger
# a registry pull. The image store lives on the blockstore, which is blank
# on a fresh instantiation -- the tarballs on the system disk are what
# survive imaging. Idempotent: images already present are skipped.
IMG_CACHE=/usr/local/share/testbed/images
if [ -f "$IMG_CACHE/manifest.txt" ]; then
    PRESENT="$($SUDO ctr -n k8s.io images ls -q 2>/dev/null || true)"
    while read -r tarname ref; do
        [ -n "$tarname" ] && [ -n "$ref" ] || continue
        [ -s "$IMG_CACHE/$tarname" ] || continue
        if echo "$PRESENT" | grep -qxF "$ref"; then
            continue
        fi
        echo "importing $ref"
        $SUDO ctr -n k8s.io images import "$IMG_CACHE/$tarname" >/dev/null \
            || echo "WARN: import failed for $tarname"
    done < "$IMG_CACHE/manifest.txt"
    echo "containerd images: $($SUDO ctr -n k8s.io images ls -q 2>/dev/null | wc -l)"
fi

# Node IP and kubelet data directory.
#
# --node-ip matters more than it looks. CloudLab nodes are multi-homed, and
# an unpinned kubelet picks whichever interface it enumerates first: it may
# choose the experiment LAN on some nodes and the control network on others.
# The control plane then has no route to half the cluster, and everything that
# depends on the API server reaching a pod -- admission webhooks above all --
# times out with an error that names none of this.
# So the address must be pinned, and every node must pin to the same LAN.
#
# This used to pin to the default-route source address, on the reasoning that
# the CloudLab control network is shared by every node "and carries no measured
# traffic". The first half is true; the second is not. The node IP is exactly
# what pod traffic follows -- Calico is pinned below to
# IP_AUTODETECTION_METHOD=kubernetes-internal-ip -- so pinning there put ALL
# measured traffic on the control interface. On c6420 that is a 1 Gb/s link
# beside an idle 10 Gb/s experiment LAN: measured 846 Mbit/s against
# 8885 Mbit/s, a 10.5x ceiling sitting directly upstream of the tail latency
# these experiments evaluate.
#
# Pick by capability, never by interface name -- the hardware type is a profile
# parameter and c6420 will not be the last one. Highest link speed among
# physical, up, RFC1918-addressed interfaces wins; ties break on name so every
# node applies an identical rule and lands on the same LAN, which is the
# consistency property the original was protecting. Restricting to private
# addresses is what separates an experiment LAN from the routable control
# network on CloudLab.
select_node_ip() {
    best_if=""; best_ip=""; best_speed=-1
    for path in /sys/class/net/*; do
        cand_if=$(basename "$path")
        # Physical devices only. Virtual interfaces -- docker0, cali*, veth,
        # tunl, bridges -- have no device symlink. A property check rather than
        # a name blocklist, so a virtual driver nobody has seen yet cannot slip
        # through by failing to match a pattern.
        [ -e "$path/device" ] || continue
        [ "$(cat "$path/operstate" 2>/dev/null)" = "up" ] || continue
        cand_ip=$(ip -4 -brief addr show "$cand_if" 2>/dev/null \
                  | awk '{print $3}' | cut -d/ -f1 | head -1)
        [ -n "$cand_ip" ] || continue
        case "$cand_ip" in
            10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;;
            *) continue ;;
        esac
        speed=$(cat "$path/speed" 2>/dev/null || echo 0)
        case "$speed" in ""|*[!0-9]*) speed=0 ;; esac
        if [ "$speed" -gt "$best_speed" ] \
           || { [ "$speed" -eq "$best_speed" ] && [ "$cand_if" \< "$best_if" ]; }; then
            best_speed=$speed; best_if=$cand_if; best_ip=$cand_ip
        fi
    done
    [ -n "$best_ip" ] || return 1
    echo "$best_ip $best_if $best_speed"
}
NODE_IP=""
if NODE_SEL="$(select_node_ip)"; then
    NODE_IP="${NODE_SEL%% *}"
    echo "node IP: $NODE_IP (${NODE_SEL#* } Mb/s, fastest private interface)"
else
    # No private interface at all: fall back to the previous behaviour rather
    # than leaving kubelet to guess, which is the failure described above.
    NODE_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
    if [ -z "$NODE_IP" ]; then
        echo "WARNING: no private interface and no default route; kubelet will guess"
    else
        echo "node IP: $NODE_IP (no private interface found; using the default route)"
    fi
fi
# These go in /etc/default/kubelet, not a systemd drop-in. kubeadm's unit
# reads that path with EnvironmentFile=, and systemd applies EnvironmentFile
# after every Environment= setting regardless of drop-in order -- so a
# drop-in is silently overridden by the empty KUBELET_EXTRA_ARGS the package
# ships there, with no error anywhere.
$SUDO tee /etc/default/kubelet >/dev/null <<KUBELET
KUBELET_EXTRA_ARGS=--root-dir=$SHARED/k8s_cache/kubelet${NODE_IP:+ --node-ip=$NODE_IP}
KUBELET
$SUDO rm -f /etc/systemd/system/kubelet.service.d/20-root-dir.conf \
            /etc/systemd/system/kubelet.service.d/20-testbed.conf
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
# CloudLab returns names like ctl1.<user>-NNNNN.<proj>-PG0.utah.cloudlab.us.
# DNS is case-insensitive, but kubeadm validates against RFC-1123, which
# requires lowercase -- an uppercase project suffix is rejected outright.
SERVER_HOST="$(echo "$SERVER_HOST" | tr '[:upper:]' '[:lower:]')"
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

        if $SUDO_E kubectl apply -f \
            "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml"
        then
            # Default autodetection is first-found, which on a multi-homed
            # node disagrees with --node-ip above. Follow the node IP.
            $SUDO_E kubectl -n kube-system set env daemonset/calico-node \
                IP_AUTODETECTION_METHOD=kubernetes-internal-ip >/dev/null \
                || echo "WARN: could not pin Calico IP autodetection"
        else
            echo "WARN: Calico apply failed; retry with 'make cni'"
        fi

        # Dispatchers are deliberately absent from the cluster, so they are
        # not counted here -- waiting for them would never finish.
        EXPECTED=$((1 + WK_HOSTS + ST_HOSTS + NG_HOSTS + QS_HOSTS + LG_HOSTS))
        echo "waiting for $EXPECTED Ready nodes"
        READY=0
        for _ in $(seq 1 120); do
            READY=$($SUDO_E kubectl get nodes --no-headers 2>/dev/null \
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
    dp)
        # Prepared exactly like any other node -- storage, containerd,
        # kernel settings, tooling -- but never joined. See the header.
        echo "dispatcher host: prepared, not joined to the cluster by design"
        ;;
    wk|st|ng|qs|lg)
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
