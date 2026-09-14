"""Service-mesh testbed on CloudLab bare metal (Kubernetes + Istio).

Project-neutral infrastructure. Namespaces, labels and paths use the generic
name "testbed", so the same profile serves any system under test.

Physical hosts. Every role takes the cluster-wide hardware type unless it is
given one of its own, so a cluster can be heterogeneous: pin the machine you
are characterising for the workers and let the supporting roles be whatever is
available.

    ctl<j>  Kubernetes control plane. ctl1 initialises; ctl2.. join the same
            control plane with stacked etcd, so the count should be odd.
            ctl1 stays the endpoint, and also carries the private container
            registry when no registry host is requested.
    wk<j>   worker hosts: meshed workloads and per-node agents
    st<j>   standby hosts: cluster services kept off the measured workers
    ng<j>   gateway hosts: ingress / reverse proxy
    qs<j>   query-scheduler hosts: the request-scheduling tier, held off the
            measured workers so its cost is never attributed to them
    dp<j>   dispatcher hosts: drive load over ssh; deliberately NOT joined
            to the cluster, so no workload pod can ever land on a machine
            that is generating the load
    rg<j>   registry hosts: the private container registry, given its own
            machine so image pulls at scale do not compete with the API
            server. 0 of these keeps the registry on ctl1.

ONE experiment LAN. There is no default hardware type -- hw_type is blank
unless you pin one -- and the profile assumes only that every node has a
single usable experimental interface, which is the floor across the types
we use. The earlier client+mesh split is not physically possible on such a
type and has been removed rather than left as a trap. Reintroducing a
second LAN requires hardware with a second experimental interface AND a
matching change here; do not add one without checking the type you pinned.

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
    ctl<j>  10.10.1.(9+j)       wk<j>   10.10.1.(20+j)
    st<j>   10.10.1.(60+j)      ng<j>   10.10.1.(80+j)
    dp<j>   10.10.1.(100+j)     qs<j>   10.10.1.(120+j)
    rg<j>   10.10.1.(160+j)
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
    "preset", "Configuration preset", portal.ParameterType.STRING, "custom",
    longDescription="Free text, and 'custom' by default: every num_* field "
                    "below stays in force, which is how a daily testbed is "
                    "sized. Naming a preset instead -- smoke, medium, full, "
                    "submission -- OVERRIDES the individual fields that "
                    "preset defines; read PRESETS in the source for exactly "
                    "what each one binds. Note that no preset meets the "
                    "daily Macaw role floors: medium is one dp short. "
                    "Presets are versioned with the repository, so a run can "
                    "still name its configuration by commit. An unknown name "
                    "is rejected at parameterize time, not at boot.")
pc.defineParameter(
    "num_ctl_hosts", "Control-plane hosts (custom preset)",
    portal.ParameterType.INTEGER, 1,
    longDescription="Kubernetes control-plane members. 1 is a single "
                    "control plane. More than 1 brings up additional members "
                    "that join the SAME control plane with stacked etcd, "
                    "which needs an odd count to keep a quorum -- 1, 3 or 5. "
                    "The endpoint stays ctl1, so losing ctl1 still costs you "
                    "the cluster; this buys redundancy of the API server and "
                    "etcd, not a floating VIP.")
pc.defineParameter(
    "num_rg_hosts", "Registry hosts (custom preset)",
    portal.ParameterType.INTEGER, 0,
    longDescription="Dedicated hosts for the private container registry. "
                    "0 keeps the registry on ctl1, which is the historical "
                    "behaviour and fine for small clusters. Give it its own "
                    "host when image pulls at scale would otherwise compete "
                    "with the API server.")
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
    "hw_type", "Hardware type (blank = let the cluster choose)",
    portal.ParameterType.STRING, "",
    longDescription="Free text and deliberately EMPTY by default -- there is "
                    "no default hardware type, because any type this profile "
                    "picked for you would sooner or later be one that is out "
                    "of stock. Blank leaves the choice to the mapper, which "
                    "is the right setting when the run does not care. Name a "
                    "type to pin it, and check resinfo first: every host must "
                    "land in ONE cluster, and a request that cannot be fully "
                    "mapped fails entirely. One homogeneous type per "
                    "comparison series; a daily testbed may mix freely via "
                    "the per-role fields. This profile builds a SINGLE "
                    "experiment LAN, so one experimental interface is enough "
                    "and types with more leave the extras unused. Verify the "
                    "core count of whatever you pin -- the workload harness "
                    "pins cores per node itself and must agree with the "
                    "hardware. Types we have used: c6420 (Clemson) one 10G "
                    "expt iface; c6525-25g (Utah) 16c/128GB 2x25G; c6620 "
                    "(Utah) 28c/128GB NVMe, often reserved; d6515 (Utah) "
                    "32c/128GB 3 expt; d7615 (Utah) 32c/192GB NVMe, only 6 "
                    "exist; c6525-100g (Utah) 24c/128GB 2x100G.")
pc.defineParameter(
    "hw_type_custom", "Custom hardware type (overrides the list)",
    portal.ParameterType.STRING, "",
    longDescription="Escape hatch for new or unlisted node types. One "
                    "experimental interface is enough for this profile.")

# Per-role hardware. Each is an override: leave it empty and the role takes
# the cluster-wide type above. A mixed cluster is normal -- the measured
# workers usually want the machine you are characterising, while gateways,
# schedulers, the registry and the load drivers only need to be big enough
# not to become the bottleneck. Give every role you override a type whose
# core count you have checked: the workload harness pins cores per node and
# must agree with the hardware it lands on.
for _role, _label, _hint in (
        ("ctl", "control-plane", "Runs the API server, etcd and the "
                                 "scheduler. Modest is fine unless the "
                                 "cluster is large."),
        ("wk", "worker", "Hosts the measured workload. This is the machine "
                         "the comparison is about, so it is usually the one "
                         "worth pinning explicitly."),
        ("st", "standby", "Cluster services kept off the measured workers."),
        ("ng", "gateway", "Ingress / reverse proxy. Needs network, not cores."),
        ("qs", "query-scheduler", "The request-scheduling tier."),
        ("dp", "load-driver", "Generates load over ssh. Wants enough cores "
                              "and network to saturate the workers without "
                              "itself becoming the limit."),
        ("rg", "registry", "Serves container images to the whole cluster. "
                           "Disk and network matter more than cores."),
):
    pc.defineParameter(
        "hw_type_%s" % _role,
        "Hardware type: %s hosts (blank = cluster default)" % _label,
        portal.ParameterType.STRING, "",
        longDescription="%s Leave blank to use the cluster-wide hardware "
                        "type. Availability differs per type, and a request "
                        "mixing scarce types waits for the scarcest."
                        % _hint,
        advanced=True)
# Ten CUSTOM HOST SLOTS. Each is one machine, requested only when its
# hardware type is filled in, so a RUNNING experiment can absorb whatever
# the cluster happens to have free -- one isolated idle host at a time --
# without disturbing the nodes it already holds. Fill cm1, Modify; later
# fill cm2, Modify again. The portal adds the new node and leaves the
# existing mapping alone.
#
# Deliberately UNASSIGNED to a role. A machine taken because it was free is
# not yet known to be a worker or a gateway; it joins the cluster labelled
# testbed/role=cm-host and is given a job afterwards. That is why these are
# ten separate fields rather than a count plus one type: the slots are
# meant to hold DIFFERENT types, filled at different times, as
# availability appears.
for _m in range(1, 11):
    pc.defineParameter(
        "cm%d_hw_type" % _m,
        "Custom host cm%d -- hardware type (empty = not requested)" % _m,
        portal.ParameterType.STRING, "",
        longDescription="One extra machine of this CloudLab type, named "
                        "cm%d, address 10.10.1.%d. Empty leaves the slot "
                        "unused. It joins the Kubernetes cluster like a "
                        "worker but carries no role of its own until it is "
                        "given one."
                        % (_m, 180 + _m),
        advanced=True)
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
pc.defineParameter(
    "lan_best_effort", "Best-effort experiment LAN (mixed hardware only)",
    portal.ParameterType.BOOLEAN, False,
    advanced=True,
    longDescription="Leave this OFF for anything that produces a number. "
                    "Emulab refuses to build one flat LAN across hardware "
                    "types with different interface speeds -- measured on "
                    "robin98-315025, 2026-09-08, which mapped 11x d430 + 3x "
                    "d710, reached ready on every node, and then failed with "
                    "'SliverStart: Failed to set up experimental networks'. "
                    "d710 is 1Gb, d430 has 10Gb. This flag drops the "
                    "guarantee so such a LAN can be built at all, which is "
                    "what makes 'add a few nodes of another type to reach the "
                    "count' possible when the preferred type is short. It is "
                    "OFF by default because a best-effort LAN spanning mixed "
                    "NICs is not the network the other runs were measured on: "
                    "it buys a testbed to work on, never a comparable one.")

params = pc.bindParameters()

ROLE_LETTERS = ("ctl", "wk", "st", "ng", "qs", "dp", "rg")

CONFIG_FIELDS = ("num_ctl_hosts", "num_wk_hosts", "num_st_hosts",
                 "num_ng_hosts", "num_qs_hosts", "num_dp_hosts",
                 "num_rg_hosts", "hw_type", "disk_image",
                 "istio_version", "install_istio", "link_bw",
                 "lan_best_effort")
cfg = {f: getattr(params, f) for f in CONFIG_FIELDS}
if params.hw_type_custom.strip():
    cfg["hw_type"] = params.hw_type_custom.strip()
# Per-role overrides are resolved AFTER the preset is applied, so a preset can
# still set the cluster-wide type and an override still wins over it.
for _r in ROLE_LETTERS:
    cfg["hw_type_%s" % _r] = getattr(params, "hw_type_%s" % _r, "").strip()
# The slots actually filled, in slot order. A gap is not an error: leaving
# cm2 empty and filling cm3 is what happens when a type stops being
# available between one Modify and the next.
cfg["cm_hosts"] = [(_m, getattr(params, "cm%d_hw_type" % _m, "").strip())
                   for _m in range(1, 11)
                   if getattr(params, "cm%d_hw_type" % _m, "").strip()]
if params.preset != "custom":
    if params.preset not in PRESETS:
        pc.reportError(portal.ParameterError(
            "unknown preset %r" % params.preset, ["preset"]))
    else:
        cfg.update(PRESETS[params.preset])

if cfg["num_wk_hosts"] < 1:
    pc.reportError(portal.ParameterError(
        "At least one worker host is required.", ["num_wk_hosts"]))
if cfg["num_ctl_hosts"] < 1:
    pc.reportError(portal.ParameterError(
        "At least one control-plane host is required.", ["num_ctl_hosts"]))
elif cfg["num_ctl_hosts"] % 2 == 0:
    # Stacked etcd needs an odd number to hold a quorum. Refusing here beats
    # handing back a cluster that loses its API server when one node reboots.
    pc.reportError(portal.ParameterError(
        "Control-plane hosts must be odd (1, 3, 5): stacked etcd needs an "
        "odd count to keep a quorum.", ["num_ctl_hosts"]))
for field, label in (("num_st_hosts", "Standby"), ("num_ng_hosts", "Gateway"),
                     ("num_qs_hosts", "Query-scheduler"),
                     ("num_dp_hosts", "Dispatcher"),
                     ("num_rg_hosts", "Registry")):
    if cfg[field] < 0:
        pc.reportError(portal.ParameterError(
            "%s hosts cannot be negative." % label, [field]))
# The address plan blocks each role into its own decade-ish range; overrun
# would silently collide two roles on one address.
for field, limit, base in (("num_ctl_hosts", 10, 9),
                           ("num_wk_hosts", 39, 20), ("num_st_hosts", 19, 60),
                           ("num_ng_hosts", 19, 80), ("num_dp_hosts", 19, 100),
                           ("num_qs_hosts", 40, 120),
                           ("num_rg_hosts", 19, 160)):
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
# Only when explicitly asked for. See the parameter's description: this makes a
# mixed-hardware LAN buildable and makes it incomparable at the same time.
if cfg["lan_best_effort"]:
    client_lan.best_effort = True


def hw_for(role):
    """Hardware type for a role: its own override, else the cluster default."""
    return cfg.get("hw_type_%s" % role) or cfg["hw_type"]


def make_node(name, role, extra_args="", hw=None):
    node = request.RawPC(name)
    # A custom host names its OWN type -- each slot is filled with whatever
    # was free at the time, so there is no per-role type to look up.
    if hw is None:
        hw = hw_for(role)
    if hw:
        node.hardware_type = hw
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


# ctl1 initialises the cluster. It also carries the private container
# registry unless a registry host was asked for, so the registry never
# competes with a measured worker either way.
ctl = make_node("ctl1", "ctl",
                " --ctl-hosts %d --wk-hosts %d --st-hosts %d --ng-hosts %d"
                " --qs-hosts %d --dp-hosts %d --rg-hosts %d"
                " --cm-hosts %d"
                " --istio-version %s%s"
                % (cfg["num_ctl_hosts"], cfg["num_wk_hosts"],
                   cfg["num_st_hosts"], cfg["num_ng_hosts"],
                   cfg["num_qs_hosts"], cfg["num_dp_hosts"],
                   cfg["num_rg_hosts"], len(cfg["cm_hosts"]),
                   cfg["istio_version"],
                   "" if cfg["install_istio"] else " --no-istio"))
attach(ctl, client_lan, "10.10.1.10")

# Additional control-plane members. They join the control plane ctl1 created,
# using the certificate key it uploaded, so this is one HA control plane and
# not several clusters. ctl1 stays the endpoint.
for j in range(2, cfg["num_ctl_hosts"] + 1):
    n = make_node("ctl%d" % j, "ctl")
    attach(n, client_lan, "10.10.1.%d" % (9 + j))

# role letter, count, address base
for role, count, base in (("wk", cfg["num_wk_hosts"], 20),
                          ("st", cfg["num_st_hosts"], 60),
                          ("ng", cfg["num_ng_hosts"], 80),
                          ("dp", cfg["num_dp_hosts"], 100),
                          ("qs", cfg["num_qs_hosts"], 120),
                          ("rg", cfg["num_rg_hosts"], 160)):
    for j in range(1, count + 1):
        n = make_node("%s%d" % (role, j), role)
        attach(n, client_lan, "10.10.1.%d" % (base + j))

# Custom hosts last, and addressed by SLOT rather than by fill order: cm3
# is always 10.10.1.183 whether or not cm2 was ever requested. An absorbed
# host that changed address because another was added later would
# invalidate every config that already named it.
for m, cm_hw in cfg["cm_hosts"]:
    n = make_node("cm%d" % m, "cm", hw=cm_hw)
    attach(n, client_lan, "10.10.1.%d" % (180 + m))

pc.printRequestRSpec(request)
