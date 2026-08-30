#!/usr/bin/env python3
"""フェーズ1: collect-etcd-metrics.sh が集めた記録を判定に使える形に落とす。

    ./analyze-etcd-metrics.py <収集ディレクトリ>

主判定（leader_changes / proposals_failed）と副判定（fsync と commit の分位点）を
plan.md の「合否基準」の並びで出す。
"""
import sys
import os
from collections import defaultdict

# etcd のヒストグラムのバケット境界は 2 のべき乗で刻まれており、10ms の境界を持たない。
# plan.md の「10ms 超」に最も近い実測可能な境界は 8ms である。
NEAR_10MS = 0.008


def parse(path):
    """metrics.tsv を {ts: {node: {metric: {labels: value}}}} に読み込む。"""
    snaps = defaultdict(lambda: defaultdict(lambda: defaultdict(dict)))
    if not os.path.exists(path):
        sys.exit(f"見つかりません: {path}")
    with open(path) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 3:
                continue
            ts, node, sample = parts
            name, _, value = sample.rpartition(" ")
            if "{" in name:
                name, _, labels = name.partition("{")
                labels = labels.rstrip("}")
            else:
                labels = ""
            try:
                snaps[ts][node][name][labels] = float(value)
            except ValueError:
                continue
    return snaps


def bucket_delta(first, last):
    """2 スナップショット間のバケット差分を [(le, 累積数), ...] で返す。"""
    out = []
    for labels, end in last.items():
        le = labels.split("le=")[-1].strip('"')
        start = first.get(labels, 0.0)
        out.append((float("inf") if le == "+Inf" else float(le), end - start))
    return sorted(out)


def quantile(buckets, q):
    """累積ヒストグラムから分位点を線形補間で求める（Prometheus と同じ方式）。"""
    if not buckets:
        return None
    total = buckets[-1][1]
    if total <= 0:
        return None
    target = q * total
    prev_le, prev_count = 0.0, 0.0
    for le, count in buckets:
        if count >= target:
            if le == float("inf"):
                return prev_le  # +Inf バケットに落ちた場合は下限しか言えない
            if count == prev_count:
                return le
            return prev_le + (le - prev_le) * (target - prev_count) / (count - prev_count)
        prev_le, prev_count = le, count
    return None


def over(buckets, threshold):
    """threshold を超えた観測数。"""
    total = buckets[-1][1] if buckets else 0
    under = 0.0
    for le, count in buckets:
        if le <= threshold:
            under = count
    return total - under


def ms(v):
    return "—" if v is None else f"{v * 1000:.2f}ms"


