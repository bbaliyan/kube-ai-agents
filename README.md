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
| `charts/substrate-idle-suspend` | A CronJob that suspends idle actors from Prometheus metrics, and the PodMonitors of the control plane. The `agent` chart deploys it for each agent, and `substrate-stack` deploys it once for the PodMonitors. |
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

## Fallback models

Set `fallbackModels` on an agent to a list of model names. If a call to `model` fails or runs past `modelTimeoutSeconds`, pr-agent tries the next one in the list. The models share one model server, so each must start with the same prefix as `model`. A fallback model on another server is not supported.

```yaml
model: ollama/qwen3-coder:30b
fallbackModels: [ollama/qwen3:8b]
```

## Reporting a running command

pr-agent has counters for commands, tokens and model calls, but no gauge for the commands that run now. With metrics on, the actor reports one: the gauge `pr_agent_commands_in_flight` (OpenTelemetry name `pr_agent.commands_in_flight`, unit `{command}`). It is 1 while a command runs, and 0 when it ends. It has the label `ate_actor`, in the form `<atespace>/<actor name>`, from the resource attribute `OTEL_RESOURCE_ATTRIBUTES`. The chart does not use the template name, because that name is a hash of the template, and the env is part of the template.

The code is an inline patch, `charts/agent/files/actor_patch.py`. The chart puts it in the command of the actor, next to the patch that turns on `keep_base_url`, and not in a derived image. A derived image is one more image to build, sign and pin. The patch wraps `PRAgent.handle_request`, adds 1 and pushes the metrics at once, runs the command, and subtracts 1 and pushes again. If the meter or the push fails, it logs a warning and runs the command. It does nothing when `OTEL__IS_ENABLED` is not `true`. The upstream gap is issue 5125 in The-PR-Agent/pr-agent (an in-flight gauge). Delete the patch when it ships.

The collector chart `pr-agent-metrics` copies only `ate.actor` to a label and deletes `service.instance.id`, so a restart overwrites an old value and does not leave a second series. A suspend in the middle of a command can leave a stale 1. The chart `substrate-idle-suspend` reads the gauge as the signal `busy`, and it stops reading a value as busy after a cap, so `metricExpiration` stays at its default.

## Dashboard

Each agent can bring a simple Grafana dashboard, `Agent: <name>`. It shows four numbers and three charts:

- Working right now? shows Busy or Idle.
- Reviews started in the last 24 hours.
- Model calls per review. A review that is cut into chunks shows a higher number.
- Tokens used in the last 24 hours.
- Work started: reviews, descriptions and improvement suggestions that started, in bars (pr-agent counts a command when it starts). A bar covers the slice of time that ends at its right edge, on the same time scale as the busy time beside it.
- Busy time: when the agent runs a command.
- Tokens read by the model, and tokens written by the model, in the last 24 hours. Two plain numbers: a review reads far more than it writes.

To turn it on, set `agent.dashboard.enabled: true`. It needs `agent.metricsCollector.enabled: true`. The chart `pr-agent-metrics` makes a ConfigMap with the label `grafana_dashboard: "1"`, and the Grafana sidecar loads it.

## Suspend idle actors

Substrate v1.0.1 never suspends an idle actor. The chart `substrate-idle-suspend` runs a CronJob that does it for the actors you list. The `agent` chart deploys it for each agent that sets `agent.idleSuspend.enabled`, with the actor of that agent. The CronJob uses the registration image, which is built in the repository kube-agent-substrate (`images/substrate-registration`) and pulled by digest. A release with an empty `actors` list renders only the PodMonitors, so one release can own the scrape objects of the control plane while other releases list the actors. You can delete the chart when upstream ships its own idle policy.

Warnings:

- An actor that answers at once and keeps working in the background can look idle. Set `idleMinutes` longer than its longest background task.
- A request that is younger than one scrape interval is not in the data yet. Keep `idleMinutes` well above the scrape interval.
- Upstream v1.0.1 documents no drain of a running request on suspend. A suspend at that moment can cut the request.

The chart needs a Prometheus that scrapes `atenet-router`, `atenet-egress`, `ate-api-server` and `atelet`. With the Prometheus Operator, the PodMonitors come from `substrate-stack` (see PodMonitors). The PodMonitors are in the control plane namespace, so the `podMonitorNamespaceSelector` of the Prometheus must include it. Upstream makes a scrape object only on GKE.

### How long to wait

A pr-agent actor reports the commands it runs (see "Reporting a running command"), and the chart reads that as the signal `busy`. While a command runs, the actor is never suspended, so `idleMinutes` does not have to outlast a review. It only has to outlast what follows the last command: the router events that the comments of the agent cause, which arrive within seconds. `idleMinutes: 2` is enough.

Measured with one agent and a local 30 billion parameter model:

| Merge request | Time the actor was busy | Suspended after the last command |
|---|---|---|
| Small (one file) | about 1 minute | about 12 minutes with `idleMinutes: 10` and no `busy` signal |
| Large, cut into chunks (4 files, 330,000 characters), first run | 12.4 minutes | not measured |
| The same, second run, `idleMinutes: 2` | 15.8 minutes, not suspended in the middle | about 3 to 4 minutes |

