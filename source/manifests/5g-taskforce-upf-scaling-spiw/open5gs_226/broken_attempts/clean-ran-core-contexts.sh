#!/usr/bin/env bash
set -euo pipefail

NS="default"

GNB_DEPLOY="ueransim-gnb"
UE_DEPLOY="ueransim-gnb-ues"
ADD_DEPLOY="ueransim-ues-additional"

AMF_DEPLOY="open5gs-amf"
SMF_DEPLOY="open5gs-smf"

wait_no_pods() {
  local selector="$1"
  local name="$2"

  for i in $(seq 1 90); do
    COUNT="$(kubectl -n "$NS" get pod -l "$selector" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    echo "$name pods remaining=$COUNT"

    if [ "$COUNT" = "0" ]; then
      return 0
    fi

    sleep 2
  done

  echo "ERROR: pods still exist for $name"
  kubectl -n "$NS" get pod -l "$selector" -o wide || true
  exit 1
}

echo "=== 1. Stop UE pods ==="

kubectl -n "$NS" scale deploy/"$UE_DEPLOY" --replicas=0 2>/dev/null || true
kubectl -n "$NS" scale deploy/"$ADD_DEPLOY" --replicas=0 2>/dev/null || true

kubectl -n "$NS" delete pod -l app.kubernetes.io/instance="$UE_DEPLOY" \
  --grace-period=0 --force --wait=false 2>/dev/null || true

kubectl -n "$NS" delete pod -l app.kubernetes.io/instance="$ADD_DEPLOY" \
  --grace-period=0 --force --wait=false 2>/dev/null || true

wait_no_pods "app.kubernetes.io/instance=$UE_DEPLOY" "$UE_DEPLOY"
wait_no_pods "app.kubernetes.io/instance=$ADD_DEPLOY" "$ADD_DEPLOY"

echo
echo "=== 2. Stop gNB ==="

kubectl -n "$NS" scale deploy/"$GNB_DEPLOY" --replicas=0
wait_no_pods "app.kubernetes.io/instance=$GNB_DEPLOY" "$GNB_DEPLOY"

echo
echo "=== 3. Restart AMF and SMF only ==="

kubectl -n "$NS" rollout restart deploy/"$AMF_DEPLOY"
kubectl -n "$NS" rollout restart deploy/"$SMF_DEPLOY"

kubectl -n "$NS" rollout status deploy/"$AMF_DEPLOY" --timeout=240s
kubectl -n "$NS" rollout status deploy/"$SMF_DEPLOY" --timeout=240s

echo
echo "=== 4. Start clean gNB ==="

kubectl -n "$NS" scale deploy/"$GNB_DEPLOY" --replicas=1
kubectl -n "$NS" rollout status deploy/"$GNB_DEPLOY" --timeout=240s

sleep 20

GNB_POD="$(kubectl -n "$NS" get pod \
  -l app.kubernetes.io/instance="$GNB_DEPLOY" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')"

echo
echo "GNB_POD=$GNB_POD"

kubectl -n "$NS" get pod "$GNB_POD" \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,STARTED:.status.containerStatuses[0].state.running.startedAt,NODE:.spec.nodeName'

kubectl -n "$NS" exec "$GNB_POD" -- sh -lc '
COUNT="$(ps -eo comm= | sed "s/^ *//;s/ *$//" | grep -cx "nr-gnb" || true)"
echo "REAL_NR_GNB_COUNT=$COUNT"

if [ "$COUNT" != "1" ]; then
  echo "ERROR: expected exactly one nr-gnb process"
  exit 1
fi
'

echo
echo "=== 5. Start base UE only ==="

kubectl -n "$NS" scale deploy/"$UE_DEPLOY" --replicas=1
kubectl -n "$NS" rollout status deploy/"$UE_DEPLOY" --timeout=240s

echo
echo "=== 6. Wait for UE registration ==="

sleep 180

UE_POD="$(kubectl -n "$NS" get pod \
  -l app.kubernetes.io/instance="$UE_DEPLOY" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')"

echo
echo "UE_POD=$UE_POD"

echo
echo "=== 7. Final state ==="

kubectl -n "$NS" get pod -o wide | grep -E 'NAME|open5gs-amf|open5gs-smf|ueransim-gnb|ueransim-gnb-ues'

echo
echo "=== 8. UE tunnel count ==="

kubectl -n "$NS" exec "$UE_POD" -- sh -lc '
COUNT="$(ip -o -4 addr show | grep -E " uesimtun[0-9]+ " | wc -l | tr -d " ")"
echo "UE_TUNNELS=$COUNT"

if [ "$COUNT" != "70" ]; then
  echo "ERROR: expected 70 UE tunnels"
  exit 1
fi
'

echo
echo "=== 9. Check recent gNB errors ==="

kubectl -n "$NS" logs "$GNB_POD" --since=5m | \
  egrep -i 'abort|core dumped|terminate|unknown-local-UE-NGAP-ID|Association terminated|UE context not found|signal lost|error|warn' || true

echo
echo "=== Context cleanup finished ==="
