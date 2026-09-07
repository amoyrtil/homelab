# homelab 構築計画

## このドキュメントの位置づけ

homelab に Kubernetes クラスターと GitOps ベースの CI/CD を整備するための計画である。
コントロールプレーンに HP EliteDesk 800 G6 を3台、ワーカーに MINISFORUM MS-03 を使う本番構成を対象とする。

このドキュメントには決定した内容だけを書く。
なぜそう決めたかの根拠、検証の経過、途中で否定した仮説は [knowledge/](knowledge/) に置く。

前バージョンの計画は `plan_old.md` に退避した。
旧計画はハードウェア構成とネットワーク構成が未検証のまま、ファイル単位の実装タスクまで書き切っていた。
前提が覆れば計画全体が無効になる構造だったため、検証と設計を先に置く形に組み替えた。

## 現在地

**リハーサル（手順2）の R3 まで完了。次は R4。**
最終更新は 2026年9月6日である。

### いまのクラスターの状態

**全ノードの電源が落ちている。** ディスクの内容は消していないため、電源を入れれば下記の状態から再開できる。

| ノード | 機器 | アドレス | 状態 |
| --- | --- | --- | --- |
| cp-1 | S100-WLP（morty） | 192.168.20.31 | 停止中。Talos v1.14.0 と Cilium が入っている |
| worker-1 | MS-03 | 192.168.20.41 | 停止中 |

入っているものは Talos v1.14.0、Kubernetes v1.37.0、Cilium v1.20.1（kube-proxy 置換、L7 proxy、Gateway API、L2 Announcement）である。
`GatewayClass`、`CiliumLoadBalancerIPPool`（192.168.20.200-250）、`CiliumL2AnnouncementPolicy` は残してある。
検証に使った nginx と Gateway は削除済みで、`default` namespace は空である。

これはリハーサル環境であり、EliteDesk 到着後に本番として組み直す。
クラスター名もノード名も暫定のままでよい。

### 次にやること

**R4: Cilium BGP を UCG-Fiber と対向させる。**

着手前に2つ決める必要がある。

- **BGP の ASN** — クラスター側とルーター側で別の番号を使い、eBGP にする。プライベート ASN（64512-65534）から選ぶ
- **UCG-Fiber の FRR 設定** — UniFi の Settings → Routing → BGP に設定ファイルをアップロードする方式である。UniFi OS 4.1.13 以降で対応

R4 が通れば L2 Announcement は不要になる。
`bootstrap/cilium-networks.yaml` の `CiliumL2AnnouncementPolicy` を落とし、`CiliumBGPClusterConfig` に置き換える。

### 作業の進め方

- [x] **1. テンプレートの評価** — `onedr0p/cluster-template` を採用するか判断する。記録は [knowledge/cluster-template-evaluation.md](knowledge/cluster-template-evaluation.md)
- [ ] **2. リハーサル** — いま動いているクラスターで、フェーズ1の構成を通す。R1 から R3 まで完了。詳細は「リハーサル」節
- [ ] **3. 知見の集約** — 2 の結果を `knowledge/` に記録する。R1 から R3 の分は [knowledge/talos-operations.md](knowledge/talos-operations.md) に反映済み
- [ ] **4. 規約の整備** — 命名規則など homelab 全体のルールを決め、プロジェクトルートの `CLAUDE.md` を更新する
- [ ] **5. フェーズ1の構築** — EliteDesk 到着後、クラスターを本番として組み直す

### 作業環境

ツールは `mise` で固定している。リポジトリのルートで `mise install` を実行すれば揃う。
`KUBECONFIG` と `TALOSCONFIG` も `.mise/config.toml` で設定しているため、`cd` するだけで接続先がそろう。

`talos/clusterconfig/` は gitignore 対象である。
消えている場合は `cd talos && talhelper genconfig` で再生成する。

### 技術判断の基準

選択肢を評価するときは、次の3点を毎回確認する。

1. 一昔前のデファクトスタンダードではなく、最新トレンドを踏まえた現時点でもっとも合理的な手法になっているか
2. スケーラビリティを考慮し、不要な再構築や手戻りを避けているか
3. 現時点で利用しない不要な技術スタックは導入せず、ミニマムな構成に保っているか

## 機材

### 現在保有している機材

| 機器 | 台数 | 用途 |
| --- | --- | --- |
| UniFi Cloud Gateway Fiber | 1 | ルーター、VLAN、DHCP、ファイアウォール |
| アンマネージド 1GbE スイッチ | 1 | 未使用（UCG-Fiber の LAN ポートに直結する） |
| MINISFORUM MS-03 | 1 | ワーカーノード |
| MINISFORUM S100-WLP | 3 | 2台目の MS-03 を調達するまでのワーカー候補。1台は Pi-hole を稼働中 |

S100-WLP はコントロールプレーンの候補として評価し、etcd の要件を満たすことを確認したが、EliteDesk 800 G6 への置き換えを決めたため役割から外れた。
経緯は [knowledge/s100-etcd-evaluation.md](knowledge/s100-etcd-evaluation.md) にある。

