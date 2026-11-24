# Every check lives here. The CI workflow only sets up the environment and
# calls a target, so a run on a laptop matches a run on GitHub.
#
# Run inside the kube-devenv image. Values arrive as Make variables:
#   BASE_REF  commit the branch started from; empty skips commit-messages

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

CHECKS   ?= /usr/share/kube-devenv/checks
BASE_REF ?= $(shell git rev-parse --verify --quiet origin/main)
export REQUIRE_SIGNOFF := 0

.PHONY: test-commit test-fast hooks lint-yaml lint-pipelines lint-renovate secrets commit-messages charts test-charts test-scripts

test-commit: test-fast lint-yaml lint-pipelines lint-renovate charts test-charts test-scripts commit-messages

test-fast: secrets

hooks:
	git config core.hooksPath .githooks

YAML_FILES := $(wildcard charts/*/Chart.yaml charts/*/values.yaml charts/*/ci/*.yaml charts/*/tests/*.yaml)

lint-yaml:
	yamllint -d '{extends: relaxed, rules: {line-length: disable}}' .github/workflows renovate.json examples $(YAML_FILES)

# Lint every chart and validate what it renders. Argo CD, External Secrets and Prometheus own most of the
# kinds, and no catalog has a schema for all of them, so a missing schema is skipped.
# The chart agent needs the values that ai-agent gives it, and ai-agent is rendered with each example.
charts: export KUBECONFORM_IGNORE_MISSING_SCHEMAS = 1
charts:
	for chart in substrate-stack substrate-credential-policy pr-agent-webhook pr-agent-metrics; do \
		$(CHECKS)/helm-kubeconform.sh charts/$$chart; \
	done
	helm lint charts/agent --values charts/agent/ci/values.yaml
	helm template charts/agent --values charts/agent/ci/values.yaml | kubeconform -strict -summary -ignore-missing-schemas
	for example in examples/*.yaml; do \
		helm lint charts/ai-agent --values $$example; \
		helm template charts/ai-agent --values $$example | kubeconform -strict -summary -ignore-missing-schemas; \
	done

# What the charts render, as declared tests (helm-unittest).
test-charts:
	helm unittest charts/pr-agent-webhook charts/substrate-credential-policy

# What the charts hand to each other: the parent, the stack and the agents.
test-scripts:
	tests/render.sh

lint-pipelines:
	$(CHECKS)/pipeline-lint.sh .

lint-renovate:
	python3 -c "import json; json.load(open('renovate.json'))"

secrets:
	$(CHECKS)/secrets.sh .

commit-messages:
	$(CHECKS)/commit-messages.sh "$(BASE_REF)"
