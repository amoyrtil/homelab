# homelab 構築計画

## このドキュメントの位置づけ

homelab に Kubernetes クラスターと GitOps ベースの CI/CD を整備するための**作業計画**である。
いま何をしているか、次に何をするか、何がまだ決まっていないかをここに置く。

すでに決まっている構成 — 機材、ネットワーク、ノードのイメージ、ソフトウェアスタック — は [design.md](design.md) にある。
検証の経過と判断の根拠は [knowledge/](knowledge/) にある。

## 現在地

**リハーサル（手順2）の R3 まで完了。次は R4。**
最終更新は 2026年9月8日である。

### いまのクラスターの状態

**クラスターは起動している。**

| ノード | 機器 | アドレス | 役割 |
| --- | --- | --- | --- |
| cp-1 | S100-WLP（morty） | 192.168.20.31 | コントロールプレーン |
| worker-1 | MS-03 | 192.168.20.41 | ワーカー |
| VIP | — | 192.168.20.100 | Kubernetes API エンドポイント |

入っているものは Talos v1.14.0、Kubernetes v1.37.0、Cilium v1.20.1（kube-proxy 置換、L7 proxy、Gateway API、L2 Announcement）である。
`allowSchedulingOnControlPlanes` は `false` にしてある。
`GatewayClass`、`CiliumLoadBalancerIPPool`（192.168.20.200-250）、`CiliumL2AnnouncementPolicy` は残してある。
プールは R4 で VLAN 120（`192.168.120.100-250`）に移す。
検証に使った nginx と Gateway は削除済みで、`default` namespace は空である。

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

VLAN 10、30、40、50、60 は未着手である。
DHCP Guarding も入れていない。VLAN 120 は対象外でよいが、機器を収容する VLAN では有効にする価値がある（特に部屋の LAN ドロップがある VLAN 30 とゲスト用の VLAN 60）。

### 次にやること

**R4: Cilium BGP を UCG-Fiber と対向させる。**

