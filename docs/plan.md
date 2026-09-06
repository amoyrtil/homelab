# homelab 構築計画

## このドキュメントの位置づけ

homelab に Kubernetes クラスターと GitOps ベースの CI/CD を整備するための計画である。
コントロールプレーンに HP EliteDesk 800 G6 を3台、ワーカーに MINISFORUM MS-03 を使う本番構成を対象とする。

このドキュメントには決定した内容だけを書く。
なぜそう決めたかの根拠、検証の経過、途中で否定した仮説は [knowledge/](knowledge/) に置く。

前バージョンの計画は `plan_old.md` に退避した。
旧計画はハードウェア構成とネットワーク構成が未検証のまま、ファイル単位の実装タスクまで書き切っていた。
前提が覆れば計画全体が無効になる構造だったため、検証と設計を先に置く形に組み替えた。

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
| `siderolabs/iscsi-tools` | 採用 | democratic-csi の Synology 向けドライバは iSCSI のみ。将来使う可能性に備える |
| `siderolabs/util-linux-tools` | 採用 | iscsi-tools と組で使う |
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

データベースとアプリケーションの状態は、もともと OpenEBS Local PV（MS-03 の NVMe）に置く計画である。
SMB の制約は残る用途に当たらないため、**DS923+ の SMB 運用は維持できる**。

`plan_old.md` の記述を1点訂正する。
「Synology API を通じて NFS 共有を動的プロビジョニング」とあるが、democratic-csi が Synology 向けに持つドライバは `synology-iscsi`（experimental）だけで、NFS 版は存在しない。
SMB を使う場合は democratic-csi ではなく `csi-driver-smb` を使う。

| 層 | ドライバ | バックエンド | 必要な拡張 |
| --- | --- | --- | --- |
| メディア（大容量、共有） | `csi-driver-smb` | DS923+ の SMB 共有 | なし（`mount.cifs` はドライバ Pod 内で動く） |
| DB、アプリ状態（高速） | OpenEBS Local PV | MS-03 の NVMe | なし |
| ブロック（必要になった場合） | democratic-csi `synology-iscsi` | DS923+ の LUN | `iscsi-tools`、`util-linux-tools` |

### 残っている作業

構築そのものは完了しており、`worker-1` はクラスターに参加している。

- [ ] 10GbE で DS923+ との実効スループットを測る（DS923+ を VLAN 20 に載せてから）
- [ ] 本設置時の接続 NIC を決める（X710 の SFP+ か RTL8127 の RJ-45 か）

Intel Quick Sync と NPU を使うワークロードは初期スコープ外である。
それでも `xe` と `intel-npu` を最初の ISO に含めるのは、後から拡張を足すと `talosctl upgrade` と再起動が要るためである。
カーネルモジュールとファームウェアは拡張が用意するが、コンテナからアクセラレータを使うためのユーザー空間は別途要る。
Intel Device Plugin が `xe` と NPU のデバイスをどう公開するかは、実際に使う段階で確認する。

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
- **コントロールプレーンのイメージ**：標準 Talos を Image Factory の schematic で使う。EliteDesk 800 G6 は SATA と NVMe であり、UFS の制約を受けない
- **GitOps**：Flux v2。main ブランチへのマージをトリガーに反映する
- **ツール管理**：mise。ローカル環境の再現性を確保する
- **シークレット管理**：SOPS + age。暗号化済み Secret を Git にコミットする
- **リポジトリ構成**：`onedr0p/cluster-template` に準拠する
- **証明書**：cert-manager + Let's Encrypt。DNS-01 チャレンジに Cloudflare を使う
- **ワーカーノード**：MS-03。標準 Talos を Image Factory の schematic でカスタムして使う。2台目の MS-03 を調達するまでのつなぎに S100-WLP をワーカーに回す場合も、標準 Talos で動くことを確認済みである
- **Talos のバージョン**：全ノードを v1.14.0 に揃える。Kubernetes は v1.37.0
- **ストレージ**：大容量メディアは `csi-driver-smb` で DS923+ の SMB 共有へ。データベースとアプリケーションの状態は OpenEBS Local PV で MS-03 の NVMe へ

### バージョンとイメージの整合

同じクラスターのノードであるため、Talos のバージョンを揃える。
採用するのは v1.14.0 である（2026年9月3日リリース、上流の最新安定版）。

全ノードのイメージを Image Factory に揃える。

| ノード | インストーラーイメージ |
| --- | --- |
| EliteDesk 800 G6 | 未定。拡張の要否を決めてから schematic を作る |
| MS-03 | `factory.talos.dev/metal-installer/b7f363548fe975dbb10e85983906f0c3f44ab3804b6246b677508ca1bb20d1f4:v1.14.0` |
| S100-WLP | `factory.talos.dev/metal-installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.14.0`（素の schematic） |

イメージが1系統に揃うため、Renovate で追跡先が分かれてバージョンがずれる問題は起きない。

`talosctl gen config` の既定値が素の schematic を指しているため、拡張が要らないノードでは `--install-image` を明示する必要すらない。

### 決定待ち事項

| 項目 | 選択肢 | 状況 |
| --- | --- | --- |
| EliteDesk 800 G6 の schematic | 拡張の要否を決めて登録する | 未着手。これが決まらないとインストーラーイメージが確定しない |
| S100-WLP 3台の行き先 | ワーカーとして使う / 退役させる | 2台目の MS-03 の調達時期による。標準 Talos で動くことは確認済み |
| Pi-hole の移設先 | Kubernetes 上 / 別ハードウェア | 未着手。S100-WLP 1台を占有している |
| CNI | Cilium（kube-proxy 完全置換、eBPF モード） | ノード構成の確定後。現在は既定の Flannel |
| LoadBalancer | Cilium L2 Announcement（Pool: 192.168.20.200-250） | VLAN 20 確定済みのため着手可能 |
| Ingress | Traefik | CNI の稼働後 |
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
