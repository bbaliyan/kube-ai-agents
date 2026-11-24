# kube-ai-agents

Helm charts that run AI agents on Agent Substrate with Argo CD.

The parent chart `ai-agent` renders the shared control plane and one child for each agent in a list. A consumer repository supplies the environment values: the GitLab address, the model, storage and the names of its Secrets. This repository holds none of them.

Status: new. The charts are added in steps.
