Kubernetes/Open5GS thesis laboratory export
Generated: Mon Aug 24 12:55:41 AM CEST 2026

CONTENTS

cluster-info/
    Human-readable information about the running cluster.

resources/namespaced/
    Complete YAML exports of every listable namespaced API resource.

resources/cluster-scoped/
    Complete YAML exports of every listable cluster-scoped API resource.

helm/
    Helm release values, rendered manifests, hooks, notes and histories.

source/
    Original local source manifests, Helm charts, Ansible files and scripts.

logs/failed-exports.txt
    Resources which could not be exported.

IMPORTANT:
The resources directory is a RAW snapshot of the Kubernetes API.
It contains runtime metadata such as UID, resourceVersion, status and
managedFields. It is intended primarily for documentation and inspection,
not for direct kubectl apply restoration.

Secrets are also included if the current Kubernetes user has permission
to read them.
