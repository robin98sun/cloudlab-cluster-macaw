"""Service-mesh testbed on CloudLab bare metal (k3s + Istio).

Project-neutral infrastructure. Namespaces, labels and paths use the generic
name "testbed", so the same profile serves any system under test.

Physical hosts (one hardware type per comparison series, default c6525-25g):

    ctl1    k3s control plane, Istio control plane, monitoring   client LAN
    wk<j>   worker hosts: meshed workloads and per-node agents   client + mesh
                                                                 LANs
    lg<i>   optional dedicated load-generator hosts              client LAN

Every worker node is prepared with:

  * cgroup v2 unified hierarchy
  * containerd with NRI enabled, configured through a k3s config template
    rather than by editing generated config (see cloudlab/containerd-nri.sh)
  * a BPF toolchain and kernel BTF, for CPU and kernel telemetry
  * an Istio sidecar-injection-ready namespace

Purposes are parameter bindings of this one generator, selected by `preset`:

    preset       machines  workers  intent
    smoke        2         1        plumbing verification, fast iteration
    medium       4         3        multi-node behaviour
    full         7         6        full-scale runs
    submission   7         6        frozen bindings for reported results;
                                    bind a portal profile to a release TAG
                                    of this repo so it can never drift
    custom       --        --       the individual form fields apply

When preset != custom, the preset's bindings OVERRIDE the individual form
fields they name; fields a preset does not name (notably disk_image and
istio_version) still come from the form.

Istio version note: Envoy dynamic-module extensions are absent from Istio
1.30.x and present from 1.31. If you do not need them, any listed version
works. See docs/runbook.md.

Networks: client 10.10.1.0/24, mesh 10.10.2.0/24. Kubernetes and Istio
control traffic ride CloudLab's control network, so the experiment LANs stay
clean.

Address plan: ctl1 10.10.1.10; lg<i> 10.10.1.(10+i); wk<j> 10.10.1.(20+j)
and 10.10.2.(20+j).
"""

import geni.portal as portal
import geni.rspec.pg as pg

BASE_IMAGE = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"
# Once a golden image has been baked (cloudlab/bake.sh, then "Create Disk
# Image" in the portal), pin its URN here and commit. An unversioned URN
# tracks the latest bake; append :N to freeze a version, and do that inside
# the submission preset before tagging a release.
GOLDEN_IMAGE = BASE_IMAGE

# Pinned so that an allocation is reproducible from a commit alone.
DEFAULT_ISTIO = "1.31.0-rc.0"

PRESETS = {
    "smoke":      dict(num_wk_hosts=1, num_lg_hosts=0),
    "medium":     dict(num_wk_hosts=3, num_lg_hosts=0),
    "full":       dict(num_wk_hosts=6, num_lg_hosts=0),
    "submission": dict(num_wk_hosts=6, num_lg_hosts=0, hw_type="c6525-25g",
                       client_bw=0, mesh_bw=0),
}

pc = portal.Context()

pc.defineParameter(
    "preset", "Configuration preset", portal.ParameterType.STRING, "smoke",
    legalValues=[("smoke", "smoke: 2 machines, 1 worker"),
                 ("medium", "medium: 4 machines, 3 workers"),
                 ("full", "full: 7 machines, 6 workers"),
                 ("submission", "submission: frozen full-scale bindings"),
                 ("custom", "custom: use the individual fields below")],
    longDescription="Anything other than 'custom' overrides the individual "
                    "fields it defines. Presets are versioned with the "
                    "repository, so every run can name its configuration by "
                    "commit.")
pc.defineParameter(
    "num_wk_hosts", "Worker hosts (custom preset)",
    portal.ParameterType.INTEGER, 1,
    longDescription="Hosts running meshed workloads and the per-node agent. "
                    "One worker is enough to exercise every code path; more "
                    "are needed only for cross-host behaviour.")
pc.defineParameter(
    "num_lg_hosts", "Dedicated load-generator hosts (custom preset)",
    portal.ParameterType.INTEGER, 0,
    longDescription="0 runs load generation on ctl1. Add hosts when the "
                    "generator itself becomes the bottleneck.")
pc.defineParameter(
    "hw_type", "Hardware type", portal.ParameterType.STRING, "c6525-25g",
    legalValues=[
        ("c6525-25g", "c6525-25g (Utah): 16c/128GB, 2x25G expt -- usually free"),
        ("c6620", "c6620 (Utah): 28c/128GB NVMe, 2 expt -- often reserved"),
        ("d6515", "d6515 (Utah): 32c/128GB, 3 expt ifaces"),
        ("d7615", "d7615 (Utah): 32c/192GB NVMe, 3 expt -- only 6 exist"),
        ("c6525-100g", "c6525-100g (Utah): 24c/128GB, 2x100G expt"),
    ],
    longDescription="Vetted types only: every entry has >= 2 experimental "
                    "interfaces (the worker-host requirement) and a core "
                    "count high enough for meaningful per-core work. "
                    "Availability shifts; c6525-25g is the most reliably "
                    "free. One homogeneous type per comparison series.")
