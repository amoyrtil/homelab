# homelab 構築計画

## このドキュメントの位置づけ

homelab に Kubernetes クラスターと GitOps ベースの CI/CD を整備するための**作業計画**である。
いま何をしているか、次に何をするか、何がまだ決まっていないかをここに置く。

すでに決まっている構成 — 機材、ネットワーク、ノードのイメージ、ソフトウェアスタック — は [design.md](design.md) にある。
検証の経過と判断の根拠は [knowledge/](knowledge/) にある。

## 現在地

**リハーサル（手順2）の R7 は手順5まで検証済み。**
手順6（Flux の Webhook Receiver）と証明書の production 切り替えが main へのマージを待っている。
最終更新は 2026年9月9日である。

### いまのクラスターの状態

**クラスターは起動している。**

| ノード | 機器 | アドレス | 役割 |
| --- | --- | --- | --- |
| cp-1 | S100-WLP（morty） | 192.168.20.31 | コントロールプレーン |
| worker-1 | MS-03 | 192.168.20.41 | ワーカー |
| VIP | — | 192.168.20.100 | Kubernetes API エンドポイント |

入っているものは Talos v1.14.0、Kubernetes v1.37.0、Cilium v1.20.1（kube-proxy 置換、L7 proxy、Gateway API、BGP Control Plane）である。
`allowSchedulingOnControlPlanes` は `false` にしてある。
`GatewayClass`、`CiliumLoadBalancerIPPool`（`192.168.120.100-250`）、BGP の3リソースが載っている。
`CiliumL2AnnouncementPolicy` は R4 で削除した。
Longhorn 1.12.1 が `longhorn-system` に入っており、worker-1 のみに展開されている。
Flux が `flux-system` で動き、`kubernetes/` 以下を同期している。Longhorn はその管理下にある。
cert-manager 1.21.1 が `cert-manager` に入り、Let's Encrypt の ClusterIssuer を staging と production の2本持っている。
`network` には Gateway が2本（internal が `192.168.120.101`、external が `192.168.120.100`）、cloudflared、external-dns の Cloudflare 系統が入っている。
ワイルドカード証明書は `network` の `wildcard-tls` にある。
検証に使ったリソースは削除済みで、`default` namespace は空である。

**手でクラスターに入れたものは3つある。**
Cilium の Helm リリース、flux-operator の Helm リリース、`sops-age` Secret である。
残りは Flux が Git から反映する。
クラスターを作り直すときの順序は [knowledge/cluster-bootstrap-order.md](knowledge/cluster-bootstrap-order.md) にまとめてある。

cp-1 は USB Ethernet ドングル（`r8152`、MAC `6c:1f:f7:d3:99:42`）で接続している。
S100-WLP は3台のうち2台の内蔵 I226-V に物理層障害があり、そのための回避策である。

これはリハーサル環境であり、EliteDesk 到着後に本番として組み直す。
クラスター名もノード名も暫定のままでよい。

### いまのネットワークの状態

VLAN 設計は実装の途中である。
作業端末は VLAN 1（`192.168.1.0/24`）にいて、VLAN 20 と VLAN 120 だけが先に切られている。

| 済んだこと | 内容 |
| --- | --- |
| VLAN 20 | 作成済み。DHCP プールを `.150-250` に拡張済み |
| VLAN 120 | 作成済み。ゲートウェイ `192.168.120.1` に作業端末から到達を確認 |
| BGP | UCG-Fiber に FRR 設定を投入済み（UniFi 上の名前は `Blackwall-BGP`）。worker-1 とのピアが確立している |

VLAN 10、30、40、50、60 は未着手である。
DHCP Guarding も入れていない。VLAN 120 は対象外でよいが、機器を収容する VLAN では有効にする価値がある（特に部屋の LAN ドロップがある VLAN 30 とゲスト用の VLAN 60）。

### 次にやること

**R7: cert-manager、Cloudflare Tunnel、external-dns（Cloudflare 系統のみ）。**

