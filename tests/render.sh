#!/usr/bin/env bash
# Tests for what the charts render: the parent chart, its children and the checks of the agent chart.
# A shell script, because the charts hand values to each other through Argo CD Applications, and
# helm-unittest tests one chart at a time. Needs helm and python3 with PyYAML (both are in the kube-devenv image).
# Run: tests/render.sh
# shellcheck disable=SC2319 # "$?" right after a test command is the point of the is() helper
set -uo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

command -v helm >/dev/null || { echo "tests/render.sh needs helm (it is in the kube-devenv image)" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "tests/render.sh needs python3 with PyYAML (it is in the kube-devenv image)" >&2; exit 2; }

report() { # name, ok or the reason
  if [ "$2" = ok ]; then echo "ok: $1"; else echo "FAIL: $1 ($2)"; failures=$((failures + 1)); fi
}
is() { # name, condition result (0 = pass), detail
  if [ "$2" -eq 0 ]; then report "$1" ok; else report "$1" "${3:-failed}"; fi
}

# The valuesObject of one Application in a rendered file, written as a values file.
app_values() { # rendered file, Application name, values file to write
  python3 - "$1" "$2" "$3" <<'PY'
import sys, yaml
rendered, name, out = sys.argv[1:4]
for doc in yaml.safe_load_all(open(rendered)):
    if doc and doc.get("kind") == "Application" and doc["metadata"]["name"] == name:
        yaml.safe_dump(doc["spec"]["source"]["helm"]["valuesObject"], open(out, "w"))
        break
else:
    sys.exit("no Application " + name)
PY
}
# One key of the install values in the rendered stack, by a dotted path.
install_value() { # rendered stack file, dotted path
  python3 - "$1" "$2" <<'PY'
import sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc["metadata"]["name"] == "substrate-install":
        value = doc["spec"]["source"]["helm"]["valuesObject"]
        for key in sys.argv[2].split("."):
            value = value.get(key) if isinstance(value, dict) else None
        print("" if value is None else value)
PY
}
app_names() { grep -A3 '^kind: Application' "$1" | grep -E '^  name: ' | sed 's/^  name: //'; }
wave() { grep -A10 "^  name: $2$" "$1" | grep -o 'sync-wave: "[-0-9]*"'; }
# The sync wave of one document, by kind and name.
wave_of() { python3 - "$@" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d["kind"] == sys.argv[2] and d["metadata"]["name"] == sys.argv[3]:
        print(d["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"])
PY
}
# The lines of one Application, from its name to the next document.
application() { awk -v name="$2" '/^kind:/ {kind = $2} $0 == "  name: " name && kind == "Application" {on = 1} on && /^---/ {exit} on' "$1"; }

ai_agent() { helm template p "$repo/charts/ai-agent" "$@"; }
# The chain for one fixture: the parent, the substrate stack, the credential policy and each agent.
render_chain() { # name, values file
  local dir="$work/$1" agent
  mkdir -p "$dir"
  ai_agent -f "$2" >"$dir/parent.yaml" || return 1
  app_values "$dir/parent.yaml" substrate "$dir/stack-values.yaml" || return 1
  helm template stack "$repo/charts/substrate-stack" -f "$dir/stack-values.yaml" >"$dir/stack.yaml" || return 1
  app_values "$dir/stack.yaml" substrate-credential-policy "$dir/policy-values.yaml" || return 1
  helm template policy "$repo/charts/substrate-credential-policy" -f "$dir/policy-values.yaml" >"$dir/policy.yaml" || return 1
  for agent in $(app_names "$dir/parent.yaml" | grep -vx 'substrate'); do
    app_values "$dir/parent.yaml" "$agent" "$dir/$agent-values.yaml" || return 1
    helm template "$agent" "$repo/charts/agent" -f "$dir/$agent-values.yaml" >"$dir/$agent.yaml" || return 1
  done
}

incluster="$repo/examples/in-cluster-gitlab.yaml"
external="$repo/examples/external-gitlab.yaml"

