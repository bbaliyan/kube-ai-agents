{{- /* The scheme, host name and port of an address. The port comes from the address, or from the scheme. */ -}}
{{- define "agent.endpoint" -}}
{{- $url := urlParse . -}}
{{- $port := (regexFind ":[0-9]+$" $url.host) | trimPrefix ":" -}}
{{- if not $port }}{{ $port = ternary "443" "80" (eq $url.scheme "https") }}{{ end -}}
{{- toJson (dict "protocol" $url.scheme "host" $url.hostname "port" ($port | atoi)) -}}
{{- end -}}

{{- /* An address, checked: http or https, and a DNS name, because the egress policy matches host names. It takes the address and the name of its value. */ -}}
{{- define "agent.checkedAddress" -}}
{{- $address := .address -}}
{{- $endpoint := include "agent.endpoint" $address | fromJson -}}
{{- if not (has $endpoint.protocol (list "http" "https")) }}{{ fail (printf "%s must start with http:// or https://, got %q" .name $address) }}{{ end -}}
{{- if or (regexMatch `^[0-9]{1,3}(\.[0-9]{1,3}){3}$` $endpoint.host) (contains ":" $endpoint.host) }}{{ fail (printf "%s must use a DNS name, not an IP address, because the egress policy matches host names. Got %q" .name $address) }}{{ end -}}
{{- toJson $endpoint -}}
{{- end -}}

{{- /* The pr-agent setting that holds the base URL of the model server, and the one that holds its key, by the prefix of the model name. */ -}}
{{- define "agent.providerSettings" -}}
{{- $providers := dict "ollama" (dict "base" "OLLAMA__API_BASE" "key" "OLLAMA__API_KEY") "openai" (dict "base" "OPENAI__API_BASE" "key" "OPENAI__KEY") -}}
{{- $prefix := index (splitList "/" .) 0 -}}
{{- if not (hasKey $providers $prefix) }}{{ fail (printf "agent.model must start with one of: %s. Got %q" (keys $providers | sortAlpha | join "/, " | printf "%s/") .) }}{{ end -}}
{{- toJson (get $providers $prefix) -}}
{{- end -}}

