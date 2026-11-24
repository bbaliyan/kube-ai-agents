# kube-ai-agents

Helm charts that run AI agents on Agent Substrate with Argo CD.

You point one Argo CD Application at the chart `ai-agent` and list your agents in its values. The chart makes the rest. This repository holds no environment values: the GitLab address, the model, the storage and the names of your Secrets are yours to set.

## Charts

| Chart | What it makes |
|---|---|
| `charts/ai-agent` | The parent. An Argo CD project `ai-agent`, one Application `substrate` and one Application for each agent. |
| `charts/substrate-stack` | The shared control plane: the credential policy, the install and the workers. |
| `charts/substrate-credential-policy` | The namespace policy of the credential provider, built from the list of agents. It also makes a stub of the PodMonitoring CRD. |
| `charts/agent` | One agent: the actor, its registration, idle suspend, the webhook shim and the metrics collector. |
| `charts/pr-agent-webhook` | The GitLab webhook shim, an Envoy proxy. |
| `charts/pr-agent-metrics` | An OpenTelemetry collector for the metrics of pr-agent. |

Every child Application uses the project `ai-agent`. The project allows this repository, the Agent Substrate repository, and the namespaces of the control plane and of each agent.

## How it fits together

1. The project `ai-agent` syncs first (wave -1).
2. The Application `substrate` syncs next (wave 0). Inside it, the credential policy comes first, then the install, then the workers.
3. One Application for each agent syncs last (wave 1). Inside it, the actor, the shim and the collector come first, then the registration, then idle suspend.

The install lists the registration service account of each agent as an owner of the control plane. The router allow-list holds the shim of each agent that has a webhook. The chart builds both lists from `agents`, so you do not write them.

## Use it

1. Pin `substrate.revision` and `substrate.installImageDigest` to a commit of Agent Substrate and to the image that was built from it.
2. Set `substrate.s3Endpoint` to your S3 store.
3. Make the Secret `snapshot-store-keys` in the namespace `ate-system`. It holds the keys `access-key-id` and `secret-access-key` of the store.
4. For each agent, make its namespace and these Secrets in it: `gitlab-pr-agent` (keys `token` and `WEBHOOK_SECRET`) and, if the model server needs a key, the Secret that `modelApiKeySecret` names.
5. Add one entry to `agents` for each agent. See `examples/ci-shaped.yaml` and `examples/corp-shaped.yaml`.

An agent entry takes `name` and `type`, and every key of `charts/agent/values.yaml` under `agent`. The only type is `pr-agent`. The `atespace` and the `namespace` default to the name. The actor is named `pr-agent` in its atespace, unless you set `actorName`.

Names must be unique. The chart fails if two agents share a name, a namespace, or an actor name in one atespace.

## Webhook and pipeline route

The chart `agent` does not fill the pipeline route of the shim. Pass `webhook.pipeline` in full: `enabled`, `issuer`, `jwksUri` and `namespacePaths`.

## Names

For an agent named `reviewer`, the Applications are `reviewer`, `reviewer-actor`, `reviewer-registration`, `reviewer-idle-suspend`, `reviewer-webhook` and `reviewer-metrics`. The service accounts are `reviewer-registration`, `reviewer-idle-suspend` and `reviewer-webhook`.

The metrics collector uses fixed resource names in its namespace, so each agent needs its own namespace.

## Known gap: PodMonitors

The Prometheus scrape objects for the control plane (PodMonitors) come from the idle suspend chart of Agent Substrate. That chart cannot render them without an actor. So the first agent that turns on idle suspend owns them. If you remove that agent, the PodMonitors go with it. Another agent takes them over at the next sync. The upstream fix is tracked in the planning hub as cloud-hub#302.

## Tests

Run the checks in the kube-devenv image:

```
make test-commit
```

- `make charts` lints each chart and validates what it renders.
- `make test-charts` runs the helm-unittest tests.
- `make test-scripts` runs `tests/render.sh`. It renders the parent, the stack and each agent for both examples, and it checks the failures.

The charts are not applied to a cluster by these checks.
