{{- /* The agents with their defaults, as JSON. It fails on a name, a namespace or an actor that two agents share. */ -}}
{{- define "ai-agent.agents" -}}
{{- $names := list -}}
{{- $namespaces := list -}}
{{- $actors := list -}}
{{- $resolved := list -}}
{{- range .Values.agents -}}
{{- $name := required "every entry of agents needs a name" .name -}}
{{- if not (has (default "" .type) (list "pr-agent")) }}{{ fail (printf "agents[%s].type must be pr-agent, got %q" $name (default "" .type)) }}{{ end -}}
{{- $agent := mergeOverwrite (dict "atespace" $name "namespace" $name) (deepCopy .) -}}
{{- if has $name $names }}{{ fail (printf "two agents are named %q. Names must be unique" $name) }}{{ end -}}
{{- if has $agent.namespace $namespaces }}{{ fail (printf "two agents use the namespace %q. Each agent needs its own namespace" $agent.namespace) }}{{ end -}}
{{- $actor := printf "%s/%s" $agent.atespace (default "pr-agent" $agent.actorName) -}}
{{- if has $actor $actors }}{{ fail (printf "two agents use the actor %q. An actor name must be unique in its atespace" $actor) }}{{ end -}}
{{- $names = append $names $name -}}
{{- $namespaces = append $namespaces $agent.namespace -}}
{{- $actors = append $actors $actor -}}
{{- $resolved = append $resolved $agent -}}
{{- end -}}
{{- toJson $resolved -}}
{{- end -}}