3台のうち1台は Ubuntu で Pi-hole を稼働させており、家庭内の DNS を担っている。
この1台を転用するには Pi-hole の移設先を先に決める必要がある。

### 導入予定のコントロールプレーン

| 機器 | 台数 | 用途 |
| --- | --- | --- |
| HP EliteDesk 800 G6 | 3 | コントロールプレーンノード |

ストレージは SATA と NVMe であり、S100-WLP のような UFS の制約を受けない。
標準 Talos がそのまま使える。

### 将来導入する機器

`physical-network-topology-plan.svg` に描かれた構成のうち、未購入のものを含む。
VLAN 設計はこの全機器が接続された状態を前提に行う。

- ネットワーク：USW-Pro-XG-10-PoE、USW-Pro-Max-16-PoE、USW-Flex-XG、USW-Flex-2.5G-PoE、U7 Pro XG（2台）、U7 Mesh
- サーバー：MS-03（2台）、コントロールプレーンノード（3台）、Synology DS923+
- インフラサービス：Backup DNS、Log Server
- クライアント：Windows PC、Mac mini、MacBook Pro
- AV とゲーム機：Apple TV、PS5、Nintendo Switch 2（2台）、HTPC
- カメラ：G5 Turret Ultra、G6 Entry
- 部屋の LAN ドロップ：1F Dining Room、2F Bed Room、2F Shiori Room

### トポロジ図で確認が必要な点

トポロジ図では、USW-Pro-XG-10-PoE のポート 5 から 10（DS923+、MS-03 x2、サーバーノード x3 が接続される）が `GbE` と表記されている。
USW-Pro-XG-10-PoE は全 RJ45 ポートが 10GbE の機種であり、MS-03 は 10G SFP+ を 2 口持つ。
表記が機器側 NIC の制約を指しているのか、単なる記入漏れなのかを確定させる必要がある。
10GbE を活かせるかどうかは、DS923+ との SMB スループットに直接効く。

## ネットワーク設計

### アドレス方針

`192.168.<VLAN ID>.0/24` を採用する。
第3オクテットと VLAN ID を一致させることで、アドレスを見た時点で所属 VLAN が判別できる。

Kubernetes の内部 CIDR は既定値を維持する。
Pod CIDR に `10.244.0.0/16`、Service CIDR に `10.96.0.0/12` を使う。
ホスト側が `192.168.0.0/16` のため、重複は発生しない。

### VLAN 一覧

| VLAN | CIDR | 名前 | 収容する機器 |
| --- | --- | --- | --- |
| 10 | 192.168.10.0/24 | Management | UCG-Fiber、USW 4台、U7 3台 |
| 20 | 192.168.20.0/24 | Server | Kubernetes ノード全台、MS-03 x2、DS923+、Backup DNS、Log Server、Cilium LoadBalancer IP Pool |
| 30 | 192.168.30.0/24 | Trusted | Windows PC、Mac mini、MacBook Pro、モバイル端末、Apple TV、PS5、Switch 2 x2、HTPC、部屋の LAN ドロップ 3系統 |
| 40 | 192.168.40.0/24 | Untrusted | 信頼度の低い IoT 家電 |
| 50 | 192.168.50.0/24 | Camera | G5 Turret Ultra、G6 Entry、NVR |
| 99 | 192.168.99.0/24 | Guest | ゲスト WiFi |

番号は小さいほど基幹に近い。
Management を先頭に置き、Server、Trusted と続け、信頼度が下がるにつれて番号を増やす。
Guest だけを 99 に離してあるのは、今後 VLAN を追加しても Guest が最下位に留まるようにするためである。
それ以外は 10 番刻みで空けてあるので、たとえば Server と Trusted の間に別の層を挟む余地が残る。

VLAN 1（UniFi の既定 VLAN）には機器を収容しない。

### 配置の根拠

**Kubernetes ノードと DS923+ を VLAN 20 に統合する。**
分離した場合、NFS と CSI のトラフィックがすべて UCG-Fiber の L3 転送を経由し、配線を 10GbE にしてもゲートウェイのルーティング性能が上限になる。
Cilium の L2 Announcement も、LoadBalancer IP Pool がノードと同一 L2 ドメインにあることを要求する。
この二つの制約から、ノード、ストレージ、LB Pool は同一 VLAN に置く。

**Backup DNS と Log Server を VLAN 20 に置く。**
Management VLAN はネットワーク機器の管理専用とし、インフラサービスはサーバー側に寄せる。

**Apple TV、PS5、Switch 2、HTPC を VLAN 30 に置く。**
これらを Untrusted VLAN に分けると、VLAN 30 のクライアントからの AirPlay や画面共有のたびに VLAN 越えが発生する。
VLAN 40 は照明やセンサーなど、インターネット接続以外の権限を与えたくない機器のためのものとする。

**部屋の LAN ドロップは VLAN 30 とする。**
壁の LAN 端子に到達できる時点で物理アクセスが成立しており、そこだけを低信頼として扱う実益がない。

### VLAN 20 のアドレス割り当て

