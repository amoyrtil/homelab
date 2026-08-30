#!/usr/bin/env bash
# フェーズ1: etcd に持続的な書き込み負荷をかける。
#
#   KUBECONFIG=... ./load-etcd.sh <継続秒数> [並列数] [1バッチのオブジェクト数]
#
# Secret を作っては消すループを並列で回す。
# 負荷生成器は手元の Mac で動かす。コントロールプレーン上に置くと、
# 測定対象のノードに etcd 以外の I/O を足してしまうためである。
set -uo pipefail

DURATION="${1:?継続秒数を指定してください}"
WORKERS="${2:-6}"
BATCH="${3:-20}"
NS="${NS:-etcd-load-test}"

command -v kubectl >/dev/null || { echo "kubectl がありません"; exit 1; }
kubectl get ns >/dev/null || { echo "クラスターに接続できません。KUBECONFIG を確認してください"; exit 1; }

WORK=$(mktemp -d)
END=$(( $(date +%s) + DURATION ))

cleanup() {
  echo
  echo "後始末中..."
  # namespace は消さない。Terminating 中に次の run が始まると apply が失敗するためである。
  kubectl delete secrets -n "$NS" --all --wait=false >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# 1オブジェクトあたり約 2KB。etcd の WAL エントリとして現実的な大きさにする。
PAYLOAD=$(head -c 1500 /dev/urandom | base64 | tr -d '\n')

worker() {
  local id=$1
  local n=0
  local manifest="$WORK/worker-$id.yaml"
  for i in $(seq 1 "$BATCH"); do
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: load-%s-%s\n  namespace: %s\ndata:\n  payload: %s\n---\n' \
      "$id" "$i" "$NS" "$PAYLOAD"
  done > "$manifest"

  while [ "$(date +%s)" -lt "$END" ]; do
    kubectl apply -f "$manifest" >/dev/null 2>&1 || true
    kubectl delete -f "$manifest" --ignore-not-found >/dev/null 2>&1 || true
    n=$(( n + BATCH * 2 ))
  done
  echo "$n" > "$WORK/count-$id"
}

echo "負荷開始  並列=$WORKERS バッチ=$BATCH 継続=${DURATION}s  namespace=$NS"
START=$(date +%s)
for i in $(seq 1 "$WORKERS"); do worker "$i" & done
wait

ELAPSED=$(( $(date +%s) - START ))
TOTAL=$(cat "$WORK"/count-* 2>/dev/null | paste -sd+ - | bc 2>/dev/null || echo 0)
echo "負荷終了  ${ELAPSED}s で ${TOTAL} 書き込み (約 $(( TOTAL / (ELAPSED > 0 ? ELAPSED : 1) )) ops/s)"
