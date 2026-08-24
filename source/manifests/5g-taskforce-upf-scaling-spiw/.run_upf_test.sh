#!/usr/bin/env bash
# keep simple; no -e, but keep -u and pipefail
set -uo pipefail

NAMESPACE="default"
UE_DEPLOY="ueransim-gnb-ues"
UPF_SELECTOR='app.kubernetes.io/instance=open5gs,app.kubernetes.io/name=upf'
VPA_NAME='upf-vpa'
IPERF_SVC="iperf3.default.svc.cluster.local"
DURATION=30
PARALLEL=4
RESULTS="/home/ansible/manifests/5g-taskforce-upf-scaling-spiw/upf_vpa_results.csv"
SETTLE=20

to_bytes() {
  val="$1"
  case "$val" in
    *Ki) echo $(( ${val%Ki} * 1024 ));;
    *Mi) echo $(( ${val%Mi} * 1024 * 1024 ));;
    *Gi) echo $(( ${val%Gi} * 1024 * 1024 * 1024 ));;
    *Ti) echo $(( ${val%Ti} * 1024 * 1024 * 1024 * 1024 ));;
    *K)  echo $(( ${val%K}  * 1000 ));;
    *M)  echo $(( ${val%M}  * 1000 * 1000 ));;
    *G)  echo $(( ${val%G}  * 1000 * 1000 * 1000 ));;
    *T)  echo $(( ${val%T}  * 1000 * 1000 * 1000 * 1000 ));;
    *)   echo "${val}";;
  esac
}

to_millicores() {
  c="$1"
  case "$c" in
    *m) echo "${c%m}" ;;
    *)  awk -v v="$c" 'BEGIN{printf "%.0f", v*1000}' ;;
  esac
}

build_selector() {
  kubectl -n "${NAMESPACE}" get deploy "${UE_DEPLOY}" \
    -o jsonpath='{range $k,$v:=.spec.selector.matchLabels}{printf "%s=%s,", $k, $v}{end}' \
    2>/dev/null | sed 's/,$//'
}

for UE_TARGET in 20 40 60; do
  echo "==> Scaling UEs to ${UE_TARGET}"
  kubectl -n "${NAMESPACE}" scale deploy/"${UE_DEPLOY}" --replicas="${UE_TARGET}"

  # Wait until availableReplicas reaches desired
  for i in $(seq 1 240); do
    avail=$(kubectl -n "${NAMESPACE}" get deploy "${UE_DEPLOY}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "")
    [ -z "$avail" ] && avail=0
    if [ "$avail" -eq "${UE_TARGET}" ]; then
      break
    fi
    sleep 2
  done

  # Give UEs time to attach/register in Open5gs
  sleep "${SETTLE}"

  SEL=$(build_selector)
  [ -z "$SEL" ] && SEL="app=${UE_DEPLOY}"

  # Try to pick a Running UE pod first
  UE_POD=$(kubectl -n "${NAMESPACE}" get pods -l "$SEL" \
             --field-selector=status.phase=Running \
             -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  # If still empty, try without the phase filter
  if [ -z "${UE_POD}" ]; then
    UE_POD=$(kubectl -n "${NAMESPACE}" get pods -l "$SEL" \
               -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  fi

  if [ -z "${UE_POD}" ]; then
    echo "No UE pod found using selector: $SEL ; writing zeros."
    MBPS=0
  else
    # Run iperf3 from the UE pod so traffic traverses UPF
    OUT=$(kubectl -n "${NAMESPACE}" exec "${UE_POD}" -- sh -lc \
          "iperf3 -c ${IPERF_SVC} -t ${DURATION} -P ${PARALLEL}" 2>/dev/null || true)

    MBPS=$(printf "%s\n" "$OUT" \
      | awk '/SUM.*receiver/ {x=$(NF-1);u=$NF} END {if(u=="Mbits/sec") print x; else if(u=="Gbits/sec") print x*1000; else if(u=="Kbits/sec") print x/1000; else print 0}')
    [ -z "$MBPS" ] && MBPS=0
  fi

  # Find current UPF pod
  UPF_POD=$(kubectl -n "${NAMESPACE}" get pods -l "${UPF_SELECTOR}" \
             --field-selector=status.phase=Running \
             -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  # Requests (from spec)
  UPF_REQ_CPU=$(kubectl -n "${NAMESPACE}" get pod "${UPF_POD}" -o jsonpath='{.spec.containers[0].resources.requests.cpu}' 2>/dev/null || echo "")
  UPF_REQ_MEM=$(kubectl -n "${NAMESPACE}" get pod "${UPF_POD}" -o jsonpath='{.spec.containers[0].resources.requests.memory}' 2>/dev/null || echo "")

  # Live usage via kubectl top (fallback to 0/0 if metrics not ready)
  RAW_CPU=$(kubectl -n "${NAMESPACE}" top pod "${UPF_POD}" --containers 2>/dev/null | awk 'NR==2 {print $2}')
  RAW_MEM=$(kubectl -n "${NAMESPACE}" top pod "${UPF_POD}" --containers 2>/dev/null | awk 'NR==2 {print $3}')
  [ -z "$RAW_CPU" ] && RAW_CPU="0m"
  [ -z "$RAW_MEM" ] && RAW_MEM="0Mi"

  CPU_M=$(to_millicores "$RAW_CPU")
  MEM_B=$(to_bytes "$RAW_MEM")

  # VPA target (fallback blanks if not present)
  VPA_T_CPU=$(kubectl -n "${NAMESPACE}" get vpa "${VPA_NAME}" -o jsonpath='{.status.recommendation.containerRecommendations[0].target.cpu}' 2>/dev/null || echo "")
  VPA_T_MEM=$(kubectl -n "${NAMESPACE}" get vpa "${VPA_NAME}" -o jsonpath='{.status.recommendation.containerRecommendations[0].target.memory}' 2>/dev/null || echo "")

  TS=$(date -Iseconds)
  echo "${TS},${UE_TARGET},${MBPS},${UPF_REQ_CPU},${UPF_REQ_MEM},${CPU_M},${MEM_B},${VPA_T_CPU},${VPA_T_MEM}" >> "${RESULTS}"
  echo "Logged row for ${UE_TARGET} UEs"
done
