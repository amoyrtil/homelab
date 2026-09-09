# Longhorn を Talos に入れる

リハーサルの R5 の記録である。
Longhorn をワーカーにのみ展開し、レプリカ1で PVC が使えるところまでを通した。

実施は 2026年9月9日、Longhorn 1.12.1 と Talos v1.14.0 のコントロールプレーン1台ワーカー1台の構成である。

## kubelet に /var/lib/longhorn を bind mount する

Talos の kubelet はコンテナとして動くため、ホストのパスが自動では見えない。
Longhorn は `/var/lib/longhorn` にデータを置き、CSI が作ったマウントを kubelet へ伝播させる必要がある。
このため、kubelet の `extraMounts` に bind mount を足す。

```yaml
# talconfig.yaml
worker:
  patches:
    - |-
      machine:
        kubelet:
          extraMounts:
            - destination: /var/lib/longhorn
              type: bind
              source: /var/lib/longhorn
              options:
                - bind
                - rshared
                - rw
```

`rshared` が要る理由は、Longhorn 側で作られたマウントを kubelet 側へ伝えるためである。
`rw` と `bind` だけでは、マウントの作成が kubelet から見えない。

パスは Helm の `defaultSettings.defaultDataPath` と揃える。
片方だけ変えると、Longhorn がデータを置く場所と kubelet に見えている場所がずれる。

### 適用に再起動は要らない

`talosctl apply-config` は kubelet の再起動だけで済んだ。

```
$ talosctl -n 192.168.20.41 apply-config -f talos/clusterconfig/homelab-worker-1.yaml
Applied configuration without a reboot
```

適用前に `--dry-run` を付けると、再起動の要否と設定の差分が両方出る。
ノードの設定を変えるときは先にこれを見る。

```
Dry run summary:
Applied configuration without a reboot (skipped in dry-run).
Config diff:
...
```

Node は両方とも `Ready` のままで、Cilium の BGP セッションも切れなかった。

## コントロールプレーンへの展開は taint に任せる

Longhorn チャートの `taintToleration` は既定が空である。
`allowSchedulingOnControlPlanes` が `false` であればコントロールプレーンに `node-role.kubernetes.io/control-plane:NoSchedule` が付いているため、**何も指定しなければワーカーにしか載らない**。

`nodeSelector` を書く必要はない。

実際、19個の Pod がすべて worker-1 に載り、cp-1 には1つも載らなかった。

```
$ kubectl -n longhorn-system get pods --field-selector spec.nodeName=cp-1
No resources found in longhorn-system namespace.
```

コントロールプレーンにワークロードを載せる構成に変える場合は、ここが逆に働く。
その場合は `longhornManager` などに明示的な `nodeSelector` を足して、ワーカーに限定し直すことになる。

## namespace に privileged を与える

Talos は Pod Security Admission を既定で `baseline` に設定する。
Longhorn は特権コンテナを使うため、namespace に `privileged` を与えないと Pod が作られない。

```bash
kubectl create namespace longhorn-system
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged
```

`enforce` だけでも動くが、`audit` と `warn` を揃えないと Pod を作るたびに警告が出る。

## PVC を使う側は fsGroup が要る

Longhorn が作るボリュームは root 所有である。
非 root で動く Pod からは、`fsGroup` を与えないと書き込めない。

```
dd: can't open '/data/test.bin': Permission denied
```

Pod 側に `securityContext.fsGroup` を置くと、CSI がマウント時に所有権を合わせる。
コンテナの `securityContext` ではなく Pod の `securityContext` に置く。

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
```

Longhorn 固有の話ではなく、非 root の Pod がブロックボリュームを使うときに共通して要る。

## 実測値

| 確認項目 | 結果 |
| --- | --- |
| 適用時の再起動 | 不要（`Applied configuration without a reboot`） |
| Pod の配置 | 19個すべて worker-1。cp-1 は0件 |
| `nodes.longhorn.io` | `READY: True`、`SCHEDULABLE: True` |
| ディスクの認識 | `/var/lib/longhorn`、244.0 GB 利用可能 / 253.6 GB |
| StorageClass | `longhorn`（default）と `longhorn-static` |
| PVC の払い出し | `Bound`、1Gi |
| 書き込み | 64MB を 239.2 MB/s |
| Pod 作り直し後 | md5 が一致。データは残る |
| レプリカ | 1本、worker-1 上で `running` |
| Cilium への影響 | BGP セッションは維持。Node は両方 `Ready` |

書き込み速度はテスト Pod から `dd` で1回測った値であり、ベンチマークではない。
DS923+ との実効スループットの測定は [plan.md](../plan.md) の「いずれ回収する項目」に残してある。

## フェーズ2で変えるもの

`defaultReplicaCount` は 1 にしてある。
ワーカーが MS-03 の1台だけであり、レプリカを増やしても同じディスクに載るためである。

S100-WLP をワーカーとして足す段で 2 に上げる。
そのとき S100-WLP 側の schematic には `iscsi-tools` と `util-linux-tools` が要る。
素の schematic のままでは Longhorn のノードとして登録されない。
