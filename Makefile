# The whole sandbox on kind, CPU only, at no cloud cost.
# A shell for every recipe: macOS make 3.81 runs a simple recipe without one,
# and the PATH exported below then never reaches it.
SHELL := /usr/bin/env bash
BIN := $(CURDIR)/.cache/bin
export PATH := $(BIN):$(PATH)

.PHONY: tools up demo test check down

tools:
	@./scripts/install-tools.sh >/dev/null

up: tools
	kind create cluster --config kind/cluster.yaml --wait 120s
	./scripts/install-gvisor.sh
	./scripts/install-sandbox.sh

demo: tools
	-kubectl -n agents delete job agent-demo records-clerk --ignore-not-found --wait=true
	kubectl apply -f manifests/agent/job.yaml
	for j in agent-demo records-clerk; do \
	  until kubectl -n agents get job $$j -o jsonpath='{.status.succeeded}{.status.failed}' | grep -q .; do sleep 2; done; \
	done
	kubectl -n agents logs job/agent-demo
	kubectl -n agents logs job/records-clerk

test: tools
	./tests/e2e/run.sh

check: tools
	./scripts/validate.sh
	python3 tests/static/plant_violations.py

down: tools
	kind delete cluster --name agent-sandbox