```
192.168.20.1          UCG-Fiber（デフォルトゲートウェイ）
192.168.20.10-19      インフラサービス（Backup DNS: .10, Log Server: .11）
192.168.20.20-29      ストレージ（DS923+: .20）
192.168.20.31-39      Kubernetes コントロールプレーンノード（.31, .32, .33）
192.168.20.41-49      Kubernetes ワーカーノード（.41, .42）
192.168.20.100        Talos VIP（Kubernetes API エンドポイント）
192.168.20.150-199    DHCP プール（一時利用、検証機）
192.168.20.200-250    Cilium LoadBalancer IP Pool
```

サーバー機は全台 DHCP 予約または静的割り当てとし、DHCP プールから払い出さない。

### VLAN 間ポリシー

| 送信元 | 宛先 | 方針 |
| --- | --- | --- |
| Trusted | Management | 許可（UniFi 管理 UI） |
| Trusted | Server | 許可（kubectl、NAS、各サービスの Web UI） |
| Trusted | Untrusted | 許可（家電の操作） |
| Server | Trusted | 応答を除き拒否 |
| Server | インターネット | 許可 |
| Untrusted | 内部 VLAN 全般 | 応答と DNS を除き拒否 |
| Untrusted | インターネット | 許可 |
| Camera | NVR | 許可 |
| Camera | インターネット | 拒否 |
| Guest | 内部 VLAN 全般 | DNS を除き拒否 |
| Guest | インターネット | 許可 |

全 VLAN から `192.168.20.10`（Backup DNS）への 53/udp と 53/tcp を個別に許可する。
Untrusted と Guest の隔離方針に穴を開ける形になるため、ポートを限定して通す。

### 既知の設定要件

Apple TV を VLAN 30、IoT 家電を VLAN 40 に置いた結果、HomeKit と Matter が使う mDNS が VLAN 30 と VLAN 40 をまたぐ。
UniFi の mDNS リフレクタを両 VLAN で有効化する必要がある。
これは設計の破綻ではなく、この配置を選んだことに伴う必要設定である。

### 未決定事項

- **UniFi Protect の録画先**：UCG-Fiber はストレージを持たないため、カメラ2台の録画先が存在しない。UNVR の追加、DS923+ の Surveillance Station、Kubernetes 上の NVR（Frigate 等）が候補になる。選択によって Camera VLAN のポリシーが変わる。
- **DNS の常用系と待機系の役割分担**：現在は S100-WLP 1台の Ubuntu 上で Pi-hole が家庭内 DNS を担っている。トポロジ図の Backup DNS は待機系にあたる。Pi-hole を Kubernetes 上に移すなら、クラスター停止時のフォールバックとして Backup DNS が機能する構成になる。ただしクラスターが安定するまでは、作り直しを繰り返す環境に家庭の DNS を載せるわけにはいかない。Backup DNS を先に常用系として立てるか、Pi-hole を別ハードウェアへ移すかを決める必要がある。
- **10GbE 配線の到達範囲**：前掲の「トポロジ図で確認が必要な点」を参照。

## コントロールプレーンのセットアップ

HP EliteDesk 800 G6 DM を3台、コントロールプレーンノードとして構築する。

### ハードウェアと Talos での扱い

| 項目 | 内容 | Talos 側 |
| --- | --- | --- |
| CPU | Intel Core i5-10500T（Comet Lake、6コア12スレッド、TDP 35W） | `siderolabs/intel-ucode` |
| RAM | 8GB | — |
| ストレージ | 256GB SSD | 実機で NVMe か SATA かを確認する |
| NIC | 内蔵 1GbE（Intel I219-LM 想定） | `e1000e`。カーネルに組み込み済み |

3台とも同一構成である。

RAM 8GB はコントロールプレーン専用なら足りる。
Talos 本体、etcd、apiserver、controller-manager、scheduler、kubelet、containerd、CNI を合わせて 3GB から 4GB の見込みである。
`allowSchedulingOnControlPlanes` を `false` に保つ限り余裕がある。
逆にコントロールプレーンにもワークロードを載せる構成にするなら、ここが最初に詰まる。

NIC が 1GbE でワーカーの 10GbE と差があるが、etcd はスループットではなく fsync レイテンシで不安定になるため、この差は効かない。

### ISO の作成

拡張は `intel-ucode` だけにする。

```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/intel-ucode
```

この内容で登録すると、次の ID が返る。

```
2d61dd07b20062062ea671b4d01873506103b67c0f7a4c3fb6cf4ee85585dcb8
```

```
ISO         https://factory.talos.dev/image/2d61dd07b20062062ea671b4d01873506103b67c0f7a4c3fb6cf4ee85585dcb8/v1.14.0/metal-amd64.iso
installer   factory.talos.dev/metal-installer/2d61dd07b20062062ea671b4d01873506103b67c0f7a4c3fb6cf4ee85585dcb8:v1.14.0
```

定義は `talos/schematics/elitedesk-schematic.yaml` にある。

### 拡張を絞る根拠

MS-03 の5つをそのまま持ち込む必要はない。
コントロールプレーンはワークロードを載せないため、用途が違う。

