#!/usr/bin/env bash
# フェーズ1: etcd メトリクスとリンク状態の継続記録
#
#   ./collect-etcd-metrics.sh <出力ディレクトリ> [間隔秒] [ノードIP...]
#
# 例: ./collect-etcd-metrics.sh runs/step3-load 15 192.168.20.31 192.168.20.32
#
# Ctrl-C で停止する。解析は analyze-etcd-metrics.py に渡す。
set -uo pipefail

OUT="${1:?出力ディレクトリを指定してください}"
INTERVAL="${2:-15}"
shift 2 2>/dev/null || shift $# 
NODES=("$@")
[ ${#NODES[@]} -eq 0 ] && NODES=(192.168.20.31)

mkdir -p "$OUT"
METRICS="$OUT/metrics.tsv"
LINKS="$OUT/links.tsv"
VIPLOG="$OUT/vip.tsv"

# Talos VIP は etcd のリーダー選出でノード間を移る。
# つまり VIP の移動そのものが fsync 遅延の影響を受ける可観測な挙動になる。
VIP_ADDR="${VIP_ADDR:-192.168.20.100}"

# 記録するメトリクスを絞る。全文だと1回 170KB を超えて解析が重くなる。
FILTER='^etcd_disk_wal_fsync_duration_seconds_(bucket|sum|count)'
FILTER="$FILTER"'|^etcd_disk_backend_commit_duration_seconds_(bucket|sum|count)'
FILTER="$FILTER"'|^etcd_network_peer_round_trip_time_seconds_(bucket|sum|count)'
FILTER="$FILTER"'|^etcd_server_(leader_changes_seen_total|proposals_failed_total|proposals_pending|proposals_committed_total|has_leader|is_leader)'
FILTER="$FILTER"'|^etcd_mvcc_db_total_size_in_bytes'

echo "収集開始 ノード=${NODES[*]} 間隔=${INTERVAL}s 出力=$OUT"
echo "停止は Ctrl-C。"

while true; do
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for n in "${NODES[@]}"; do
    curl -s --max-time 5 "http://${n}:2381/metrics" \
      | grep -E "$FILTER" \
      | awk -v ts="$TS" -v node="$n" '{print ts "\t" node "\t" $0}' >> "$METRICS"

    # リンクのフラップ検出用。LinkStatus の version は状態が変わるたびに増える。
    # yaml 内の出現順は id -> version -> ... -> driver -> ... -> linkState。
    # linkState 行で1リンク分を確定させる。id 行で前のリンクの値をリセットする。
    talosctl -n "$n" get links -o yaml 2>/dev/null \
      | awk -v ts="$TS" -v node="$n" '
          /^    id: /        { id=$2; ver=""; drv=""; next }
          /^    version: /   { if (ver=="") ver=$2; next }
          /^    driver: /    { drv=$2; next }
          /^    linkState: / { if (drv=="r8152" || drv=="igc" || drv=="i40e" || drv=="r8169")
                                 print ts "\t" node "\t" id "\t" ver "\t" $2 "\t" drv }
        ' >> "$LINKS"

    # パイプで grep -q を使うと、マッチ時に talosctl が SIGPIPE で落ちて
    # pipefail がパイプライン全体を失敗と判定してしまう。文字列一致で見る。
    addrs=$(talosctl -n "$n" get addresses 2>/dev/null || true)
    case "$addrs" in
      *"$VIP_ADDR"*) held=yes ;;
      *)             held=no  ;;
    esac
    printf '%s\t%s\t%s\n' "$TS" "$n" "$held" >> "$VIPLOG"
  done
  sleep "$INTERVAL"
done
