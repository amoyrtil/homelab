# Talos の運用で踏んだこと

機種や個別の検証に依らない、Talos そのものの挙動と扱い方の記録である。
どれも実作業でつまずいて調べた結果であり、次に同じ場面に出たときに調べ直さずに済むように残す。

## v1.14 で設定が独立ドキュメントに移った

Talos v1.14 は、これまで `v1alpha1` の `machine` や `cluster` の下にあった設定の一部を、独立した設定ドキュメントに移した。

| 設定 | v1.14 での行き先 |
| --- | --- |
| ホスト名 | `HostnameConfig` |
| ネームサーバー | `ResolverConfig` |
| `deviceSelector` | `LinkAliasConfig` |
| 静的アドレスと経路 | `LinkConfig` |
| VIP | `Layer2VIPConfig` |
| インストール先とイメージ | `UnattendedInstallConfig`（`machine.install` も引き続き受け付ける） |

**同じ設定を v1alpha1 と独立ドキュメントの両方に書くと、適用時に拒否される。**
`talosctl gen config` が出力する新しいドキュメントを残したまま、v1alpha1 側に同じ項目を書くパッチを当てると次のようになる。

```
error applying configuration: rpc error: code = InvalidArgument desc = 3 errors occurred:
	* .machine.network.nameservers is already set in v1alpha1 config
	* static hostname is already set in v1alpha1 config
	* .cluster.allowSchedulingOnControlPlanes is already set in v1alpha1 config
```

`talosctl validate` は静的な検証しか行わないため、この重複を検出しない。
手書きでパッチを当てるときは、どちらか一方に寄せる必要がある。

`cluster.allowSchedulingOnControlPlanes` に対応するのは `KubeNodeConfig` の `taints` である。
コントロールプレーンに Pod を載せたいなら、v1alpha1 のフラグではなく `KubeNodeConfig` から `node-role.kubernetes.io/control-plane: NoSchedule` を外す。

talhelper は 3.1.17 の時点でこの形式に対応している。
リリース日は Talos v1.14.0 より前だが、生成される machine config は新しいドキュメント形式になっており、重複も起こさない。

## インストーラーイメージは Image Factory から取る

v1.14 で `ghcr.io/siderolabs/installer` の公開が止まった。
標準構成であっても Image Factory 経由のイメージが要る。

パスは `metal-installer` である。

```
factory.talos.dev/metal-installer/<schematic-id>:<version>
```

`factory.talos.dev/installer/<schematic-id>` の旧パスも HTTP 200 を返すが、`talosctl gen config` が生成するのは `metal-installer` のほうである。

拡張もカーネル引数も持たない素の schematic の ID は決まっている。

```
376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba
```

`talosctl gen config` の既定値はこの素の schematic を指しており、`--install-disk` は `/dev/sda`、`--kubernetes-version` はその Talos が既定とする版になっている。
拡張が要らないノードでは `--install-image` を明示する必要すらない。

schematic の ID は内容から決まる。
YAML にコメントを足しても ID は変わらず、Talos のバージョンを変えても変わらない。

Image Factory はイメージをオンデマンドでビルドする。
新しい schematic とバージョンの組み合わせを初めて要求すると、拡張5つを含む ISO で5分ほどかかる。
二度目以降はキャッシュが効く。

## reset はシステムディスクを丸ごと消す

`talosctl reset` の `--wipe-mode` は既定が `all` で、システムディスク全体を対象にする。
STATE と EPHEMERAL だけでなく EFI も消えるため、**ファームウェアが起動先を見つけられず UEFI Shell に落ちる**。

ノードを作り直す前提ならこれでよい。
特定のパーティションだけ残したいなら `--system-labels-to-wipe` で明示する。

`--reboot` を付けなければ、reset のあとノードはシャットダウンする。
付けると再起動する。

**machine config も STATE と一緒に消える。**
静的アドレスは machine config が持っているため、reset 後のノードはメンテナンスモードで DHCP に落ちる。
DHCP 予約や払い出し範囲を把握していないと、reset した瞬間にノードを見失う。

`talosctl reset` はノードからの完了通知を待つ。
アドレスが変わって到達できなくなると、ワイプ自体は成立していてもコマンドはハングし続ける。
完了の確認は、他のノードから etcd のメンバー一覧を見るほうが確実である。

## Pod Security Admission が既定で有効

Talos は Pod Security Admission を既定で有効にしており、`default` namespace では `baseline` が強制される。
特権 Pod や `hostPath` ボリュームは拒否される。

```
pods "devcheck" is forbidden: violates PodSecurity "baseline:latest":
host namespaces (hostPID=true), hostPath volumes (volume "dev"),
privileged (container "c" must not set securityContext.privileged=true)
```

`/dev/dri` や `/dev/accel` の確認のように特権が要る作業では、専用の namespace を作ってラベルを付ける。

```bash
kubectl create namespace devcheck
kubectl label namespace devcheck pod-security.kubernetes.io/enforce=privileged
```

## etcd の HTTP エンドポイントが 2383 に移った

v1.14 で etcd が 3.7 系になり、`/metrics`、`/health`、gRPC-gateway の JSON API が専用のリスナー（2383）に移った。
クライアントポート 2379 は gRPC 専用になる。

`--listen-metrics-urls` を明示している場合は移動しない。
2379 をファイアウォールで塞いでいたなら、2383 も塞ぐ必要がある。

## メンテナンスモードのノードは DHCP に依存する

machine config を持たないノード（初回起動、reset 後）は DHCP でアドレスを取る。
このため次の2つが噛み合っていないと、ノードを見失うか、稼働中のノードとアドレスが衝突する。

- **MAC ベースの DHCP 予約**：予約した個体と実際に挿さっている個体が入れ替わると、メンテナンスモードのノードが別ノードのアドレスを取りに行く。稼働中のノードは machine config の静的アドレスで動き続けるため、入れ替えに気付けない。衝突が表面化するのは reset した後である。
- **スイッチポートの VLAN 割り当て**：ポートが目的の VLAN になっていないと、別セグメントの DHCP が応答する。その状態でノード側に目的セグメントの静的アドレスを設定しても、L2 が違うので届かない。

どちらも、どの個体をどこに挿したかを記録していないことが原因になる。
NIC の MAC とスイッチポートの割り当ては、機材の表と一緒に残しておく。

## ノードを探す

アドレスを見失ったときは、Talos API のポートで走査するのが早い。

```bash
for i in $(seq 1 254); do
  ( nc -z -G 1 -w 1 192.168.20.$i 50000 2>/dev/null && echo "192.168.20.$i OPEN" ) &
done
wait
```

VIP を持つノードがあると、VIP のアドレスでもポートが開いて見える。
