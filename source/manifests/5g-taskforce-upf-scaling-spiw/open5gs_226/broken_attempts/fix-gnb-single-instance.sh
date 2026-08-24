#!/usr/bin/env bash
set -euo pipefail

NS="default"
GNB_DEPLOY="ueransim-gnb"
BASE_UE_DEPLOY="ueransim-gnb-ues"
ADDITIONAL_UE_DEPLOY="ueransim-ues-additional"

echo "=== 1. Stop UE first - no UE re-registration storm during gNB repair ==="
kubectl -n "$NS" scale deploy/"$BASE_UE_DEPLOY" --replicas=0 2>/dev/null || true
kubectl -n "$NS" scale deploy/"$ADDITIONAL_UE_DEPLOY" --replicas=0 2>/dev/null || true

kubectl -n "$NS" delete pod -l app.kubernetes.io/instance="$BASE_UE_DEPLOY" \
  --grace-period=0 --force --wait=false 2>/dev/null || true

kubectl -n "$NS" delete pod -l app.kubernetes.io/instance="$ADDITIONAL_UE_DEPLOY" \
  --grace-period=0 --force --wait=false 2>/dev/null || true

sleep 20

echo
echo "=== 2. Remove UERANSIM HPA if any exists ==="
kubectl -n "$NS" get hpa -o name 2>/dev/null | grep -i 'ueransim' | xargs -r kubectl -n "$NS" delete || true

echo
echo "=== 3. Detect gNB container name ==="
GNB_CONTAINER="$(kubectl -n "$NS" get deploy "$GNB_DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].name}')"
echo "GNB_CONTAINER=$GNB_CONTAINER"

echo
echo "=== 4. Patch gNB: Recreate strategy, one replica, stable resources, clean stop ==="
kubectl -n "$NS" patch deploy "$GNB_DEPLOY" --type='strategic' -p "{
  \"spec\": {
    \"replicas\": 1,
    \"strategy\": {
      \"type\": \"Recreate\"
    },
    \"template\": {
      \"spec\": {
        \"terminationGracePeriodSeconds\": 15,
        \"containers\": [
          {
            \"name\": \"$GNB_CONTAINER\",
            \"resources\": {
              \"requests\": {
                \"cpu\": \"1000m\",
                \"memory\": \"768Mi\"
              }
            },
            \"lifecycle\": {
              \"preStop\": {
                \"exec\": {
                  \"command\": [
                    \"/bin/sh\",
                    \"-c\",
                    \"pkill -TERM nr-gnb 2>/dev/null || true; sleep 3; pkill -KILL nr-gnb 2>/dev/null || true\"
                  ]
                }
              }
            }
          }
        ]
      }
    }
  }
}"

echo
echo "=== 5. Hard clean gNB: scale to zero, wait until no gNB pod exists ==="
kubectl -n "$NS" scale deploy/"$GNB_DEPLOY" --replicas=0

for i in $(seq 1 30); do
  CNT="$(kubectl -n "$NS" get pod \
    -l app.kubernetes.io/instance="$GNB_DEPLOY" \
    --no-headers 2>/dev/null | wc -l)"

  echo "gNB pods remaining=$CNT"

  if [ "$CNT" -eq 0 ]; then
    break
  fi

  sleep 5
done

kubectl -n "$NS" delete pod -l app.kubernetes.io/instance="$GNB_DEPLOY" \
  --grace-period=0 --force --wait=false 2>/dev/null || true

sleep 10

echo
echo "=== 6. Start exactly one gNB ==="
kubectl -n "$NS" scale deploy/"$GNB_DEPLOY" --replicas=1
kubectl -n "$NS" rollout status deploy/"$GNB_DEPLOY" --timeout=240s

GNB_POD="$(kubectl -n "$NS" get pod \
  -l app.kubernetes.io/instance="$GNB_DEPLOY" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')"

echo
echo "GNB_POD=$GNB_POD"

echo
echo "=== 7. Check gNB pod identity ==="
kubectl -n "$NS" get pod "$GNB_POD" \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,STARTED:.status.containerStatuses[0].state.running.startedAt,NODE:.spec.nodeName'

echo
echo "=== 8. Check gNB processes inside pod ==="
kubectl -n "$NS" exec "$GNB_POD" -- sh -lc '
echo "nr-gnb process count:"
pgrep -af "nr-gnb" | wc -l || true

echo
echo "matching processes:"
ps -eo pid,ppid,stat,args | egrep "nr-gnb|ueransim|gnb" | grep -v egrep || true
'

echo
echo "=== 9. Wait 120s and verify gNB did not restart ==="
sleep 120

kubectl -n "$NS" get pod "$GNB_POD" \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,STARTED:.status.containerStatuses[0].state.running.startedAt,NODE:.spec.nodeName'

echo
echo "=== 10. Suspicious gNB logs ==="
kubectl -n "$NS" logs "$GNB_POD" --tail=250 | \
  egrep -i 'signal lost|already exists|discarding|error|fail|abort|terminate|exception|assert|panic|segmentation|context' || true

echo
echo "DONE: gNB hardened. Start base UE only after checking process count/restarts above."