pc.defineParameter(
    "hw_type_custom", "Custom hardware type (overrides the list)",
    portal.ParameterType.STRING, "",
    longDescription="Escape hatch for new or unlisted node types. Worker "
                    "hosts need >= 2 experimental interfaces.")
pc.defineParameter(
    "disk_image", "Disk image URN", portal.ParameterType.STRING, GOLDEN_IMAGE,
    longDescription="Defaults to the golden image once one is pinned in the "
                    "profile source. Use BASE_IMAGE to rebuild from scratch. "
                    "Not overridden by presets.")
pc.defineParameter(
    "istio_version", "Istio version", portal.ParameterType.STRING,
    DEFAULT_ISTIO,
    longDescription="Installed on ctl1 at boot. Envoy dynamic-module "
                    "extensions are absent from 1.30.x and present from "
                    "1.31. Not overridden by presets.")
pc.defineParameter(
    "install_istio", "Install Istio at boot", portal.ParameterType.BOOLEAN,
    True,
    longDescription="Uncheck to bring up a bare Kubernetes cluster and "
                    "install the mesh by hand (make istio).")
pc.defineParameter(
    "client_bw", "Client link bandwidth (Kbps, 0 = native)",
    portal.ParameterType.INTEGER, 0)
pc.defineParameter(
    "mesh_bw", "Mesh link bandwidth (Kbps, 0 = native)",
    portal.ParameterType.INTEGER, 0)

params = pc.bindParameters()

CONFIG_FIELDS = ("num_wk_hosts", "num_lg_hosts", "hw_type", "disk_image",
                 "istio_version", "install_istio", "client_bw", "mesh_bw")
cfg = {f: getattr(params, f) for f in CONFIG_FIELDS}
if params.hw_type_custom.strip():
    cfg["hw_type"] = params.hw_type_custom.strip()
if params.preset != "custom":
    if params.preset not in PRESETS:
        pc.reportError(portal.ParameterError(
            "unknown preset %r" % params.preset, ["preset"]))
    else:
        cfg.update(PRESETS[params.preset])

if cfg["num_wk_hosts"] < 1:
    pc.reportError(portal.ParameterError(
        "At least one worker host is required.", ["num_wk_hosts"]))
if cfg["num_lg_hosts"] < 0:
    pc.reportError(portal.ParameterError(
        "Load-generator hosts cannot be negative.", ["num_lg_hosts"]))
if not str(cfg["istio_version"]).strip():
    pc.reportError(portal.ParameterError(
        "Istio version must not be empty.", ["istio_version"]))
pc.verifyParameters()

request = pc.makeRequestRSpec()

client_lan = request.LAN("client")
mesh_lan = request.LAN("mesh")
if cfg["client_bw"] > 0:
    client_lan.bandwidth = cfg["client_bw"]
if cfg["mesh_bw"] > 0:
    mesh_lan.bandwidth = cfg["mesh_bw"]


def make_node(name, role, extra_args=""):
    node = request.RawPC(name)
    if cfg["hw_type"]:
        node.hardware_type = cfg["hw_type"]
    node.disk_image = cfg["disk_image"]
    node.addService(pg.Execute(
        shell="bash",
        command="bash /local/repository/cloudlab/bootstrap.sh %s%s"
                % (role, extra_args)))
    return node


def attach(node, lan, addr):
    iface = node.addInterface()
    iface.addAddress(pg.IPv4Address(addr, "255.255.255.0"))
    lan.addInterface(iface)


ctl = make_node("ctl1", "ctl",
                " --wk-hosts %d --lg-hosts %d --istio-version %s%s"
                % (cfg["num_wk_hosts"], cfg["num_lg_hosts"],
                   cfg["istio_version"],
                   "" if cfg["install_istio"] else " --no-istio"))
attach(ctl, client_lan, "10.10.1.10")

for i in range(1, cfg["num_lg_hosts"] + 1):
    n = make_node("lg%d" % i, "lg")
    attach(n, client_lan, "10.10.1.%d" % (10 + i))

for j in range(1, cfg["num_wk_hosts"] + 1):
    n = make_node("wk%d" % j, "wk")
    attach(n, client_lan, "10.10.1.%d" % (20 + j))
    attach(n, mesh_lan, "10.10.2.%d" % (20 + j))

pc.printRequestRSpec(request)
