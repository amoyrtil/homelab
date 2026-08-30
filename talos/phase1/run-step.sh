#!/usr/bin/env bash
# フェーズ1: 定常状態と負荷時を続けて測る。
#
#   KUBECONFIG=... TALOSCONFIG=... ./run-step.sh <ラベル> <定常秒> <負荷秒> <ノードIP...>
#
# runs/<ラベル>-idle と runs/<ラベル>-load に記録する。
# 負荷区間は前後に60秒の無負荷を挟み、立ち上がりと収束を含めて見られるようにする。
set -uo pipefail

LABEL="${1:?ラベルを指定してください}"
IDLE="${2:?定常状態の秒数を指定してください}"
LOAD="${3:?負荷の秒数を指定してください}"
shift 3
NODES=("$@")
[ ${#NODES[@]} -eq 0 ] && NODES=(192.168.20.31)

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNS="$HERE/runs"
mkdir -p "$RUNS"

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }

collector_pid=""
stop_collector() { [ -n "$collector_pid" ] && kill "$collector_pid" 2>/dev/null; collector_pid=""; }
trap 'stop_collector; exit 130' INT TERM

log "=== 定常状態 ${IDLE}s ==="
rm -rf "$RUNS/$LABEL-idle"
"$HERE/collect-etcd-metrics.sh" "$RUNS/$LABEL-idle" 15 "${NODES[@]}" >/dev/null 2>&1 &
collector_pid=$!
sleep "$IDLE"
stop_collector
log "定常状態の記録を終了"

log "=== 負荷 ${LOAD}s ==="
rm -rf "$RUNS/$LABEL-load"
"$HERE/collect-etcd-metrics.sh" "$RUNS/$LABEL-load" 15 "${NODES[@]}" >/dev/null 2>&1 &
collector_pid=$!
sleep 60
"$HERE/load-etcd.sh" "$LOAD" 20 60
sleep 60
stop_collector
log "負荷の記録を終了"

echo
log "=== 定常状態 ==="
"$HERE/analyze-etcd-metrics.py" "$RUNS/$LABEL-idle"
echo
log "=== 負荷時 ==="
"$HERE/analyze-etcd-metrics.py" "$RUNS/$LABEL-load"
