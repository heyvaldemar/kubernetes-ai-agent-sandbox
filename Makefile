# The whole sandbox on kind, CPU only, at no cloud cost.
BIN := $(CURDIR)/.cache/bin
export PATH := $(BIN):$(PATH)

.PHONY: tools up demo test check down

tools:
	@./scripts/install-tools.sh >/dev/null

up: tools
	kind create cluster --config kind/cluster.yaml --wait 120s
	./scripts/install-gvisor.sh
	kubectl apply -k manifests/
	kubectl -n tools rollout status deployment/tool-gateway --timeout=180s
	kubectl -n corp rollout status deployment/internal-records --timeout=180s

demo: tools
	-kubectl -n agents delete job agent-demo --ignore-not-found --wait=true
	kubectl apply -f manifests/agent/job.yaml
	kubectl -n agents wait --for=jsonpath='{.status.conditions[?(@.status=="True")].type}' job/agent-demo --timeout=180s
	kubectl -n agents logs job/agent-demo

test: tools
	./tests/e2e/run.sh

check: tools
	./scripts/validate.sh
	python3 tests/static/plant_violations.py

down: tools
	kind delete cluster --name agent-sandbox
