"""Verify an allocated testbed: cluster health, node capabilities, mesh.

Reads topology.json, runs checks over SSH, prints a PASS/FAIL table and
writes a JSON result file. Every check is read-only except C08, which
creates and deletes one pod in the testbed namespace.

    python3 orchestrator/verify.py --topology topology.json

Checks:
    C01 every node Ready
    C02 one hardware type across the allocation
    C03 containerd NRI enabled on every node
    C03b kubelet uses the systemd cgroup driver
    C04 BPF toolchain and kernel BTF present
    C05 cgroup v2 unified hierarchy
    C06 clocks synchronised (each node's own NTP offset)
    C07 Istio control plane healthy
    C08 sidecar injection produces a native-sidecar proxy
    C09 Envoy supports dynamic-module extensions
    C10 experiment LAN reachability matches the address plan
"""

import argparse
import json
import shlex
import subprocess
import sys
import time

NS = "testbed"
KUBECTL = "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl"
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
       "-o", "StrictHostKeyChecking=accept-new"]


def sh(node, cmd, timeout=120):
    """Run cmd on node over SSH. Returns (rc, stdout+stderr)."""
    target = "%s@%s" % (node["user"], node["control"])
    try:
        p = subprocess.run(SSH + [target, cmd], capture_output=True,
                           text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "timeout after %ds" % timeout
    except OSError as e:
        return 125, str(e)


def ctl_of(topo):
    for n in topo["nodes"]:
        if n["role"] == "ctl":
            return n
    sys.exit("topology has no ctl node")


# --------------------------------------------------------------- checks ---

def c01_nodes_ready(topo, ctl):
    expected = len(topo["nodes"])
    rc, out = sh(ctl, "%s get nodes --no-headers" % KUBECTL)
    if rc != 0:
        return False, "kubectl failed: %s" % out.splitlines()[:1]
    ready = [l for l in out.splitlines() if " Ready" in l]
    ok = len(ready) >= expected
    return ok, "%d/%d Ready" % (len(ready), expected)


def c02_homogeneous(topo, ctl):
    kinds = {n.get("hardware") for n in topo["nodes"] if n.get("hardware")}
    if not kinds:
        return True, "hardware not recorded in topology (derive mode)"
    ok = len(kinds) == 1
    return ok, ("all %s" % kinds.pop()) if ok else "MIXED: %s" % sorted(kinds)


def c03_nri(topo, ctl):
    """NRI must be live, per containerd's own effective configuration.

    Both probes need root. The socket directory is mode 0700, and containerd
    config dump requires privilege -- an unprivileged check reports a working
    node as broken.
    """
    bad = []
    for n in topo["nodes"]:
        rc, out = sh(n, "sudo test -S /var/run/nri/nri.sock && echo sock; "
                        "sudo containerd config dump 2>/dev/null | "
                        "awk '/io.containerd.nri.v1.nri/,/^$/' | "
                        "grep -q 'disable = false' && echo enabled")
        missing = [k for k in ("sock", "enabled") if k not in out]
        if missing:
            bad.append("%s:%s" % (n["name"], "+".join(missing)))
    return not bad, "socket live and enabled on all nodes" if not bad \
        else "missing " + ", ".join(bad)


def c03b_cgroup_driver(topo, ctl):
    """The systemd driver produces kubepods.slice/...; cgroupfs produces
    kubepods/..., and every cgroup and PSI reader then sees nothing."""
    bad = []
    for n in topo["nodes"]:
        rc, out = sh(n, "test -d /sys/fs/cgroup/kubepods.slice && echo systemd || "
                        "(test -d /sys/fs/cgroup/kubepods && echo cgroupfs)")
        if "systemd" not in out:
            bad.append("%s(%s)" % (n["name"], out.strip() or "no kubepods yet"))
    return not bad, "kubepods.slice on all nodes" if not bad \
        else "wrong layout: " + ", ".join(bad)


def c04_bpf(topo, ctl):
    bad = []
    for n in topo["nodes"]:
        rc, out = sh(n, "test -e /sys/kernel/btf/vmlinux && echo btf; "
                        "command -v clang >/dev/null && echo clang; "
                        "(command -v bpftool || ls /usr/lib/linux-tools*/bpftool) "
                        ">/dev/null 2>&1 && echo bpftool")
        missing = [t for t in ("btf", "clang", "bpftool") if t not in out]
        if missing:
            bad.append("%s:%s" % (n["name"], "+".join(missing)))
    return not bad, "all nodes" if not bad else "missing " + ", ".join(bad)


def c05_cgroup_v2(topo, ctl):
    bad = []
    for n in topo["nodes"]:
        rc, out = sh(n, "test -e /sys/fs/cgroup/cgroup.controllers && "
                        "cat /sys/fs/cgroup/cgroup.controllers")
        if rc != 0 or "cpu" not in out:
            bad.append(n["name"])
    return not bad, "unified, cpu controller present" if not bad \
        else "not unified on " + ", ".join(bad)


def c06_clock(topo, ctl):
    """Read each node's own NTP offset.

    Comparing wall clocks across sequential SSH calls measures SSH latency,
    not skew -- on a healthy cluster that reading is hundreds of milliseconds
    and tells you nothing. chrony already knows its offset; ask it.
    """
    offsets, unknown = {}, []
    for n in topo["nodes"]:
        rc, out = sh(n, "chronyc tracking 2>/dev/null | "
                        "awk '/^System time/ {print $4}'")
        try:
            offsets[n["name"]] = float(out.split()[0])
        except (ValueError, IndexError):
            unknown.append(n["name"])
    if not offsets:
        return False, "chrony not reporting on any node (%s)" % ", ".join(unknown)
    worst_node = max(offsets, key=lambda k: offsets[k])
    worst = offsets[worst_node]
    detail = "worst offset %.6fs (%s)" % (worst, worst_node)
    if unknown:
        detail += "; no reading from " + ", ".join(unknown)
    # 50 ms bounds gross skew without being so tight that a node which has
    # just started stepping its clock trips it.
    return worst < 0.05 and not unknown, detail


def c07_istio(topo, ctl):
    rc, out = sh(ctl, "%s -n istio-system get pods --no-headers" % KUBECTL)
    if rc != 0 or not out:
        return False, "no istio-system pods (install may still be running)"
    lines = [l for l in out.splitlines() if l.strip()]
    running = [l for l in lines if " Running " in l or l.split()[2] == "Running"]
    ok = len(lines) > 0 and len(running) == len(lines)
    return ok, "%d/%d pods Running" % (len(running), len(lines))


def c08_injection(topo, ctl):
    """A meshed namespace must produce a pod carrying istio-proxy, and the
    proxy must be a *native sidecar*.

    Native means an initContainer with restartPolicy: Always (Kubernetes
    1.29+), which is what guarantees the proxy starts before the application
    containers and stops after them. Injected as an ordinary container it
    still works, but that ordering is gone -- the application can serve
    before the proxy is ready. The profile sets ENABLE_NATIVE_SIDECARS, so
    the ordinary form here means the setting did not take effect.
    """
    name = "inject-probe-%d" % int(time.time())
    create = ("%s -n %s run %s --image=registry.k8s.io/pause:3.9 "
              "--restart=Never 2>&1" % (KUBECTL, NS, name))
    rc, out = sh(ctl, create)
    if rc != 0:
        return False, "could not create probe pod: %s" % out[:160]
    try:
        regular = side = ""
        for _ in range(30):
            rc, regular = sh(ctl, "%s -n %s get pod %s -o "
                                  "jsonpath='{.spec.containers[*].name}'"
                             % (KUBECTL, NS, name))
            rc, side = sh(ctl, "%s -n %s get pod %s -o "
                               "jsonpath='{.spec.initContainers[*].name}'"
                          % (KUBECTL, NS, name))
            if "istio-proxy" in regular or "istio-proxy" in side:
                break
            time.sleep(2)
        if "istio-proxy" in side:
            rc, policy = sh(ctl, "%s -n %s get pod %s -o jsonpath="
                                 "'{.spec.initContainers[?(@.name==\"istio-proxy\")]"
                                 ".restartPolicy}'" % (KUBECTL, NS, name))
            ok = policy.strip() == "Always"
            return ok, ("native sidecar (initContainers: %s)" % side) if ok \
                else "in initContainers but restartPolicy=%r, not Always" % policy
        if "istio-proxy" in regular:
            return False, ("injected as an ordinary container (%s): startup "
                           "ordering is not guaranteed. Check "
                           "ENABLE_NATIVE_SIDECARS on istiod." % regular)
        return False, ("no istio-proxy; containers=[%s] initContainers=[%s]"
                       % (regular or "-", side or "-"))
    finally:
        sh(ctl, "%s -n %s delete pod %s --ignore-not-found --wait=false "
                ">/dev/null 2>&1" % (KUBECTL, NS, name))


def c09_dynamic_modules(topo, ctl):
    """Is the Envoy in the deployed proxy image able to load dynamic modules?

    Three independent signals; all must be present. See
    docs/runbook.md for the standalone version of this check.
    """
    rc, tag = sh(ctl, "%s -n istio-system get deploy istiod -o "
                      "jsonpath='{.spec.template.spec.containers[0].image}'"
                 % KUBECTL)
    if rc != 0 or not tag:
        return False, "could not read the istiod image tag"
    version = tag.rsplit(":", 1)[-1]
    image = "docker.io/istio/proxyv2:%s" % version
    probe = (
        "grep -ao 'envoy[.a-z_0-9]*filters[.a-z_0-9]*dynamic_modules' "
        "/usr/local/bin/envoy | head -1; "
        "grep -ao ENVOY_DYNAMIC_MODULES_SEARCH_PATH /usr/local/bin/envoy | head -1; "
        "grep -ao 'envoy_dynamic_module_on_program_init' /usr/local/bin/envoy | head -1")
    cmd = ("sudo ctr -n k8s.io image pull %s >/dev/null 2>&1; "
           "sudo ctr -n k8s.io run --rm %s dmprobe%d /bin/bash -c %s"
           % (image, image, int(time.time()), shlex.quote(probe)))
    rc, out = sh(ctl, cmd, timeout=300)
    signals = {
        "filter": "filters" in out and "dynamic_modules" in out,
        "search_path": "ENVOY_DYNAMIC_MODULES_SEARCH_PATH" in out,
        "entrypoint": "envoy_dynamic_module_on_program_init" in out,
    }
    ok = all(signals.values())
    missing = [k for k, v in signals.items() if not v]
    return ok, ("proxy %s supports dynamic modules" % version) if ok \
        else "proxy %s missing: %s" % (version, ", ".join(missing))


def c10_lans(topo, ctl):
    """Each worker must hold an address on both experiment LANs."""
    bad = []
    for n in topo["nodes"]:
        if n["role"] != "wk":
            continue
        have = n.get("ifaces", {})
        if not have.get("client") or not have.get("mesh"):
            bad.append(n["name"])
            continue
        rc, _ = sh(ctl, "ping -c1 -W2 %s >/dev/null 2>&1" % have["client"])
        if rc != 0:
            bad.append("%s(client unreachable)" % n["name"])
    return not bad, "all workers dual-homed and reachable" if not bad \
        else "problems: " + ", ".join(bad)


CHECKS = [
    ("C01", "nodes Ready", c01_nodes_ready),
    ("C02", "homogeneous hardware", c02_homogeneous),
    ("C03", "containerd NRI", c03_nri),
    ("C03b", "systemd cgroup driver", c03b_cgroup_driver),
    ("C04", "BPF toolchain + BTF", c04_bpf),
    ("C05", "cgroup v2 unified", c05_cgroup_v2),
    ("C06", "clock sync", c06_clock),
    ("C07", "Istio control plane", c07_istio),
    ("C08", "sidecar injection", c08_injection),
    ("C09", "Envoy dynamic modules", c09_dynamic_modules),
    ("C10", "experiment LANs", c10_lans),
]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--topology", default="topology.json")
    p.add_argument("--skip", default="",
                   help="comma-separated check ids, e.g. C09")
    p.add_argument("--out", default="verify-results.json")
    a = p.parse_args()

    topo = json.load(open(a.topology))
    ctl = ctl_of(topo)
    skip = {s.strip().upper() for s in a.skip.split(",") if s.strip()}

    results, failed = [], 0
    for cid, title, fn in CHECKS:
        if cid in skip:
            print("%-5s %-26s SKIP" % (cid, title))
            results.append(dict(id=cid, title=title, status="skip", detail=""))
            continue
        t0 = time.time()
        try:
            ok, detail = fn(topo, ctl)
        except Exception as e:                      # a check must never abort the run
            ok, detail = False, "check raised: %r" % e
        status = "PASS" if ok else "FAIL"
        failed += 0 if ok else 1
        print("%-5s %-26s %-4s  %s  (%.1fs)"
              % (cid, title, status, detail, time.time() - t0))
        results.append(dict(id=cid, title=title,
                            status=status.lower(), detail=detail))

    with open(a.out, "w") as fh:
        json.dump({"generated_at": time.time(), "topology": topo,
                   "results": results}, fh, indent=2)
    print("\n%d/%d passed -- wrote %s"
          % (len(results) - failed - len(skip), len(CHECKS) - len(skip), a.out))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