対象ドメインは `kaeritei.com` である。
ゾーンは Cloudflare に委任済みで、`cheryl.ns.cloudflare.com` と `mark.ns.cloudflare.com` が権威応答を返す。
リポジトリが public のため、ドメイン名は SOPS で暗号化した `cluster-secrets` に置き、各 Kustomization の `postBuild` で `${SECRET_DOMAIN}` として展開する。

手順を6段に分けた。

| # | 内容 | 状態 |
| --- | --- | --- |
| 1 | `cluster-secrets` と、入口 Kustomization に復号を足す FluxInstance のパッチ | 書いた |
| 2 | cert-manager と ClusterIssuer（staging と production） | 書いた |
| 3 | Gateway 本体と証明書 | 書いた |
| 4 | cloudflared。ingress ルールは ConfigMap に置く | 書いた |
| 5 | external-dns（Cloudflare 系統） | 書いた |
| 6 | Flux の Webhook Receiver | 書いた。マージ待ち |

Cloudflare の API トークンとトンネルの認証情報は SOPS で暗号化して `kubernetes/` に置いた。
トークンは `Zone:DNS:Edit` と `Zone:Zone:Read` を `kaeritei.com` だけに絞ってある。
ACME のメールアドレスは使わない。Let's Encrypt は有効期限の通知メールを廃止しており、省略しても証明書は取れる。

**Gateway は internal と external の2本に分けた。**
公開のスイッチを `HTTPRoute` の `parentRefs` に持たせるためである。
external-dns（Cloudflare 系統）は `homelab/scope=external` の Gateway に繋がった `HTTPRoute` だけを見るため、そこに繋がないサービスは公開 DNS に載らない。
internal は宅内からの経路で、TLS を Gateway 自身が終端する。
external は Cloudflare Edge が TLS を終端するため listener は HTTP だけでよい。

**証明書は staging で1回通してから production に切り替える。**
Let's Encrypt の production はレート制限が厳しく、設定を誤ると週次の上限を使い切る。
staging での発行を確認したため、`Certificate` の `issuerRef` は production に変えた。

**cloudflared の egress を絞る NetworkPolicy は R7 に含めない。**
Cilium の Gateway API はデータプレーンが Pod endpoint ではないため、`CiliumNetworkPolicy` で外部 Gateway だけを許可する書き方を確かめる必要がある。
トンネルが通ることを確認したあとに、単独で検証して入れる。

**Tunnel は CLI で作る。**
Terraform への移行は R8 に置いた。CLI で作ったトンネルは後から import できるため、二重には作らない（[knowledge/terraform-provisioning.md](knowledge/terraform-provisioning.md)）。

**external-dns の Pi-hole 系統は R7 の範囲外とする。**
内部 DNS が待機系を持たないうちに宅内の名前解決をクラスターに寄せると、クラスターの停止が家中に波及する。
着手の条件はフェーズ1の作業項目に書いた。

Flux の Webhook Receiver を R7 に含めるのは、GitHub の push を直接受けるには受け口を外に出す必要があり、Cloudflare Tunnel が前提になるためである。
それまではポーリングで反映される。

### 作業の進め方

