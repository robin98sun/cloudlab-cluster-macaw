"""Build topology.json for the Kubernetes + Istio layout.

Physical hosts carry roles ctl|wk|lg.

Prefer `from-manifest` -- the CloudLab manifest is authoritative and belongs
in every result bundle. `derive` covers the gap before you download one.
"""

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET

ROLE_OF = re.compile(r"^(ctl|wk|st|ng|dp|lg)\d*$")
# One experiment LAN; the default hardware type has a single experimental
# interface. "lg" is retained only to read manifests from older allocations.
LAN_BY_PREFIX = {"10.10.1.": "client"}


def strip_ns(tag):
    return tag.split("}", 1)[-1]


def parse_manifest(path):
    root = ET.parse(path).getroot()
    nodes = []
    for el in root.iter():
        if strip_ns(el.tag) != "node":
            continue
        name = el.get("client_id")
        if not name:
            continue
        m = ROLE_OF.match(name)
        if not m:
            continue
        entry = {"name": name, "role": m.group(1), "control": None,
                 "user": None, "hardware": None, "ifaces": {}}
        for sub in el.iter():
            t = strip_ns(sub.tag)
            if t == "login" and entry["control"] is None:
                entry["control"] = sub.get("hostname")
                entry["user"] = sub.get("username")
            elif t == "ip" and sub.get("type") == "ipv4":
                addr = sub.get("address") or ""
                lan = LAN_BY_PREFIX.get(addr[:8])
                if lan:
                    entry["ifaces"][lan] = addr
            elif t == "node_type" and sub.get("type_name"):
                entry["hardware"] = entry["hardware"] or sub.get("type_name")
        nodes.append(entry)
    if not nodes:
        sys.exit("no ctl/wk/lg nodes found in manifest -- wrong file?")
    return nodes


# role letter -> address base on the single experiment LAN. Must match the
# address plan in profile.py; a mismatch here silently mislabels nodes.
ROLE_BASE = (("wk", 20), ("st", 60), ("ng", 80), ("dp", 100))


def derive_nodes(user, domain, counts):
    def node(name, role, ifaces):
        return {"name": name, "role": role,
                "control": "%s.%s" % (name, domain),
                "user": user, "hardware": None, "ifaces": ifaces}
    nodes = [node("ctl1", "ctl", {"client": "10.10.1.10"})]
    for role, base in ROLE_BASE:
        for j in range(1, counts.get(role, 0) + 1):
            nodes.append(node("%s%d" % (role, j), role,
                              {"client": "10.10.1.%d" % (base + j)}))
    return nodes


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    m = sub.add_parser("from-manifest")
    m.add_argument("manifest")

    d = sub.add_parser("derive")
    d.add_argument("--user", required=True)
    d.add_argument("--domain", required=True,
                   help="e.g. testbed-smoke.myproject.utah.cloudlab.us")
    d.add_argument("--wk", type=int, default=1)
    d.add_argument("--st", type=int, default=0)
    d.add_argument("--ng", type=int, default=0)
    d.add_argument("--dp", type=int, default=0)

    for q in (m, d):
        q.add_argument("--out", default="topology.json")

    a = p.parse_args()
    nodes = (parse_manifest(a.manifest) if a.cmd == "from-manifest"
             else derive_nodes(a.user, a.domain,
                               {"wk": a.wk, "st": a.st, "ng": a.ng,
                                "dp": a.dp}))
    topo = {"nodes": nodes, "lans": {"client": "10.10.1.0/24"}}
    with open(a.out, "w") as fh:
        json.dump(topo, fh, indent=2)
    counts = {}
    for n in nodes:
        counts[n["role"]] = counts.get(n["role"], 0) + 1
    print("wrote %s: hosts %s" % (a.out, counts))


if __name__ == "__main__":
    main()