def report_hist(title, first, last, thresholds=()):
    b = bucket_delta(first, last)
    total = b[-1][1] if b else 0
    if total <= 0:
        print(f"  {title}: 観測なし")
        return
    # バケットは累積なので、全件を含む最小の境界が最大値の最も厳しい上限になる。
    top = next((le for le, c in b if c >= total and le != float("inf")), None)
    print(f"  {title}")
    print(f"    観測数        {int(total)}")
    print(f"    p50 / p99     {ms(quantile(b, 0.50))} / {ms(quantile(b, 0.99))}")
    print(f"    p99.9         {ms(quantile(b, 0.999))}")
    if top is None:
        print("    最大          最上位バケットを超えた観測がある")
    else:
        print(f"    最大          {ms(top)} 以下")
    for th in thresholds:
        n = over(b, th)
        print(f"    {ms(th) + ' 超':<14}{int(n)} 件 ({n / total * 100:.3f}%)")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    d = sys.argv[1]
    snaps = parse(os.path.join(d, "metrics.tsv"))
    if not snaps:
        sys.exit("メトリクスが記録されていません")

    times = sorted(snaps)
    nodes = sorted({n for t in times for n in snaps[t]})
    print(f"収集期間  {times[0]} 〜 {times[-1]}  (スナップショット {len(times)} 点)")
    print(f"ノード    {', '.join(nodes)}")

    for node in nodes:
        present = [t for t in times if node in snaps[t]]
        if len(present) < 2:
            print(f"\n[{node}] スナップショットが2点未満のため差分を取れません")
            continue
        first, last = snaps[present[0]][node], snaps[present[-1]][node]
        print(f"\n[{node}]")

        print("  主判定")
        for name in ("etcd_server_leader_changes_seen_total",
                     "etcd_server_proposals_failed_total"):
            a = first.get(name, {}).get("", 0.0)
            b = last.get(name, {}).get("", 0.0)
            delta = b - a
            flag = "" if delta == 0 else "  ← 増加"
            reset = "  (カウンタが巻き戻っています。etcd の再起動を疑う)" if b < a else ""
            print(f"    {name.replace('etcd_server_', ''):28} 期間中の増加 {int(delta)}"
                  f" (現在値 {int(b)}){flag}{reset}")

        print("  副判定")
        report_hist("wal_fsync",
                    first.get("etcd_disk_wal_fsync_duration_seconds_bucket", {}),
                    last.get("etcd_disk_wal_fsync_duration_seconds_bucket", {}),
                    thresholds=(NEAR_10MS, 0.016, 0.032, 0.064, 0.128))
        report_hist("backend_commit",
                    first.get("etcd_disk_backend_commit_duration_seconds_bucket", {}),
                    last.get("etcd_disk_backend_commit_duration_seconds_bucket", {}),
                    thresholds=(0.025,))
        peer_first = first.get("etcd_network_peer_round_trip_time_seconds_bucket", {})
        if peer_first:
            report_hist("peer_rtt", peer_first,
                        last.get("etcd_network_peer_round_trip_time_seconds_bucket", {}))

        # 外れ値が「いつ」出たかを見る。判定を分けるのは最大値ではなく頻度と分布である。
        spikes = []
        for a, b in zip(present, present[1:]):
            d_b = bucket_delta(snaps[a][node].get("etcd_disk_wal_fsync_duration_seconds_bucket", {}),
                               snaps[b][node].get("etcd_disk_wal_fsync_duration_seconds_bucket", {}))
            n = over(d_b, NEAR_10MS) if d_b else 0
            if n > 0:
                spikes.append((b, int(n), int(d_b[-1][1])))
        if spikes:
            print(f"  {ms(NEAR_10MS)} 超が出た区間 ({len(spikes)}/{len(present) - 1})")
            for ts, n, tot in spikes[:20]:
                print(f"    {ts}  {n} / {tot} 件")
            if len(spikes) > 20:
                print(f"    ... 他 {len(spikes) - 20} 区間")
        else:
            print(f"  {ms(NEAR_10MS)} 超は全区間で発生していません")

    vip = os.path.join(d, "vip.tsv")
    if os.path.exists(vip):
        holder, moves = None, []
        with open(vip) as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) != 3 or p[2] != "yes":
                    continue
                if holder != p[1]:
                    moves.append((p[0], holder, p[1]))
                    holder = p[1]
        print("\nVIP の保持")
        if len(moves) <= 1:
            print(f"  {holder} が保持したまま移動なし")
        else:
            for ts, old_n, new_n in moves[1:]:
                print(f"  {ts}  {old_n} -> {new_n}")
            print("  VIP は etcd のリーダー選出で移る。leader_changes と突き合わせること。")

    links = os.path.join(d, "links.tsv")
    if os.path.exists(links):
        seen, flaps = {}, []
        with open(links) as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) != 6:
                    continue
                ts, node, iface, ver, state, drv = p
                key = (node, iface)
                if key in seen and seen[key] != (ver, state):
                    flaps.append((ts, node, iface, drv, seen[key], (ver, state)))
                seen[key] = (ver, state)
        print("\nリンクの変化")
        if flaps:
            for ts, node, iface, drv, old, new in flaps:
                print(f"  {ts}  {node} {iface} ({drv})  version/state "
                      f"{old[0]}/{old[1]} -> {new[0]}/{new[1]}")
            print("  リーダー選出が起きている場合、同時刻に変化がないか突き合わせること。")
        else:
            print("  監視対象のリンクに変化なし")


if __name__ == "__main__":
    main()
