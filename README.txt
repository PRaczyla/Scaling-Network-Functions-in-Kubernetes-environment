UPF Scaling laboratory export

CONTENTS

Grafana/
    JSON file with the view and screenshots from Grafana used in the thesis.

ansible/
    Playbook and script used before execution of the test.

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


IMPORTANT:
The resources directory is a RAW snapshot of the Kubernetes API.
It contains runtime metadata such as UID, resourceVersion, status and
managedFields. It is intended primarily for documentation and inspection.