{{- /* The actor list that the actor chart and the registration chart share, as JSON. */ -}}
{{- define "agent.actors" -}}
{{- $p := .Values.agent -}}
{{- $_ := required "agent.namespace is required" $p.namespace -}}
{{- $_ := required "agent.atespace is required" $p.atespace -}}
{{- $_ := required "agent.gitlabUrl is required, the GitLab address that the actor calls, for example http://gitlab.example.test" $p.gitlabUrl -}}
{{- if not $p.modelEndpoint }}{{ fail "agent.modelEndpoint is required, the base URL of the model server, for example http://model.example.test:11434" }}{{ end -}}
{{- $model := include "agent.checkedAddress" (dict "address" $p.modelEndpoint "name" "agent.modelEndpoint") | fromJson -}}
{{- $provider := include "agent.providerSettings" $p.model | fromJson -}}
{{- range $p.fallbackModels | default list }}
{{- if ne (index (splitList "/" .) 0) (index (splitList "/" $p.model) 0) }}{{ fail (printf "agent.fallbackModels must use the same prefix as agent.model, because they share one model server. Got %q" .) }}{{ end }}
{{- end -}}
{{- $gitlabRules := list -}}
{{- $gitlabHttps := false -}}
{{- $gitlabHosts := list -}}
{{- range $index, $url := concat (list $p.gitlabUrl) (default (list) $p.gitlabExtraUrls) }}
{{- $name := ternary "agent.gitlabUrl" "agent.gitlabExtraUrls" (eq $index 0) -}}
{{- $address := include "agent.checkedAddress" (dict "address" $url "name" $name) | fromJson -}}
{{- if has $address.host $gitlabHosts }}{{ fail (printf "%s repeats the GitLab host %q, which is already in agent.gitlabUrl or agent.gitlabExtraUrls" $name $address.host) }}{{ end -}}
{{- if eq $address.host $model.host }}{{ fail (printf "%s has the same host as agent.modelEndpoint, %q. One host cannot send two different credentials" $name $address.host) }}{{ end -}}
{{- $gitlabHosts = append $gitlabHosts $address.host -}}
{{- if eq $address.protocol "https" }}{{ $gitlabHttps = true }}{{ end -}}
{{- $gitlabRules = append $gitlabRules (dict
  "protocol" $address.protocol
  "hostnames" (list $address.host)
  "ports" (list $address.port)
  "credential" (dict
    "header" "Authorization"
    "prefix" "Bearer "
    "credentialUri" (printf "ate-secret://k8s.io/default/%s/gitlab-pr-agent/token" $p.namespace))) -}}
{{- end -}}
{{- $modelRule := dict
  "protocol" $model.protocol
  "hostnames" (list $model.host)
  "ports" (list $model.port) -}}
{{- /* The router reaches an actor on port 80 and ignores the Host port, so the app must listen there. */ -}}
{{- $env := dict
  "PORT" "80"
  "CONFIG__GIT_PROVIDER" "gitlab"
  "CONFIG__MODEL" $p.model
  "CONFIG__FALLBACK_MODELS" ($p.fallbackModels | default list | toJson)
  "CONFIG__CUSTOM_MODEL_MAX_TOKENS" ($p.contextLength | toString)
  "CONFIG__MAX_MODEL_TOKENS" ($p.contextLength | toString)
  "CONFIG__DUPLICATE_PROMPT_EXAMPLES" "true"
  "GITLAB__URL" $p.gitlabUrl
  "GITLAB__AUTH_TYPE" "oauth_token"
  "GITLAB__PERSONAL_ACCESS_TOKEN" "replaced-by-the-egress-proxy"
  "GITLAB__SHARED_SECRET" $p.hopToken -}}
{{- $_ := set $env $provider.base $p.modelEndpoint -}}
{{- /* Metrics: pr-agent pushes its OpenTelemetry counters (commands, tokens, model calls) over OTLP/HTTP to a collector. With agent.metricsCollector.enabled the collector is the chart pr-agent-metrics. The egress proxy adds the bearer token of agent.metricsApiKeySecret, so the actor never holds it. */ -}}
{{- $metricsEndpoint := $p.metricsEndpoint -}}
{{- if and $p.metricsCollector.enabled (not $metricsEndpoint) }}{{ $metricsEndpoint = printf "http://pr-agent-metrics.%s.svc.cluster.local:4318" $p.namespace }}{{ end -}}
{{- /* With the collector and no Secret of your own, the chart makes one with a random token inside the cluster. */ -}}
{{- $metricsSecret := $p.metricsApiKeySecret -}}
{{- if and $p.metricsCollector.enabled (not $metricsSecret) }}{{ $metricsSecret = dict "name" "pr-agent-metrics" "key" "password" }}{{ end -}}
{{- $metricsRules := list -}}
{{- if $metricsEndpoint }}
{{- $metrics := include "agent.checkedAddress" (dict "address" $metricsEndpoint "name" "agent.metricsEndpoint") | fromJson -}}
{{- if or (eq $metrics.host $model.host) (has $metrics.host $gitlabHosts) }}{{ fail (printf "agent.metricsEndpoint has the same host as the model server or GitLab, %q. Use a separate host" $metrics.host) }}{{ end -}}
{{- $_ := set $env "OTEL__IS_ENABLED" "true" -}}
{{- $_ := set $env "OTEL__EXPORTER_TYPE" "otlp" -}}
{{- $_ := set $env "OTEL__OTLP_ENDPOINT" $metricsEndpoint -}}
{{- $_ := set $env "OTEL__ENVIRONMENT" $p.metricsEnvironment -}}
{{- $metricsRule := dict "protocol" $metrics.protocol "hostnames" (list $metrics.host) "ports" (list $metrics.port) -}}
{{- if $metricsSecret }}
{{- /* The gateway replaces an Authorization header the actor sends and never adds one. */ -}}
{{- $_ := set $env "OTEL__OTLP_HEADERS" "Authorization=Bearer replaced-by-the-egress-proxy" -}}
{{- $_ := set $metricsRule "credential" (dict
  "header" "Authorization"
  "prefix" "Bearer "
  "credentialUri" (printf "ate-secret://k8s.io/default/%s/%s/%s" $p.namespace (required "agent.metricsApiKeySecret needs a name" $metricsSecret.name) (required "agent.metricsApiKeySecret needs a key" $metricsSecret.key))) -}}
{{- end }}
{{- $metricsRules = list $metricsRule -}}
{{- end -}}
{{- if $p.runDetails }}{{ $_ := set $env "CONFIG__OUTPUT_RUN_DETAILS" "true" }}{{ end -}}
{{- $timeout := int $p.modelTimeoutSeconds -}}
{{- if lt $timeout 1 }}{{ fail "agent.modelTimeoutSeconds must be a whole number of seconds, at least 1" }}{{ end -}}
{{- $_ := set $env "CONFIG__AI_TIMEOUT" ($timeout | toString) -}}
{{- /* Each gunicorn worker is one process with one event loop. Unset, pr-agent counts them from the CPUs of the actor. The metrics carry the id of the worker (actor_patch.py), so the workers do not overwrite each other. */ -}}
{{- if not (kindIs "invalid" $p.workers) }}
{{- if lt (int $p.workers) 1 }}{{ fail "agent.workers must be a whole number, at least 1, or unset" }}{{ end -}}
{{- $_ := set $env "GUNICORN_WORKERS" (int $p.workers | toString) -}}
{{- end -}}
{{- if not (kindIs "invalid" $p.maxWorkers) }}
{{- if lt (int $p.maxWorkers) 1 }}{{ fail "agent.maxWorkers must be a whole number, at least 1, or unset" }}{{ end -}}
{{- $_ := set $env "GUNICORN_MAX_WORKERS" (int $p.maxWorkers | toString) -}}
{{- end -}}
{{- /* With a fallback, do not replay a call on the model that just failed: move on at once. */ -}}
{{- $retryOnTimeout := $p.retrySameModelOnTimeout -}}
{{- $modelRetries := $p.modelRetries -}}
{{- if $p.fallbackModels }}
{{- if kindIs "invalid" $retryOnTimeout }}{{ $retryOnTimeout = false }}{{ end -}}
{{- if kindIs "invalid" $modelRetries }}{{ $modelRetries = 1 }}{{ end -}}
{{- end -}}
{{- if not (kindIs "invalid" $retryOnTimeout) }}{{ $_ := set $env "CONFIG__RETRY_SAME_MODEL_ON_TIMEOUT" (toString $retryOnTimeout) }}{{ end -}}
{{- if not (kindIs "invalid" $modelRetries) }}
{{- if or (lt (int $modelRetries) 0) (gt (int $modelRetries) 10) }}{{ fail "agent.modelRetries must be a whole number from 0 to 10" }}{{ end -}}
{{- $_ := set $env "CONFIG__NUM_RETRIES" (int $modelRetries | toString) -}}
{{- end -}}
{{- if $p.largeReviews }}
{{- $calls := int $p.maxReviewCalls -}}
{{- if lt $calls 1 }}{{ fail "agent.maxReviewCalls must be a whole number, at least 1" }}{{ end -}}
{{- $_ := set $env "PR_REVIEWER__ENABLE_LARGE_PR_CHUNKING" "true" -}}
{{- $_ := set $env "PR_REVIEWER__MAX_NUMBER_OF_CALLS" ($calls | toString) -}}
{{- end -}}
{{- /* The egress gateway ends TLS and starts it again, so the actor must trust the gateway CA for every https rule. */ -}}
{{- $https := or (eq $model.protocol "https") $gitlabHttps -}}
{{- if and $https (not $p.egressTrustBundle) }}{{ fail "The agent uses an https address (agent.gitlabUrl, agent.gitlabExtraUrls or agent.modelEndpoint), so the actor must trust the egress gateway CA. Set agent.egressTrustBundle to true, or use an http address." }}{{ end -}}
{{- if $https }}
{{- $bundle := "/run/ate/egress-trust-bundle/trust-bundle.pem" -}}
{{- $_ := set $env "SSL_CERT_FILE" $bundle -}}
{{- $_ := set $env "REQUESTS_CA_BUNDLE" $bundle -}}
{{- $_ := set $env "GITLAB__SSL_VERIFY" $bundle -}}
{{- end -}}
{{- if $p.modelApiKeySecret }}
{{- $secretName := required "agent.modelApiKeySecret needs a name, the name of the Secret that holds the key of the model server" $p.modelApiKeySecret.name -}}
{{- $secretKey := required "agent.modelApiKeySecret needs a key, the key in the Secret that holds the key of the model server" $p.modelApiKeySecret.key -}}
{{- $_ := set $modelRule "credential" (dict
  "header" "Authorization"
  "prefix" "Bearer "
  "credentialUri" (printf "ate-secret://k8s.io/default/%s/%s/%s" $p.namespace $secretName $secretKey)) -}}
{{- $_ := set $env $provider.key "replaced-by-the-egress-proxy" -}}
{{- end -}}
{{- /*
GitLab builds the link to the next page of a list from its external URL, not from the address of the request.
python-gitlab follows that link unless the client has keep_base_url, and pr-agent has no setting for it. So a
long list (more than 100 changed files, notes or discussions) leaves agent.gitlabUrl for a host that the actor
may not resolve or reach. The command turns keep_base_url on for every client and then runs gunicorn. The args
are the rest of the CMD of the gitlab_webhook image, which the command replaces.
*/ -}}
{{- /*
With metrics on, the command also runs files/actor_patch.py, which reports each running command as the gauge
pr_agent.commands_in_flight. An inline patch, like the one above, and not a derived image: no new image to
build, sign and pin. The resource attribute names the actor, because the name of the template is a hash of
its contents, which include this env.
*/ -}}
{{- $patch := "" -}}
{{- if $metricsEndpoint }}
{{- /* Agent Substrate refuses an inline command of more than 4096 characters, so the comment lines of the file stay out of it. */ -}}
{{- $patch = regexReplaceAll `(?m)^[ \t]*#[^\n]*\n` (.Files.Get "files/actor_patch.py") "" -}}
{{- $_ := set $env "OTEL_RESOURCE_ATTRIBUTES" (printf "ate.actor=%s/%s" $p.atespace $p.actorName) -}}
{{- end -}}
{{- $actor := dict
  "name" $p.actorName
  "atespace" $p.atespace
  "image" $p.image
  "command" (list "python" "-c" (printf "%s\n%s\n%s" `import functools, runpy, gitlab; gitlab.Gitlab.__init__ = functools.partialmethod(gitlab.Gitlab.__init__, keep_base_url=True)` $patch `runpy.run_module("gunicorn", run_name="__main__", alter_sys=True)`))
  "args" (list "-k" "uvicorn_worker.UvicornWorker" "-c" "pr_agent/servers/gunicorn_config.py" "--forwarded-allow-ips" "*" "pr_agent.servers.gitlab_webhook:app")
  "env" $env
  "resources" (dict "cpuMillicores" $p.cpuMillicores "memoryBytes" $p.memoryBytes)
  "wakeupProbe" (dict "path" "/" "port" 80)
  "warm" true
  "egress" (concat $gitlabRules (list $modelRule) $metricsRules) -}}
{{- if $https }}{{ $_ := set $actor "egressTrustBundle" true }}{{ end -}}
{{- toJson (list $actor) -}}
{{- end -}}

{{/* The metadata and the project that every Application of an agent has. Deleting the Application deletes what it made. Without the finalizer, removing an agent leaves its children behind. */}}
{{- define "agent.application" -}}
metadata:
  name: {{ .root.Values.agent.name }}-{{ .suffix }}
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: {{ .wave | quote }}
spec:
  project: {{ required "project is required: the parent chart passes the project of the agent" .root.Values.project }}
{{- end }}

{{- define "agent.destination" -}}
server: https://kubernetes.default.svc
namespace: {{ .namespace }}
{{- end }}
