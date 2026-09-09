# homelab 構築計画

## このドキュメントの位置づけ

homelab に Kubernetes クラスターと GitOps ベースの CI/CD を整備するための**作業計画**である。
いま何をしているか、次に何をするか、何がまだ決まっていないかをここに置く。

すでに決まっている構成 — 機材、ネットワーク、ノードのイメージ、ソフトウェアスタック — は [design.md](design.md) にある。
検証の経過と判断の根拠は [knowledge/](knowledge/) にある。

## 現在地

**リハーサル（手順2）の R4 まで完了。次は R5。**
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
検証に使った nginx と Service は削除済みで、`default` namespace は空である。

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

**R5: Longhorn をワーカーにのみ展開する。**

決まっていることは [design.md の「ストレージ」](design.md#ストレージ) にある。
コントロールプレーンには載せず、DaemonSet が control-plane の taint を許容しないよう設定する。
namespace には `pod-security.kubernetes.io/enforce=privileged` を与える。
Talos は既定で `baseline` を強制するため、これがないと動かない。

ワーカーは MS-03 の1台だけなので、レプリカ数は 1 とする。
MS-03 の schematic には `iscsi-tools` と `util-linux-tools` が既に入っている。

手順は着手時に詰める。

### 作業の進め方

- [x] **1. テンプレートの評価** — `onedr0p/cluster-template` を採用するか判断する。記録は [knowledge/cluster-template-evaluation.md](knowledge/cluster-template-evaluation.md)
- [ ] **2. リハーサル** — いま動いているクラスターで、フェーズ1の構成を通す。R1 から R4 まで完了。詳細は「[リハーサル](#リハーサル)」節
- [ ] **3. 知見の集約** — 2 の結果を `knowledge/` に記録する。R1 から R4 の分は [knowledge/talos-operations.md](knowledge/talos-operations.md) と [knowledge/bgp-peering.md](knowledge/bgp-peering.md) に反映済み
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
- [ ] **R5: Longhorn をワーカーにのみ展開する**（レプリカ1）
- [ ] **R6: Flux Operator と SOPS**
- [ ] **R7: cert-manager、Cloudflare Tunnel、external-dns**（ドメインと Cloudflare の API トークンが要る）

R1 から R3 が山場である。
ここが通れば残りは積み上げになる。

### 完了した検証

R1 から R4 で確定した設定値は [design.md の「Talos と Cilium の必須設定」](design.md#talos-と-cilium-の必須設定)に移してある。
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

## 構築の作業

台数の推移とフェーズごとの設計は [design.md の「構築のフェーズ」](design.md#構築のフェーズ)にある。
ここには実際に手を動かす項目を置く。

**フェーズ1**

UCG-Fiber 側の VLAN 120 と BGP はリハーサルで投入済みであり、クラスターを組み直しても残る（「[いまのネットワークの状態](#いまのネットワークの状態)」）。
本番は最初から BGP 構成で組める。

- [ ] EliteDesk 800 G6 を1台、`cp-1` として構築する
- [ ] MS-03 を `worker-1` として再投入する
- [ ] 「フェーズ1で入れるコンポーネント」を一式入れる
- [ ] Pi-hole を移設し、クラスター外の副 DNS を用意する

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
