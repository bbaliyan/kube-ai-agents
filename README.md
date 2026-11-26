# kube-ai-agents

Helm charts that run AI agents on Agent Substrate with Argo CD.

You point one Argo CD Application at the chart `ai-agent` and list your agents in its values. The chart makes the rest. This repository holds no environment values: the GitLab address, the model, the storage and the names of your Secrets are yours to set.

## Charts

| Chart | What it makes |
|---|---|
| `charts/ai-agent` | The parent. An Argo CD project `ai-agents-stack`, one project for each agent, one Application `substrate` and one Application for each agent. |
| `charts/substrate-stack` | The shared control plane: the credential policy, the install and the workers. |
| `charts/substrate-credential-policy` | The namespace policy of the credential provider, built from the list of agents. |
| `charts/agent` | One agent: the actor, its registration, idle suspend, the webhook shim and the metrics collector. |
| `charts/substrate-idle-suspend` | A CronJob that suspends idle actors from Prometheus metrics. The `agent` chart deploys it for each agent. |
| `charts/pr-agent-webhook` | The GitLab webhook shim, an Envoy proxy. |
| `charts/pr-agent-metrics` | An OpenTelemetry collector for the metrics of pr-agent. |

The Applications `substrate` and one for each agent use the shared project `ai-agents-stack`. It allows this repository, the Agent Substrate repository, and the namespaces `argocd`, of the control plane and of each agent. Each agent also has its own project, named `ai-agent-<name>`. The project allows the same repositories, the namespace of the agent and of the control plane, and no cluster-scoped kind. Every child Application of the agent uses that project. The parent passes its name to the `agent` chart in the value `project`.

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

## Who can call the shim

The shim has a NetworkPolicy that denies all incoming traffic. Only the senders in `webhook.allowFrom` reach its port. The list has no default, and the shim does not render when it is empty. Each entry is a `from` entry of a NetworkPolicy.

> **Breaking change:** a consumer with a `webhook` and no `allowFrom` must add the list before it moves to this revision. Until then, the shim Application shows a render error, and Argo CD does not change the shim.

List each sender that you use:

| Sender | Entry |
|---|---|
| GitLab in the cluster | The GitLab pods that send webhooks. |
| `webhook.ingressRoute`, or another ingress or gateway | The pods of that controller. An external GitLab and a CI job that calls the route need only this entry. |
| A CI job that calls the Service of the shim | The pods of the CI jobs. |

Put `namespaceSelector` and `podSelector` in one entry, so only those pods of that namespace match:

```yaml
webhook:
  allowFrom:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: traefik}}
      podSelector: {matchLabels: {app.kubernetes.io/name: traefik}}
```

- Probes need no entry. A pod always accepts traffic from its own node.
- The shim has no metrics port, so Prometheus needs no entry.
- The registration and idle suspend Jobs do not call the shim.
- Your CNI must enforce NetworkPolicy. Without that, the policy has no effect.
- On some CNIs, such as Cilium, an `ipBlock` matches no pod and no node. Use selectors for pods. A controller on the host network can need a policy of your CNI.

## Names

For an agent named `reviewer`, the Applications are `reviewer`, `reviewer-actor`, `reviewer-registration`, `reviewer-idle-suspend`, `reviewer-webhook` and `reviewer-metrics`. The service accounts are `reviewer-registration`, `reviewer-idle-suspend` and `reviewer-webhook`.

The metrics collector uses fixed resource names in its namespace, so each agent needs its own namespace.

## Removing the stack

Every Application and project of the stack has the resources finalizer. When you delete the root Application with cascade, Argo CD deletes the Applications and what they made. The finalizer of a project keeps it until no Application uses it. Do not put your root Application in the project `ai-agents-stack`: the root and the project would wait for each other.

The cascade stops the running actors, because it deletes the worker pool. It does not delete the control plane. The namespace `ate-system` is marked `Prune=false,Delete=false`, and the install Job creates the control plane outside Argo CD.

To remove the control plane too, do these steps.

> **Warning:** these steps delete the database of the control plane. You cannot undo this.

1. Remove every agent from `agents` and let Argo CD sync.
2. Delete the root Application with `argocd app delete <root> --cascade` or in the Argo CD UI. If the root has no finalizer, `kubectl delete` leaves its Applications behind.
3. Wait until the Applications of the stack are gone.
4. Delete the namespace with `kubectl delete namespace ate-system`.
5. Delete the namespace `podcertificate-controller-system`.
6. List the cluster-scoped objects with `kubectl get crd,clusterrole,clusterrolebinding,clustertrustbundle -o name`.
7. Delete the CustomResourceDefinitions whose name ends in `.ate.dev`. If the stack made the stub `podmonitorings.monitoring.googleapis.com` (a cluster without the GKE operator), delete it too. Argo CD does not track a CustomResourceDefinition, so a cascade keeps it.
8. Delete the ClusterRoles and bindings `ate-api-server`, `ate-controller`, `atelet` and `podcert-ate-dev-signer`.
9. Delete the ClusterTrustBundles whose name contains `ate.dev`.