| 拡張 | 判断 | 根拠 |
| --- | --- | --- |
| `siderolabs/intel-ucode` | 採用 | Comet Lake のマイクロコード。入れない理由がない |
| `siderolabs/i915` | 見送り | ワークロードを載せないため iGPU 自体が要らない |
| `siderolabs/intel-npu` | 見送り | NPU を持たない |
| `siderolabs/iscsi-tools` | 見送り | Longhorn をワーカーに限定するため、コントロールプレーンで iSCSI を使う場面がない |
| `siderolabs/util-linux-tools` | 見送り | `iscsi-tools` と組で使うものであり、単独では要らない |
| `iommu=pt` | 見送り | SR-IOV も PCIe パススルーも使わない |

etcd のバックアップは `talosctl etcd snapshot` で行う。
このコマンドはノードから実行元へスナップショットをストリームするだけで、ノードは外部ストレージをマウントしない。
バックアップを理由に `iscsi-tools` が要ることはない。

**拡張を後から足すことはできる。**
`talosctl upgrade` とインストーラーイメージの差し替えで再起動が要るが、コントロールプレーン3台なら1台ずつローリングで上げられる。
MS-03 で必要になりうる拡張を最初に焼き込んだのは、ワーカーが1台しかなく再起動がワークロード停止に直結したためである。
3台構成のコントロールプレーンにはその制約がない。

## MS-03 のセットアップ

MS-03 はワーカーノード `worker-1`（`192.168.20.41`）として稼働している。

Talos ではシステム拡張を後から足すのに `talosctl upgrade` とインストーラーイメージの差し替えが要る。
拡張を足すたびに再起動が発生するため、必要になりうる拡張は最初の ISO に焼き込む。

### ハードウェアと Talos での扱い

| 項目 | 内容 | Talos 側 |
| --- | --- | --- |
| CPU | Intel Core Ultra 9 386H（Panther Lake） | `siderolabs/intel-ucode` |
| iGPU | Xe3 4コア | `siderolabs/xe`（`i915` ではない） |
| NPU | Panther Lake 内蔵 | `siderolabs/intel-npu` |
| NIC | Intel X710 10GbE SFP+ x2 | `i40e`（`CONFIG_I40E=m`、VF も `CONFIG_I40EVF=m`） |
| NIC | Realtek RTL8127 10GbE RJ-45 | `r8169`（`CONFIG_R8169=m`） |
| NIC | Intel i226-LM 2.5GbE RJ-45 | `igc`（`CONFIG_IGC=m`） |
| 拡張スロット | PCIe x8、U.2 | 初期スコープ外 |
| ストレージ | NVMe SKHynix HFS256GDE9X081N 256GB | インストール先 `/dev/nvme0n1` |

**NIC は4つとも Talos が認識する。**
インターフェース名は起動順で入れ替わりうるため、`deviceSelector` は MAC で指定する。

| インターフェース | MAC | ドライバ | Vendor:Device | チップ |
| --- | --- | --- | --- | --- |
| `eno2` | `38:05:25:3b:cc:d2` | `igc` | 8086:125b | Intel i226-LM 2.5GbE |
| `eno3` | `38:05:25:3b:cc:d5` | `r8169` | 10ec:8127 | Realtek RTL8127 10GbE RJ-45 |
| `eno4np0` | `38:05:25:3b:cc:d3` | `i40e` | 8086:1572 | Intel X710 SFP+ #1 |
| `eno5np1` | `38:05:25:3b:cc:d4` | `i40e` | 8086:1572 | Intel X710 SFP+ #2 |

現在は X710 の SFP+ #1 に DAC 直結し、10GbE でリンクしている。
トポロジ図では USW-Pro-XG-10-PoE の RJ-45 ポートに接続する想定であり、この経路は RTL8127 に依存する。
どちらを本設置で使うかは配線とあわせて決める。
USW-Pro-XG-10-PoE の SFP28 ポートは2口しかなく、うち1口は UCG-Fiber への上流で埋まる。

**iGPU は使えるが、NPU は使えない。**
`xe` 拡張により `/dev/dri` に `card0` と `renderD128` が現れる。
NPU は PCI デバイスとして見えており `intel_vpu` もロードされるが、probe が `-EIO` で失敗し `/dev/accel` が作られない。
Linux 6.18 のドライバが Panther Lake 世代を扱いきれていないと見ている。
NPU を使うワークロードは初期スコープ外のため、当面は支障にならない。

### ISO の作成

Talos Image Factory を使う。

`talos/schematics/ms03-schematic.yaml` を次の内容で作る。

```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/intel-ucode
      - siderolabs/xe
      - siderolabs/intel-npu
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
  extraKernelArgs:
    - iommu=pt
```

schematic を登録して ID を得る。

```bash
curl -X POST --data-binary @talos/schematics/ms03-schematic.yaml \
  https://factory.talos.dev/schematics
```

上記の内容で登録すると、次の ID が返る。

```
b7f363548fe975dbb10e85983906f0c3f44ab3804b6246b677508ca1bb20d1f4
```

この ID から ISO とインストーラーイメージが決まる。

