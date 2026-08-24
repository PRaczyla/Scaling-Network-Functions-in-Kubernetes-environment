Kubernetes/Open5GS thesis laboratory export

CONTENTS

cluster-info/
   Information about the running cluster.

resources/namespaced/
    Complete YAML exports of every listable namespaced API resource.

resources/cluster-scoped/
    Complete YAML exports of every listable cluster-scoped API resource.

helm/
    Helm release values, rendered manifests, hooks, notes and histories.

source/
    Original local source manifests, Helm charts, Ansible files and scripts.

upf_scaling_v2.yaml
   Script used for measurements and executing iperf test

mongo.txt
   Command to populate MongoDB database

prepare-ran-once-before-playbook.sh
   Restarting gNB and UE, togeter with clearing old policies to ensure proper UE registration

IMPORTANT:
The resources directory is a RAW snapshot of the Kubernetes API.
It contains runtime metadata such as UID, resourceVersion, status and
managedFields. It is intended primarily for documentation and inspection,
not for direct kubectl apply restoration.
