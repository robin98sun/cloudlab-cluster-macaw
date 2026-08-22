#!/usr/bin/env bash
# Configure containerd for Kubernetes: systemd cgroups, NRI, and a data root
# on the large disk.
#
# The file written here contains only the overrides. containerd applies its
# built-in defaults for everything else, so `containerd config default` is
# not needed -- it only prints those same defaults explicitly.
#
# Why not the usual recipe: it generates the default file and rewrites it
# with `sed s/SystemdCgroup = false/SystemdCgroup = true/`. That depends on
# generated text, and containerd's defaults change between releases -- 2.x
# renamed the CRI plugin and moved to config version 3. A pattern written
# for one release silently matches nothing on the next, leaving a cluster
# that looks configured and is not. Writing only our own keys means there is
# no generated text to match against.
#
# The effective configuration is read back from containerd itself at the end,
# rather than assumed from the file.
#
# Idempotent. Restarts containerd only when the configuration changed.
set -euo pipefail

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo -H"

DATA_ROOT="${1:-/var/lib/containerd}"
CONF=/etc/containerd/config.toml

$SUDO mkdir -p /etc/containerd /etc/nri/conf.d /opt/nri/plugins \
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
cat > "$TMP" <<CONFIG
version = $CONF_VERSION

# Image and snapshot data on the large disk: the CloudLab root filesystem is
# about 64 GB, small enough that image churn causes DiskPressure evictions.
root = '$DATA_ROOT'

# Kubernetes requires the systemd cgroup driver on a systemd host. It also
# produces the kubepods.slice/... layout that cgroup and PSI readers expect;
# the cgroupfs driver produces kubepods/... and they silently read nothing.
[plugins.'$CRI_RUNTIME'.containerd.runtimes.runc.options]
  SystemdCgroup = true

# Registry host configuration directory. The zero value is EMPTY -- the
# /etc/containerd/certs.d path shown by "containerd config default" is
# what the generator writes into a full config file, not a built-in
# fallback. Without this line the CRI image service ignores certs.d
# entirely and hosts.toml drop-ins (private-registry trust) never apply,
# while a manual ctr --hosts-dir pull works -- a maximally confusing
# split. NOTE: this block is written through an unquoted heredoc, so
# backticks in comments would EXECUTE; keep them out.
[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = '/etc/containerd/certs.d'

[plugins.'io.containerd.nri.v1.nri']
  disable = false
  disable_connections = false
  plugin_config_path = '/etc/nri/conf.d'
  plugin_path = '/opt/nri/plugins'
  plugin_registration_timeout = '5s'
  plugin_request_timeout = '2s'
  socket_path = '/var/run/nri/nri.sock'
CONFIG

changed=1
if $SUDO test -f "$CONF" && $SUDO cmp -s "$TMP" "$CONF"; then
    changed=0
fi
$SUDO install -m 0644 "$TMP" "$CONF"
rm -f "$TMP"

$SUDO systemctl enable containerd >/dev/null 2>&1 || true
if [ "$changed" -eq 1 ] || ! systemctl is-active --quiet containerd; then
    $SUDO systemctl restart containerd
fi

for _ in $(seq 1 20); do
    [ -S /run/containerd/containerd.sock ] && break
    sleep 1
done
if [ ! -S /run/containerd/containerd.sock ]; then
    echo "ERROR: containerd socket did not appear" >&2
    $SUDO journalctl -u containerd --no-pager -n 30 >&2 || true
    exit 1
fi

# Read the effective configuration back from containerd. A file that parses
# is not proof the settings applied -- a key in the wrong plugin section is
# accepted and ignored.
DUMP="$($SUDO containerd config dump 2>/dev/null || true)"
fail=0
echo "$DUMP" | grep -q 'SystemdCgroup = true' || {
    echo "ERROR: SystemdCgroup did not take effect" >&2; fail=1; }
echo "$DUMP" | awk '/io.containerd.nri.v1.nri/,/^$/' | grep -q 'disable = false' || {
    echo "ERROR: NRI is not enabled in the effective config" >&2; fail=1; }
[ "$fail" -eq 0 ] || { echo "$DUMP" | grep -A8 'nri' >&2 || true; exit 1; }

echo "containerd configured: root=$DATA_ROOT, systemd cgroups, NRI enabled"
