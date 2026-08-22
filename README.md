# cloudlab-cluster-macaw

A parameterized CloudLab profile that boots a bare-metal Kubernetes cluster
with an Istio service mesh, plus the bootstrap, golden-image, and
verification tooling around it.

Upstream Kubernetes installed with kubeadm — not a lightweight distribution —
so container-runtime paths, cgroup layout and ecosystem components behave the
way they do on an ordinary cluster.

The profile is neutral to whatever runs on top: namespaces, labels and paths
use the generic name `testbed`, and nothing here depends on a particular
workload or system under test.

Every node comes up with:

- **Kubernetes** via kubeadm, one pinned minor series with the packages held;
  Calico CNI over 192.168.0.0/16
- **Istio**, version-pinned, with a sidecar-injection-enabled namespace
- **containerd with NRI enabled** and the **systemd cgroup driver**,
  configured through a drop-in rather than by editing generated config
- **cgroup v2** unified hierarchy
- a **BPF toolchain** and kernel BTF, for CPU and kernel telemetry
- two isolated experiment LANs, with control-plane traffic kept off both

```
profile.py                    CloudLab geni-lib profile (presets: smoke/medium/full/submission)
cloudlab/bootstrap.sh         two-layer node bootstrap (bake layer + boot layer)
cloudlab/containerd-config.sh containerd: systemd cgroups, NRI, data root
cloudlab/install-istio.sh     version-pinned mesh install
cloudlab/bake.sh              prepare a node for golden-image capture
orchestrator/topology.py      build topology.json from a manifest
orchestrator/verify.py        11-check cluster verification suite
docs/runbook.md               how to run all of it
```

## Quick start

1. Create a profile in the CloudLab portal from this repository.
2. Instantiate it with the `smoke` preset (2 machines).
3. Download the manifest to `./manifest.xml`, then:

```bash
make topology && make verify
```

`make verify` prints a PASS/FAIL table and writes `verify-results.json`.

See [docs/runbook.md](docs/runbook.md) for everything else — golden images,
hardware selection, the Istio version question, and what each check means.

## Layout

| Role | Count | Networks | Purpose |
|---|---|---|---|
| `ctl1` | 1 | client | Kubernetes and Istio control plane, monitoring |
| `wk<j>` | 1–6 | client + mesh | meshed workloads and per-node agents |
| `lg<i>` | 0–n | client | optional dedicated load generators |

Addresses: `ctl1` 10.10.1.10, `lg<i>` 10.10.1.(10+i), `wk<j>` 10.10.1.(20+j)
and 10.10.2.(20+j).

## License

MIT. See [LICENSE](LICENSE).