```
ISO         https://factory.talos.dev/image/b7f363548fe975dbb10e85983906f0c3f44ab3804b6246b677508ca1bb20d1f4/v1.14.0/metal-amd64.iso
installer   factory.talos.dev/metal-installer/b7f363548fe975dbb10e85983906f0c3f44ab3804b6246b677508ca1bb20d1f4:v1.14.0
```

ID は schematic の内容から決まるため、拡張やカーネル引数を変えると別の ID になる。
逆に Talos のバージョンを変えても ID は変わらない。
schematic を変更したら ID もこのドキュメントで更新する。

2026年9月6日に上記の内容を再送して ID の一致を確認した。
採用した5つの拡張はいずれも v1.14.0 向けに提供されている。

### 当初案からの変更点

検討時に想定していた構成に対し、3点を変更した。

| 項目 | 判断 | 根拠 |
| --- | --- | --- |
| `siderolabs/intel-ucode` | 採用 | Panther Lake のマイクロコード |
| `siderolabs/xe` | 採用 | Xe3 iGPU の DRM ドライバ。`i915` は旧世代向けなので不要 |
| `siderolabs/intel-npu` | 採用 | Panther Lake 内蔵 NPU のファームウェアとカーネルモジュール。`xe` と同じく、後から足すと `talosctl upgrade` と再起動が要るため最初に含める |
| `siderolabs/iscsi-tools` | 採用 | Longhorn の前提条件。ボリュームのアタッチに `iscsid` と `iscsiadm` を使う |
| `siderolabs/util-linux-tools` | 採用 | Longhorn の前提条件。ボリュームの trim に `fstrim` を使う |
| `siderolabs/nfs-utils` | **見送り** | この拡張が提供するのは rpcbind と rpc.statd であり、NFSv3 のファイルロック専用である。NFS クライアント自体は Talos のカーネルに組み込まれており v4.2 まで対応済み（`CONFIG_NFS_V4_2=y`）。NFSv4 を使う限り不要 |
| `intel_iommu=on` | **削除** | Talos のカーネルは `CONFIG_INTEL_IOMMU_DEFAULT_ON=y` で、指定しても挙動が変わらない |
| `iommu=pt` | 維持 | `CONFIG_IOMMU_DEFAULT_PASSTHROUGH` は未設定のため、指定に意味がある。X710 の SR-IOV や将来の PCIe パススルーで効く |

採用した5つのうち `intel-ucode`、`xe`、`iscsi-tools` は core 区分だが、`intel-npu` と `util-linux-tools` は contrib 区分である。
上流のサポート水準が異なる点は把握しておく。

discrete GPU を PCIe スロットに載せる場合は `siderolabs/mei`（Intel Arc の前提条件）が追加で要る。
現時点では載せないため含めない。

### ストレージ方式

DS923+ を SMB のまま使いたいという要望について、成立する範囲を確かめた。

CIFS は Talos のカーネルに組み込まれている（`CONFIG_CIFS=y`）ため、SMB マウント自体は動く。
ただし `CONFIG_CIFS_POSIX` は無効である。
ファイルごとの所有者とパーミッションを持てず、マウントオプションの `uid`、`gid`、`file_mode`、`dir_mode` で共有全体に一律の値が付く。

この制約が実害になるかは用途で分かれる。

| 用途 | SMB | 理由 |
| --- | --- | --- |
| 写真、動画などの大容量メディア | 使える | 読み取りが主体でファイルロックに依存しない。既存の SMB 運用をそのまま流用できる |
| データベース、アプリケーションの状態 | 使えない | POSIX のロックが期待どおりに効かず、SQLite や PostgreSQL でデータ破損の危険がある |

データベースとアプリケーションの状態はワーカーのローカルディスクに置く。
SMB の制約は残る用途に当たらないため、**DS923+ の SMB 運用は維持できる**。

`plan_old.md` の記述を1点訂正する。
「Synology API を通じて NFS 共有を動的プロビジョニング」とあるが、democratic-csi が Synology 向けに持つドライバは `synology-iscsi`（experimental）だけで、NFS 版は存在しない。
SMB を使う場合は democratic-csi ではなく `csi-driver-smb` を使う。

| 層 | ドライバ | バックエンド | 必要な拡張 |
| --- | --- | --- | --- |
| メディア（大容量、共有） | `csi-driver-smb` | DS923+ の SMB 共有 | なし（`mount.cifs` はドライバ Pod 内で動く） |
| ブロック（DB、アプリ状態） | Longhorn | ワーカーのローカルディスク | `iscsi-tools`、`util-linux-tools` |

**Longhorn はワーカーにのみ展開する。**
コントロールプレーンには taint があってワークロードが載らないため、そこにレプリカを置く意味がない。
DaemonSet が control-plane の taint を許容しないよう設定し、コントロールプレーンの schematic には `iscsi-tools` を含めない。

Longhorn は DS923+ の LUN に iSCSI で繋ぐためのものではない。
ボリュームをノードにアタッチする際に Longhorn 自身がイニシエータとターゲットの役割を果たすため、ノードに `iscsid` と `iscsiadm` が要る。
`util-linux-tools` はボリュームの trim に使う `fstrim` のために要る。
どちらも Longhorn の Talos 向けドキュメントが前提条件として挙げているものである。