- [x] **1. テンプレートの評価** — `onedr0p/cluster-template` を採用するか判断する。記録は [knowledge/cluster-template-evaluation.md](knowledge/cluster-template-evaluation.md)
- [ ] **2. リハーサル** — いま動いているクラスターで、フェーズ1の構成を通す。R1 から R6 まで完了し、R7 に着手した。詳細は「[リハーサル](#リハーサル)」節
- [ ] **3. 知見の集約** — 2 の結果を `knowledge/` に記録する。R1 から R6 の分は [knowledge/](knowledge/) に反映済み
- [ ] **4. 規約の整備** — 命名規則など homelab 全体のルールを決め、プロジェクトルートの `CLAUDE.md` を更新する
- [ ] **5. フェーズ1の構築** — EliteDesk 到着後、クラスターを本番として組み直す。UniFi と Cloudflare は R8 で書いた Terraform の構成をそのまま使う

### 作業環境

ツールは `mise` で固定している。リポジトリのルートで `mise install` を実行すれば揃う。
`KUBECONFIG` と `TALOSCONFIG` も `.mise/config.toml` で設定しているため、`cd` するだけで接続先がそろう。

`talos/clusterconfig/` は gitignore 対象である。
消えている場合は `cd talos && talhelper genconfig` で再生成する。

## リハーサル

EliteDesk 800 G6 の到着を待つあいだ、S100-WLP + MS-03 のクラスターでフェーズ1の構成を通す。
目的は手順とハマりどころを洗い出すことであり、成果物は `knowledge/` に残す。

R1 から R4 までで踏んだ落とし穴は、**いずれも Cilium 側にあった**。
`bpf.autoMount.enabled` を無効にすると `cilium-envoy` から BPF マップが見えなくなる件、Gateway API の CRD が experimental チャネルを要求する件、values を変えても Pod が入れ替わらない件の3つである。
どれも [knowledge/talos-operations.md](knowledge/talos-operations.md) に記録した。

クラスター名とノード名は現状のまま（`homelab`、`cp-1`、`worker-1`）で進める。
命名規約は手順4で整理するため、ここでは触らない。

**検証したことは、通るたびに `knowledge/` へ書き出す。**
セッションが切れても再開できるよう、チェックボックスと記録を対にして進める。

### 検証項目

- [x] **R1: `cni: none` と kube-proxy 無効でクラスターを作る**（2026年9月6日 完了）
- [x] **R2: Cilium を kube-proxy 置換・L7 proxy 有効で入れる**（2026年9月6日 完了）
- [x] **R3: Cilium の Gateway API と LB IPAM**（2026年9月6日 完了）
- [x] **R4: Cilium BGP を UCG-Fiber と対向させる**（2026年9月9日 完了）
- [x] **R5: Longhorn をワーカーにのみ展開する**（2026年9月9日 完了）
- [x] **R6: Flux Operator と SOPS**（2026年9月9日 完了）
- [ ] **R7: cert-manager、Cloudflare Tunnel、external-dns**（手順5まで検証済み。残りは Webhook Receiver）
- [ ] **R8: UniFi と Cloudflare を Terraform に移す**（未着手の VLAN から始め、既存リソースを import で回収する）

R1 から R3 が山場である。
ここが通れば残りは積み上げになる。

### 完了した検証

R1 から R6 で確定した設定値は [design.md の「Talos と Cilium の必須設定」](design.md#talos-と-cilium-の必須設定)に移してある。
ここには実測の結果だけを残す。

**R1 の結果（2026年9月6日）**

| 確認項目 | 結果 |
| --- | --- |
| 両ノードの状態 | `NotReady`。理由は `cni plugin not initialized` |
| DaemonSet | `No resources found`。kube-proxy が作られていない |
| CoreDNS | `Pending`。Pod ネットワークがないため |
| コントロールプレーンの静的 Pod | `Running`。ホストネットワークで動くため CNI 不要 |
| etcd | 3.7.1、リーダー、healthy |
| VIP | cp-1 が保持し、`kubectl` も VIP 経由で応答 |

途中で v1alpha1 の `cluster.proxy.disabled` を書いて生成に失敗した。
正解は `KubeProxyConfig` ドキュメントの `enabled: false` である。
詳細は [knowledge/talos-operations.md](knowledge/talos-operations.md) に記した。

**R2 の結果（2026年9月6日、Cilium v1.20.1）**

| 確認項目 | 結果 |
| --- | --- |
| Node の状態 | 両ノードとも `Ready` |
| `KubeProxyReplacement` | `True`（Direct Routing） |
| Cilium の健全性 | `Modules Health: OK(75)`、`Controller Status: 13/13 healthy` |
| cilium-envoy | 両ノードで Running（`l7Proxy` が効いている） |
| ClusterIP 経由の疎通 | `HTTP 200` |
| CoreDNS の名前解決 | `nginx.default.svc.cluster.local` を解決 |
| kube-proxy | 不在のまま |

Service の負荷分散を Cilium の eBPF が肩代わりしていることを、kube-proxy 不在の状態で実証した。

導入はまず `helm install` で最小構成を通し、動作を確認してから値を足した。
失敗したときに Cilium 側の問題か値の問題かを切り分けるためである。

**helmfile への移行は未着手である。**
いまは `bootstrap/cilium-values.yaml` を `helm upgrade` に直接渡している。
bootstrap を helmfile で行う方針は [knowledge/cluster-template-evaluation.md](knowledge/cluster-template-evaluation.md) で採ってあり、手順5（フェーズ1の構築）で実装する。

**R3 の結果（2026年9月6日）**

| 確認項目 | 結果 |
| --- | --- |
| `GatewayClass` | `ACCEPTED: True`（`io.cilium/gateway-controller`） |
| `Gateway` | `PROGRAMMED: True`、アドレス `192.168.20.200` |
| LB IPAM | プールから払い出し。51 IP 利用可能 |
| L2 Announcement | VLAN 20 の外にいる作業端末から到達 |
| nginx への疎通 | 連続5回すべて `HTTP 200` |

**2箇所でつまずいた。**
CRD をどのチャネルで入れるかと、`bpf.autoMount.enabled` を無効にすると `cilium-envoy` から BPF マップが見えなくなる件である。
後者は CNI としての疎通が正常なまま Gateway だけが 500 を返すため、Gateway API を入れるまで気付けない。
詳細は [knowledge/talos-operations.md](knowledge/talos-operations.md) に記した。

**R4 着手前の調査（2026年9月8日）**

BGP に移す前に、LB IP の到達性と名前解決の2点を調べた。
LB Pool をノードと同じ VLAN に置いたままでは BGP に移せないことが実測で分かり、VLAN 120 を切ることになった。
同じ URL で家庭 LAN 内とインターネットの両方から届く構成は、既存の external-dns 2系統のまま成立する。
記録は [knowledge/service-exposure.md](knowledge/service-exposure.md) にある。

**R4 の結果（2026年9月9日）**

| 確認項目 | 結果 |
| --- | --- |
| BGP CRD の API バージョン | `cilium.io/v2`（5種） |
| `CiliumBGPNodeConfig` | `worker-1` のみ生成。コントロールプレーンには作られない |
| ピア確立 | `established`。`bgp listen range` で成立 |
| 広告される経路 | `192.168.120.100/32`、next-hop `192.168.20.41` |
| VLAN 1 から LB IP へ | 連続5回すべて `HTTP 200` |
| VLAN 20 から LB IP へ | 到達（検証端末 `192.168.20.32` から） |
| ZBF の分類 | 宛先ネットワーク。Service ゾーンのポリシーが効く |
| L2 Announcement 削除後 | BGP のみで到達を維持 |

**`bgp listen range` は UniFi に通った。**
明示列挙へのフォールバックは要らず、ノードを増やしても UCG-Fiber 側は変えずに済む。

**Zone-Based Firewall は宛先ネットワークでゾーンを決める。**
BGP で学習した `/32` は、next-hop が VLAN 20 にあってもアドレスの属する VLAN 120 のゾーンに入る。
design.md のゾーン間ポリシー表は、この前提のまま成立する。

**ここでも落とし穴は Cilium 側だった。**
`helm upgrade` で values を変えても Pod は入れ替わらず、ConfigMap だけが書き換わって設定が黙って効かない。
`rollOutCiliumPods` と `operator.rollOutPods` と `envoy.rollOutPods` を有効にして解消した。

詳細は [knowledge/bgp-peering.md](knowledge/bgp-peering.md) にある。

**R5 の結果（2026年9月9日、Longhorn 1.12.1）**

| 確認項目 | 結果 |
| --- | --- |
| `apply-config` の再起動 | 不要（`Applied configuration without a reboot`） |
| Pod の配置 | 19個すべて worker-1。cp-1 は0件 |
| `nodes.longhorn.io` | `READY: True`、`SCHEDULABLE: True` |
| ディスクの認識 | `/var/lib/longhorn`、244.0 GB 利用可能 / 253.6 GB |
| StorageClass | `longhorn`（default）と `longhorn-static` |
| PVC | `Bound`、1Gi。Pod を作り直しても md5 が一致 |
| レプリカ | 1本、worker-1 上で `running` |
| Cilium への影響 | BGP セッションは維持。Node は両方 `Ready` |

**Talos 側に kubelet の bind mount が要る。**
`/var/lib/longhorn` を `rshared` で bind mount しないと、CSI が作るマウントが kubelet へ伝播しない。
`talconfig.yaml` の `worker.patches` に足した。ノードの再起動は要らなかった。

**ワーカーに限定するのに `nodeSelector` は要らない。**
チャートの `taintToleration` が既定で空であり、コントロールプレーンの taint を許容しないためである。

**非 root の Pod から PVC を使うには `fsGroup` が要る。**
Longhorn が作るボリュームは root 所有で、`fsGroup` がないと `Permission denied` になる。

詳細は [knowledge/longhorn-on-talos.md](knowledge/longhorn-on-talos.md) にある。

**R6 の結果（2026年9月9日、flux-operator 0.59.0、Flux v2.9.5）**

| 確認項目 | 結果 |
| --- | --- |
| コントローラー | source、kustomize、helm、notification の4つが Running |
| `FluxInstance` | `READY: True` |
| `GitRepository` | `True`。認証なしで public リポジトリを取得 |
| Kustomization | `flux-system`、`apps`、`longhorn` がすべて `True` |
| Longhorn の再導入 | Flux 経由で 19 Pod が worker-1 に。cp-1 は0件 |
| PVC | `Bound`、書き込みと読み出しが成功 |
| SOPS の復号 | Git 上の暗号化 Secret がクラスターで平文になる |
| prune | Git から消すとクラスターからも消える |

**手でクラスターに入れる鍵は `sops-age` の1つだけである。**
リポジトリが public のため Git の認証情報が要らない。
private 化やオーガナイゼーションへの移行のときに2つ目が要る。

**flux-operator は `FluxInstance` の名前によらず `flux-system` という名前で GitRepository を作る。**
`sourceRef` をそちらに向ける。

**Kubernetes の Secret は `encrypted_regex` で `data` と `stringData` だけを暗号化する。**
ファイル全体を暗号化すると `kind` まで隠れ、kustomize がリソースとして読めない。

**Longhorn の `helm uninstall` は `deleting-confirmation-flag` を要求する。**
ボリュームがある状態で行うとデータが消えるため、移行の前に0本であることを確かめる。

詳細は [knowledge/flux-bootstrap.md](knowledge/flux-bootstrap.md) にある。

**R7 の結果（2026年9月9日、cert-manager 1.21.1、external-dns 0.21.0、cloudflared 2026.8.3）**

| 確認項目 | 結果 |
| --- | --- |
| ClusterIssuer | staging と production の両方が `Ready` |
| DNS-01 チャレンジ | `kaeritei.com` と `*.kaeritei.com` の2本とも `valid` |
| 証明書 | staging で発行。SAN は `*.kaeritei.com` と `kaeritei.com` |
| Gateway | internal `192.168.120.101`、external `192.168.120.100`。両方 `PROGRAMMED: True` |
| トンネル | コネクション4本を `nrt10` `nrt12` `nrt14` `nrt15` に登録 |
| external に繋いだ HTTPRoute | インターネットから連続5回すべて `HTTP 200` |
| internal だけに繋いだ HTTPRoute | 公開 DNS に載らない。LAN 内からは `HTTP 200` |
| LAN 内の TLS | Gateway がワイルドカード証明書を出す |
| HTTP から HTTPS へ | `301` |
| HTTPRoute の削除 | CNAME と TXT が消える |
| 未登録のホスト名 | Cloudflare Edge が `530` で落とす |

**公開のスイッチは `HTTPRoute` の `parentRefs` である。**
external-dns（Cloudflare 系統）は `homelab/scope=external` の Gateway に繋がった `HTTPRoute` だけを見る。
external に繋がなければ公開 DNS にレコードが作られず、インターネットからは名前解決の段階で届かない。

**external-dns の `--default-targets` では target を上書きできない。**
このフラグはソースが target を出さなかった場合にしか効かず、`gateway-httproute` ソースは Gateway のアドレスを出す。
external Gateway に `external-dns.alpha.kubernetes.io/target` アノテーションを付ける方法で解決した。

**`txtPrefix` を付けないと CNAME と TXT が衝突する。**
同じ名前に両方を置けないためである。

詳細は [knowledge/gateway-and-tunnel.md](knowledge/gateway-and-tunnel.md) にある。

## 構築の作業

台数の推移とフェーズごとの設計は [design.md の「構築のフェーズ」](design.md#構築のフェーズ)にある。
ここには実際に手を動かす項目を置く。

**フェーズ1**

UCG-Fiber 側の VLAN 120 と BGP はリハーサルで投入済みであり、クラスターを組み直しても残る（「[いまのネットワークの状態](#いまのネットワークの状態)」）。
本番は最初から BGP 構成で組める。

- [ ] EliteDesk 800 G6 を1台、`cp-1` として構築する
- [ ] MS-03 を `worker-1` として再投入する
- [ ] 「フェーズ1で入れるコンポーネント」を一式入れる
- [ ] クラスター外に Backup DNS を構築する
- [ ] Pi-hole をクラスター上へ移設する
- [ ] Pi-hole と Backup DNS の同期機構（`nebula-sync`）を動かす
- [ ] external-dns の Pi-hole 系統を有効にする

**Pi-hole 周りの4項目は、この順に片付ける。**
external-dns の Pi-hole 系統を動かすと、宅内の名前解決がクラスター上の Pi-hole に依存する。
待機系と同期が揃う前にそこへ寄せると、クラスターを止めるたびに家中の名前解決が落ちる。

**Backup DNS はクラスターより先に建てる。**
いまの Pi-hole は S100-WLP 上のスタンドアロンで動いており、クラスターの作り直しの影響を受けない。
これをクラスターへ移した時点で名前解決がクラスターに依存するため、待機系が先にないと移設のあいだが無防備になる。
Backup DNS はクラスターと無関係に建てられるので、順番を入れ替える手戻りはない。
移設のあいだ DHCP で primary と secondary の両方を配っておけば、移設作業そのものも安全になる。

同期の対象に external-dns が書く Custom DNS のレコードを含める点は「[いずれ回収する項目](#いずれ回収する項目)」にある。

**フェーズ2**

- [ ] EliteDesk を2台追加し、etcd を3メンバーにする
- [ ] S100-WLP 用のワーカー schematic を作る（`iscsi-tools`、`util-linux-tools`）
- [ ] S100-WLP を1台、ワーカーとして投入する
- [ ] Longhorn のレプリカ数を 2 に上げる

**フェーズ3**

- [ ] MS-03 の2台目を投入する（ワーカーが一時的に3台になる）
- [ ] S100-WLP から Longhorn のレプリカを退避させる
- [ ] S100-WLP をクラスターから外す

## 未決定事項

### 着手前に決めること

決めないと該当の作業に入れないものである。

| 項目 | 内容 | いつまでに |
| --- | --- | --- |
| 構築期間中の DNS の常用系 | 定常運用は Pi-hole を primary、Backup DNS を待機系とすることで決着した（[knowledge/service-exposure.md](knowledge/service-exposure.md)）。残るのは構築期間中の扱いで、クラスターの作り直しを繰り返すあいだ Backup DNS を常用系に据えるかを決める。いまの Pi-hole は S100-WLP 上のスタンドアロンで動いており、クラスターの作り直しの影響を受けない | フェーズ1で Pi-hole を移設する前 |
| EliteDesk のストレージ種別 | NVMe か SATA か | 実機の到着後、ISO を焼く前 |
| MS-03 の接続 NIC | X710 の SFP+ か RTL8127 の RJ-45 か。USW-Pro-XG-10-PoE の SFP28 ポートは2口しかなく、うち1口は UCG-Fiber への上流で埋まる | 本設置の配線時 |
| 10GbE 配線の到達範囲 | トポロジ図で USW-Pro-XG-10-PoE のポート 5-10（DS923+、MS-03 x2、サーバーノード x3）が `GbE` と表記されている。同機は全 RJ45 ポートが 10GbE で、MS-03 は 10G SFP+ を2口持つ。機器側 NIC の制約を指しているのか記入漏れなのかを確定させる | 本設置の配線時 |
| フェーズ2で使う S100-WLP の個体 | morty / jerry / rick。3台のうち2台は内蔵 I226-V に物理層障害がある。容量とストレージ特性とあわせて選ぶ | フェーズ2 |
| Terraform の実行場所と認証情報の渡し方 | 手元から回すか CI から回すか。UniFi provider は controller のローカル管理者アカウントを要求し、Cloudflare provider は Tunnel を作れるトークンを要求する。どちらも Git に平文で置けないため、`sops exec-env` で渡すか別の仕組みを使うかを決める | R8 の着手前 |

### いずれ回収する項目

構築の本筋から外れるが、放置しないもの。

- [ ] **スイッチポートの VLAN 割り当てを記録する**：どのポートを VLAN 20 にしたかの記録がなく、MS-03 の投入時に一度つまずいた
- [ ] **10GbE で DS923+ との実効スループットを測る**：DS923+ を VLAN 20 に載せてから
- [ ] **Pi-hole の冗長化**：クラスター内の Pi-hole を primary、Raspberry Pi 3 を replica として `nebula-sync` で設定を同期する。Pi-hole v6 では Gravity Sync も Orbital Sync も動かず、`nebula-sync` が現行の解になる。両方が v6 である必要がある。external-dns が書く Custom DNS のレコードは同期対象に含める。含めないと replica がクラスター上のサービス名を解決できず、待機系として機能しない（[knowledge/service-exposure.md](knowledge/service-exposure.md)）。あわせて DHCP で primary と secondary の両方を配る
- [ ] **UniFi Protect の録画先**：UCG-Fiber はストレージを持たないため、カメラ2台の録画先が存在しない。UNVR の追加、DS923+ の Surveillance Station、Kubernetes 上の NVR（Frigate 等）が候補になる。選択によって Camera VLAN のポリシーが変わる
- [ ] **external-dns の Pi-hole プロバイダーが Pi-hole v6 で動くか**：未確認である。v6 は API が変わっており、`nebula-sync` を採ったのも v6 で Gravity Sync と Orbital Sync が動かなかったためで、同じ理由で引っかかる可能性がある。動かない場合は、内部 DNS を UniFi の Local DNS Records に寄せて external-dns の UniFi webhook から書く案（[knowledge/service-exposure.md](knowledge/service-exposure.md) で一度は退けたもの）の再検討になり、design.md の「内部の名前解決」の判断が変わる。着手はフェーズ1の Pi-hole 移設以降になるが、結論によって設計が変わるため早めに調べる価値がある
- [ ] **監視**：kube-prometheus-stack。未着手
- [ ] **バックアップ**：Git リポジトリ + DS923+ のスナップショット。未着手
- [ ] **MS-03 の NPU**：`intel_vpu` の probe が `-EIO` で失敗する。使う段になったらカーネルの更新か BIOS 設定を確認する
- [ ] **Intel Quick Sync のパススルー**：Intel Device Plugin が `xe` と NPU のデバイスをどう公開するかを確認する。初期スコープ外

## リファレンス

- [design.md](design.md)：確定した構成 — 機材、ネットワーク、ノードのイメージ、ソフトウェアスタック、フェーズ定義
- [knowledge/](knowledge/)：検証の記録と Talos の運用知見
- `physical-network-topology-plan.svg`：物理トポロジ図（将来導入する機器を含む）
