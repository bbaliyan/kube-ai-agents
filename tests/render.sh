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
# rendered collects the files of every chain that can hold an Application or AppProject.
rendered=()
render_chain() { # name, values file
  local dir="$work/$1" agent
  mkdir -p "$dir"
  ai_agent -f "$2" >"$dir/parent.yaml" || return 1
  rendered+=("$dir/parent.yaml")
  app_values "$dir/parent.yaml" substrate "$dir/stack-values.yaml" || return 1
  helm template stack "$repo/charts/substrate-stack" -f "$dir/stack-values.yaml" >"$dir/stack.yaml" || return 1
  rendered+=("$dir/stack.yaml")
  app_values "$dir/stack.yaml" substrate-credential-policy "$dir/policy-values.yaml" || return 1
  helm template policy "$repo/charts/substrate-credential-policy" -f "$dir/policy-values.yaml" >"$dir/policy.yaml" || return 1
  for agent in $(app_names "$dir/parent.yaml" | grep -vx 'substrate'); do
    app_values "$dir/parent.yaml" "$agent" "$dir/$agent-values.yaml" || return 1
    helm template "$agent" "$repo/charts/agent" -f "$dir/$agent-values.yaml" >"$dir/$agent.yaml" || return 1
    rendered+=("$dir/$agent.yaml")
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
assert [x["namespace"] for x in p["ai-agents-stack"]["destinations"]] == ["argocd", "ate-system", "pr-agent"], p["ai-agents-stack"]["destinations"]
assert [x["namespace"] for x in p["ai-agent-pr-agent"]["destinations"]] == ["pr-agent", "ate-system"], p["ai-agent-pr-agent"]["destinations"]
for k in ("sourceRepos", "namespaceResourceWhitelist"):
    assert p["ai-agent-pr-agent"][k] == p["ai-agents-stack"][k], k
assert p["ai-agent-pr-agent"]["clusterResourceWhitelist"] == [], "an agent project allows no cluster-scoped kind"
PY
is "the shared project reaches each agent namespace for the deployment account, and each agent has its own project with its namespace and the control plane namespace, the same repositories and no cluster-scoped kind" "$?"
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
[ "$(wave_of "$stack" Application substrate-credential-policy) $(wave_of "$stack" Application substrate-install) $(wave_of "$stack" Application substrate-workers)" = '0 1 2' ]
is "the stack syncs the credential policy, then the install, then the workers" "$?"
grep -q 'atespace: reviews' "$work/incluster/policy.yaml" && grep -q '  - pr-agent$' "$work/incluster/policy.yaml"
is "the credential policy allows the namespace of the agent in its atespace" "$?"
[ "$(install_value "$stack" podMonitoringCrdStub)" = True ] && ! grep -q 'kind: CustomResourceDefinition' "$work/incluster/policy.yaml"
is "the install makes the PodMonitoring CRD stub, and the credential policy chart does not" "$?"
out="$(helm template stack "$repo/charts/substrate-stack" -f "$work/incluster/stack-values.yaml" --set substrate.install.helmValues.config.ingressAllowedSPIFFEIDs=spiffe://cluster.local/ns/x/sa/y)"
[ "$(install_value <(printf '%s\n' "$out") config.ingressAllowedSPIFFEIDs)" = 'spiffe://cluster.local/ns/pr-agent/sa/pr-agent-webhook,spiffe://cluster.local/ns/x/sa/y' ]
is "a consumer allow-list is appended to the shim identities" "$?"
out="$(helm template stack "$repo/charts/substrate-stack" -f "$work/incluster/stack-values.yaml" --set substrate.install.helmValues.postgres.storage=20Gi)"
grep -q 'storage: 20Gi' <<<"$out"
is "a consumer value overrides an install default" "$?"
out="$(helm template stack "$repo/charts/substrate-stack")"
[ "$(install_value <(printf '%s\n' "$out") config.ateapi.authz.bootstrapOwners)" = 'system:serviceaccount:ate-system:ate-client' ] && [ "$(install_value <(printf '%s\n' "$out") config.atenet.egress.credentialProvider)" = '{"enabled":false}' ] && [ -z "$(install_value <(printf '%s\n' "$out") config.ingressAllowedSPIFFEIDs)" ]
is "with no agent the install has no agent owner, no credential provider and no allow-list" "$?"

helm template stack "$repo/charts/substrate-stack" -f "$work/incluster/stack-values.yaml" --set substrate.workers.replcas=2 >/dev/null 2>&1
is "a misspelled key of the stack fails the schema" "$((1 - $?))"
helm template metrics "$repo/charts/pr-agent-metrics" --set serviceMonitor.sampelLimit=5 >/dev/null 2>&1
is "a misspelled key of the metrics chart fails the schema" "$((1 - $?))"
helm template policy "$repo/charts/substrate-credential-policy" --set 'agents[0].atespace=a' >/dev/null 2>&1
is "an agent entry without a namespace fails the policy schema" "$((1 - $?))"

agent="$work/incluster/pr-agent.yaml"
for suffix in actor registration idle-suspend webhook metrics; do
  grep -q "^  name: pr-agent-$suffix\$" "$agent"
  is "the agent chart renders the Application pr-agent-$suffix" "$?" missing
done
[ "$(app_names "$agent" | wc -l)" -eq 5 ] && [ "$(app_names "$agent" | sort -u | wc -l)" -eq 5 ]
is "the agent chart renders five Applications with unique names" "$?"
[ "$(grep -c '^  project: ai-agent-pr-agent$' "$agent")" -eq 5 ]
is "every child Application uses the project of the agent" "$?"
for suffix in actor registration idle-suspend webhook metrics; do
  grep -q "releaseName: pr-agent-$suffix\$" "$agent"
  is "the Application pr-agent-$suffix sets its release name" "$?" missing
done
application "$agent" pr-agent-registration | grep -q 'name: pr-agent-registration$'
is "the registration service account is <agent>-registration" "$?"
application "$agent" pr-agent-registration | grep -q 'user:system:serviceaccount:pr-agent:pr-agent-idle-suspend'
is "the registration grants the idle suspend account the editor role" "$?"
application "$agent" pr-agent-idle-suspend | grep -q 'name: pr-agent-idle-suspend$'
is "idle suspend sets its service account" "$?"
application "$agent" pr-agent-idle-suspend | grep -q 'repoURL: "https://github.com/bbaliyan/kube-ai-agents"' && application "$agent" pr-agent-idle-suspend | grep -q 'path: charts/substrate-idle-suspend$'   && application "$agent" pr-agent-registration | grep -q 'repoURL: "https://github.com/bbaliyan/kube-agent-substrate"'
is "idle suspend comes from this repository (self) and the registration from Agent Substrate" "$?"
[ "$(for suffix in actor webhook metrics registration idle-suspend; do wave_of "$agent" Application "pr-agent-$suffix"; done | tr '\n' ' ')" = '0 0 0 1 2 ' ]
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
app_values "$work/two/stack.yaml" substrate-workers "$work/two/workers-values.yaml" && python3 - "$work/two/workers-values.yaml" <<'PY' && ! app_names "$work/two/stack.yaml" | grep -qx 'substrate-monitors'
import sys, yaml
got = yaml.safe_load(open(sys.argv[1])).get("observability")
sys.exit(0 if got == {"enabled": True, "podMonitorLabels": {"release": "prometheus"}} else 1)
PY
is "with idle suspend the workers chart makes the PodMonitors, once for any number of agents" "$?"
! application "$work/external/stack.yaml" substrate-workers | grep -q 'observability:'
is "the stack makes no PodMonitors when no agent has idle suspend" "$?"

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

# ---- the deployment account of an agent -------------------------------------------------------
# With application sync impersonation on, this account is all that the Applications of an agent have.
helm template d "$repo/charts/agent" -f "$repo/tests/values/agent/minimal.yaml" --show-only templates/deployer.yaml >"$work/deployer.yaml"
python3 - "$parent" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
projects = {d["metadata"]["name"]: d["spec"] for d in docs if d["kind"] == "AppProject"}
agents = [d["metadata"]["name"] for d in docs if d["kind"] == "Application" and d["spec"]["source"]["path"] == "charts/agent"]
stack = projects["ai-agents-stack"]
ok = "destinationServiceAccounts" not in stack and agents
for name in agents:
    p = projects["ai-agent-" + name]
    ok = ok and p["destinationServiceAccounts"] == [{"server": "*", "namespace": "*", "defaultServiceAccount": f"argocd:{name}-deployer"}]
    ok = ok and {d["namespace"] for d in p["destinations"]} <= {d["namespace"] for d in stack["destinations"]}
sys.exit(0 if ok else 1)
PY
is "each agent project names its deployment account for every destination, and the stack project can make that account's rights" "$?"

# Everything that the local child charts of an agent make must be covered by the rights of the account, and the account
# must hold every rule that a Role of an agent grants in the control plane namespace.
python3 - "$incluster" "$work/routed.yaml" <<'PY'
import sys, yaml
values = yaml.safe_load(open(sys.argv[1]))
values["agents"][0]["webhook"]["ingressRoute"] = {"enabled": True, "host": "review.example.test"}
yaml.safe_dump(values, open(sys.argv[2], "w"))
PY
render_chain deploy "$work/routed.yaml"
python3 - "$work/deploy" "$repo" <<'PY'
import pathlib, subprocess, sys, yaml
chain, repo = pathlib.Path(sys.argv[1]), sys.argv[2]
parent = [d for d in yaml.safe_load_all(open(chain / "parent.yaml")) if d]
agent = next(d for d in parent if d["kind"] == "Application" and d["spec"]["source"]["path"] == "charts/agent")
name = agent["metadata"]["name"]
values = chain / "agent-values.yaml"
values.write_text(yaml.safe_dump(agent["spec"]["source"]["helm"]["valuesObject"]))
render = lambda *a: [d for d in yaml.safe_load_all(subprocess.run(["helm", "template", *a], check=True, capture_output=True, text=True).stdout) if d]
tree = render(name, f"{repo}/charts/agent", "-f", str(values))
roles = {d["metadata"]["namespace"]: d["rules"] for d in tree if d["kind"] == "Role" and d["metadata"]["name"] == name + "-deployer"}
agent_ns = agent["spec"]["source"]["helm"]["valuesObject"]["agent"]["namespace"]
plane = "ate-system"
plural = lambda kind: {"NetworkPolicy": "networkpolicies"}.get(kind, kind.lower() + "s")
def allows(rules, group, resource, verb, obj=None):
    return any(group in r["apiGroups"] and resource in r["resources"] and verb in r["verbs"] and (not r.get("resourceNames") or obj in r["resourceNames"]) for r in rules)
problems, checked, routes, network_policies = [], 0, [], []
for app in (d for d in tree if d["kind"] == "Application"):
    path = app["spec"]["source"]["path"]
    if not pathlib.Path(repo, path).is_dir() or app["spec"]["source"]["repoURL"] != agent["spec"]["source"]["repoURL"]:
        continue  # A chart of kube-agent-substrate. Its tests are there.
    release = app["metadata"]["name"]
    file = chain / (release + ".yaml")
    file.write_text(yaml.safe_dump(app["spec"]["source"]["helm"].get("valuesObject", {})))
    for doc in render(release, f"{repo}/{path}", "-n", app["spec"]["destination"]["namespace"], "-f", str(file)):
        checked += 1
        if doc["kind"] == "Service" and (doc["spec"].get("type", "ClusterIP") != "ClusterIP" or "externalIPs" in doc["spec"]):
            problems.append(f"{release}: the policy refuses the Service {doc['metadata']['name']}")
        if doc["kind"] == "ServiceMonitor":
            extra = {"namespaceSelector", "attachMetadata", "scrapeClass"} & set(doc["spec"])
            extra |= {"bearerTokenFile", "bearerTokenSecret", "authorization", "basicAuth", "oauth2", "tlsConfig", "proxyUrl", "params", "relabelings"} & {k for e in doc["spec"]["endpoints"] for k in e}
            if extra:
                problems.append(f"{release}: the policy refuses the ServiceMonitor fields {sorted(extra)}")
        if doc["kind"] == "IngressRoute":
            routes.extend((r["match"], doc["spec"]["entryPoints"]) for r in doc["spec"]["routes"])
        group = doc["apiVersion"].rpartition("/")[0]
        namespace = doc["metadata"].get("namespace") or app["spec"]["destination"]["namespace"]
        obj = doc["metadata"]["name"]
        if doc["kind"] == "NetworkPolicy":
            network_policies.append(obj)
            peers = [p for r in doc["spec"].get("ingress", []) for p in r.get("from") or [None]]
            if "egress" in doc["spec"] or doc["spec"].get("policyTypes") != ["Ingress"] or doc["spec"]["podSelector"] != {"matchLabels": {"app.kubernetes.io/name": obj}} or not all(peers):
                problems.append(f"{release}: the policy refuses the NetworkPolicy {obj}")
        resource = plural(doc["kind"])
        rules = roles.get(namespace, [])
        for verb in ("create", "patch", "delete") + (("get",) if namespace == plane else ()):
            if not allows(rules, group, resource, verb, None if verb == "create" else obj):
                problems.append(f"{release}: the account cannot {verb} {doc['kind']} {namespace}/{obj}")
        if doc["kind"] == "Role" and namespace == plane:
            for rule in doc["rules"]:
                for g in rule["apiGroups"]:
                    for r in rule["resources"]:
                        for v in rule["verbs"]:
                            for n in rule.get("resourceNames", [None]):
                                if not allows(rules, g, r, v, n):
                                    problems.append(f"{release}: Role {obj} grants {v} {r}, which the account does not hold")
held = roles[plane]
# Argo CD applies a Role with kubectl auth reconcile, which reads the namespace first. Without this, only a first install fails.
if not allows(held, "", "namespaces", "get", plane):
    problems.append(f"the account cannot get the namespace {plane}, so Argo CD cannot make a Role there")
policies = {d["metadata"]["name"]: d["spec"] for d in tree if d["kind"] == "ValidatingAdmissionPolicy"}
bound = {d["spec"]["policyName"] for d in tree if d["kind"] == "ValidatingAdmissionPolicyBinding" and d["spec"]["validationActions"] == ["Deny"]}
user = f"request.userInfo.username == 'system:serviceaccount:argocd:{name}-deployer'"
for policy, resource in ((f"{name}-deployer-roles", "roles"), (f"{name}-deployer-bindings", "rolebindings"), (f"{name}-deployer-routes", "ingressroutes"), (f"{name}-deployer-services", "services"), (f"{name}-deployer-monitors", "servicemonitors"), (f"{name}-deployer-networkpolicies", "networkpolicies")):
    spec = policies.get(policy)
    if not spec or policy not in bound or spec["failurePolicy"] != "Fail" or spec["matchConditions"][0]["expression"] != user             or spec["matchConstraints"]["resourceRules"][0]["resources"] != [resource]:
        problems.append(f"the policy {policy} is missing, not bound with Deny, or does not match the account and {resource}")
allowed = [v["expression"] for v in policies.get(f"{name}-deployer-routes", {}).get("validations", [])]
if not routes:
    problems.append("the example renders no route, so the route policy is not compared with one")
for match, entry_points in routes:
    if not any(f"r.match == '{match}'" in e for e in allowed) or not any(all(f'"{p}"' in e for p in entry_points) for e in allowed):
        problems.append(f"the route policy does not allow the route that the webhook chart makes: {match} {entry_points}")
names = [v["expression"] for v in policies.get(f"{name}-deployer-networkpolicies", {}).get("validations", [])]
if f"{name}-webhook" not in network_policies:
    problems.append("the example renders no network policy of the shim, so its name is not compared")
for made in network_policies:
    if not any(e.startswith("object.metadata.name in ") and f'"{made}"' in e for e in names):
        problems.append(f"the network policy rule does not allow {made}, which a child chart makes")
own = next(d for d in parent if d["kind"] == "AppProject" and d["metadata"]["name"] == "ai-agent-" + name)
if "argocd" in {d["namespace"] for d in own["spec"]["destinations"]}:
    problems.append("the agent project reaches argocd, where its deployment account lives")
for rule in held:
    if {"pods", "secrets", "serviceaccounts", "deployments", "jobs", "*"} & set(rule["resources"]) and set(rule["verbs"]) - {"list"}:
        problems.append(f"the account has too much in {plane}: {rule}")
    if {"bind", "escalate", "impersonate", "*"} & set(rule["verbs"]):
        problems.append(f"the account can widen its rights: {rule}")
if any("secrets" in r["resources"] or "*" in r["resources"] or "roles" in r["resources"] for r in roles[agent_ns]):
    problems.append("the account can reach Secrets or Roles in the namespace of the agent")
if not checked:
    problems.append("no object of a child chart was checked")
print("\n".join(sorted(set(problems))))
sys.exit(1 if problems else 0)
PY
is "the deployment account covers what the child charts make, and holds no more in the control plane namespace than their Roles need" "$?"

out="$(helm template d "$repo/charts/agent" -f "$repo/tests/values/agent/minimal.yaml" --set agent.webhook=null --show-only templates/deployer.yaml)"
grep -q 'expression: "false"' <<<"$out"
is "the account of an agent without a webhook route can make no route" "$?" "$out"

# ---- what the parent refuses ----------------------------------------------------------
refuse() { # name, expected error text, the agents block
  local file="$work/refuse.yaml" out
  { sed '/^agents:/,$d' "$incluster"; printf '%s\n' "$3"; } >"$file"
  out="$(ai_agent -f "$file" 2>&1)"
  [ $? -ne 0 ] && grep -q "$2" <<<"$out"
  is "$1" "$?" "$out"
}
refuse "an agent with a webhook and no sender fails in the parent" 'allowFrom' 'agents: [{name: a, type: pr-agent, webhook: {port: 8080}}]'
refuse "an agent with a webhook and an empty sender list fails in the parent" 'allowFrom' 'agents: [{name: a, type: pr-agent, webhook: {port: 8080, allowFrom: []}}]'
refuse "an agent in the namespace of the control plane" "must not be argocd or the namespace of the control plane" 'agents: [{name: a, type: pr-agent, namespace: ate-system}]'
refuse "an agent in the namespace of Argo CD" "must not be argocd or the namespace of the control plane" 'agents: [{name: argocd, type: pr-agent}]'
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
out="$(agent_chart --set agent.model=openai/large --set agent.modelEndpoint=http://Model.example.test:4000/v1 --set agent.modelStreaming=true --show-only templates/actor.yaml)"
grep -q 'LITELLM__CUSTOM_LLM_PROVIDER: openai$' <<<"$out" && grep -q 'LITELLM__FORCE_STREAMING_CUSTOM_LLM_PROVIDER: openai$' <<<"$out" && grep -A1 'LITELLM__FORCE_STREAMING_API_BASE_SUBSTRINGS' <<<"$out" | grep -qF '["http://model.example.test:4000/v1"]'
is "agent.modelStreaming sets the provider and the base URL that pr-agent streams for" "$?" "$out"
! grep -q 'LITELLM__' <<<"$(agent_chart --set agent.model=openai/large --show-only templates/actor.yaml)"
is "without agent.modelStreaming the actor has no streaming setting" "$?"
agent_fails "streaming with a model that is not openai/ fails" 'agent.modelStreaming needs a model name' --set agent.modelStreaming=true
out="$(agent_chart --set agent.globalSettingsRepo=pr-agent-settings --set agent.useGroupSettingsFile=true --show-only templates/actor.yaml)"
grep -q 'CONFIG__GLOBAL_SETTINGS_REPO: pr-agent-settings$' <<<"$out" && grep -qE 'CONFIG__USE_GROUP_SETTINGS_FILE: .?true.?$' <<<"$out"
is "agent.globalSettingsRepo and agent.useGroupSettingsFile turn on the shared settings" "$?" "$out"
! grep -qE 'CONFIG__(GLOBAL_SETTINGS_REPO|USE_GROUP_SETTINGS_FILE)' <<<"$(agent_chart --show-only templates/actor.yaml)"
is "by default the actor has no shared settings" "$?"
agent_fails "subgroup settings without a settings project fail" 'agent.useGroupSettingsFile needs agent.globalSettingsRepo' --set agent.useGroupSettingsFile=true
agent_fails "a settings project with a path fails" 'globalSettingsRepo' --set agent.globalSettingsRepo=group/pr-agent-settings
grep -q 'CONFIG__OUTPUT_RUN_DETAILS' <<<"$(agent_chart --show-only templates/actor.yaml)" && ! grep -q 'CONFIG__OUTPUT_RUN_DETAILS' <<<"$(agent_chart --set agent.runDetails=false --show-only templates/actor.yaml)"
is "agent.runDetails false leaves the run details setting out" "$?"
! grep -q 'OTEL__IS_ENABLED' <<<"$(agent_chart --show-only templates/actor.yaml)"
is "metrics are off when no endpoint is set" "$?"
python3 - "$(agent_chart --set agent.metricsCollector.enabled=true --set 'agent.fallbackModels={ollama/small:8b,ollama/tiny:3b}' --set 'agent.modelContextLengths.ollama/small:8b=64000' --set 'agent.modelContextLengths.ollama/tiny:3b=8000' --show-only templates/actor.yaml)" <<'PY'
import sys, yaml
app = yaml.safe_load(sys.argv[1])
command = app["spec"]["source"]["helm"]["valuesObject"]["actors"][0]["command"]
longest = max(len(part) for part in command)
# Agent Substrate refuses an inline command of more than 4096 characters; keep 5 percent in hand.
assert longest <= 3900, f"the inline command is {longest} characters, and the limit of Agent Substrate is 4096"
assert "#" not in "".join(line.lstrip()[:1] for line in command[2].splitlines()), "a comment line is left in the inline command"
PY
is "the inline command of the actor with metrics and model lengths is under the 4096 character limit of Agent Substrate, with no comment lines" "$?"
out="$(agent_chart --set agent.metricsCollector.enabled=true --show-only templates/actor.yaml)"
grep -q 'OTEL__OTLP_ENDPOINT: http://pr-agent-metrics.a.svc.cluster.local:4318' <<<"$out" && grep -q 'ate-secret://k8s.io/default/a/pr-agent-metrics/password' <<<"$out" && ! grep -q 'GUNICORN_WORKERS' <<<"$out"
is "the metrics collector is the OTLP endpoint of the actor, with the generated token sent by the egress proxy" "$?" "$out"
out="$(agent_chart --set agent.metricsCollector.enabled=true --show-only templates/actor.yaml)"
grep -q 'OTEL_RESOURCE_ATTRIBUTES: ate.actor=a/pr-agent' <<<"$out" && grep -q 'pr_agent.commands_in_flight' <<<"$out" && grep -q 'keep_base_url=True' <<<"$out" && grep -q 'runpy.run_module("gunicorn"' <<<"$out"
is "with metrics the actor command has the in-flight patch, and the env names the actor" "$?" "$out"
out="$(agent_chart --set agent.metricsCollector.enabled=true --set agent.atespace=ate --set agent.actorName=rev --show-only templates/actor.yaml)"
grep -q 'OTEL_RESOURCE_ATTRIBUTES: ate.actor=ate/rev' <<<"$out"
is "the actor label follows the atespace and the actor name" "$?" "$out"
out="$(agent_chart --show-only templates/actor.yaml)"
! grep -q 'commands_in_flight' <<<"$out" && ! grep -q 'OTEL_RESOURCE_ATTRIBUTES' <<<"$out" && grep -q 'keep_base_url=True' <<<"$out"
is "without metrics the actor command has no in-flight patch and no resource attribute" "$?" "$out"
out="$(helm template m "$repo/charts/pr-agent-metrics" --show-only templates/configmap.yaml)"
grep -q 'set(attributes\["ate.actor"\], resource.attributes\["ate.actor"\])' <<<"$out" && grep -q 'set(attributes\["worker"\], resource.attributes\["service.instance.id"\])' <<<"$out" && ! grep -q 'action: delete' <<<"$out" && grep -q 'processors: \[memory_limiter, filter/pr_agent, transform/actor\]' <<<"$out"
is "the collector copies ate.actor and the worker id to labels, after the pr_agent filter" "$?" "$out"
out="$(agent_chart --set agent.metricsCollector.enabled=true --set agent.metricsApiKeySecret.name=metrics-token --set agent.metricsApiKeySecret.key=token --show-only templates/metrics.yaml)"
grep -q 'generateToken: false' <<<"$out" && grep -q 'name: metrics-token' <<<"$out" && grep -q 'key: token' <<<"$out"
is "a metrics Secret of your own turns the generated token off" "$?" "$out"
! grep -q 'name: a-metrics' <<<"$(agent_chart)"
is "the metrics Application is off by default" "$?"
out="$(agent_chart --set agent.metricsCollector.enabled=true --set agent.dashboard.enabled=true --set agent.atespace=ate --set agent.actorName=rev --show-only templates/metrics.yaml)"
grep -q 'actor: ate/rev' <<<"$out" && grep -A4 'dashboard:' <<<"$out" | grep -q 'enabled: true'
is "the dashboard value reaches the metrics chart with the actor" "$?" "$out"
out="$(agent_chart --set agent.metricsCollector.enabled=true --show-only templates/metrics.yaml)"
grep -A4 'dashboard:' <<<"$out" | grep -q 'enabled: false'
is "the dashboard is off by default" "$?" "$out"
agent_fails "the dashboard without the collector fails" 'agent.dashboard.enabled needs agent.metricsCollector.enabled' --set agent.dashboard.enabled=true
! helm template m "$repo/charts/pr-agent-metrics" | grep -q 'grafana_dashboard'
is "the metrics chart makes no dashboard ConfigMap by default" "$?"
helm template reviewer-metrics "$repo/charts/pr-agent-metrics" --set dashboard.enabled=true --set dashboard.name=reviewer --set dashboard.actor=ate/rev --show-only templates/dashboard.yaml \
  | python3 -c '
import json, sys, yaml
cm = yaml.safe_load(sys.stdin)
d = json.loads(cm["data"]["ai-agent-reviewer.json"])
assert cm["metadata"]["labels"]["grafana_dashboard"] == "1"
assert d["uid"] == "ai-agent-reviewer" and d["title"] == "Agent: reviewer" and len(d["panels"]) == 16
exprs = [t["expr"] for p in d["panels"] for t in p.get("targets", [])]
assert not any("[24h]" in e for e in exprs), "a panel has a fixed 24 hour window, and must follow the time range"
assert all(e.count("increase(") == e.count(" unless max without") and "min_over_time(" in e and "last_over_time(" in e for e in exprs if "increase(" in e), "a panel counts with a bare increase(), which loses the first value of a new series"
assert all("increase(" not in e for e in exprs if "$__interval" in e), "a chart counts a bucket with increase(), which loses a jump between two buckets"
assert all("[30d:1m] offset $__interval" in e for e in exprs if "$__interval" in e and "_total{" in e), "a bucket count must compare the counter with the last value known before the bucket, or a gap counts the old events again"
import re
merge = "max without (job, endpoint, container, service, pod, instance) ("
unmerged = [e for e in exprs for m in re.finditer(r"pr_agent_[a-z_]+_total[{]", e) if not e[:m.start()].endswith(merge)]
assert not unmerged, "a counter reads a series with its scrape labels, so a restart of the collector counts the old events again: " + unmerged[0]
timeline = [x for x in d["panels"] if x["id"] == 12][0]
assert any(o["matcher"]["options"] == "No command answered yet" and o["properties"][0]["id"] == "custom.hideFrom" and o["properties"][0]["value"]["viz"] for o in timeline["fieldConfig"]["overrides"]), "the placeholder row of the timeline must be hidden from the chart"
assert "No command answered yet" in timeline["targets"][0]["expr"], "the timeline needs the placeholder so that it never has an empty result"
assert any("sum by (pr_agent_command)" in t["expr"] and "outcome=\"failed\"" in t["expr"] for x in d["panels"] if x["id"] == 13 for t in x["targets"]), "the failures chart must split by command"
assert d["time"]["from"] == "now-24h" and "ai-agent" in d["tags"] and d["graphTooltip"] == 1
assert all("ate_actor=\"ate/rev\"" in e for e in exprs), exprs
'
is "the dashboard ConfigMap holds JSON with the uid, the title, 16 panels (13 and 3 section rows), every number on the time range, and the actor in every query" "$?"
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
grep -q 'CONFIG__FALLBACK_MODELS: .\["ollama/small:8b","ollama/tiny:3b"\]' <<<"$(agent_chart --set 'agent.fallbackModels={ollama/small:8b,ollama/tiny:3b}' --show-only templates/actor.yaml)" && grep -q 'CONFIG__FALLBACK_MODELS: .\[\]' <<<"$(agent_chart --show-only templates/actor.yaml)"
is "agent.fallbackModels sets the fallback list, empty by default" "$?"
out="$(agent_chart --set 'agent.fallbackModels={ollama/small:8b}' --show-only templates/actor.yaml)"; plain="$(agent_chart --show-only templates/actor.yaml)"
grep -q 'CONFIG__RETRY_SAME_MODEL_ON_TIMEOUT: "false"' <<<"$out" && grep -q 'CONFIG__NUM_RETRIES: "1"' <<<"$out" && ! grep -q 'RETRY_SAME_MODEL_ON_TIMEOUT' <<<"$plain" && grep -q 'CONFIG__AI_TIMEOUT: "300"' <<<"$plain"
is "with fallbackModels the actor fails over at once, and the timeout defaults to 300 seconds" "$?"
out="$(agent_chart --set 'agent.fallbackModels={ollama/small:8b}' --set agent.retrySameModelOnTimeout=true --set agent.modelRetries=3 --show-only templates/actor.yaml)"; plain="$(agent_chart --set agent.modelRetries=0 --show-only templates/actor.yaml)"
grep -q 'CONFIG__RETRY_SAME_MODEL_ON_TIMEOUT: "true"' <<<"$out" && grep -q 'CONFIG__NUM_RETRIES: "3"' <<<"$out" && grep -q 'CONFIG__NUM_RETRIES: "0"' <<<"$plain"
is "agent.retrySameModelOnTimeout and agent.modelRetries override the failover defaults" "$?"
grep -q 'GUNICORN_WORKERS: "4"' <<<"$(agent_chart --set agent.workers=4 --show-only templates/actor.yaml)" && ! grep -q 'GUNICORN_' <<<"$(agent_chart --show-only templates/actor.yaml)"
is "agent.workers overrides the worker processes, and none is set by default so pr-agent counts them from the CPUs" "$?"
grep -q 'GUNICORN_MAX_WORKERS: "8"' <<<"$(agent_chart --set agent.maxWorkers=8 --show-only templates/actor.yaml)"
is "agent.maxWorkers sets the ceiling of the automatic worker count" "$?"
agent_fails "zero workers fail" 'agent.workers' --set agent.workers=0
agent_fails "a zero ceiling fails" 'agent.maxWorkers' --set agent.maxWorkers=0
agent_fails "a model retry count above 10 fails" 'agent.modelRetries' --set agent.modelRetries=11
out="$(agent_chart --set 'agent.fallbackModels={ollama/small:8b}' --set agent.contextLength=16000 --set 'agent.modelContextLengths.ollama/small:8b=64000' --show-only templates/actor.yaml)"
grep -q 'MAX_TOKENS.update({"ollama/small:8b":64000})' <<<"$out" && grep -A1 'CONFIG__MAX_MODEL_TOKENS' <<<"$out" | grep -q '64000' && grep -A1 'CONFIG__CUSTOM_MODEL_MAX_TOKENS' <<<"$out" | grep -q '16000'
is "modelContextLengths gives a model its own limit and raises the cap to the largest" "$?" "$out"
! grep -q 'MAX_TOKENS.update' <<<"$(agent_chart --show-only templates/actor.yaml)"
is "without modelContextLengths the command does not touch the table of pr-agent" "$?"
agent_fails "a limit for a model that the agent does not use fails" 'agent.modelContextLengths names' --set 'agent.modelContextLengths.ollama/other=1000'
grep -q 'CONFIG__CUSTOM_MODEL_MAX_TOKENS' <<<"$(agent_chart --set agent.contextLength=1000000 --show-only templates/actor.yaml)" && grep -A1 'CONFIG__CUSTOM_MODEL_MAX_TOKENS' <<<"$(agent_chart --set-json agent.contextLength=1000000 --show-only templates/actor.yaml)" | grep -q '"1000000"'
is "a context length of one million stays a whole number" "$?"
many="$(python3 -c 'import json; print(json.dumps(["ollama/a-model-with-a-long-name-%02d" % i for i in range(100)]))')"
lengths="$(python3 -c 'import json; print(json.dumps({"ollama/a-model-with-a-long-name-%02d" % i: 1000 for i in range(100)}))')"
agent_fails "so many model lengths that the command is too long fail" 'Agent Substrate refuses more than 4096' --set-json "agent.fallbackModels=$many" --set-json "agent.modelContextLengths=$lengths"
agent_fails "a fallback model with another prefix fails" 'agent.fallbackModels must use the same prefix' --set 'agent.fallbackModels={openai/other}'
agent_fails "a value that the schema does not know fails, so a typo does not pass silently" 'idleSuspnd' --set agent.idleSuspnd.enabled=true
agent_fails "a nested value that the schema does not know fails" 'enable' --set agent.idleSuspend.enable=true
agent_fails "a model timeout that is not a number fails" 'agent.modelTimeoutSeconds' --set agent.modelTimeoutSeconds=abc
agent_fails "a webhook with no sender fails in the agent chart" 'allowFrom' --set agent.webhook.port=8080
agent_fails "idle suspend with no Prometheus address fails" 'agent.idleSuspend.prometheusUrl is required' --set agent.idleSuspend.enabled=true

# ---- the webhook and the registration -------------------------------------------------------
out="$(agent_chart --set agent.webhook.port=8080 --set 'agent.webhook.allowFrom[0].podSelector.matchLabels.app=sender' --set agent.hopToken=custom-hop --set agent.webhook.hopToken=other --show-only templates/webhook.yaml)"
grep -q 'hopToken: custom-hop' <<<"$out" && ! grep -q 'hopToken: other' <<<"$out" && grep -q 'name: a-webhook$' <<<"$out" && grep -q 'name: pr-agent$' <<<"$out"
is "the shim gets its name, the actor and the hop token of the agent, whatever the webhook values say" "$?" "$out"
! grep -q 'name: a-webhook' <<<"$(agent_chart)"
is "an empty agent.webhook renders no shim" "$?"
out="$(agent_chart --set agent.webhook.port=8080 --set 'agent.webhook.allowFrom[0].podSelector.matchLabels.app=sender' --set agent.webhook.pipeline.enabled=true --set agent.webhook.pipeline.issuer=https://gitlab.example.test --set agent.webhook.pipeline.jwksUri=https://gitlab.example.test/oauth/discovery/keys --set 'agent.webhook.pipeline.namespacePaths={team}' --show-only templates/webhook.yaml)"
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
out="$(helm template s "$repo/charts/pr-agent-webhook" --set name=a-webhook --set actor.name=pr-agent --set 'allowFrom[0].ipBlock.cidr=192.0.2.0/24')"
grep -q 'kind: ServiceAccount' <<<"$out" && grep -q '^  name: a-webhook$' <<<"$out" && ! grep -q '^  name: pr-agent-webhook$' <<<"$out"
is "the shim chart names its service account from the name value, not from the actor" "$?" "$out"

echo
python3 - "$repo" <<'PY'
import json, sys
root = sys.argv[1]
chart = json.load(open(f"{root}/charts/agent/values.schema.json"))["properties"]["agent"]
parent = json.load(open(f"{root}/charts/ai-agent/values.schema.json"))["definitions"]["agent"]
sys.exit(0 if chart == parent else 1)
PY
is "the agent schema of the parent chart is the same as the schema of the agent chart" "$?"

# ---- removal: every rendered chain ------------------------------------------------------------
out="$("${CHECKS:-/usr/share/kube-devenv/checks}/argocd-removal.sh" "${rendered[@]}" 2>&1)"
is "every Application and AppProject that the charts render has the resources finalizer" "$?" "$out"
! grep -l 'kube-stack/keep-resources-on-delete' "${rendered[@]}"
is "no object of the agent stack keeps its resources: removal deletes them all" "$?"

if [ "$failures" -gt 0 ]; then echo "$failures failed"; exit 1; fi
echo "all passed"
