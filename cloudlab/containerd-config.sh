#!/usr/bin/env bash
# Configure containerd for Kubernetes: systemd cgroups, NRI, and a data root
# on the large disk.
#
# Why a drop-in and not sed: the usual recipe rewrites the generated
# config.toml with `sed s/SystemdCgroup = false/SystemdCgroup = true/`. That
# depends on generated text, and containerd's defaults and quoting change
# between versions -- containerd 2.x renamed the CRI plugin and switched to
# config version 3. A pattern written for one release silently matches
# nothing on the next, leaving a cluster that looks configured and is not.
#
# Instead: generate the defaults, prepend an `imports` line (valid TOML only
# at the top, before any table), and put every override in our own file.
# Nothing pattern-matches generated content.
#
# Idempotent. Restarts containerd only when the configuration changed.
set -euo pipefail

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo -H"

DATA_ROOT="${1:-/var/lib/containerd}"
CONF=/etc/containerd/config.toml
DROPIN_DIR=/etc/containerd/conf.d
DROPIN="$DROPIN_DIR/10-testbed.toml"

$SUDO mkdir -p /etc/containerd "$DROPIN_DIR" /etc/nri/conf.d /opt/nri/plugins \
              /var/run/nri "$DATA_ROOT"

# containerd 2.x renamed the CRI runtime plugin and uses config version 3.
RAW="$(containerd --version 2>/dev/null | awk '{print $3}' | sed 's/^v//')"
MAJOR="${RAW%%.*}"; MAJOR="${MAJOR:-1}"
if [ "$MAJOR" -ge 2 ]; then
    CRI_RUNTIME="io.containerd.cri.v1.runtime"
    CONF_VERSION=3
else
    CRI_RUNTIME="io.containerd.grpc.v1.cri"
    CONF_VERSION=2
fi
echo "containerd $RAW -> config version $CONF_VERSION, CRI plugin $CRI_RUNTIME"

TMP="$(mktemp)"
{
    # Top-level keys must precede every table, so this line goes first.
    echo "imports = ['$DROPIN_DIR/*.toml']"
    containerd config default
} > "$TMP"
$SUDO install -m 0644 "$TMP" "$CONF"
rm -f "$TMP"

TMPD="$(mktemp)"
cat > "$TMPD" <<DROP
version = $CONF_VERSION

# Image and snapshot data on the large disk: the root filesystem is small
# enough that image churn causes DiskPressure evictions.
root = '$DATA_ROOT'

# Kubernetes requires the systemd cgroup driver when the host is systemd.
# It also produces the kubepods.slice/... layout that the cgroup and PSI
# readers expect; the cgroupfs driver produces kubepods/... and they see
# nothing.
[plugins.'$CRI_RUNTIME'.containerd.runtimes.runc.options]
  SystemdCgroup = true

[plugins.'io.containerd.nri.v1.nri']
  disable = false
  disable_connections = false
  plugin_config_path = '/etc/nri/conf.d'
  plugin_path = '/opt/nri/plugins'
  plugin_registration_timeout = '5s'
  plugin_request_timeout = '2s'
  socket_path = '/var/run/nri/nri.sock'
DROP

if $SUDO test -f "$DROPIN" && $SUDO cmp -s "$TMPD" "$DROPIN"; then
    changed=0
else
    changed=1
fi
$SUDO install -m 0644 "$TMPD" "$DROPIN"
rm -f "$TMPD"

$SUDO systemctl enable containerd >/dev/null 2>&1 || true
if [ "$changed" -eq 1 ] || ! systemctl is-active --quiet containerd; then
    $SUDO systemctl restart containerd
fi

# Fail loudly here rather than letting kubeadm fail later with a vaguer error.
for _ in $(seq 1 20); do
    [ -S /run/containerd/containerd.sock ] && break
    sleep 1
done
[ -S /run/containerd/containerd.sock ] || {
    echo "ERROR: containerd socket did not appear" >&2
    $SUDO journalctl -u containerd --no-pager -n 30 >&2 || true
    exit 1; }

echo "containerd configured: root=$DATA_ROOT, systemd cgroups, NRI enabled"
