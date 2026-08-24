#!/usr/bin/env bash
set -euo pipefail

NS="default"

COUNT="${1:-}"

if [ -z "$COUNT" ]; then
  COUNT="$(grep -E '^[[:space:]]*required_registered_ues:' upf_scaling.yaml | awk '{print $2}' | tail -1)"
fi

if [ -z "$COUNT" ]; then
  echo "ERROR: cannot detect UE count. Use: ./prepare-ran-once-before-playbook.sh 50"
  exit 1
fi

GNB_DEPLOY="ueransim-gnb"
UE_DEPLOY="ueransim-gnb-ues"

echo "=== ONE-TIME RAN CLEAN START BEFORE PLAYBOOK ==="
echo "UE_COUNT=$COUNT"
echo "NOTE: this script runs BEFORE traffic only. It does not modify the test methodology."

echo
echo "=== 1. Stop UE pods first ==="

kubectl -n "$NS" scale deploy/"$UE_DEPLOY" --replicas=0

kubectl -n "$NS" delete pod -l app.kubernetes.io/instance="$UE_DEPLOY" \
  --grace-period=0 --force --wait=false 2>/dev/null || true

for i in $(seq 1 60); do
  UE_LEFT="$(kubectl -n "$NS" get pod -l app.kubernetes.io/instance="$UE_DEPLOY" --no-headers 2>/dev/null | wc -l | tr -d ' ')"

  echo "UE pods remaining=$UE_LEFT"

  if [ "$UE_LEFT" = "0" ]; then
    break
  fi

  sleep 2
done

echo
echo "=== 2. Stop gNB ==="

kubectl -n "$NS" scale deploy/"$GNB_DEPLOY" --replicas=0

kubectl -n "$NS" delete pod -l app.kubernetes.io/instance="$GNB_DEPLOY" \
  --grace-period=0 --force --wait=false 2>/dev/null || true

for i in $(seq 1 60); do
  GNB_LEFT="$(kubectl -n "$NS" get pod -l app.kubernetes.io/instance="$GNB_DEPLOY" --no-headers 2>/dev/null | wc -l | tr -d ' ')"

  echo "gNB pods remaining=$GNB_LEFT"

  if [ "$GNB_LEFT" = "0" ]; then
    break
  fi

  sleep 2
done

echo
echo "=== 3. Set native UE count, keep chart wrapper ==="

kubectl -n "$NS" patch deploy "$UE_DEPLOY" --type='json' -p='[
  {
    "op": "remove",
    "path": "/spec/template/spec/containers/0/command"
  }
]' 2>/dev/null || true

kubectl -n "$NS" patch deploy "$UE_DEPLOY" --type='json' -p="[
  {
    \"op\": \"replace\",
    \"path\": \"/spec/template/spec/containers/0/args\",
    \"value\": [\"ue\", \"-n\", \"$COUNT\"]
  },
  {
    \"op\": \"replace\",
    \"path\": \"/spec/template/spec/containers/0/env\",
    \"value\": [
      {
        \"name\": \"GNB_HOSTNAME\",
        \"value\": \"ueransim-gnb\"
      }
    ]
  }
]"

kubectl -n "$NS" get deploy "$UE_DEPLOY" \
  -o jsonpath='COMMAND={.spec.template.spec.containers[0].command}{"\n"}ARGS={.spec.template.spec.containers[0].args}{"\n"}ENV={.spec.template.spec.containers[0].env}{"\n"}'

echo
echo "=== 4. Start fresh gNB ==="

kubectl -n "$NS" scale deploy/"$GNB_DEPLOY" --replicas=1
kubectl -n "$NS" rollout status deploy/"$GNB_DEPLOY" --timeout=240s

sleep 20

GNB_POD="$(kubectl -n "$NS" get pod \
  -l app.kubernetes.io/instance="$GNB_DEPLOY" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')"

echo "GNB_POD=$GNB_POD"

kubectl -n "$NS" get pod "$GNB_POD" \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,STARTED:.status.containerStatuses[0].state.running.startedAt,NODE:.spec.nodeName'

echo
echo "=== 5. gNB startup log check ==="

kubectl -n "$NS" logs "$GNB_POD" --tail=100 | \
  egrep -i 'NG Setup|SCTP|successful|error|warn|segmentation|core dumped' || true

if kubectl -n "$NS" logs "$GNB_POD" --tail=200 | egrep -qi 'segmentation|core dumped|failed'; then
  echo "ERROR: gNB log contains failure after fresh start"
  exit 1
fi

echo
echo "=== 6. Start UE pod ==="

kubectl -n "$NS" scale deploy/"$UE_DEPLOY" --replicas=1
kubectl -n "$NS" rollout status deploy/"$UE_DEPLOY" --timeout=240s

UE_POD="$(kubectl -n "$NS" get pod \
  -l app.kubernetes.io/instance="$UE_DEPLOY" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')"

echo "UE_POD=$UE_POD"

echo
echo "=== 7. Wait for tunnels ==="

TUNNELS="0"

for i in $(seq 1 90); do
  TUNNELS="$(kubectl -n "$NS" exec "$UE_POD" -- sh -lc \
    "ip -o -4 addr show | grep -E ' uesimtun[0-9]+ ' | wc -l | tr -d ' '" 2>/dev/null || echo 0)"

  GNB_RESTARTS="$(kubectl -n "$NS" get pod "$GNB_POD" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}')"

  UE_RESTARTS="$(kubectl -n "$NS" get pod "$UE_POD" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}')"

  echo "STATUS tunnels=$TUNNELS expected=$COUNT gnb_restarts=$GNB_RESTARTS ue_restarts=$UE_RESTARTS"

  if [ "$GNB_RESTARTS" != "0" ] || [ "$UE_RESTARTS" != "0" ]; then
    echo "ERROR: restart detected before test"
    echo
    echo "=== gNB logs ==="
    kubectl -n "$NS" logs "$GNB_POD" --tail=160 || true
    echo
    echo "=== UE logs ==="
    kubectl -n "$NS" logs "$UE_POD" --tail=160 || true
    exit 1
  fi

  if [ "$TUNNELS" = "$COUNT" ]; then
    echo "OK: $COUNT tunnels ready"
    break
  fi

  sleep 5
done

if [ "$TUNNELS" != "$COUNT" ]; then
  echo "ERROR: expected $COUNT tunnels, got $TUNNELS"
  echo
  echo "=== gNB logs ==="
  kubectl -n "$NS" logs "$GNB_POD" --tail=180 || true
  echo
  echo "=== UE logs ==="
  kubectl -n "$NS" logs "$UE_POD" --tail=180 || true
  exit 1
fi

echo
echo "=== 8. Final clean RAN state before playbook ==="

kubectl -n "$NS" get pod "$GNB_POD" "$UE_POD" \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,STARTED:.status.containerStatuses[0].state.running.startedAt,NODE:.spec.nodeName'

echo
echo "=== 9. Recent gNB warnings/errors after clean start ==="

kubectl -n "$NS" logs "$GNB_POD" --since=10m | \
  egrep -i 'core dumped|segmentation|UE context not found|unknown-local-UE-NGAP-ID|Association terminated|signal lost|error|warn' || true

echo
echo "=== READY: run ansible-playbook upf_scaling.yaml now ==="
