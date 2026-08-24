#!/usr/bin/env bash
set -euo pipefail

NS="default"
GNB_DEPLOY="ueransim-gnb"
UE_DEPLOY="ueransim-gnb-ues"
ADD_DEPLOY="ueransim-ues-additional"
AMF_DEPLOY="open5gs-amf"
SMF_DEPLOY="open5gs-smf"

UE_COUNT="70"
UE_START_DELAY="5"

wait_no_pods() {
  local selector="$1"
  local label="$2"
  local count

  for i in $(seq 1 90); do
    count="$(kubectl -n "$NS" get pod -l "$selector" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    echo "$label pods remaining=$count"

    if [ "$count" = "0" ]; then
      return 0
    fi

    sleep 2
  done

  echo "ERROR: pods still exist: $label"
  kubectl -n "$NS" get pod -l "$selector" -o wide || true
  exit 1
}

patch_strategy_recreate() {
  local deploy="$1"

  kubectl -n "$NS" patch deploy "$deploy" --type='json' -p='[
    {
      "op": "replace",
      "path": "/spec/strategy",
      "value": {
        "type": "Recreate"
      }
    }
  ]' >/dev/null
}

echo "=== 1. Stop UE pods and gNB ==="

kubectl -n "$NS" scale deploy/"$UE_DEPLOY" --replicas=0 2>/dev/null || true
kubectl -n "$NS" scale deploy/"$ADD_DEPLOY" --replicas=0 2>/dev/null || true

kubectl -n "$NS" delete pod -l app.kubernetes.io/instance="$UE_DEPLOY" \
  --grace-period=0 --force --wait=false 2>/dev/null || true

kubectl -n "$NS" delete pod -l app.kubernetes.io/instance="$ADD_DEPLOY" \
  --grace-period=0 --force --wait=false 2>/dev/null || true

wait_no_pods "app.kubernetes.io/instance=$UE_DEPLOY" "$UE_DEPLOY"
wait_no_pods "app.kubernetes.io/instance=$ADD_DEPLOY" "$ADD_DEPLOY"

kubectl -n "$NS" scale deploy/"$GNB_DEPLOY" --replicas=0
wait_no_pods "app.kubernetes.io/instance=$GNB_DEPLOY" "$GNB_DEPLOY"

echo
echo "=== 2. Force Recreate strategy ==="

patch_strategy_recreate "$GNB_DEPLOY"
patch_strategy_recreate "$UE_DEPLOY"

echo
echo "=== 3. Patch gNB resources/lifecycle ==="

GNB_CONTAINER="$(kubectl -n "$NS" get deploy "$GNB_DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].name}')"

kubectl -n "$NS" patch deploy "$GNB_DEPLOY" --type='strategic' -p "{
  \"spec\": {
    \"replicas\": 0,
    \"template\": {
      \"spec\": {
        \"terminationGracePeriodSeconds\": 20,
        \"containers\": [
          {
            \"name\": \"$GNB_CONTAINER\",
            \"resources\": {
              \"requests\": {
                \"cpu\": \"1000m\",
                \"memory\": \"768Mi\"
              },
              \"limits\": {
                \"cpu\": \"2000m\",
                \"memory\": \"1536Mi\"
              }
            }
          }
        ]
      }
    }
  }
}"

echo
echo "=== 4. Patch base UE: one pod, staggered nr-ue startup ==="

UE_CONTAINER="$(kubectl -n "$NS" get deploy "$UE_DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].name}')"

export UE_CONTAINER
export UE_COUNT
export UE_START_DELAY

python3 - <<'PY' >/tmp/ue-stagger-patch.json
import json
import os

container_name = os.environ["UE_CONTAINER"]
ue_count = os.environ["UE_COUNT"]
ue_start_delay = os.environ["UE_START_DELAY"]

startup_script = r'''set -euo pipefail

COUNT="${UE_COUNT:-70}"
DELAY="${UE_START_DELAY:-5}"
BASE="/etc/ueransim/ue.yaml"
CFG_DIR="/tmp/ueransim-staggered"

mkdir -p "$CFG_DIR"

NR_UE_BIN="$(command -v nr-ue || true)"

if [ -z "$NR_UE_BIN" ]; then
  NR_UE_BIN="$(find / -type f -name nr-ue -perm -111 2>/dev/null | head -n 1)"
fi

if [ -z "$NR_UE_BIN" ]; then
  echo "ERROR: nr-ue binary not found"
  exit 1
fi

GNB_IP="$(getent hosts "$GNB_HOSTNAME" | sed -n '1s/[[:space:]].*//p')"

if [ -z "$GNB_IP" ]; then
  echo "ERROR: cannot resolve GNB_HOSTNAME=$GNB_HOSTNAME"
  exit 1
fi

if [ ! -f "$BASE" ]; then
  echo "ERROR: missing UE config: $BASE"
  exit 1
fi

echo "STAGGERED_UE_START count=$COUNT delay=$DELAY gnb=$GNB_HOSTNAME gnb_ip=$GNB_IP bin=$NR_UE_BIN"

cleanup() {
  echo "Stopping nr-ue processes"
  pkill -TERM nr-ue 2>/dev/null || true
  sleep 5
  pkill -KILL nr-ue 2>/dev/null || true
  exit 0
}

trap cleanup TERM INT

i=0

while [ "$i" -lt "$COUNT" ]; do
  MSISDN="$(printf '%010d' "$((1 + i))")"
  IMSI="99970${MSISDN}"
  CFG="$CFG_DIR/ue-$i.yaml"

  sed \
    -e "s#\${GNB_IP}#$GNB_IP#g" \
    -e "s#^[[:space:]]*supi:.*#supi: 'imsi-${IMSI}'#" \
    "$BASE" > "$CFG"

  if grep -q '^tunName:' "$CFG"; then
    sed -i "s#^tunName:.*#tunName: 'uesimtun${i}'#" "$CFG"
  else
    printf "\ntunName: 'uesimtun%s'\n" "$i" >> "$CFG"
  fi

  echo "START_UE idx=$i imsi=$IMSI tun=uesimtun$i"

  "$NR_UE_BIN" -c "$CFG" > "/tmp/nr-ue-$i.log" 2>&1 &

  i="$((i + 1))"
  sleep "$DELAY"
done

echo "ALL_UE_PROCESSES_LAUNCHED"

while true; do
  RUNNING="$(pgrep -x nr-ue | wc -l | tr -d ' ')"
  TUNNELS="$(ip -o -4 addr show | grep -E ' uesimtun[0-9]+ ' | wc -l | tr -d ' ')"
  echo "UE_STATUS running=$RUNNING tunnels=$TUNNELS"
  sleep 30
done
'''