ASN は決まっており（[design.md の BGP](design.md#bgp)）、UniFi 側の VLAN 120 も作成済みである。
残るのは Cilium と UCG-Fiber の設定である。

**あわせて LB Pool を VLAN 120 に移す。**
ノードと同じ VLAN に置いたままでは、BGP に移した時点で VLAN 20 の機器から到達できなくなる。
根拠は [knowledge/service-exposure.md](knowledge/service-exposure.md) にある。

いま `default` は空でサービスが載っていない。
プールを切り替えてもダウンタイムが出ないため、切り替えるならこの状態のうちに済ませる。

**手順**

1. Cilium の BGP Control Plane を有効化する。`bootstrap/cilium-values.yaml` に `bgpControlPlane.enabled: true` を足して `helm upgrade` する。これで BGP の CRD が入る
2. Cilium 側の BGP リソースを作る。`CiliumBGPClusterConfig`、`CiliumBGPPeerConfig`、`CiliumBGPAdvertisement` の3つ。広告はワーカーのみとする
3. UCG-Fiber に FRR 設定を入れる（下記）
4. ピア確立を確認する。クラスター側は `cilium bgp peers`、ルーター側は `show ip bgp summary`
5. `bootstrap/cilium-networks.yaml` のプールを `192.168.120.100-250` に変える
6. テスト用の Service を作り、新プールから払い出した IP への到達を確認する
7. `CiliumL2AnnouncementPolicy` を削除し、Helm values の `l2announcements` も外す
8. 下記の2件を実測する

**UCG-Fiber の FRR 設定**

Settings → Routing → BGP からアップロードする（UniFi のバージョンによっては Policy Engine → Dynamic Routing → BGP）。

```
router bgp 65000
 bgp router-id 192.168.20.1
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast
 !
 neighbor k8s peer-group
 neighbor k8s remote-as 65001
 bgp listen range 192.168.20.0/24 peer-group k8s
 bgp listen limit 16
 !
 address-family ipv4 unicast
  neighbor k8s activate
  neighbor k8s soft-reconfiguration inbound
 exit-address-family
!
```

`no bgp ebgp-requires-policy` を落とすと、**ピアは張れるのに経路が一切交換されない**。
FRR は RFC 8212 に従って eBGP に route-map を要求するためである。
症状から原因にたどり着きにくいので、最初から入れておく。

`bgp listen range` は、ノードの IP を列挙せずに VLAN 20 からの接続を待ち受ける指定である。
接続を開始するのは Cilium 側なので、ルーターは待つだけでよい。
ノードが増えても両側とも設定を変えずに済む。

**UniFi がこの構文を受け付けるかは未確認である。**
参考にした記事3件はいずれもノード IP を明示列挙しており、UniFi で `listen range` を使った実例を見つけられなかった。
弾かれた場合は明示列挙にフォールバックする。

```
 neighbor 192.168.20.31 peer-group k8s
 neighbor 192.168.20.41 peer-group k8s
```

フォールバックした場合、ノードを増やすたびに UCG-Fiber 側も更新することになる。
そのときはフェーズ2とフェーズ3の作業項目に書き足す。

**R4 で測る2件**

どちらも [knowledge/service-exposure.md](knowledge/service-exposure.md) の調査で確認できずに残ったものである。

- **VLAN 20 の機器から VLAN 120 の LB IP に届くか。** 今回の設計変更が狙いどおり効いているかの本丸である。DS923+（`192.168.20.20`）は SSH が閉じているため、測るには VLAN 20 に検証用のホストを用意する必要がある
- **UniFi の Zone-Based Firewall が、BGP で学習した `/32` をどのゾーンに分類するか。** VLAN 120 を定義すればそのゾーンのポリシーが効く見込みだが、実機で確かめていない

### 作業の進め方

- [x] **1. テンプレートの評価** — `onedr0p/cluster-template` を採用するか判断する。記録は [knowledge/cluster-template-evaluation.md](knowledge/cluster-template-evaluation.md)
- [ ] **2. リハーサル** — いま動いているクラスターで、フェーズ1の構成を通す。R1 から R3 まで完了。詳細は「[リハーサル](#リハーサル)」節
- [ ] **3. 知見の集約** — 2 の結果を `knowledge/` に記録する。R1 から R3 の分は [knowledge/talos-operations.md](knowledge/talos-operations.md) に反映済み
- [ ] **4. 規約の整備** — 命名規則など homelab 全体のルールを決め、プロジェクトルートの `CLAUDE.md` を更新する
- [ ] **5. フェーズ1の構築** — EliteDesk 到着後、クラスターを本番として組み直す

### 作業環境

ツールは `mise` で固定している。リポジトリのルートで `mise install` を実行すれば揃う。
`KUBECONFIG` と `TALOSCONFIG` も `.mise/config.toml` で設定しているため、`cd` するだけで接続先がそろう。

`talos/clusterconfig/` は gitignore 対象である。
消えている場合は `cd talos && talhelper genconfig` で再生成する。

## リハーサル

EliteDesk 800 G6 の到着を待つあいだ、S100-WLP + MS-03 のクラスターでフェーズ1の構成を通す。
目的は手順とハマりどころを洗い出すことであり、成果物は `knowledge/` に残す。

R1 から R3 までで、**この構成の落とし穴は2つとも Cilium 側にあった**ことが分かっている。
`bpf.autoMount.enabled` を無効にすると `cilium-envoy` から BPF マップが見えなくなる件と、Gateway API の CRD が experimental チャネルを要求する件である。
どちらも [knowledge/talos-operations.md](knowledge/talos-operations.md) に記録した。

クラスター名とノード名は現状のまま（`homelab`、`cp-1`、`worker-1`）で進める。
命名規約は手順4で整理するため、ここでは触らない。

**検証したことは、通るたびに `knowledge/` へ書き出す。**
セッションが切れても再開できるよう、チェックボックスと記録を対にして進める。

### 検証項目

- [x] **R1: `cni: none` と kube-proxy 無効でクラスターを作る**（2026年9月6日 完了）
- [x] **R2: Cilium を kube-proxy 置換・L7 proxy 有効で入れる**（2026年9月6日 完了）
- [x] **R3: Cilium の Gateway API と LB IPAM**（2026年9月6日 完了）
- [ ] **R4: Cilium BGP を UCG-Fiber と対向させる**（UCG-Fiber 側の FRR 設定と、VLAN 120 の定義が要る）
- [ ] **R5: Longhorn をワーカーにのみ展開する**（レプリカ1）
- [ ] **R6: Flux Operator と SOPS**
- [ ] **R7: cert-manager、Cloudflare Tunnel、external-dns**（ドメインと Cloudflare の API トークンが要る）

R1 から R3 が山場である。
ここが通れば残りは積み上げになる。

### 完了した検証

R1 から R3 で確定した設定値は [design.md の「Talos と Cilium の必須設定」](design.md#talos-と-cilium-の必須設定)に移してある。
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

導入はまず `helm install` で最小構成を通し、動作を確認してから helmfile に落とした。
失敗したときに Cilium の問題か helmfile の問題かを切り分けるためである。

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

L2 Announcement は R4 で BGP に移すまでの確認用であり、ワーカーのみが広告するよう `nodeSelector` を付けている。

**R4 着手前の調査（2026年9月8日）**

BGP に移す前に、LB IP の到達性と名前解決の2点を調べた。
LB Pool をノードと同じ VLAN に置いたままでは BGP に移せないことが実測で分かり、VLAN 120 を切ることになった。
同じ URL で家庭 LAN 内とインターネットの両方から届く構成は、既存の external-dns 2系統のまま成立する。
記録は [knowledge/service-exposure.md](knowledge/service-exposure.md) にある。

## 構築の作業

台数の推移とフェーズごとの設計は [design.md の「構築のフェーズ」](design.md#構築のフェーズ)にある。
ここには実際に手を動かす項目を置く。

**フェーズ1**

- [ ] EliteDesk 800 G6 を1台、`cp-1` として構築する
- [ ] MS-03 を `worker-1` として再投入する
- [ ] 「フェーズ1で入れるコンポーネント」を一式入れる
- [ ] Pi-hole を移設し、クラスター外の副 DNS を用意する
- [ ] UCG-Fiber に VLAN 120 を定義する（ゲートウェイ IP のみ、DHCP なし）
- [ ] UCG-Fiber に FRR の BGP 設定を入れる

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
| 構築期間中の DNS の常用系 | 定常運用は Pi-hole を primary、Backup DNS を待機系とすることで決着した（[knowledge/service-exposure.md](knowledge/service-exposure.md)）。残るのは構築期間中の扱いで、クラスターの作り直しを繰り返すあいだ Backup DNS を常用系に据えるかを決める | フェーズ1で Pi-hole を移設する前 |
| EliteDesk のストレージ種別 | NVMe か SATA か | 実機の到着後、ISO を焼く前 |
| MS-03 の接続 NIC | X710 の SFP+ か RTL8127 の RJ-45 か。USW-Pro-XG-10-PoE の SFP28 ポートは2口しかなく、うち1口は UCG-Fiber への上流で埋まる | 本設置の配線時 |
| 10GbE 配線の到達範囲 | トポロジ図で USW-Pro-XG-10-PoE のポート 5-10（DS923+、MS-03 x2、サーバーノード x3）が `GbE` と表記されている。同機は全 RJ45 ポートが 10GbE で、MS-03 は 10G SFP+ を2口持つ。機器側 NIC の制約を指しているのか記入漏れなのかを確定させる | 本設置の配線時 |
| フェーズ2で使う S100-WLP の個体 | morty / jerry / rick。3台のうち2台は内蔵 I226-V に物理層障害がある。容量とストレージ特性とあわせて選ぶ | フェーズ2 |

### いずれ回収する項目

構築の本筋から外れるが、放置しないもの。

- [ ] **スイッチポートの VLAN 割り当てを記録する**：どのポートを VLAN 20 にしたかの記録がなく、MS-03 の投入時に一度つまずいた
- [ ] **10GbE で DS923+ との実効スループットを測る**：DS923+ を VLAN 20 に載せてから
- [ ] **Pi-hole の冗長化**：クラスター内の Pi-hole を primary、Raspberry Pi 3 を replica として `nebula-sync` で設定を同期する。Pi-hole v6 では Gravity Sync も Orbital Sync も動かず、`nebula-sync` が現行の解になる。両方が v6 である必要がある。external-dns が書く Custom DNS のレコードは同期対象に含める。含めないと replica がクラスター上のサービス名を解決できず、待機系として機能しない（[knowledge/service-exposure.md](knowledge/service-exposure.md)）。あわせて DHCP で primary と secondary の両方を配る
- [ ] **UniFi Protect の録画先**：UCG-Fiber はストレージを持たないため、カメラ2台の録画先が存在しない。UNVR の追加、DS923+ の Surveillance Station、Kubernetes 上の NVR（Frigate 等）が候補になる。選択によって Camera VLAN のポリシーが変わる
- [ ] **監視**：kube-prometheus-stack。未着手
- [ ] **バックアップ**：Git リポジトリ + DS923+ のスナップショット。未着手
- [ ] **MS-03 の NPU**：`intel_vpu` の probe が `-EIO` で失敗する。使う段になったらカーネルの更新か BIOS 設定を確認する
- [ ] **Intel Quick Sync のパススルー**：Intel Device Plugin が `xe` と NPU のデバイスをどう公開するかを確認する。初期スコープ外

## リファレンス

- [design.md](design.md)：確定した構成 — 機材、ネットワーク、ノードのイメージ、ソフトウェアスタック、フェーズ定義
- [knowledge/](knowledge/)：検証の記録と Talos の運用知見
- `physical-network-topology-plan.svg`：物理トポロジ図（将来導入する機器を含む）