The suspend takes about 3 minutes, not 2, because the router counts the last comment events of the agent for a short time after the last command. Your model and merge requests will differ. The busy time is the time that the actor stays awake, so measure it with the gauge `pr_agent_commands_in_flight` before you lower `idleMinutes`.

Through the `agent` chart you set `agent.idleSuspend.prometheusUrl`, `idleMinutes` and `schedule`, and anything else of the chart in `agent.idleSuspend.helmValues`. The `agent` chart also gives the service account of the CronJob the `editor` role in the atespace of the actor, through the registration. The principal is `user:system:serviceaccount:<release namespace>:<agent>-idle-suspend`. Do not make this account a bootstrap owner.

If Prometheus needs a bearer token, set `prometheus.bearerTokenSecret.name`. If it uses a private CA, set `prometheus.caSecret.name`.

| Value | Default | Meaning |
|---|---|---|
| `actors` | `[]` | The `atespace` and `name` of each actor to watch. An empty list fails each run. |
| `schedule` | `"*/5 * * * *"` | Cron schedule of the CronJob |
| `idleMinutes` | `30` | Minutes with no activity before a suspend |
| `idleCpuCores` | `0.05` | CPU cores that still count as idle |
| `suspendMode` | `async` | `async` (the upstream default) or `sync`: how the snapshot becomes durable |
| `prometheus.url` | `http://prometheus-operated.monitoring.svc:9090` | Base URL of Prometheus |
| `podMonitors.enabled`, `podMonitors.labels`, `podMonitors.interval` | `false`, `{}`, `30s` | PodMonitors of the Prometheus Operator for the four components that feed the signals. They are made in the control plane namespace. |
| `prometheus.timeoutSeconds` | `20` | Time limit of one query |
| `queries.*` | see `values.yaml` | The PromQL of each signal |
| `image.digest` | all zeros | Digest of the registration image |
| `activeDeadlineSeconds` | `300` | Time limit of one run |
| `startingDeadlineSeconds` | `120` | A run that starts later than this is skipped. |
| `suspend` | `false` | Set to `true` to stop the schedule and keep the chart. |

### When an actor is suspended

A run suspends an actor only when all of these are true:

- `kubectl ate` reads the actor, and the state is `ACTOR_STATE_RUNNING`.
- Every `health` query returns a number above 0. This proves that each metric source is scraped.
- Every signal query returns exactly one number, and each says idle.

| Signal | Busy when |
|---|---|
| `routed` | The router counted a request for the template of the actor in the idle time. |
| `resumed` | The API server resumed the actor in the idle time. |
| `inflight` | Any request or tunnel through the router was open in the idle time. This signal covers every actor. |
| `egress` | The egress proxy had a request to an outside host in flight in the idle time (counted inside its tunnels, one for each call; an idle open connection does not count). An actor that waits for a model answer is quiet on every other signal, and a suspend closes its outbound connections. This signal covers every actor. A call shorter than a scrape can be missed, and plain TCP passthrough is not counted. |
| `busy` | Optional, off by default (`busy.enabled`). An agent that reports commands in flight exports a gauge (`busy.metric`, default `pr_agent_commands_in_flight`) that is 1 while a command runs. Its label (`busy.actorLabel`, default `ate_actor`) holds `<atespace>/<actor>`. The signal is busy when the gauge was above 0 at any time in the idle time. A missing series counts as 0. |
| `cpu` | The CPU rate over the idle time is above `idleCpuCores` (default 0.05). |

A crash or a suspend in the middle of a command can leave the `busy` gauge at 1. If the gauge was above 0 for the whole of the last `busy.maxMinutes` (default 30), the run ignores the `busy` signal and logs one line that names the cap. Set the cap above the longest command. The other signals still apply.

Any other result suspends nothing and fails the run. One failing actor does not stop the run for the other actors. The queries are values in `queries.*`. If your Prometheus names the metrics or labels in another way, change the queries.

Each actor of `substrate-actor` has its own template, so a template signal is an actor signal. If actors share a template, a busy actor keeps the others awake.

## PodMonitors

When an agent turns on idle suspend, the `substrate-stack` chart makes one Application, `substrate-monitors`. It renders the PodMonitors of the control plane from the chart `substrate-idle-suspend` (an empty `actors` list), so no agent owns them. Set the label that Prometheus selects them by in `substrate.podMonitorLabels`.

## Tests

Run the checks in the kube-devenv image:

```
make test-commit
```

- `make charts` lints each chart and validates what it renders.
- `make test-charts` runs the helm-unittest tests, among them those of `substrate-idle-suspend`.
- `make test-scripts` runs the unit tests of the patch (`tests/test_actor_patch.py`), the idle suspend script against stubs of `kubectl-ate` and `curl` (`charts/substrate-idle-suspend/tests/idle_suspend_test.sh`, which needs bash and jq) and `tests/render.sh`. It renders the parent, the stack and each agent for both examples, and it checks the failures.

The charts are not applied to a cluster by these checks.

## Limits

- The project `ai-agents-stack` allows a ClusterRoleBinding, because the install binds a cluster role. Any source that the project allows can therefore escalate. Allow only repositories that you trust.
- The credential policy is read once, when the credential provider starts. If you add an agent after the first install, restart the credential provider so that it reads the new entry.