# ---- the in-cluster-gitlab example: one agent with a webhook, metrics and idle suspend -----------
render_chain incluster "$incluster"
is "the in-cluster-gitlab example renders the whole chain" "$?"
parent="$work/incluster/parent.yaml"
grep -q 'kind: AppProject' "$parent" && grep -q '^  name: ai-agents-stack$' "$parent"
is "the parent renders the shared project ai-agents-stack" "$?"
grep -q 'github.com/bbaliyan/kube-ai-agents' "$parent" && grep -q 'github.com/bbaliyan/kube-agent-substrate' "$parent"
is "the project allows this repository and the Substrate repository" "$?"
[ "$(grep -c '^kind: Application' "$parent")" -eq 2 ] && [ "$(grep -c '^  project: ai-agents-stack$' "$parent")" -eq 2 ]
is "the parent renders the substrate Application and one Application for the one agent, both in the shared project" "$?"
! grep -q '^  project: default$' "$work"/incluster/*.yaml
is "no Application of the chain uses the default project" "$?"
python3 - "$parent" <<'PY'
import sys, yaml
p = {d["metadata"]["name"]: d["spec"] for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "AppProject"}
assert sorted(p) == ["ai-agent-pr-agent", "ai-agents-stack"], sorted(p)
assert [x["namespace"] for x in p["ai-agents-stack"]["destinations"]] == ["argocd", "ate-system"], p["ai-agents-stack"]["destinations"]
assert [x["namespace"] for x in p["ai-agent-pr-agent"]["destinations"]] == ["pr-agent", "ate-system"], p["ai-agent-pr-agent"]["destinations"]
for k in ("sourceRepos", "namespaceResourceWhitelist"):
    assert p["ai-agent-pr-agent"][k] == p["ai-agents-stack"][k], k
assert p["ai-agent-pr-agent"]["clusterResourceWhitelist"] == [], "an agent project allows no cluster-scoped kind"
PY
is "the shared project has no agent namespace, and each agent has its own project with its namespace and the control plane namespace, the same repositories and no cluster-scoped kind" "$?"
grep -A12 '^  clusterResourceWhitelist:' "$parent" | grep -q 'kind: CustomResourceDefinition' && grep -A12 '^  clusterResourceWhitelist:' "$parent" | grep -q 'kind: Namespace'
is "the project allows the cluster-scoped kinds that the children make" "$?"
[ "$(wave_of "$parent" Application substrate)" = 0 ] && [ "$(wave_of "$parent" Application pr-agent)" = 1 ] && [ "$(wave_of "$parent" AppProject ai-agents-stack)" = -1 ]
is "the project syncs first, then the control plane, then the agents" "$?"
[ "$(wave_of "$parent" AppProject ai-agent-pr-agent)" -lt "$(wave_of "$parent" Application pr-agent)" ]
is "the project of an agent has a lower wave than its Application, so removal prunes the Application first" "$?"

stack="$work/incluster/stack.yaml"
[ "$(install_value "$stack" config.ateapi.authz.bootstrapOwners)" = 'system:serviceaccount:ate-system:ate-client,system:serviceaccount:pr-agent:pr-agent-registration' ]
is "the install owners are the control plane client and the registration account of the agent" "$?" "$(install_value "$stack" config.ateapi.authz.bootstrapOwners)"
[ "$(install_value "$stack" config.ingressAllowedSPIFFEIDs)" = 'spiffe://cluster.local/ns/pr-agent/sa/pr-agent-webhook' ]
is "the router allow-list holds the webhook shim identity of the agent" "$?"
grep -q 'credentialProvider: .{"name":"k8s.io"}.' "$stack"
is "the credential provider is on when an agent exists" "$?"
{ wave "$stack" substrate-credential-policy; wave "$stack" substrate-install; wave "$stack" substrate-workers; } | tr '\n' ' ' | grep -q 'sync-wave: "0" sync-wave: "1" sync-wave: "2"'
is "the stack syncs the credential policy, then the install, then the workers" "$?"
grep -q 'atespace: reviews' "$work/incluster/policy.yaml" && grep -q '  - pr-agent$' "$work/incluster/policy.yaml"
is "the credential policy allows the namespace of the agent in its atespace" "$?"
grep -q 'kind: CustomResourceDefinition' "$work/incluster/policy.yaml"
is "the credential policy chart makes the PodMonitoring CRD stub" "$?"
out="$(helm template stack "$repo/charts/substrate-stack" -f "$work/incluster/stack-values.yaml" --set substrate.install.helmValues.config.ingressAllowedSPIFFEIDs=spiffe://cluster.local/ns/x/sa/y)"
[ "$(install_value <(printf '%s\n' "$out") config.ingressAllowedSPIFFEIDs)" = 'spiffe://cluster.local/ns/pr-agent/sa/pr-agent-webhook,spiffe://cluster.local/ns/x/sa/y' ]
is "a consumer allow-list is appended to the shim identities" "$?"
out="$(helm template stack "$repo/charts/substrate-stack" -f "$work/incluster/stack-values.yaml" --set substrate.install.helmValues.postgres.storage=20Gi)"
grep -q 'storage: 20Gi' <<<"$out"
is "a consumer value overrides an install default" "$?"
out="$(helm template stack "$repo/charts/substrate-stack")"
[ "$(install_value <(printf '%s\n' "$out") config.ateapi.authz.bootstrapOwners)" = 'system:serviceaccount:ate-system:ate-client' ] && grep -q 'enabled":false' <<<"$out" && [ -z "$(install_value <(printf '%s\n' "$out") config.ingressAllowedSPIFFEIDs)" ]
is "with no agent the install has no agent owner, no credential provider and no allow-list" "$?"

agent="$work/incluster/pr-agent.yaml"
for suffix in actor registration idle-suspend webhook metrics; do
  grep -q "^  name: pr-agent-$suffix\$" "$agent" || report "the agent chart renders the Application pr-agent-$suffix" "missing"
done
[ "$(app_names "$agent" | wc -l)" -eq 5 ] && [ "$(app_names "$agent" | sort -u | wc -l)" -eq 5 ]
is "the agent chart renders five Applications with unique names" "$?"
[ "$(grep -c '^  project: ai-agent-pr-agent$' "$agent")" -eq 5 ]
is "every child Application uses the project of the agent" "$?"
[ "$(grep -c 'resources-finalizer.argocd.argoproj.io' "$agent")" -eq 5 ] && application "$parent" pr-agent | grep -q 'resources-finalizer.argocd.argoproj.io'
is "every agent Application deletes what it made when it is removed" "$?"
for suffix in actor registration idle-suspend webhook metrics; do
  grep -q "releaseName: pr-agent-$suffix\$" "$agent" || report "the Application pr-agent-$suffix sets its release name" "missing"
done
application "$agent" pr-agent-registration | grep -q 'name: pr-agent-registration$'
is "the registration service account is <agent>-registration" "$?"
application "$agent" pr-agent-registration | grep -q 'user:system:serviceaccount:pr-agent:pr-agent-idle-suspend'
is "the registration grants the idle suspend account the editor role" "$?"
application "$agent" pr-agent-idle-suspend | grep -q 'name: pr-agent-idle-suspend$' && ! application "$agent" pr-agent-idle-suspend | grep -q 'podMonitors:'
is "idle suspend sets its service account and leaves the PodMonitors to the stack" "$?"
{ wave "$agent" pr-agent-actor; wave "$agent" pr-agent-webhook; wave "$agent" pr-agent-metrics; } | sort -u | grep -qx 'sync-wave: "0"' \
  && [ "$(wave "$agent" pr-agent-registration)" = 'sync-wave: "1"' ] && [ "$(wave "$agent" pr-agent-idle-suspend)" = 'sync-wave: "2"' ]
is "within an agent the actor syncs first, then the registration, then idle suspend" "$?"
application "$agent" pr-agent-webhook | grep -q 'name: pr-agent-webhook$' && application "$agent" pr-agent-webhook | grep -q 'path: charts/pr-agent-webhook'
is "the webhook shim is named <agent>-webhook" "$?"

# ---- the external-gitlab example: two agents, https and a model key ---------------------------
render_chain external "$external"
is "the external-gitlab example renders the whole chain, with https addresses" "$?"
parent="$work/external/parent.yaml"
[ "$(grep -c '^kind: Application' "$parent")" -eq 3 ]
is "the parent renders one Application for each of the two agents, and the control plane" "$?"
[ -z "$({ app_names "$work/external/reviewer.yaml"; app_names "$work/external/reviewer-docs.yaml"; app_names "$parent"; } | sort | uniq -d)" ]
is "no Application name repeats across the agents" "$?"
owners="$(install_value "$work/external/stack.yaml" config.ateapi.authz.bootstrapOwners)"
grep -q 'system:serviceaccount:reviewer:reviewer-registration' <<<"$owners" && grep -q 'system:serviceaccount:reviewer-docs-agent:reviewer-docs-registration' <<<"$owners"
is "the install owners list the registration account of both agents" "$?" "$owners"
[ "$(install_value "$work/external/stack.yaml" config.ingressAllowedSPIFFEIDs)" = 'spiffe://cluster.local/ns/reviewer/sa/reviewer-webhook' ]
is "only the agent with a webhook is on the router allow-list" "$?"
grep -q 'atespace: reviewer-docs' "$work/external/policy.yaml" && grep -q '  - reviewer-docs-agent$' "$work/external/policy.yaml"
is "the credential policy has one entry for each agent, and the atespace defaults to the name" "$?"
grep -q 'egressTrustBundle: true' "$work/external/reviewer.yaml" && grep -q 'ate-secret://k8s.io/default/reviewer/model-key/api-key' "$work/external/reviewer.yaml"
is "the https agent trusts the egress CA and sends the model key from its Secret" "$?"
! grep -q 'name: reviewer-idle-suspend' "$work/external/reviewer.yaml" && ! grep -q 'name: reviewer-docs-metrics' "$work/external/reviewer-docs.yaml" && ! grep -q 'name: reviewer-docs-webhook' "$work/external/reviewer-docs.yaml"
is "idle suspend, metrics and the shim are off unless an agent sets them" "$?"

two_idle="$work/two-idle.yaml"
{
  sed '/^agents:/,$d' "$incluster"
  cat <<'YAML'
agents:
  - {name: first, type: pr-agent, modelEndpoint: "http://model.example.test:11434", gitlabUrl: "http://gitlab.example.test", idleSuspend: {enabled: true, prometheusUrl: "http://prometheus.example.test:9090"}}
  - {name: second, type: pr-agent, modelEndpoint: "http://model.example.test:11434", gitlabUrl: "http://gitlab.example.test", idleSuspend: {enabled: true, prometheusUrl: "http://prometheus.example.test:9090"}}
YAML
} >"$two_idle"
render_chain two "$two_idle"
is "two agents with idle suspend render" "$?"
[ "$(app_names "$work/two/stack.yaml" | grep -cx 'substrate-monitors')" -eq 1 ] && application "$work/two/stack.yaml" substrate-monitors | grep -q 'enabled: true' \
  && application "$work/two/stack.yaml" substrate-monitors | grep -q 'release: prometheus' && ! grep -q 'podMonitors:' "$work/two/first.yaml" "$work/two/second.yaml"
is "the stack makes one monitors Application for any number of agents with idle suspend" "$?"
! app_names "$work/external/stack.yaml" | grep -qx 'substrate-monitors'
is "the stack makes no monitors Application when no agent has idle suspend" "$?"

# What each agent deploys must fit its project: every object in a permitted namespace, and no cluster-scoped kind.
# The Applications of the agent chart are rendered, then each source chart is rendered with the values that the Application gives.
fits_project() { # chain directory
  python3 - "$1" "$repo" <<'PY'
import sys, os, subprocess, yaml
d, repo = sys.argv[1:3]
parent = [x for x in yaml.safe_load_all(open(d + "/parent.yaml")) if x]
projects = {x["metadata"]["name"]: x["spec"] for x in parent if x["kind"] == "AppProject"}
cluster_kinds = {"Namespace", "CustomResourceDefinition", "ClusterRole", "ClusterRoleBinding", "MutatingAdmissionPolicy", "MutatingAdmissionPolicyBinding", "ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding", "Bundle", "ClusterIssuer", "PriorityClass", "StorageClass", "RuntimeClass", "APIService", "ValidatingWebhookConfiguration", "MutatingWebhookConfiguration"}
problems = []
for app in parent:
    if app["kind"] != "Application" or app["metadata"]["name"] == "substrate":
        continue
    agent = app["metadata"]["name"]
    project = projects["ai-agent-" + agent]
    allowed = {x["namespace"] for x in project["destinations"]}
    for child in yaml.safe_load_all(open("%s/%s.yaml" % (d, agent))):
        if not child or child["kind"] != "Application":
            continue
        name, spec = child["metadata"]["name"], child["spec"]
        if spec["project"] != "ai-agent-" + agent:
            problems.append("%s uses project %s" % (name, spec["project"]))
        if spec["destination"]["namespace"] not in allowed:
            problems.append("%s deploys to %s" % (name, spec["destination"]["namespace"]))
        chart = spec["source"]["path"].split("/")[-1]
        local = repo + "/charts/" + chart
        if not os.path.isdir(local):
            continue  # a chart of kube-agent-substrate: not in this repository
        values = d + "/child-" + name + ".yaml"
        yaml.safe_dump(spec["source"]["helm"].get("valuesObject", {}), open(values, "w"))
        out = subprocess.run(["helm", "template", spec["source"]["helm"].get("releaseName", name), local, "-f", values, "--namespace", spec["destination"]["namespace"]], capture_output=True, text=True)
        if out.returncode:
            problems.append("%s does not render: %s" % (name, out.stderr[:200]))
            continue
        for obj in yaml.safe_load_all(out.stdout):
            if not obj:
                continue
            if obj["kind"] in cluster_kinds:
                problems.append("%s makes the cluster-scoped %s %s" % (name, obj["kind"], obj["metadata"]["name"]))
            else:
                ns = obj["metadata"].get("namespace") or spec["destination"]["namespace"]
                if ns not in allowed:
                    problems.append("%s makes %s %s in %s" % (name, obj["kind"], obj["metadata"]["name"], ns))
if problems:
    sys.exit(chr(10).join(problems))
PY
}
for fixture in incluster external two; do
  out="$(fits_project "$work/$fixture" 2>&1)"
  is "what each agent of the $fixture fixture makes fits its project" "$?" "$out"
done

[ -n "$(install_value "$work/external/stack.yaml" config.egress.trustedCaPem)" ] || [ -n "$(install_value "$work/external/stack.yaml" egress.trustedCaPem)" ]
is "the external-gitlab example passes a private CA to the install as the trusted CA of the egress proxy" "$?" "$(install_value "$work/external/stack.yaml" egress.trustedCaPem)"
# Every host in a public example is a reserved example name, a cluster-internal name or a public code host.
hosts="$(grep -ohE '(https?)://[A-Za-z0-9.-]+' "$external" | sed 's|^[a-z]*://||' | sort -u)"
[ -n "$hosts" ] && ! grep -vE '(^|\.)(example\.test|github\.com)$|\.svc(\.cluster\.local)?$' <<<"$hosts" | grep -q .
is "the external-gitlab example names only example hosts" "$?" "$hosts"

# ---- what the parent refuses ----------------------------------------------------------
refuse() { # name, expected error text, the agents block
  local file="$work/refuse.yaml" out
  { sed '/^agents:/,$d' "$incluster"; printf '%s\n' "$3"; } >"$file"
  out="$(ai_agent -f "$file" 2>&1)"
  [ $? -ne 0 ] && grep -q "$2" <<<"$out"
  is "$1" "$?" "$out"
}
addresses='modelEndpoint: "http://model.example.test:11434", gitlabUrl: "http://gitlab.example.test"'
refuse "two agents with one name fail" 'two agents are named' "agents:
  - {name: same, type: pr-agent, $addresses}
  - {name: same, type: pr-agent, namespace: other, $addresses}"
refuse "an unknown agent type fails" 'type' "agents:
  - {name: odd, type: other-agent, $addresses}"
refuse "an agent with no type fails" 'type' "agents:
  - {name: odd, $addresses}"
refuse "two agents in one namespace fail" 'two agents use the namespace' "agents:
  - {name: one, type: pr-agent, namespace: shared, $addresses}
  - {name: two, type: pr-agent, namespace: shared, $addresses}"
refuse "two actors with one name in one atespace fail" 'two agents use the actor' "agents:
  - {name: one, type: pr-agent, atespace: shared, $addresses}
  - {name: two, type: pr-agent, atespace: shared, $addresses}"
refuse "an agent named like another agent plus a suffix fails" 'would make an Application named' "agents:
  - {name: rev, type: pr-agent, $addresses}
  - {name: rev-actor, type: pr-agent, $addresses}"
refuse "an agent named substrate fails" 'would make an Application named' "agents:
  - {name: substrate, type: pr-agent, $addresses}"
refuse "an agent name that is not a DNS label fails" 'name' "agents:
  - {name: Bad_Name, type: pr-agent, $addresses}"

# ---- the checks of the agent chart ------------------------------------------------------
base=(--set project=a --set agent.name=a --set agent.atespace=a --set agent.namespace=a --set agent.gitlabUrl=http://gitlab.example.test --set agent.modelEndpoint=http://model.example.test:11434)
agent_chart() { helm template a "$repo/charts/agent" "${base[@]}" "$@"; }
agent_fails() { # name, expected text, helm arguments
  local name="$1" text="$2" out
  shift 2
  out="$(agent_chart "$@" 2>&1)"
  [ $? -ne 0 ] && grep -q "$text" <<<"$out" && ! grep -q 'kind: Application' <<<"$out"
  is "$name" "$?" "$out"
}
out="$(agent_chart --show-only templates/actor.yaml)"
grep -q 'CONFIG__MODEL: ollama/qwen3-coder:30b' <<<"$out" && grep -q 'OLLAMA__API_BASE: http://model.example.test:11434' <<<"$out" && grep -q 'CONFIG__CUSTOM_MODEL_MAX_TOKENS: "16000"' <<<"$out" \
  && grep -q 'name: pr-agent$' <<<"$out" && grep -q 'atespace: a$' <<<"$out"
is "the actor has the model, the model address, the context length and the default actor name" "$?" "$out"
out="$(agent_chart --set agent.actorName=reviewer --show-only templates/actor.yaml)"
grep -q 'name: reviewer$' <<<"$out" && ! grep -q 'name: pr-agent$' <<<"$out"
is "agent.actorName sets the name of the actor" "$?" "$out"
grep -q 'CONFIG__OUTPUT_RUN_DETAILS' <<<"$(agent_chart --show-only templates/actor.yaml)" && ! grep -q 'CONFIG__OUTPUT_RUN_DETAILS' <<<"$(agent_chart --set agent.runDetails=false --show-only templates/actor.yaml)"
is "agent.runDetails false leaves the run details setting out" "$?"
! grep -q 'OTEL__IS_ENABLED' <<<"$(agent_chart --show-only templates/actor.yaml)"
is "metrics are off when no endpoint is set" "$?"
out="$(agent_chart --set agent.metricsCollector.enabled=true --show-only templates/actor.yaml)"
grep -q 'OTEL__OTLP_ENDPOINT: http://pr-agent-metrics.a.svc.cluster.local:4318' <<<"$out" && grep -q 'ate-secret://k8s.io/default/a/pr-agent-metrics/password' <<<"$out" && grep -q 'GUNICORN_WORKERS: "1"' <<<"$out"
is "the metrics collector is the OTLP endpoint of the actor, with the generated token sent by the egress proxy" "$?" "$out"
out="$(agent_chart --set agent.metricsCollector.enabled=true --set agent.metricsApiKeySecret.name=metrics-token --set agent.metricsApiKeySecret.key=token --show-only templates/metrics.yaml)"
grep -q 'generateToken: false' <<<"$out" && grep -q 'name: metrics-token' <<<"$out" && grep -q 'key: token' <<<"$out"
is "a metrics Secret of your own turns the generated token off" "$?" "$out"
! grep -q 'name: a-metrics' <<<"$(agent_chart)"
is "the metrics Application is off by default" "$?"
! grep -q 'PR_REVIEWER__ENABLE_LARGE_PR_CHUNKING' <<<"$(agent_chart --set agent.largeReviews=false --show-only templates/actor.yaml)" && grep -q 'PR_REVIEWER__MAX_NUMBER_OF_CALLS: "5"' <<<"$(agent_chart --set agent.maxReviewCalls=5 --show-only templates/actor.yaml)"
is "agent.largeReviews and agent.maxReviewCalls set the chunking" "$?"
grep -q 'CONFIG__AI_TIMEOUT: "300"' <<<"$(agent_chart --set agent.modelTimeoutSeconds=300 --show-only templates/actor.yaml)"
is "agent.modelTimeoutSeconds sets the model timeout" "$?"
out="$(agent_chart --set agent.model=openai/example-model --set agent.modelEndpoint=https://llm.example.test/v1 --set agent.egressTrustBundle=true --set agent.modelApiKeySecret.name=model-key --set agent.modelApiKeySecret.key=api-key --show-only templates/actor.yaml)"
grep -q 'OPENAI__API_BASE: https://llm.example.test/v1' <<<"$out" && grep -q 'OPENAI__KEY: replaced-by-the-egress-proxy' <<<"$out" && grep -q 'SSL_CERT_FILE' <<<"$out" && grep -q 'egressTrustBundle: true' <<<"$out"
is "an https model server with a key trusts the egress CA and gets a placeholder key" "$?" "$out"
out="$(agent_chart --set agent.gitlabExtraUrls=null --show-only templates/actor.yaml 2>&1)"
grep -q 'kind: Application' <<<"$out"
is "a null agent.gitlabExtraUrls renders" "$?" "$out"
agent_fails "an agent with no model endpoint fails" 'agent.modelEndpoint' --set agent.modelEndpoint=
agent_fails "an agent with no GitLab address fails" 'agent.gitlabUrl is required' --set agent.gitlabUrl=
agent_fails "an agent with no namespace fails" 'agent.namespace is required' --set agent.namespace=
agent_fails "an IP address as the model endpoint fails" 'must use a DNS name' --set agent.modelEndpoint=http://192.0.2.10:11434
agent_fails "an address with another scheme fails" 'must start with http' --set agent.modelEndpoint=ftp://model.example.test
agent_fails "a model with an unknown provider prefix fails" 'agent.model must start with one of' --set agent.model=other/model
agent_fails "an https model without the trust bundle fails" 'must trust the egress gateway CA' --set agent.model=openai/example-model --set agent.modelEndpoint=https://llm.example.test
agent_fails "an https GitLab address without the trust bundle fails" 'must trust the egress gateway CA' --set agent.gitlabUrl=https://git.example.test
agent_fails "an extra GitLab address without a scheme fails" 'agent.gitlabExtraUrls must start with http' --set 'agent.gitlabExtraUrls={git.example.test}'
agent_fails "an extra GitLab address that is an IP address fails" 'agent.gitlabExtraUrls must use a DNS name' --set 'agent.gitlabExtraUrls={http://192.0.2.20}'
agent_fails "an extra GitLab address that repeats the first fails" 'repeats the GitLab host' --set 'agent.gitlabExtraUrls={http://gitlab.example.test}'
agent_fails "an extra GitLab address on the model host fails" 'same host as agent.modelEndpoint' --set 'agent.gitlabExtraUrls={http://model.example.test}'
agent_fails "a metrics endpoint on the model host fails" 'agent.metricsEndpoint has the same host' --set agent.metricsEndpoint=http://model.example.test:9090
agent_fails "a model key Secret with no key fails" 'agent.modelApiKeySecret needs a key' --set agent.modelApiKeySecret.name=model-key
agent_fails "a model key Secret with no name fails" 'agent.modelApiKeySecret needs a name' --set agent.modelApiKeySecret.key=api-key
agent_fails "a review call cap that is not a number fails" 'agent.maxReviewCalls' --set agent.maxReviewCalls=abc
agent_fails "a model timeout that is not a number fails" 'agent.modelTimeoutSeconds' --set agent.modelTimeoutSeconds=abc
agent_fails "idle suspend with no Prometheus address fails" 'agent.idleSuspend.prometheusUrl is required' --set agent.idleSuspend.enabled=true

# ---- the webhook and the registration -------------------------------------------------------
out="$(agent_chart --set agent.webhook.port=8080 --set agent.hopToken=custom-hop --set agent.webhook.hopToken=other --show-only templates/webhook.yaml)"
grep -q 'hopToken: custom-hop' <<<"$out" && ! grep -q 'hopToken: other' <<<"$out" && grep -q 'name: a-webhook$' <<<"$out" && grep -q 'name: pr-agent$' <<<"$out"
is "the shim gets its name, the actor and the hop token of the agent, whatever the webhook values say" "$?" "$out"
! grep -q 'name: a-webhook' <<<"$(agent_chart)"
is "an empty agent.webhook renders no shim" "$?"
out="$(agent_chart --set agent.webhook.port=8080 --set agent.webhook.pipeline.enabled=true --set agent.webhook.pipeline.issuer=https://gitlab.example.test --set agent.webhook.pipeline.jwksUri=https://gitlab.example.test/oauth/discovery/keys --set 'agent.webhook.pipeline.namespacePaths={team}' --show-only templates/webhook.yaml)"
grep -q 'issuer: https://gitlab.example.test' <<<"$out" && grep -q 'jwksUri: https://gitlab.example.test/oauth/discovery/keys' <<<"$out" && grep -q -- '- team' <<<"$out"
is "the pipeline route values pass through in full, with no defaulting" "$?" "$out"
! grep -q 'accessBindings' <<<"$(agent_chart --show-only templates/registration.yaml)"
is "the registration has no access binding when idle suspend is off" "$?"
out="$(agent_chart --show-only templates/registration.yaml)"
! grep -q 'unregister' <<<"$out"
is "the registration has no unregister value by default, so an older registration chart still renders" "$?"
out="$(agent_chart --set agent.registration.unregister=true --show-only templates/registration.yaml)"
grep -A1 'unregister:' <<<"$out" | grep -q 'enabled: true'
is "agent.registration.unregister turns on unregister.enabled in the registration chart" "$?" "$out"

# ---- the shim chart takes the name that the parent gives it ----------------------------------
out="$(helm template s "$repo/charts/pr-agent-webhook" --set name=a-webhook --set actor.name=pr-agent)"
grep -q 'kind: ServiceAccount' <<<"$out" && grep -q '^  name: a-webhook$' <<<"$out" && ! grep -q '^  name: pr-agent-webhook$' <<<"$out"
is "the shim chart names its service account from the name value, not from the actor" "$?" "$out"

echo
if [ "$failures" -gt 0 ]; then echo "$failures failed"; exit 1; fi
echo "all passed"