Longhorn は namespace に `pod-security.kubernetes.io/enforce=privileged` を要求する。
Talos は既定で `baseline` を強制するため、この設定を入れないと動かない。

### 残っている作業

MS-03 固有の残作業は「TODO」節にまとめてある。

Intel Quick Sync と NPU を使うワークロードは初期スコープ外である。
それでも `xe` と `intel-npu` を最初の ISO に含めるのは、後から拡張を足すと `talosctl upgrade` と再起動が要るためである。
カーネルモジュールとファームウェアは拡張が用意するが、コンテナからアクセラレータを使うためのユーザー空間は別途要る。
Intel Device Plugin が `xe` と NPU のデバイスをどう公開するかは、実際に使う段階で確認する。

## 構築のフェーズ

ハードウェアは3段階で揃える。
コスト、設置スペース、ネットワーク機器の空きポートによる制約である。

| | コントロールプレーン | ワーカー | etcd メンバー | Longhorn レプリカ |
| --- | --- | --- | --- | --- |
| フェーズ1 | EliteDesk x1 | MS-03 x1 | 1 | 1 |
| フェーズ2 | EliteDesk x3 | MS-03 x1、S100-WLP x1 | 3 | 2 |
| フェーズ3 | EliteDesk x3 | MS-03 x2 | 3 | 2 |

フェーズ2の S100-WLP は、2台目の MS-03 を調達するまでのつなぎである。
フェーズ3で MS-03 に置き換わり、S100-WLP はクラスターから外れる。

**ソフトウェアの構成はフェーズをまたいで変えない。**
CNI も CSI もフェーズ1から最終形のものを入れる。
後から差し替えると PV の作り直しやデータ移送が発生するためであり、フェーズ間で変わるのは台数と、それに伴うレプリカ数だけにする。

### フェーズごとに変わること

**etcd のメンバー数**はフェーズ1で 1、フェーズ2以降で 3 になる。
フェーズ1でコントロールプレーンが落ちると API が使えなくなるが、ワーカー上で動いている Pod は動き続ける。

**Longhorn のレプリカ数**は 1、2、2 と推移する。
フェーズ2で S100-WLP を1台に留めるのは、この推移を単調にするためである。
2台入れてレプリカを 3 まで上げると、フェーズ3で 2 に落とす際にレプリカを削る操作が要る。

フェーズ2からフェーズ3への移行では、先に MS-03 の2台目を投入してワーカーを一時的に3台にする。
そのうえで S100-WLP のレプリカを退避させてから外せば、レプリカ数 2 を保ったまま入れ替えられる。

### フェーズごとの作業

**フェーズ1**

- [ ] EliteDesk 800 G6 を1台、`cp-1` として構築する
- [ ] MS-03 を `worker-1` として再投入する
- [ ] 「フェーズ1で入れるコンポーネント」を一式入れる
- [ ] Pi-hole を移設し、クラスター外の副 DNS を用意する
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

### フェーズ1の可用性について

フェーズ1はワーカーが MS-03 1台だけであり、Longhorn のレプリカも1つである。
このノードが落ちれば、その上のワークロードとボリュームは復旧まで到達できない。

家庭の DNS を担う Pi-hole をフェーズ1でクラスターに載せるため、**クラスター外に副の DNS を用意することが前提条件になる**。
UCG-Fiber 自身の DNS を副として配るか、別途 Backup DNS を立てる。
これはクラスターの構築対象外として扱う。

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
- [ ] **R4: Cilium BGP を UCG-Fiber と対向させる**（UCG-Fiber 側の FRR 設定が要る）
- [ ] **R5: Longhorn をワーカーにのみ展開する**（レプリカ1）
- [ ] **R6: Flux Operator と SOPS**
- [ ] **R7: cert-manager、Cloudflare Tunnel、external-dns**（ドメインと Cloudflare の API トークンが要る）

R1 から R3 が山場である。
ここが通れば残りは積み上げになる。

### R1 で変える設定

`talconfig.yaml` に次を足す。

```yaml
cniConfig:
  name: none
```

コントロールプレーンのパッチに次を足す。

```yaml
cluster:
  proxy:
    disabled: true
```

**これはクラスター構築時に効く設定である。**
後から変えるとノードの作り直しになるため、リハーサルで手順を固めておく価値がある。

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

### R2 で要る Cilium の設定

Talos は Cilium に対して固有の前提を持つ。
公式ガイド（Deploy Cilium CNI）が挙げているものと、kube-proxy 不在への対応をまとめる。

| 設定 | 値 | 理由 |
| --- | --- | --- |
| `ipam.mode` | `kubernetes` | Talos の要求 |
| `kubeProxyReplacement` | `true` | kube-proxy を置換する |
| `l7Proxy` | `true` | Gateway API の前提条件 |
| `k8sServiceHost` | `127.0.0.1` | KubePrism 経由で API に到達する |
| `k8sServicePort` | `7445` | 同上 |
| `cgroup.autoMount.enabled` | `false` | Talos が既に cgroupv2 を提供している |
| `bpf.autoMount.enabled` | `false` | Talos が既に bpffs を提供している |
| `securityContext.capabilities` | `SYS_MODULE` を除く | Talos はワークロードにカーネルモジュールのロードを許さない |

