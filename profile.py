"""Service-mesh testbed on CloudLab bare metal (Kubernetes + Istio).

Project-neutral infrastructure. Namespaces, labels and paths use the generic
name "testbed", so the same profile serves any system under test.

Physical hosts (one hardware type per comparison series, default c6420):

    ctl1    Kubernetes control plane + private container registry
    wk<j>   worker hosts: meshed workloads and per-node agents
    st<j>   standby hosts: cluster services kept off the measured workers
    ng<j>   gateway hosts: ingress / reverse proxy
    qs<j>   query-scheduler hosts: the request-scheduling tier, held off the
            measured workers so its cost is never attributed to them
    dp<j>   dispatcher hosts: drive load over ssh; deliberately NOT joined
            to the cluster, so no workload pod can ever land on a machine
            that is generating the load

ONE experiment LAN. The default hardware type (c6420) has a single 10G
experimental interface, so the earlier client+mesh split is not physically
possible and has been removed rather than left as a trap. Reintroducing a
second LAN requires hardware with a second experimental interface AND a
matching change here; do not add one without checking the type.

Every worker node is prepared with:

  * cgroup v2 unified hierarchy
  * upstream Kubernetes installed with kubeadm, Calico CNI, one pinned
    minor series with the packages held
  * containerd with NRI enabled and the systemd cgroup driver, configured
    through a drop-in rather than by editing generated config
    (see cloudlab/containerd-config.sh)
  * a BPF toolchain and kernel BTF, for CPU and kernel telemetry
  * an Istio sidecar-injection-ready namespace

Purposes are parameter bindings of this one generator, selected by `preset`:

    preset      machines  wk  st  ng  qs  dp  intent
    smoke        3         1   0   0   1   0  plumbing verification
    medium      15         5   3   2   3   1  multi-node behaviour
    full        49        20  10   4  10   4  full-scale runs
    submission  49        20  10   4  10   4  frozen bindings for reported
                                              results; bind a portal profile
                                              to a release TAG of this repo
                                              so it can never drift
    custom      --        --  --  --  --  --  the individual fields apply

Every preset adds ctl1, so machines = 1 + wk + st + ng + qs + dp.

Query-scheduler hosts are sized at roughly half the worker count. That ratio
is a starting point, not a measured requirement: size it against the actual
scheduling load and revise here. Setting it to 0 does not disable the tier --
it puts the tier back on the workers, which is the contamination this role
exists to avoid.

When preset != custom, the preset's bindings OVERRIDE the individual form
fields they name; fields a preset does not name (notably disk_image and
istio_version) still come from the form.

A 39-node request is large. Check availability before instantiating, and
expect to wait or to reduce counts if the cluster is busy.

Istio version note: Envoy dynamic-module extensions are absent from Istio
1.30.x and present from 1.31. If you do not need them, any listed version
works. See docs/runbook.md.

Network: one experiment LAN, 10.10.1.0/24. Kubernetes and Istio control
traffic ride CloudLab's control network, so the experiment LAN stays clean.
Pod networking is Calico over 192.168.0.0/16.

Address plan, blocked by role so a node's address names its purpose:
    ctl1    10.10.1.10
    wk<j>   10.10.1.(20+j)      st<j>   10.10.1.(60+j)
    ng<j>   10.10.1.(80+j)      dp<j>   10.10.1.(100+j)
    qs<j>   10.10.1.(120+j)
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
    "smoke":      dict(num_wk_hosts=1,  num_st_hosts=0,  num_ng_hosts=0,
                       num_qs_hosts=1,  num_dp_hosts=0),
    "medium":     dict(num_wk_hosts=5,  num_st_hosts=3,  num_ng_hosts=2,
                       num_qs_hosts=3,  num_dp_hosts=1),
    "full":       dict(num_wk_hosts=20, num_st_hosts=10, num_ng_hosts=4,
                       num_qs_hosts=10, num_dp_hosts=4),
    "submission": dict(num_wk_hosts=20, num_st_hosts=10, num_ng_hosts=4,
                       num_qs_hosts=10, num_dp_hosts=4, hw_type="c6420",
                       link_bw=0),
}

pc = portal.Context()

pc.defineParameter(
    "preset", "Configuration preset", portal.ParameterType.STRING, "smoke",
    legalValues=[("smoke", "smoke: 3 machines (1 wk, 1 qs)"),
                 ("medium", "medium: 15 machines (5 wk, 3 st, 2 ng, 3 qs, 1 dp)"),
                 ("full", "full: 49 machines (20 wk, 10 st, 4 ng, 10 qs, 4 dp)"),
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
    "num_st_hosts", "Standby hosts (custom preset)",
    portal.ParameterType.INTEGER, 0,
    longDescription="Hosts for cluster services that must not share a "
                    "machine with the measured workload, so their overhead "
                    "never lands in a worker's numbers.")
pc.defineParameter(
    "num_ng_hosts", "Gateway hosts (custom preset)",
    portal.ParameterType.INTEGER, 0,
    longDescription="Ingress / reverse-proxy hosts fronting the meshed "
                    "services.")
pc.defineParameter(
    "num_qs_hosts", "Query-scheduler hosts (custom preset)",
    portal.ParameterType.INTEGER, 0,
    longDescription="Hosts for the request-scheduling tier. It is not the "
                    "subject of the experiment, so it is kept off the "
                    "workers rather than having its cost land in their "
                    "numbers. Presets size it at about half the worker "
                    "count as a starting point; measure and revise. 0 does "
                    "not disable the tier, it returns it to the workers.")
pc.defineParameter(
    "num_dp_hosts", "Dispatcher hosts (custom preset)",
    portal.ParameterType.INTEGER, 0,
    longDescription="Hosts that drive load, reached over ssh. They are NOT "
                    "joined to the Kubernetes cluster: a load generator that "
                    "is also a schedulable node can end up hosting the very "
                    "workload it is measuring. 0 drives load from ctl1.")
pc.defineParameter(
    "hw_type", "Hardware type", portal.ParameterType.STRING, "c6420",
    legalValues=[
        ("c6420", "c6420 (Clemson): one 10G experimental interface"),
        ("c6525-25g", "c6525-25g (Utah): 16c/128GB, 2x25G expt"),
        ("c6620", "c6620 (Utah): 28c/128GB NVMe, 2 expt -- often reserved"),
        ("d6515", "d6515 (Utah): 32c/128GB, 3 expt ifaces"),
        ("d7615", "d7615 (Utah): 32c/192GB NVMe, 3 expt -- only 6 exist"),
        ("c6525-100g", "c6525-100g (Utah): 24c/128GB, 2x100G expt"),
    ],
    longDescription="One homogeneous type per comparison series. This "
                    "profile builds a SINGLE experiment LAN, so one "
                    "experimental interface is sufficient and types with "
                    "more simply leave the extras unused. Availability "
                    "shifts; a large request may need to wait. Verify the "
                    "core count of whichever type you pick -- the workload "
                    "harness pins cores per node itself and must agree with "
                    "the hardware.")
pc.defineParameter(
    "hw_type_custom", "Custom hardware type (overrides the list)",
    portal.ParameterType.STRING, "",
    longDescription="Escape hatch for new or unlisted node types. One "
                    "experimental interface is enough for this profile.")
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
    "link_bw", "Experiment LAN bandwidth (Kbps, 0 = native)",
    portal.ParameterType.INTEGER, 0,
    longDescription="0 leaves the link at line rate. Shape it only to model "
                    "a constrained network deliberately.")

params = pc.bindParameters()

CONFIG_FIELDS = ("num_wk_hosts", "num_st_hosts", "num_ng_hosts",
                 "num_qs_hosts", "num_dp_hosts", "hw_type", "disk_image",
                 "istio_version", "install_istio", "link_bw")
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
for field, label in (("num_st_hosts", "Standby"), ("num_ng_hosts", "Gateway"),
                     ("num_qs_hosts", "Query-scheduler"),
                     ("num_dp_hosts", "Dispatcher")):
    if cfg[field] < 0:
        pc.reportError(portal.ParameterError(
            "%s hosts cannot be negative." % label, [field]))
# The address plan blocks each role into its own decade-ish range; overrun
# would silently collide two roles on one address.
for field, limit, base in (("num_wk_hosts", 39, 20), ("num_st_hosts", 19, 60),
                           ("num_ng_hosts", 19, 80), ("num_dp_hosts", 19, 100),
                           ("num_qs_hosts", 40, 120)):
    if cfg[field] > limit:
        pc.reportError(portal.ParameterError(
            "At most %d hosts for this role: the address plan gives it "
            "10.10.1.%d upward and the next role starts after that."
            % (limit, base + 1), [field]))
if not str(cfg["istio_version"]).strip():
    pc.reportError(portal.ParameterError(
        "Istio version must not be empty.", ["istio_version"]))
pc.verifyParameters()

request = pc.makeRequestRSpec()

# ONE experiment LAN: the default hardware type has a single experimental
# interface. See the module docstring before adding a second.
client_lan = request.LAN("client")
if cfg["link_bw"] > 0:
    client_lan.bandwidth = cfg["link_bw"]


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


# ctl1 carries the control plane AND the private container registry, so the
# registry never competes for a measured worker.
ctl = make_node("ctl1", "ctl",
                " --wk-hosts %d --st-hosts %d --ng-hosts %d --qs-hosts %d"
                " --dp-hosts %d --istio-version %s%s"
                % (cfg["num_wk_hosts"], cfg["num_st_hosts"],
                   cfg["num_ng_hosts"], cfg["num_qs_hosts"],
                   cfg["num_dp_hosts"], cfg["istio_version"],
                   "" if cfg["install_istio"] else " --no-istio"))
attach(ctl, client_lan, "10.10.1.10")

# role letter, count, address base
for role, count, base in (("wk", cfg["num_wk_hosts"], 20),
                          ("st", cfg["num_st_hosts"], 60),
                          ("ng", cfg["num_ng_hosts"], 80),
                          ("dp", cfg["num_dp_hosts"], 100),
                          ("qs", cfg["num_qs_hosts"], 120)):
    for j in range(1, count + 1):
        n = make_node("%s%d" % (role, j), role)
        attach(n, client_lan, "10.10.1.%d" % (base + j))

pc.printRequestRSpec(request)
