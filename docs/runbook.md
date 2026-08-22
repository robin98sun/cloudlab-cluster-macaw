# Runbook

## 1. Allocate

Create a profile in the CloudLab portal from this repository, then
instantiate it. Choose a preset:

| Preset | Machines | Workers | Use |
|---|---|---|---|
| `smoke` | 2 | 1 | plumbing verification, fast iteration |
| `medium` | 4 | 3 | multi-node behaviour |
| `full` | 7 | 6 | full-scale runs |
| `submission` | 7 | 6 | frozen bindings for reported results |
| `custom` | — | — | the individual form fields apply |

A preset overrides the individual fields it names. Fields it does not name —
`disk_image`, `istio_version`, `install_istio` — still come from the form.

**For reported results**, bind the portal profile to a release *tag* of this
repository rather than to `main`, so the configuration cannot drift after
the fact.

### Hardware

All listed types have at least two experimental interfaces, which worker
hosts require. `c6525-25g` (Utah, 16 cores) is the most reliably free.

Use one hardware type across any series of runs you intend to compare.
Results are comparable within a type, never across. Check C02 reports a
single type.

## 2. Build the topology file

Download the manifest from the portal into `./manifest.xml`, then:

```bash
make topology
```

If you have not downloaded a manifest yet:

```bash
make topology-derive DOMAIN=<exp>.<proj>.utah.cloudlab.us WK=3
```

The manifest version is authoritative and records hardware types; the derived
version does not, so C02 cannot check homogeneity from it.

## 3. Verify

```bash
make verify
```

| Check | Meaning | If it fails |
|---|---|---|
| C01 | every node Ready | agents may still be joining; wait and re-run |
| C02 | one hardware type | a mixed allocation invalidates comparisons — reallocate |
| C03 | containerd NRI enabled | run `make containerd-reconfigure` |
| C03b | systemd cgroup driver | as above; then restart kubelet |
| C04 | BPF toolchain and BTF | the bake layer's tool install failed; see §6 |
| C05 | cgroup v2 unified | wrong base image — Ubuntu 22.04 defaults to unified |
| C06 | clocks synchronised | chrony did not start; check `bootstrap.log` |
| C07 | Istio control plane | the install may still be running; see §4 |
| C08 | sidecar injection | the namespace label is missing, or istiod is unhealthy — see §5.1 |
| C09 | Envoy dynamic modules | see §5.1 |
| C10 | experiment LANs | a worker is missing an interface — check the manifest |

`make verify-fast` skips C09, which pulls a container image and takes a
couple of minutes.

Logs live on each node at `/local/testbed/logs/bootstrap.log`, and the mesh
install at `/local/testbed/logs/istio.log`.

## 4. The mesh

The install runs in the background at boot, so `C07` can fail simply because
it has not finished. Check the log, and re-run by hand if needed:

```bash
make istio
```

It is idempotent. To bring up a bare cluster and install the mesh yourself,
uncheck `install_istio` when instantiating.

## 5. The injected proxy

Modern Istio injects the proxy as a **native sidecar**: an initContainer with
`restartPolicy: Always`, a Kubernetes 1.29+ feature, rather than as an
ordinary container. Verified on Istio 1.31.0-rc.0, where a meshed pod carries
`istio-init` and `istio-proxy` in `.spec.initContainers` and shows `2/2`
ready.

This matters when inspecting or extending the proxy. `kubectl get pod -o
jsonpath='{.spec.containers[*].name}'` will not list it; check
`.spec.initContainers` too. Native sidecars also start before the
application's own containers and stop after them, so anything the proxy must
establish is in place before the application serves traffic.

C08 accepts either form and reports which one it found.

## 5.1 Envoy dynamic modules

Envoy can load native extensions as **dynamic modules** — compiled libraries
loaded at startup, which unlike WebAssembly extensions may use system calls
directly.

Support depends on the Istio version, and **release dates do not tell you**.
The change was accepted into the Istio proxy on 22 April 2026 and Istio 1.30
was released on 18 May 2026, yet 1.30 does not have it: the release branch
was cut before the change landed.