**`k8sServiceHost` には KubePrism を使う。**
KubePrism は Talos が各ノードの `127.0.0.1:7445` で提供する API プロキシで、コントロールプレーンが増えても追従する。
実 IP を直書きするとフェーズ2で3台に増やしたときに書き換えが要るため、こちらが適する。
`machine.features.kubePrism` は既定で有効であり、`KubePrismStatus` リソースで healthy を確認できる。

導入はまず `helm install` で最小構成を通し、動作を確認してから helmfile に落とす。
失敗したときに Cilium の問題か helmfile の問題かを切り分けるためである。

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

### R3 で足すもの

Gateway API の CRD は **experimental チャネル**の v1.6.1 を使う。
Cilium は `tlsroutes` と `backendtlspolicies` を含む7種を必須として要求し、`tlsroutes` は standard チャネルに存在しない。

`CiliumLoadBalancerIPPool` と `CiliumL2AnnouncementPolicy` は `bootstrap/cilium-networks.yaml` に置く。
プールは `192.168.20.200-250` で、これは「VLAN 20 のアドレス割り当て」で確保した帯である。
L2 Announcement は R4 で BGP に移すまでの確認用であり、ワーカーのみが広告するよう `nodeSelector` を付けている。

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

## 現在のクラスター

コントロールプレーンを EliteDesk 800 G6 に置き換えるまでの暫定構成である。

| ノード | 機器 | アドレス | 役割 |
| --- | --- | --- | --- |
| cp-1 | S100-WLP（morty） | 192.168.20.31 | コントロールプレーン |
| worker-1 | MS-03 | 192.168.20.41 | ワーカー |
| VIP | — | 192.168.20.100 | Kubernetes API エンドポイント |

Talos は v1.14.0、Kubernetes は v1.37.0。
CNI は Talos 既定の Flannel で、`allowSchedulingOnControlPlanes` は `false` にしてある。

cp-1 は USB Ethernet ドングル（`r8152`、MAC `6c:1f:f7:d3:99:42`）で接続している。
S100-WLP は3台のうち2台の内蔵 I226-V に物理層障害があり、そのための回避策である。

## 本構築

### 確定している方針

- **OS**：Talos Linux。設定管理は talhelper（`talconfig.yaml`）
- **コントロールプレーンの機種**：HP EliteDesk 800 G6 を3台。S100-WLP からの置き換えを数日中に行う
- **コントロールプレーンのイメージ**：標準 Talos を Image Factory の schematic で使う。拡張は `intel-ucode` のみ
- **CNI**：Cilium。kube-proxy を完全に置換し、eBPF モードで動かす。フェーズ1から入れる
- **Ingress**：Cilium の Gateway API 実装を使う。Ingress API の後継が Gateway API であり、Cilium が Core conformance を全通過しているため、専用の Ingress コントローラーを足さない。前提として `kubeProxyReplacement=true` と `l7Proxy=true` が要る
- **外部公開**：Cloudflare Tunnel。ルーターのポートを開けない
- **GitOps**：Flux v2。Flux Operator と FluxInstance で管理する。main ブランチへのマージをトリガーに反映する
- **CI/CD**：Flux の Webhook Receiver を使う。GitHub Actions はクラスターに触らない。push イベントを Cloudflare Tunnel 経由で受け、Flux が即座に Git を pull する。CI 側の仕事はマニフェストの検証と Renovate による更新 PR に限る
- **内部の名前解決**：external-dns の Pi-hole プロバイダーで、クラスターのホスト名を Pi-hole の Custom DNS に書き込む。DNS サーバーを別途立てない
- **ツール管理**：mise。ローカル環境の再現性を確保する
- **シークレット管理**：SOPS + age。暗号化済み Secret を Git にコミットする
- **リポジトリ構成**：`onedr0p/cluster-template` に準拠する
- **証明書**：cert-manager + Let's Encrypt。DNS-01 チャレンジに Cloudflare を使う
- **ワーカーノード**：MS-03。標準 Talos を Image Factory の schematic でカスタムして使う。2台目の MS-03 を調達するまでのつなぎに S100-WLP をワーカーに回す場合も、標準 Talos で動くことを確認済みである
- **Talos のバージョン**：全ノードを v1.14.0 に揃える。Kubernetes は v1.37.0
- **ストレージ**：大容量メディアは `csi-driver-smb` で DS923+ の SMB 共有へ。データベースとアプリケーションの状態は Longhorn でワーカーのローカルディスクへ。Longhorn はワーカーにのみ展開し、フェーズ1から入れる
- **LoadBalancer**：Cilium BGP。UCG-Fiber は UniFi OS 4.1.13 以降で BGP に対応しており、FRR 形式の設定ファイルをアップロードして構成する（Settings → Routing → BGP）

### フェーズ1で入れるコンポーネント