## Deployment accounts

By default, Argo CD deploys everything with the account of its controller, which can do anything in the cluster. With [application sync impersonation](https://argo-cd.readthedocs.io/en/stable/operator-manual/app-sync-using-impersonation/), it deploys the Applications of an agent with the account `<agent>-deployer` in `argocd`. Kubernetes then enforces what they can make. The feature is beta in Argo CD.

To turn it on, set these keys in the ConfigMap `argocd-cm`:

```yaml
application.sync.impersonation.enabled: "true"
application.sync.impersonation.enforced: "false"
```

The charts need no other change: each agent project names the account for every destination. With `enforced: "false"`, a project that names no account keeps the account of the controller. With the default, `"true"`, the sync of every such project fails.

The account can do this:

- In the namespace of the agent: manage the kinds that the charts of an agent make. It cannot read or write a Secret, and it cannot make a Role.
- In the namespace of the control plane: make Roles and bindings, and change only the two of the agent. Their rules can give no more than the account holds. That is: read the namespace and the Service `api`, list Pods, forward a port to a Pod, and manage the two Roles and bindings. It cannot make a Pod or read a Secret there.

Kubernetes lets an account write any Role within its own rights and name anyone in a binding. RBAC also says nothing about what an object holds. Five [ValidatingAdmissionPolicies](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/) limit what the account writes:

- Roles: only the two of the agent, with no other rules than reading the Service `api`, listing Pods and forwarding a port.
- Bindings: only to those two Roles, and only for service accounts of the namespace of the agent.
- Traefik routes: only `Host` with the host of `webhook.ingressRoute`, on its entry points, to Services of the namespace of the agent. A route has no priority, no Middleware and no TLS setting other than the name of a Secret. An agent without that route can make none.
- Services: only `ClusterIP`, with no external IP.
- ServiceMonitors: only Services of their own namespace, with no credential, proxy or change of the target address.

**You must also enforce a Pod Security level on the namespace of each agent.** The account makes Deployments and Jobs there. Without this, a Pod can be privileged or mount the disk of its node, and that gives control of the cluster. The Pods of the charts pass the strictest level:

```yaml
metadata:
  labels:
    pod-security.kubernetes.io/enforce: restricted
```

This limits the Applications of the agent, and a person whose rights in Argo CD end at the project of the agent. It does not limit the other Applications of the stack. They keep the account of the controller, and the install account in the control plane namespace is `cluster-admin`. A person who can change a source repository at the revision that you pin can change those too.

What stays open. This list holds what we found. It is not a proof that nothing else is open.

- The account makes Deployments and Jobs in the namespace of the agent. A Pod there can mount any Secret of that namespace.
- The account makes ExternalSecrets. A `ClusterSecretStore` without [namespace conditions](https://external-secrets.io/latest/api/clustersecretstore/) serves them too. Give each store the namespaces that can use it.
- It can forward a port to any Pod of the control plane namespace, because the Jobs of an agent need that to reach the API.
- The policies trust the host in `webhook.ingressRoute.host`. If another application serves that host, the route of the agent competes with it.
- No policy limits what a Pod of the agent connects to. Limit that with NetworkPolicies.
- A ServiceMonitor can keep the labels that its target sends (`honorLabels`) or rewrite them (`metricRelabelings`). An agent can then send series that look like those of another application. Prometheus also follows a redirect of its target to another HTTP address.
- The account makes ConfigMaps. A component that reads labelled ConfigMaps of every namespace, such as a Grafana sidecar, reads these too. Limit it to the namespaces that you trust.

## Removing an agent

Remove its entry from `agents`. Argo CD prunes the Applications of the agent (wave 1) before its project (wave -1), so the finalizers and the unregister hook still find the namespace permitted. Each Application of the agent has the resources finalizer, so Argo CD deletes the Applications and what they made. It does not delete the namespace of the agent (the consumer owns it). By default it does not unregister the actor, its templates or the atespace in Agent Substrate: they are rows in the control plane database, which a finalizer cannot reach. Set `agent.registration.unregister: true` to unregister them. The registration chart then runs an Argo CD PreDelete hook Job when its Application is deleted. The hook deletes the actor, its templates and the atespace if no other agent uses it. It needs a revision of `substrate.revision` that has `unregister.enabled`. If the hook fails or hangs, the sync of the parent waits for the Application to go, so the whole stack waits too. Delete the hook Job, or remove the finalizer of the Application, to go on. If you skip the finalizer, or leave the value off, delete them by hand with `kubectl ate delete actor`, `actor-template` and `atespace`.

## Fallback models

Set `fallbackModels` on an agent to a list of model names. If a call to `model` fails or runs past `modelTimeoutSeconds`, pr-agent tries the next one in the list. The models share one model server, so each must start with the same prefix as `model`. A fallback model on another server is not supported. With `fallbackModels` set, the actor does not retry the failed model: a call that runs past `modelTimeoutSeconds` (default 300) goes to the next model at once, and a refused connection is retried once. Without `fallbackModels`, pr-agent retries the same model. Each agent can override this with `retrySameModelOnTimeout` (true or false), `modelRetries` (0 to 10) and `modelTimeoutSeconds`.

```yaml
model: ollama/qwen3-coder:30b
fallbackModels: [ollama/qwen3:8b]
```

A fallback model can have a longer or shorter context than the main model. Give each such model its own context length in `modelContextLengths`, in tokens. pr-agent then sizes each call for the model that it calls. A model that is not in the list gets `contextLength`. A model that pr-agent already knows keeps the length that pr-agent has for it. No model gets more than the largest length that you set. The context length covers the input and the answer. pr-agent keeps only 1000 to 1500 tokens of it free for the answer.

```yaml
model: openai/large-model
fallbackModels: [openai/small-model]
contextLength: 32000
modelContextLengths:
  openai/large-model: 128000
```

## Many reviews at once

pr-agent runs each command as a task on the event loop of a worker process, with no queue and no limit. A worker also does some blocking GitLab calls on that loop, so one busy worker answers new webhook calls slowly, and GitLab gives up on a call after 10 seconds. To handle more reviews at once, run more worker processes. pr-agent counts them from the CPUs of the actor, so size the actor with `cpuMillicores` and `memoryBytes` and leave `workers` unset: a 2 CPU actor gets 2 workers and a 4 CPU actor gets 4 (measured in the gVisor sandbox), up to 4. Set `maxWorkers` to raise that ceiling, or `workers` to force a number. Start with about 1 CPU and 1 GiB for each worker, and make the worker pool of Agent Substrate (`substrate.workers.cpu` and `memory`) about twice the size of the actor. The metrics carry the id of the worker, so the workers do not overwrite each other (see "Reporting a running command").

## Reporting a running command

pr-agent has counters for commands, tokens and model calls, but no gauge for the commands that run now. With metrics on, the actor reports one: the gauge `pr_agent_commands_in_flight` (OpenTelemetry name `pr_agent.commands_in_flight`, unit `{command}`). It is 1 while a command runs, and 0 when it ends. It has the label `ate_actor`, in the form `<atespace>/<actor name>`, from the resource attribute `OTEL_RESOURCE_ATTRIBUTES`. The chart does not use the template name, because that name is a hash of the template, and the env is part of the template.

The code is an inline patch, `charts/agent/files/actor_patch.py`. The chart puts it in the command of the actor, next to the patch that turns on `keep_base_url`, and not in a derived image. A derived image is one more image to build, sign and pin. The patch wraps `PRAgent.handle_request`, adds 1 and pushes the metrics at once, runs the command, and subtracts 1 and pushes again. If the meter or the push fails, it logs a warning and runs the command. It does nothing when `OTEL__IS_ENABLED` is not `true`. The upstream gap is issue 5125 in The-PR-Agent/pr-agent (an in-flight gauge). Delete the patch when it ships.

Each pr-agent worker process has its own meter, so the actor patch gives each worker its own `service.instance.id`, and the collector chart `pr-agent-metrics` copies it to the label `worker` next to `ate_actor`. The counters and the gauge of an actor are the sum over its workers, and the dashboard and the idle suspend already sum. After a restart of a worker, its old series stays until `metricExpiration`. A suspend in the middle of a command can leave a stale 1. The chart `substrate-idle-suspend` reads the gauge as the signal `busy`, and it stops reading a value as busy after a cap, so `metricExpiration` stays at its default.

## Dashboard

Each agent can bring a simple Grafana dashboard, `Agent: <name>`. Every number follows the time range at the top right, so you can look at the last hour, 30 days or 57 days. It starts on the last 24 hours. Prometheus must keep the data for as long as you want to look back.

Six numbers sit at the top:

- Working right now? shows Busy or Idle.
- Reviews started.
- Commands failed, as a share of the commands that ended. A command that pr-agent skipped does not count. Green is below 5 percent.
- Answered by a fallback model, as a share of all commands. A high value means the main model fails or times out.
- Model calls per review. A review that is cut into chunks shows a higher number.
- Tokens used.

Below them are three sections:

- Activity: Work started, in bars (pr-agent counts a command when it starts), and Busy time, on the same time scale.
- Models and failures: a timeline with one row for each model, which shows when each one answered (a fallback model has its own orange row), and the failed commands over time, with one colour for each command (review, describe, improve). An empty chart means no failures.
- Details: a table of the models that answered, with their role (main or fallback) and their commands, and the tokens read and written by the model.

The counters need care. After a restart of the collector, a counter comes back as a new series with its old value. So each query first merges the series that differ only in scrape labels, such as `pod`. A bar compares the counter with its value one step before. If the series was not there then, the bar compares with its latest value of the 30 days before. A counter that is lower than before started again, for example after a restart of a worker, and counts its new value. A number reads the growth in the time range with `increase()`. If a series is not there at the start of the range, the number also adds the step from its latest known value to its lowest value in the range. Three cases can still be wrong. A series that was away for more than 30 days counts its whole value again. A series that is away at the start of the range and restarts inside it can read high or low. The latest value is read once a minute, so a command in the last minute before a series goes away can count twice.

The model and the outcome come from the actor patch (see "Reporting a running command"). pr-agent keeps both in its run details and does not report them as metrics. The patch adds the counters `pr_agent_commands_finished_total` (labels `outcome` and `pr_agent_command`, the first word of the request, as pr-agent counts it) and `pr_agent_commands_by_model_total` (labels `model` and `fallback`).

To turn it on, set `agent.dashboard.enabled: true`. It needs `agent.metricsCollector.enabled: true`. The chart `pr-agent-metrics` makes a ConfigMap with the label `grafana_dashboard: "1"`, and the Grafana sidecar loads it.

## Suspend idle actors

Substrate v1.0.1 never suspends an idle actor. The chart `substrate-idle-suspend` runs a CronJob that does it for the actors you list. The `agent` chart deploys it for each agent that sets `agent.idleSuspend.enabled`, with the actor of that agent. The CronJob uses the registration image, which is built in the repository kube-agent-substrate (`images/substrate-registration`) and pulled by digest. You can delete the chart when upstream ships its own idle policy.

Warnings:

- An actor that answers at once and keeps working in the background can look idle. Set `idleMinutes` longer than its longest background task.
- A request that is younger than one scrape interval is not in the data yet. Keep `idleMinutes` well above the scrape interval.
- Upstream v1.0.1 documents no drain of a running request on suspend. A suspend at that moment can cut the request.

The chart needs a Prometheus that scrapes `atenet-router`, `atenet-egress`, `ate-api-server` and `atelet`. With the Prometheus Operator, the PodMonitors come from the `substrate-workers` chart (see PodMonitors). The PodMonitors are in the control plane namespace, so the `podMonitorNamespaceSelector` of the Prometheus must include it. Upstream makes a scrape object only on GKE.

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

The defaults differ on purpose. The chart `substrate-idle-suspend` alone suspends after 30 minutes and runs every 5 minutes. The `agent` chart sets `idleMinutes: 10` and a schedule of every minute, because it knows the actor reports `busy`. The default Prometheus address of `substrate-idle-suspend` is only an example. Set `prometheus.url` for your cluster, and set `pr-agent-metrics` `allowScrapeFrom` to the namespace where your Prometheus runs.

If Prometheus needs a bearer token, set `prometheus.bearerTokenSecret.name`. If it uses a private CA, set `prometheus.caSecret.name`.

| Value | Default | Meaning |
|---|---|---|
| `actors` | `[]` | The `atespace` and `name` of each actor to watch. An empty list renders nothing. |
| `schedule` | `"*/5 * * * *"` | Cron schedule of the CronJob |
| `idleMinutes` | `30` | Minutes with no activity before a suspend |
| `idleCpuCores` | `0.05` | CPU cores that still count as idle |
| `suspendMode` | `async` | `async` (the upstream default) or `sync`: how the snapshot becomes durable |
| `prometheus.url` | `http://prometheus-operated.monitoring.svc:9090` | Base URL of Prometheus |
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

When an agent turns on idle suspend, the `substrate-stack` chart turns on `observability` of the `substrate-workers` chart of Agent Substrate. That chart makes the PodMonitors of the control plane, once for all agents, and each series carries the label `app` of its pod. Set the label that Prometheus selects them by in `substrate.podMonitorLabels`. Do not set `observability.enabled: false` in `substrate.workers.helmValues`: without the PodMonitors the idle suspend cannot read its signals, so it suspends nothing.

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
