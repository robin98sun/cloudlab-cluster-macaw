# Testbed workflow. See docs/runbook.md.
SHELL := /bin/bash
TOPOLOGY ?= topology.json
USER_    ?= $(shell whoami)
DOMAIN   ?=
LG ?= 0
WK ?= 1
ISTIO_VERSION ?= 1.31.0-rc.0
SSH := ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new

CTL = $(shell python3 -c "import json;t=json.load(open('$(TOPOLOGY)'));n=next(x for x in t['nodes'] if x['role']=='ctl');print(n['user']+'@'+n['control'])" 2>/dev/null)

.PHONY: help topology topology-derive verify verify-fast istio nri-restart kubeconfig clean

help:
	@echo "topology         build $(TOPOLOGY) from a downloaded manifest.xml"
	@echo "topology-derive  build $(TOPOLOGY) from counts + DOMAIN=..."
	@echo "verify           run all cluster checks"
	@echo "verify-fast      skip the slow image probe (C09)"
	@echo "istio            (re)install the mesh on ctl1"
	@echo "nri-restart      re-apply the NRI template and restart k3s everywhere"
	@echo "kubeconfig       print the command to reach the cluster from here"

topology:
	@test -f manifest.xml || { echo "download the manifest from the CloudLab portal to ./manifest.xml"; exit 1; }
	python3 orchestrator/topology.py from-manifest manifest.xml --out $(TOPOLOGY)

topology-derive:
	@test -n "$(DOMAIN)" || { echo "set DOMAIN=<exp>.<proj>.<cluster>.cloudlab.us"; exit 1; }
	python3 orchestrator/topology.py derive --user $(USER_) --domain $(DOMAIN) \
		--lg $(LG) --wk $(WK) --out $(TOPOLOGY)

verify:
	python3 orchestrator/verify.py --topology $(TOPOLOGY)

verify-fast:
	python3 orchestrator/verify.py --topology $(TOPOLOGY) --skip C09

istio:
	@test -n "$(CTL)" || { echo "no $(TOPOLOGY); run make topology first"; exit 1; }
	$(SSH) $(CTL) "bash /local/repository/cloudlab/install-istio.sh $(ISTIO_VERSION)"

nri-restart:
	@test -f $(TOPOLOGY) || { echo "no $(TOPOLOGY); run make topology first"; exit 1; }
	@python3 -c "import json;t=json.load(open('$(TOPOLOGY)'));print('\n'.join(n['user']+'@'+n['control'] for n in t['nodes']))" \
	| while read -r host; do \
		echo "== $$host"; \
		$(SSH) "$$host" "bash /local/repository/cloudlab/containerd-nri.sh && \
			(sudo systemctl restart k3s 2>/dev/null || sudo systemctl restart k3s-agent 2>/dev/null || true)"; \
	done

kubeconfig:
	@echo "on any node:  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
	@echo "from here:    $(SSH) $(CTL) 'sudo /usr/local/bin/k3s kubectl get nodes'"

clean:
	rm -f $(TOPOLOGY) verify-results.json
