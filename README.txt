UPF Scaling laboratory export

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

used_grafana/
    Screenshots from Grafana used in the thesis.

mongo.txt
    Copy-paste population of mongoDB subscriber database

prepare-ran-once-before-playbook.sh
    Shell script to restart environment to ensure proper registration of UEs in the network

upf_scaling_v2.yaml
    Ansible playbook to automate iperf script execution

IMPORTANT:
The resources directory is a RAW snapshot of the Kubernetes API.
It contains runtime metadata such as UID, resourceVersion, status and
managedFields. It is intended primarily for documentation and inspection.
