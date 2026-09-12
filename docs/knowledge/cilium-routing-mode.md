# Cilium の routing mode を native にする

R9 の監査で、Cilium が既定の VXLAN のまま動いていることが分かった。
ノードは全台 VLAN 20 の同一 L2 にいて BGP も張っており、カプセル化する理由が構成の側に無い。
リハーサル環境で native に切り替えて測った記録である。

実施は 2026年9月11日、Talos v1.14.0 と Cilium v1.20.1 の cp-1 + worker-1 の構成である。

## 決定が存在しないまま既定値が設計になっていた

design.md は「Cilium。kube-proxy を完全に置換し、eBPF モードで動かす」としか書いておらず、routing mode の記述が無かった。
`cilium-config` を読むまで、何で動いているかを誰も見ていない状態だった。

```console
$ kubectl -n kube-system get cm cilium-config -o json | jq -r '.data'
routing-mode            = tunnel
tunnel-protocol         = vxlan
auto-direct-node-routes = false
```

**判断した形跡が無いものが、実質的な設計になっていた。**
R9 が拾ったのはこの類の項目が多い。

## 実測

`routingMode: native`、`autoDirectNodeRoutes: true`、`ipv4NativeRoutingCIDR: 10.244.0.0/16` の3つを足して `helm upgrade` した。

| 確認項目 | vxlan | native |
| --- | --- | --- |
| Pod の `eth0` MTU | 1500 | 1500 |
| **経路の実効 MTU** | **1450** | **1500** |
| **断片化しない最大ペイロード** | **1422 B** | **1472 B** |
| Pod 間 RTT 平均（50回） | 0.673 ms | 0.642 ms |
| スループット（iperf3 10秒） | 91.8 Mbps | 95.0 Mbps |
| BGP ピア | established | established（張り直し） |
| Gateway internal / external | 301 / 404 | 301 / 404 |
| インターネット経由の到達 | — | `HTTP 404`（Edge からオリジンまで到達） |
| Longhorn | 19 Pod Running | 19 Pod Running |
| Kustomization | 全 `True` | 全 `True` |
| Hubble の drop | — | Pod 間・ポリシーの drop なし |

**Pod の `eth0` は両方とも 1500 を出す。**
差が出るのは経路のほうである。

```console
$ kubectl -n nettest exec probe-worker -- ip route get 10.244.0.117
# vxlan
10.244.0.117 via 10.244.1.166 dev eth0 src 10.244.1.47
    cache mtu 1450
# native
10.244.0.117 via 10.244.1.166 dev eth0 src 10.244.1.47
    cache mtu 1500
```

インターフェースの MTU だけを見ると差が無いように見える。
`ip route get` か、DF ビットを立てた `ping -M do -s <size>` で測る。

## autoDirectNodeRoutes はホストの経路表に入る

native routing だけでは、相手ノードの PodCIDR への経路が生まれない。
`autoDirectNodeRoutes` がそれを入れる。

```console
$ talosctl -n 192.168.20.41 get routes | grep 10.244.0.0/24
inet4/192.168.20.31/10.244.0.0/24/0   10.244.0.0/24   192.168.20.31   eno4np0
```

worker-1 が「cp-1 の PodCIDR は cp-1 の実 IP へ、`eno4np0` から直接」という経路を持っている。
ルーターは関与しない。

**この機構はノードが同一 L2 にあることを要求する。**
Kubernetes ノードを全台 VLAN 20 に置く設計は、L3 転送を避けるという別の根拠で決めたものだが（[design-rationale.md](design-rationale.md)）、ここでも効いている。
将来ノードを別 VLAN に分けるなら、`autoDirectNodeRoutes` は使えなくなり、PodCIDR を BGP で広告するか VXLAN に戻すかの判断になる。

## リハーサル環境ではスループットを測れない

`+3.5%` という差が出たが、この値は評価できない。

```console
$ talosctl -n 192.168.20.31 get links -o yaml | grep -A1 r8152
    driver: r8152
    speedMbit: 100
```

cp-1 は USB Ethernet ドングルで繋いでおり、リンクが 100 Mbit である。
カプセル化の有無に関わらず、そこが上限になる。

**測れなかったことを、測った結果として残す。**
10GbE 同士のノードで初めて意味のある差が出る。
本番で MS-03 と EliteDesk を繋いだあとに測り直す価値がある。

## 稼働中に変えるとデータプレーンが途切れる

切り替えのコストも測れた。

| 事象 | 結果 |
| --- | --- |
| ロールアウト中の Pod 間 ping | 20回中2回ロス（10%） |
| 落ち着いたあとの ping | 50回中0回ロス |
| BGP セッション | uptime が 43時間から 0 に戻る |
| Longhorn、Flux、トンネル | 影響なし |

`rollOutCiliumPods` と `operator.rollOutPods` と `envoy.rollOutPods` が有効なため、`helm upgrade` がそのままロールアウトになった。
R4 で入れたこの3つが意図どおり働いている。

**クラスターを組むときに入れる。**
`cniConfig: none` のように後から変えられないわけではないが、変えれば必ず途切れる。

## "Direct Routing" の表示は routing mode ではない

`cilium-dbg status` は2箇所に紛らわしい語を出す。

```
KubeProxyReplacement:  True   [eno4np0  192.168.20.41 ... (Direct Routing)]
Routing:               Network: Native   Host: Legacy
```

**1行目の `(Direct Routing)` は kube-proxy 置換のバックエンド到達方式である。**
Pod ネットワークの routing mode は2行目の `Network:` にしか出ない。
VXLAN で動いていたときも1行目は `(Direct Routing)` のままだった。

[service-exposure.md](service-exposure.md) がこの読み違いを指摘しており、今回 native と vxlan の両方で見て確定した。
plan.md の R2 結果表にあった「`True`（Direct Routing）」の記述は、この監査で訂正した。

## 測り方

計測用の Pod を2ノードに1つずつ置く。
コントロールプレーンには taint があるため、`toleration` が要る。

```yaml
spec:
  nodeSelector: { kubernetes.io/hostname: cp-1 }
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
```

**ワーカーが1台しかないと、ノードをまたぐ経路を測れない。**
`allowSchedulingOnControlPlanes` が `false` である限り、普通に置いた Pod は2つとも worker-1 に載る。
Pod 間の経路を測るときは、この `toleration` で意図的にコントロールプレーンへ送る。
