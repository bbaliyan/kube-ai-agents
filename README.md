# kube-ai-agents

Helm charts that run AI agents on Agent Substrate with Argo CD.

You point one Argo CD Application at the chart `ai-agent` and list your agents in its values. The chart makes the rest. This repository holds no environment values: the GitLab address, the model, the storage and the names of your Secrets are yours to set.

## Charts

| Chart | What it makes |
|---|---|
| `charts/ai-agent` | The parent. An Argo CD project `ai-agents-stack`, one project for each agent, one Application `substrate` and one Application for each agent. |
| `charts/substrate-stack` | The shared control plane: the credential policy, the install and the workers. |
| `charts/substrate-credential-policy` | The namespace policy of the credential provider, built from the list of agents. It also makes a stub of the PodMonitoring CRD. |
| `charts/agent` | One agent: the actor, its registration, idle suspend, the webhook shim and the metrics collector. |
| `charts/pr-agent-webhook` | The GitLab webhook shim, an Envoy proxy. |
| `charts/pr-agent-metrics` | An OpenTelemetry collector for the metrics of pr-agent. |

The Applications `substrate` and one for each agent use the shared project `ai-agents-stack`. It allows this repository, the Agent Substrate repository, and the namespaces `argocd` and of the control plane. Each agent also has its own project, named `ai-agent-<name>`. The project allows the same repositories, the namespace of the agent and of the control plane, and no cluster-scoped kind. Every child Application of the agent uses that project. The parent passes its name to the `agent` chart in the value `project`.

## How it fits together

1. The project `ai-agents-stack` and the project of each agent sync first (wave -1).
2. The Application `substrate` syncs next (wave 0). Inside it, the credential policy comes first, then the install, then the workers.
3. One Application for each agent syncs last (wave 1). Inside it, the actor, the shim and the collector come first, then the registration, then idle suspend.

Argo CD does not assess the health of a child Application unless the platform has a health rule for the Application kind. Without that rule, a wave only sets the order of creation and does not wait for the previous wave to be ready. The charts work either way, but a strict order needs the rule.

The install lists the registration service account of each agent as an owner of the control plane. The router allow-list holds the shim of each agent that has a webhook. The chart builds both lists from `agents`, so you do not write them.

## Use it

1. Pin `substrate.revision` and `substrate.installImageDigest` to a commit of Agent Substrate and to the image that was built from it.
2. Set `substrate.s3Endpoint` to your S3 store.
3. Make the Secret `snapshot-store-keys` in the namespace `ate-system`. It holds the keys `access-key-id` and `secret-access-key` of the store.
4. For each agent, make its namespace and these Secrets in it: `gitlab-pr-agent` (keys `token` and `WEBHOOK_SECRET`) and, if the model server needs a key, the Secret that `modelApiKeySecret` names.
5. Add one entry to `agents` for each agent. See `examples/in-cluster-gitlab.yaml` and `examples/external-gitlab.yaml`.

An agent entry takes `name` and `type`, and every key of `charts/agent/values.yaml` under `agent`. The only type is `pr-agent`. The `atespace` and the `namespace` default to the name. The actor is named `pr-agent` in its atespace, unless you set `actorName`.

Names must be unique. The chart fails if two agents share a name, a namespace, or an actor name in one atespace.

## Webhook and pipeline route

The chart `agent` does not fill the pipeline route of the shim. Pass `webhook.pipeline` in full: `enabled`, `issuer`, `jwksUri` and `namespacePaths`.

## Names

For an agent named `reviewer`, the Applications are `reviewer`, `reviewer-actor`, `reviewer-registration`, `reviewer-idle-suspend`, `reviewer-webhook` and `reviewer-metrics`. The service accounts are `reviewer-registration`, `reviewer-idle-suspend` and `reviewer-webhook`.

The metrics collector uses fixed resource names in its namespace, so each agent needs its own namespace.

## Removing an agent

Remove its entry from `agents`. Argo CD prunes the Applications of the agent (wave 1) before its project (wave -1), so the finalizers and the unregister hook still find the namespace permitted. Each Application of the agent has the resources finalizer, so Argo CD deletes the Applications and what they made. It does not delete the namespace of the agent (the consumer owns it). By default it does not unregister the actor, its templates or the atespace in Agent Substrate: they are rows in the control plane database, which a finalizer cannot reach. Set `agent.registration.unregister: true` to unregister them. The registration chart then runs an Argo CD PreDelete hook Job when its Application is deleted. The hook deletes the actor, its templates and the atespace if no other agent uses it. It needs a revision of `substrate.revision` that has `unregister.enabled`. If the hook fails or hangs, the sync of the parent waits for the Application to go, so the whole stack waits too. Delete the hook Job, or remove the finalizer of the Application, to go on. If you skip the finalizer, or leave the value off, delete them by hand with `kubectl ate delete actor`, `actor-template` and `atespace`.

## PodMonitors

When an agent turns on idle suspend, the `substrate-stack` chart makes one Application, `substrate-monitors`. It renders the PodMonitors of the control plane, so no agent owns them. Set the label that Prometheus selects them by in `substrate.podMonitorLabels`.

## Tests

Run the checks in the kube-devenv image:

```
make test-commit
```

- `make charts` lints each chart and validates what it renders.
- `make test-charts` runs the helm-unittest tests.
- `make test-scripts` runs `tests/render.sh`. It renders the parent, the stack and each agent for both examples, and it checks the failures.

The charts are not applied to a cluster by these checks.

## Limits

- The project `ai-agents-stack` allows a ClusterRoleBinding, because the install binds a cluster role. Any source that the project allows can therefore escalate. Allow only repositories that you trust.
- The credential policy is read once, when the credential provider starts. If you add an agent after the first install, restart the credential provider so that it reads the new entry.