| namespace | コンポーネント | 役割 |
| --- | --- | --- |
| kube-system | cilium | CNI、kube-proxy 置換、L7 proxy、BGP、Gateway API |
| kube-system | coredns | クラスター内 DNS |
| kube-system | metrics-server | `kubectl top`、HPA |
| cert-manager | cert-manager | Let's Encrypt、DNS-01 チャレンジに Cloudflare |
| flux-system | flux-operator、flux-instance | GitOps と Webhook Receiver |
| network | cloudflare-tunnel | 外部公開 |
| network | external-dns（Cloudflare） | 公開 DNS レコード |
| network | external-dns（Pi-hole） | 内部 DNS レコード |
| longhorn-system | longhorn | ブロックストレージ |
| （未定） | pi-hole | 宅内 DNS |

**採用しないもの**：`kube-vip`、`envoy-gateway`、`traefik`、`k8s-gateway`、`spegel`、`reloader`

`onedr0p/cluster-template` はこれらを含むが、いずれも既に入るコンポーネントで代替できるか、この規模では要らない。
判断の根拠は [knowledge/cluster-template-evaluation.md](knowledge/cluster-template-evaluation.md) に記す。

### TODO

構築の本筋から外れるが、いずれ回収する項目である。

- [ ] **Pi-hole の冗長化**：クラスター内の Pi-hole を primary、Raspberry Pi 3 を replica として `nebula-sync` で設定を同期する。Pi-hole v6 では Gravity Sync も Orbital Sync も動かず、`nebula-sync` が現行の解になる。両方が v6 である必要がある。external-dns が書く Custom DNS のレコードを同期対象に含めるかは、意図を持って決める
- [ ] **10GbE で DS923+ との実効スループットを測る**：DS923+ を VLAN 20 に載せてから
- [ ] **MS-03 の本設置時の接続 NIC を決める**：X710 の SFP+ か RTL8127 の RJ-45 か。配線とあわせて決める
- [ ] **スイッチポートの VLAN 割り当てを記録する**：どのポートを VLAN 20 にしたかの記録がなく、MS-03 の投入時に一度つまずいた
- [ ] **EliteDesk のストレージが NVMe か SATA かを確認する**：実機が届いてから
- [ ] **MS-03 の NPU**：`intel_vpu` の probe が `-EIO` で失敗する。使う段になったらカーネルの更新か BIOS 設定を確認する

### バージョンとイメージの整合

同じクラスターのノードであるため、Talos のバージョンを揃える。
採用するのは v1.14.0 である（2026年9月3日リリース、上流の最新安定版）。

全ノードのイメージを Image Factory に揃える。

| ノード | インストーラーイメージ | 拡張 |
| --- | --- | --- |
| EliteDesk 800 G6 | `factory.talos.dev/metal-installer/2d61dd07b20062062ea671b4d01873506103b67c0f7a4c3fb6cf4ee85585dcb8:v1.14.0` | `intel-ucode` |
| MS-03 | `factory.talos.dev/metal-installer/b7f363548fe975dbb10e85983906f0c3f44ab3804b6246b677508ca1bb20d1f4:v1.14.0` | `intel-ucode`、`xe`、`intel-npu`、`iscsi-tools`、`util-linux-tools` |
| S100-WLP | `factory.talos.dev/metal-installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.14.0` | なし（素の schematic） |

S100-WLP をワーカーに回す場合は、Longhorn の前提条件を満たすために `iscsi-tools` と `util-linux-tools` を含む schematic に差し替える必要がある。

イメージが1系統に揃うため、Renovate で追跡先が分かれてバージョンがずれる問題は起きない。

`talosctl gen config` の既定値が素の schematic を指しているため、拡張が要らないノードでは `--install-image` を明示する必要すらない。

### 決定待ち事項

| 項目 | 選択肢 | 状況 |
| --- | --- | --- |
| フェーズ2で使う S100-WLP の個体 | morty / jerry / rick | Pi-hole がフェーズ1でクラスターに移るため、3台とも候補になる。容量とストレージ特性で選ぶ |
| S100-WLP 用のワーカー schematic | 未作成 | Longhorn の前提条件を満たすため `iscsi-tools` と `util-linux-tools` を含める |
| Ingress | Traefik / Cilium Gateway API | Cilium の稼働後 |
| BGP の ASN 設計 | クラスター側と UCG-Fiber 側の AS 番号 | プライベート ASN から選ぶ |
| MS-03 の接続 NIC | RTL8127（10G RJ-45）/ X710（SFP+） | 4つとも認識済み。本設置時に配線とあわせて決める |
| 監視 | kube-prometheus-stack | 未着手 |
| バックアップ | Git リポジトリ + DS923+ のスナップショット | 未着手 |
| Intel Quick Sync のパススルー | Intel Device Plugin | 初期スコープ外 |
| UniFi Protect の録画先 | UNVR / DS923+ / Kubernetes 上の NVR | 未着手 |

## リファレンス

- [knowledge/](knowledge/)：検証の記録と Talos の運用知見
- `plan_old.md`：前バージョンの計画。本構築フェーズの実装タスク案が残っている
- `physical-network-topology-plan.svg`：物理トポロジ図（将来導入する機器を含む）
- https://github.com/onedr0p/cluster-template：リポジトリ構成とソフトウェアスタックの参照元