patch = {
    "spec": {
        "replicas": 0,
        "template": {
            "spec": {
                "terminationGracePeriodSeconds": 30,
                "containers": [
                    {
                        "name": container_name,
                        "command": ["/bin/bash", "-lc"],
                        "args": [startup_script],
                        "env": [
                            {"name": "GNB_HOSTNAME", "value": "ueransim-gnb"},
                            {"name": "UE_COUNT", "value": ue_count},
                            {"name": "UE_START_DELAY", "value": ue_start_delay}
                        ],
                        "resources": {
                            "requests": {
                                "cpu": "1500m",
                                "memory": "1024Mi"
                            },
                            "limits": {
                                "cpu": "3000m",
                                "memory": "2048Mi"
                            }
                        }
                    }
                ]
            }
        }
    }
}

print(json.dumps(patch))
PY

kubectl -n "$NS" patch deploy "$UE_DEPLOY" --type='strategic' -p "$(cat /tmp/ue-stagger-patch.json)"

echo
echo "=== 5. Restart AMF/SMF to remove stale RAN contexts ==="

kubectl -n "$NS" rollout restart deploy/"$AMF_DEPLOY"
kubectl -n "$NS" rollout restart deploy/"$SMF_DEPLOY"

kubectl -n "$NS" rollout status deploy/"$AMF_DEPLOY" --timeout=240s
kubectl -n "$NS" rollout status deploy/"$SMF_DEPLOY" --timeout=240s

echo
echo "=== 6. Start clean gNB ==="

kubectl -n "$NS" scale deploy/"$GNB_DEPLOY" --replicas=1
kubectl -n "$NS" rollout status deploy/"$GNB_DEPLOY" --timeout=240s

GNB_POD="$(kubectl -n "$NS" get pod \
  -l app.kubernetes.io/instance="$GNB_DEPLOY" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')"

GNB_STARTED="$(kubectl -n "$NS" get pod "$GNB_POD" \
  -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}')"

echo "GNB_POD=$GNB_POD"
echo "GNB_STARTED=$GNB_STARTED"

echo
echo "=== 7. Start base UE with staggered registration ==="

kubectl -n "$NS" scale deploy/"$UE_DEPLOY" --replicas=1
kubectl -n "$NS" rollout status deploy/"$UE_DEPLOY" --timeout=240s

UE_POD="$(kubectl -n "$NS" get pod \
  -l app.kubernetes.io/instance="$UE_DEPLOY" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')"

echo "UE_POD=$UE_POD"

echo
echo "=== 8. Watch registration without traffic scan ==="

TUNNELS="0"

for i in $(seq 1 120); do
  GNB_RESTARTS="$(kubectl -n "$NS" get pod "$GNB_POD" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}')"

  GNB_NOW_STARTED="$(kubectl -n "$NS" get pod "$GNB_POD" \
    -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}')"

  TUNNELS="$(kubectl -n "$NS" exec "$UE_POD" -- sh -lc \
    "ip -o -4 addr show | grep -E ' uesimtun[0-9]+ ' | wc -l | tr -d ' '")"

  echo "REGISTER_STATUS tunnels=$TUNNELS gnb_restarts=$GNB_RESTARTS"

  if [ "$GNB_RESTARTS" != "0" ] || [ "$GNB_NOW_STARTED" != "$GNB_STARTED" ]; then
    echo "ERROR: gNB restarted during staggered UE attach"
    echo "=== Previous gNB logs ==="
    kubectl -n "$NS" logs "$GNB_POD" --previous 2>/dev/null | tail -120 || true
    exit 1
  fi

  if [ "$TUNNELS" = "$UE_COUNT" ]; then
    break
  fi

  sleep 10
done

if [ "$TUNNELS" != "$UE_COUNT" ]; then
  echo "ERROR: expected $UE_COUNT tunnels, got $TUNNELS"
  kubectl -n "$NS" logs "$UE_POD" --tail=120 || true
  exit 1
fi

echo
echo "=== 9. Final RAN state ==="

kubectl -n "$NS" get pod -o wide | grep -E 'NAME|ueransim-gnb|ueransim-gnb-ues|open5gs-amf|open5gs-smf'

echo
echo "=== 10. Recent gNB errors ==="

kubectl -n "$NS" logs "$GNB_POD" --since=10m | \
  egrep -i 'abort|core dumped|terminate|unknown-local-UE-NGAP-ID|Association terminated|UE context not found|signal lost|error|warn' || true

echo
echo "=== Staggered UE startup applied ==="
