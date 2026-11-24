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

.PHONY: test-commit test-fast hooks lint-yaml lint-pipelines lint-renovate secrets commit-messages

test-commit: test-fast lint-yaml lint-pipelines lint-renovate commit-messages

test-fast: secrets

hooks:
	git config core.hooksPath .githooks

lint-yaml:
	yamllint -d '{extends: relaxed, rules: {line-length: disable}}' .github/workflows renovate.json

lint-pipelines:
	$(CHECKS)/pipeline-lint.sh .

lint-renovate:
	python3 -c "import json; json.load(open('renovate.json'))"

secrets:
	$(CHECKS)/secrets.sh .

commit-messages:
	$(CHECKS)/commit-messages.sh "$(BASE_REF)"
