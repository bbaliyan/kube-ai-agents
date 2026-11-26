{{- /* The agents with their defaults, as JSON. It fails on a name, a namespace or an actor that two agents share. A name must also not make an Application name that another agent or the substrate stack already has: each agent makes <name>-actor, <name>-registration and more. */ -}}
{{- define "ai-agent.agents" -}}
{{- $names := list -}}
{{- $namespaces := list -}}
{{- $actors := list -}}
{{- $resolved := list -}}
{{- $applications := list "substrate" "substrate-credential-policy" "substrate-install" "substrate-workers" -}}
{{- range .Values.agents -}}
{{- $name := required "every entry of agents needs a name" .name -}}
{{- if not (has (default "" .type) (list "pr-agent")) }}{{ fail (printf "agents[%s].type must be pr-agent, got %q" $name (default "" .type)) }}{{ end -}}
{{- $agent := mergeOverwrite (dict "atespace" $name "namespace" $name) (deepCopy .) -}}
{{- if has $name $names }}{{ fail (printf "two agents are named %q. Names must be unique" $name) }}{{ end -}}
{{- if has $agent.namespace (list "argocd" $.Values.substrate.namespace) }}{{ fail (printf "agents[%s].namespace must not be argocd or the namespace of the control plane, got %q. The deployment account of an agent has broad rights in the namespace of the agent" $name $agent.namespace) }}{{ end -}}
{{- if has $agent.namespace $namespaces }}{{ fail (printf "two agents use the namespace %q. Each agent needs its own namespace" $agent.namespace) }}{{ end -}}
{{- $actor := printf "%s/%s" $agent.atespace (default "pr-agent" $agent.actorName) -}}
{{- if has $actor $actors }}{{ fail (printf "two agents use the actor %q. An actor name must be unique in its atespace" $actor) }}{{ end -}}
{{- range $suffix := list "" "-actor" "-registration" "-idle-suspend" "-webhook" "-metrics" -}}
{{- $application := printf "%s%s" $name $suffix -}}
{{- if has $application $applications }}{{ fail (printf "agents[%s] would make an Application named %q, which another agent or the substrate stack already has. Choose a name that is not another name plus -actor, -registration, -idle-suspend, -webhook or -metrics" $name $application) }}{{ end -}}
{{- $applications = append $applications $application -}}
{{- end -}}
{{- $names = append $names $name -}}
{{- $namespaces = append $namespaces $agent.namespace -}}
{{- $actors = append $actors $actor -}}
{{- $resolved = append $resolved $agent -}}
{{- end -}}
{{- toJson $resolved -}}
{{- end -}}