Verified by inspecting the shipped Envoy binary:

| Istio | Envoy inside | Dynamic modules |
|---|---|---|
| 1.30.3 | 1.38.4-dev | no |
| 1.31.0-rc.0 | 1.39.1-dev | yes |

C09 performs this check against whatever version the cluster is running, and has been confirmed passing on a live Istio 1.31.0-rc.0 cluster. To
run it standalone on any machine with `ctr` and network access:

```bash
sudo ctr -n k8s.io image pull docker.io/istio/proxyv2:<TAG>
sudo ctr -n k8s.io run --rm docker.io/istio/proxyv2:<TAG> probe /bin/bash -c '
  grep -ao "envoy[.a-z_0-9]*filters[.a-z_0-9]*dynamic_modules" /usr/local/bin/envoy | sort -u
  grep -ao ENVOY_DYNAMIC_MODULES_SEARCH_PATH /usr/local/bin/envoy | sort -u
  grep -ao "envoy_dynamic_module_on_[a-z_]*" /usr/local/bin/envoy | sort -u | head'
sudo ctr -n k8s.io image rm docker.io/istio/proxyv2:<TAG>
```

All three must produce output. Entries matching `matching...dynamic_modules`
only are not sufficient — those are protocol definitions compiled in
regardless, not the loader.

Two further notes:

- A module built for Envoy X.Y loads on X.Y and X.Y+1. Past that, rebuild.
- Envoy finds the library through `ENVOY_DYNAMIC_MODULES_SEARCH_PATH`, so
  the file must be present inside the sidecar container and that variable
  must be set during injection.

## 6. Golden images

The first boot from the base image installs packages, containerd,
kubeadm/kubelet/kubectl, `istioctl`, and the BPF toolchain. That is the
slow part. Baking it into a disk image makes redeploys fast.

```bash
ssh <user>@<node> 'bash /local/repository/cloudlab/bake.sh'
```

Then, in the portal, select that node and **Create Disk Image**. Pin the
resulting URN as `GOLDEN_IMAGE` in `profile.py` and commit. Append `:N` to
freeze a specific version, and do that inside the `submission` preset before
tagging a release.

Bump `IMAGE_LAYER` in `bootstrap.sh` whenever the bake layer's contents
change, then rebake. A node whose `/etc/testbed-image-version` does not match
rebuilds the layer automatically, so a stale image degrades to a slow boot
rather than a wrong one.

## 7. containerd

Three settings matter, and all three are applied through a **drop-in**, not
by editing generated config:

- `SystemdCgroup = true` — required by Kubernetes on a systemd host, and it
  produces the `kubepods.slice/...` layout that cgroup and PSI readers
  expect. The cgroupfs driver produces `kubepods/...` and they see nothing.
- **NRI enabled** — plugins in `/opt/nri/plugins`, their config in
  `/etc/nri/conf.d`, socket at `/var/run/nri/nri.sock`.
- **data root on the large disk** — the CloudLab root filesystem is about
  64 GB, small enough that image churn causes DiskPressure evictions.

The common recipe rewrites the generated `config.toml` with
`sed s/SystemdCgroup = false/SystemdCgroup = true/`. That depends on
generated text, and containerd's defaults change between versions — 2.x
renamed the CRI plugin and moved to config version 3. A pattern written for
one release silently matches nothing on the next, leaving a cluster that
looks configured and is not.

Instead the script generates the defaults, prepends one `imports` line, and
puts every override in its own file. Nothing pattern-matches generated
content. To re-apply:

```bash
make containerd-reconfigure
```

## 8. Reaching the cluster

On `ctl1`:

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
```

The bootstrap also copies it to `~/.kube/config` for the login account and
for `ubuntu`.

Cluster formation uses a fixed bootstrap token and certificate key so every
node joins with no coordination or file distribution. That is a deliberate
trade-off for a disposable cluster on an isolated control network, and is not
a pattern for anything internet-facing.
