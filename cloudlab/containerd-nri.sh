#!/usr/bin/env bash
# Enable NRI in the containerd that k3s embeds.
#
# Why a template and not an edit: the usual recipe rewrites containerd's
# generated config.toml in place with sed. That is fragile, because the
# generated file's TOML quoting style changes between containerd versions --
# a pattern written for one style silently matches nothing on the next, and
# the result is a cluster that looks configured but has NRI switched off.
#
# k3s regenerates its containerd config on every start from a template, if
# one exists. Writing the template means k3s composes the correct file for
# whatever containerd it ships, and nothing has to match generated text.
#
# Idempotent. Safe to run before k3s has ever started (the normal case) and
# safe to re-run afterwards, though a running k3s must be restarted to pick
# up a change.
set -euo pipefail

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo -H"

CONF_DIR=/etc/nri/conf.d
PLUGIN_DIR=/opt/nri/plugins
SOCKET_DIR=/var/run/nri
TMPL_DIR=/var/lib/rancher/k3s/agent/etc/containerd

$SUDO mkdir -p "$CONF_DIR" "$PLUGIN_DIR" "$SOCKET_DIR" "$TMPL_DIR"

# The base template directive tells k3s to emit its own default config first,
# then append this block. Both quoting styles are valid TOML, so this same
# body works for every containerd version k3s has shipped.
read -r -d '' NRI_BLOCK <<'BLOCK' || true

# --- testbed: NRI ---------------------------------------------------------
[plugins.'io.containerd.nri.v1.nri']
  disable = false
  disable_connections = false
  plugin_config_path = '/etc/nri/conf.d'
  plugin_path = '/opt/nri/plugins'
  plugin_registration_timeout = '5s'
  plugin_request_timeout = '2s'
  socket_path = '/var/run/nri/nri.sock'
BLOCK

# k3s reads config-v3.toml.tmpl with containerd 2.x and config.toml.tmpl with
# 1.x. Writing both costs nothing and survives a k3s upgrade in either
# direction; k3s reads only the one matching its containerd.
for name in config-v3.toml.tmpl config.toml.tmpl; do
    printf '%s\n%s\n' '{{ template "base" . }}' "$NRI_BLOCK" \
        | $SUDO tee "$TMPL_DIR/$name" >/dev/null
done

echo "NRI template written to $TMPL_DIR/{config-v3.toml.tmpl,config.toml.tmpl}"
echo "  plugin drop-in dir: $PLUGIN_DIR"
echo "  plugin config dir:  $CONF_DIR"

if systemctl is-active --quiet k3s 2>/dev/null || \
   systemctl is-active --quiet k3s-agent 2>/dev/null; then
    echo "NOTE: k3s is already running; restart it to apply the template."
fi
