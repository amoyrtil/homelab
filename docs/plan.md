# homelab 構築計画

## このドキュメントの位置づけ

homelab に Kubernetes クラスターと GitOps ベースの CI/CD を整備するための計画である。

前バージョンの計画は `plan_old.md` に退避した。
旧計画はハードウェア構成とネットワーク構成が未検証のまま、ファイル単位の実装タスクまで書き切っていた。
前提が覆れば計画全体が無効になる構造だったため、検証と設計を先に置く形に組み替えた。

このドキュメントでは、次の二つだけを確度高く固める。

- **ネットワーク設計**：将来導入する機器をすべて接続しても破綻しない VLAN 構成を、実装前に確定させる。
- **フェーズ1の検証**：MINISFORUM S100-WLP が etcd のコントロールプレーンノードとして使えるかを判定する。判定そのものは 2026年8月30日の Step 3 で終わっている。その後コントロールプレーンの機種を入れ替える方針が決まったため、現在のフェーズ1は残る検証項目を整理する段階にある。

本構築（Flux、Cilium、ストレージ、監視）は方針と決定待ち事項の整理に留める。
これらはフェーズ1の判定結果に依存するため、いま詳細化しても手戻りになる。

## 機材

保有状況によって、ネットワーク設計とクラスター検証で前提が異なる。

### 現在保有している機材

フェーズ1の検証はこの範囲だけで完結させる。

| 機器 | 台数 | 用途 |
| --- | --- | --- |
| UniFi Cloud Gateway Fiber | 1 | ルーター、VLAN、DHCP、ファイアウォール |
| アンマネージド 1GbE スイッチ | 1 | 検証では未使用（UCG-Fiber の LAN ポートに直結する） |
| MINISFORUM S100-WLP | 3 | 検証対象。コントロールプレーンノード候補 |
| MINISFORUM MS-03 | 1 | ワーカーノード |

S100-WLP 3台のうち1台は Ubuntu で Pi-hole を稼働させており、家庭内の DNS を担っている。
この1台を Talos に転用すると宅内の名前解決が止まるため、検証は 2台構成で進め、3台構成はフェーズ1の最後に回す。
3台化の前提条件は Pi-hole の移設先を確保することである。

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
- **DNS の常用系と待機系の役割分担**：現在は S100-WLP 1台の Ubuntu 上で Pi-hole が家庭内 DNS を担っている。トポロジ図の Backup DNS は待機系にあたる。Pi-hole を Kubernetes 上に移すなら、クラスター停止時のフォールバックとして Backup DNS が機能する構成になる。ただしフェーズ1の期間中は、検証で作り直しを繰り返すクラスターに家庭の DNS を載せるわけにはいかない。Backup DNS を先に常用系として立てるか、Pi-hole を別ハードウェアへ移すかを決める必要がある。
- **10GbE 配線の到達範囲**：前掲の「トポロジ図で確認が必要な点」を参照。

## フェーズ1: S100-WLP の etcd 性能評価

### 目的

S100-WLP は UFS ストレージを採用しており、Talos v1.13 までの標準カーネルには UFS ドライバが含まれない。
そのため `talos-ufs` のカスタムビルドが必須になる。
この制約は v1.14 で解消された。経緯は「Talos v1.14 への移行と talos-ufs の存廃」に記す。

このフェーズで判定するのは、UFS ストレージの fsync レイテンシが etcd に耐えるかである。
etcd はスループットではなく fsync 遅延で不安定になる。
判定結果に応じて、S100-WLP を継続するか HP EliteDesk 800 G6 に置き換えるかを決める。

### 前提の変更（2026年9月6日）

コントロールプレーン3台を HP EliteDesk 800 G6 に置き換える方針が決まった。
機種の二択を判定するというフェーズ1の目的は、この時点で失効している。

Step 3 までの測定結果は残す。
S100-WLP の UFS が etcd の fsync 要件を満たすことと、同じ機種でも個体によって定常時のレイテンシが違うことは、測定として成立しており、S100-WLP を別の役割で使うときの判断材料になる。

Step 4（3台構成への拡張と障害試験）は実施しない。
測る対象だった機種がコントロールプレーンから外れるため、結果を使う先がない。

S100-WLP の行き先は2つある。
2台目の MS-03 を調達するまでのあいだ、ワーカーとして使う可能性がある。
その場合、標準 Talos で起動できるかどうかが効いてくる。
`talos-ufs` はカスタムビルドであるため Image Factory による拡張の追加が使えず、ワーカーに `iscsi-tools` などが必要になった時点で行き詰まるからである。

### Step 0（完了済み）: fio による fdatasync レイテンシ測定

クラスターを組む前に、Live USB 上の fio でストレージ単体の fdatasync レイテンシを測定した。

```
fio --rw=write --ioengine=sync --fdatasync=1 \
    --directory=<測定対象> --size=22m --bs=2300 --name=etcd-fsync
```

**結果**：大半の書き込みは 10ms 以下で完了した。
ただしテスト後半、連続した書き込みが頻発する局面で1回だけ外れ値が発生した。
外れ値は 90ms 前後だったが、この数値は記憶によるもので裏付けが取れていない。
UFS ストレージの特性による頭打ちと考えられる。

この TODO は 2026年8月30日に「再測定しない」と判断して閉じた。
なお外れ値の存在そのものは、同日の Step 2.5 で etcd のメトリクスとして裏付けが取れている（64ms から 128ms が30分で17件）。

フェーズ1の主判定は Step 3 の etcd メトリクス（`etcd_server_leader_changes_seen_total` と `etcd_server_proposals_failed_total`）であり、fio の単体値は判定を分けない。
90ms という数値が裏付けを欠くことは、Step 3 の結果を解釈する際の留保として扱う。

**この結果が意味すること**：定常時の性能は etcd の要件を満たしている。
残る懸念は持続書き込み負荷下でのテールレイテンシに絞られた。

90ms という値は、etcd の既定 election timeout である 1000ms の 1割に満たない。
単発であればリーダー選出には至らない見込みである。
一方で既定の heartbeat interval 100ms とはほぼ同等の大きさであり、この規模の遅延が高頻度で発生すれば raft のハートビートが滞る。
したがって判定を分けるのは外れ値の大きさではなく **発生頻度** である。
以降の検証は「持続負荷下で外れ値がどの頻度で再現し、リーダー選出を誘発するか」を確かめることに集中する。
平均値や p99 だけを見ても判定できない。

### 検証構成

S100-WLP 2台と MS-03 1台を UCG-Fiber の LAN ポートに直結する。
アンマネージドスイッチは使わない。

UCG-Fiber には VLAN 20 だけを先に定義し、検証機を VLAN 20 に載せる。
本構築時のアドレス再採番を避けるためであり、この時点で Untrusted や Camera の設定まで行う必要はない。

| ノード | 機種 | アドレス | 役割 | 投入時期 |
| --- | --- | --- | --- | --- |
| cp-1 | S100-WLP | 192.168.20.31 | コントロールプレーン | Step 1 |
| cp-2 | S100-WLP | 192.168.20.32 | コントロールプレーン | Step 3 |
| cp-3 | S100-WLP | 192.168.20.33 | コントロールプレーン | Step 4（Pi-hole 移設後） |
| worker-1 | MS-03 | 192.168.20.41 | ワーカー | Step 3 |
| VIP | — | 192.168.20.100 | Kubernetes API エンドポイント | Step 3 |

### 既知の制約: S100-WLP の NIC 障害と USB NIC による回避

3台の S100-WLP のうち2台は、内蔵の Intel I226-V 2.5GbE でリンクが確立しない。
2026年8月11日の切り分けで、1000BASE-T と 2500BASE-T が使う 4-5 番ペアと 7-8 番ペアの信号経路にハードウェア障害があると判明した。
2ペアしか使わない 100BASE-TX は成立するため、100Mbps でのみリンクする。
経緯と否定した仮説の一覧は `info.md` に記録してある。

| 個体 | 役割 | 内蔵 I226-V | 検証で使う NIC |
| --- | --- | --- | --- |
| morty | cp-1 | 4ペアの物理層障害。10Mbps でのみ安定 | USB ドングル（`r8152`、1GbE） |
| jerry | cp-2 | 4ペアの物理層障害。100Mbps では安定 | USB ドングル（`r8152`、1GbE） |
| rick | cp-3 | 正常。2.5GbE をエラー0で確立 | 内蔵 I226-V |

cp-1 と cp-2 は USB Ethernet ドングルで接続する。
Talos は `r8152` と `ax88179` をカーネルに含むため、追加の拡張なしに動作する。

**ドングルは個体を入れ替えてはならない。**
UCG-Fiber 側で MAC アドレスに対する DHCP 予約を設定しているためである。

| ドングル MAC | ノード | 予約アドレス | 個体の内蔵 I226-V の MAC |
| --- | --- | --- | --- |
| `6c:1f:f7:d3:99:42` | cp-1 / morty | 192.168.20.31 | `58:47:ca:76:07:66` |
| `6c:1f:f7:d3:99:34` | cp-2 / jerry | 192.168.20.32 | `58:47:ca:7b:a8:48` |

入れ替えても、machine config を持つノードは静的アドレスで動き続けるため気付けない。
問題が出るのは machine config を持たないメンテナンスモードのときで、DHCP 予約に従って別ノードのアドレスを取りに行き、稼働中のノードと衝突する。
2026年9月6日の Stage B 準備中に実際に起きた。
内蔵 I226-V の MAC は個体に固定なので、どちらの機体かを見分ける手がかりになる。

machine config ではインターフェースを名前で指定せず、`deviceSelector` で `driver: r8152` を指定する。
`enp0s20f0u1` という名前は USB ポートの位置に依存し、差し替えのたびに変わるためである。

**USB-C 接続による 2.5GbE 化は、検証中は採らない。**
ドングルを USB-A から USB-C ポートに移すと 1GbE ではなく 2.5GbE でリンクすることは確認済みである。
ただし USB-C ポートの空きがなくなるため、給電を USB-C PD から内蔵 PoE に切り替える必要がある。
内蔵 PoE の PD 回路は、`info.md` §5.5 で 4-5 番ペアと 7-8 番ペアの障害の被疑箇所として挙げた部位そのものである。
原因が確定していない回路に給電を依存させると、リンクが不安定になったときの切り分けが成立しなくなる。
帯域はフェーズ1の判定指標ではないため、1GbE のまま進める。

### コントロールプレーン2台で本試験を行う理由

Pi-hole の稼働による台数制約は、この検証に限っては不利にならない。

etcd はメンバー数から quorum を決める。
2メンバーの quorum は 2 であり、すべてのコミットが両ノードの fsync 完了を待つ。
3メンバーの quorum は 2 なので、遅い1台の fsync を待たずにコミットが成立しうる。
つまり fsync のテールレイテンシに対しては **2台構成のほうが厳しい試験になる**。
S100-WLP の外れ値が commit を直撃するかを見るという目的には、2台構成が適している。

2台構成で成立しないのは障害試験だけである。
1台を落とすと quorum を失いクラスターが停止するため、リーダー選出時間の測定には3台目が要る。
そこで Step 4 を最後に置き、Pi-hole の移設が済んでから実施する。

### Step 1: talos-ufs イメージでの導入確認

`talos-ufs` のカスタムイメージを使うことは確定事項である。
標準の Talos ISO による S100-WLP の起動は検証済みで、成立しない。
標準 Talos のカーネルは UFS ドライバ（`ufshcd-pci`）を含まず、EFI パーティションが 100MiB 固定のため 4096バイトセクタに対応できない。
`talos-ufs` はこの2点を上流へのパッチで解消しており、S100-WLP（Intel N100 / 256GB UFS 2.1）は同プロジェクトの Verified Devices に登録されている。

cp-1（S100-WLP 1台）に `talos-ufs` の ISO で起動し、installer イメージで Talos を導入する。

```yaml
machine:
  install:
    disk: /dev/sda  # UFS デバイス
    image: ghcr.io/amoyrtil/talos-ufs-installer:v1.13.9
```

- [x] Secure Boot を無効化して `talos-ufs` の ISO から起動できること
- [x] メンテナンスモードで `talosctl get disks --insecure` に UFS ディスクが現れること
- [x] installer イメージによるインストールが完了し、ディスクから起動できること
- [x] 使用した `talos-ufs` のバージョンと対応する Talos バージョンを記録する

**2026年8月30日の実測（cp-1 / morty、メンテナンスモード）**

| 確認項目 | 結果 |
| --- | --- |
| Talos バージョン | `v1.13.9-dirty`（SHA `3ebd10a7-dirty`）。上流 v1.13.9 にパッチを当てたビルド |
| Secure Boot | `SecurityState.SECUREBOOT: false` |
| UFS ディスク | `sda` / 256GB / transport `ufshcd` / `KLUEG8U1EA-B0C1` |
| システム拡張 | なし（`talosctl get extensions` が空） |

インストール後のパーティション構成は次のとおりで、ディスクから起動して `STAGE: running` に到達した。

```
sda1  2.6 GB  vfat       EFI
sda2  1.0 MB  talosmeta  META
sda3  105 MB  xfs        STATE
sda4  253 GB  xfs        EPHEMERAL
```

EFI が 2.6GB で作られている点が、talos-ufs のパッチが効いている証拠である。
標準 Talos は EFI パーティションを 100MiB 固定で作るため、4096バイトセクタの UFS では成立しない。

インストール前の `/dev/sda` には Ubuntu 24.04 が残っていた（vfat 1.1GB と ext4 255GB）。
旧 GPT と旧 EFI の残骸を残さないよう `machine.install.wipe: true` でゼロクリアしてから導入した。

ISO に拡張は一つも含まれていない。
フェーズ1のコントロールプレーンは etcd を動かすだけで拡張を必要としないため、この時点では支障にならない。
ただし talos-ufs はカスタムビルドであり、Image Factory による拡張の追加が使えない。
将来コントロールプレーンに拡張が要る場合は、talos-ufs 側でイメージを作り直す必要がある。

この懸念は 2026年9月6日に解消した。
v1.14 の標準 Talos が S100-WLP で動くため、拡張が要るなら Image Factory の schematic に足せばよく、talos-ufs でイメージを作り直す必要がなくなった。

### Step 2: 単一コントロールプレーンでのメトリクス取得経路の確立

talhelper でコントロールプレーン1台の最小クラスターを構築する。
CNI は Talos 既定のままでよい。
etcd の評価に CNI の選択は影響しない。

etcd のメトリクスは既定では mTLS 付きのクライアントポートにしか出ない。
検証中は Talos の machine config に次を加え、認証なしのメトリクスエンドポイントを開ける。

```yaml
cluster:
  etcd:
    extraArgs:
      listen-metrics-urls: http://0.0.0.0:2381
```

これは検証専用の設定であり、本構築には持ち込まない。

- [x] `talosctl -n 192.168.20.31 etcd status` が応答すること
- [x] `curl http://192.168.20.31:2381/metrics` で etcd メトリクスが取得できること
- [x] 取得したメトリクスを継続記録する手段を用意する（Prometheus、または定期的な curl とログ保存）

**2026年8月30日の実測（cp-1 / morty、単一コントロールプレーン）**

| 確認項目 | 結果 |
| --- | --- |
| `talosctl etcd status` | 応答あり。メンバー `dd7677abffb26e5f`、自身がリーダー、etcd 3.6.12 |
| メトリクスエンドポイント | `http://192.168.20.31:2381/metrics` から `etcd_` 系 564 行を取得 |
| Talos VIP | `192.168.20.100/32` が `enp0s20f0u1` に付与された |

VIP は plan.md では Step 3 で有効化する予定だったが、Step 1 の時点で入れた。
`controlPlane.endpoint` は証明書と kubeconfig に焼き込まれるため、後から VIP に切り替えると設定一式の再生成になる。
単一コントロールプレーンでも VIP は成立するため、最初から `https://192.168.20.100:6443` を採用した。

**継続記録の手段**

Prometheus は使わない。
コントロールプレーン上で動かすと、測定対象そのものに I/O を足すことになるためである。
代わりに手元の Mac から定期的に curl するスクリプトを置いた。

| ファイル | 役割 |
| --- | --- |
| `talos/phase1/collect-etcd-metrics.sh` | 指定間隔で `:2381/metrics` を取得し、判定に使うメトリクスとリンク状態を TSV に追記する |
| `talos/phase1/analyze-etcd-metrics.py` | 収集結果から主判定の増分と、fsync / commit の分位点および閾値超過の件数を出す |

```bash
talos/phase1/collect-etcd-metrics.sh runs/step3-load 15 192.168.20.31 192.168.20.32
talos/phase1/analyze-etcd-metrics.py runs/step3-load
```

**「10ms 超」の測定について**

etcd の `wal_fsync` ヒストグラムのバケット境界は 1ms から 2 のべき乗で刻まれており、10ms の境界を持たない。
したがって「10ms を超える fsync の発生頻度」は、そのままでは測れない。
最も近い実測可能な境界は **8ms** であり、以降はこれを 10ms の代理として扱う。
8ms は 10ms より厳しい側に倒れているため、判定が甘くなる方向の誤差は生じない。

最大値も同様にバケット単位でしか言えない。
`max` は「この境界以下」という上限として記録する。

### Step 2.5: 単一コントロールプレーンでの先行負荷試験

cp-2 と worker-1 が揃う前に、cp-1 だけで持続負荷をかけた。
2台構成のほうが厳しい試験であることは変わらないが、単一構成で落ちるなら2台を待つ必要がない。
早期に不合格が分かれば機材の判断も早まる、という理由で Step 3 の前に実施した。

負荷は手元の Mac から kubectl で Secret を作っては消すループを20並列で回した。
コントロールプレーン上に負荷生成器を置いていないのは、測定対象に etcd 以外の I/O を足さないためである（Step 5 の緩和策3と同じ考え方）。

```bash
talos/phase1/run-step.sh step2-1cp 1800 1800 192.168.20.31
```

**2026年8月30日の結果（cp-1 / morty、単一コントロールプレーン、負荷 119 ops/s）**

| 指標 | 定常30分 | 負荷30分 |
| --- | --- | --- |
| `wal_fsync` 観測数 | 3,182 | 186,337 |
| `wal_fsync` p50 | 0.57ms | 1.72ms |
| `wal_fsync` p99 | 1.93ms | 10.69ms |
| `wal_fsync` p99.9 | 2.55ms | 26.23ms |
| `wal_fsync` 最大 | 8ms 以下 | 128ms 以下 |
| 8ms 超の割合 | 0.000% | 1.405% |
| 16ms 超 | 0 件 | 375 件 (0.201%) |
| 32ms 超 | 0 件 | 80 件 (0.043%) |
| 64ms 超 | 0 件 | 17 件 (0.009%) |
| `backend_commit` p99 | 3.65ms | 21.39ms |
| `backend_commit` 25ms 超 | 0 件 | 251 件 (1.435%) |
| `leader_changes_seen_total` | 増加なし | 増加なし |
| `proposals_failed_total` | 0 | 0 |
| USB NIC のリンク変化 | なし | なし |

**Step 0 の外れ値は再現した。**
64ms から 128ms の帯域に30分で17件、およそ1分に0.6回の頻度で発生している。
「90ms 前後の外れ値が1回」という記憶による記述は、持続負荷下では裏付けが取れたことになる。
同時に、この頻度と大きさではリーダー選出に至らないことも確認できた。

定常状態では 8ms を超える fsync が3,182件中1件も出ていない。
外れ値は UFS の定常的な性質ではなく、持続書き込みが誘発するものである。

**この結果の読み方には留保が要る。**
単一メンバーの etcd には raft のレプリケーションもピア間通信も存在せず、自ノードが常にリーダーであってリーダー選出の機会自体がない。
したがって `leader_changes_seen_total` が増えないことは、2メンバー構成での同じ結果に比べて弱い証拠にしかならない。
このステップで確かめられたのは「UFS の fsync 分布が 186,337 サンプルで 128ms 以内に収まる」という**ディスク単体の事実**までである。
可否の判定は Step 3 で行う。

### Step 3: コントロールプレーン2台での持続書き込み負荷試験

cp-2 と worker-1 を投入し、コントロールプレーン2台とワーカー1台の構成にする。
Talos VIP（192.168.20.100）もここで有効にする。
このステップがフェーズ1の本命である。

etcd に継続的な書き込みを発生させ、Step 0 で観測した外れ値がクラスター上で再現するかを見る。
Secret と ConfigMap の作成と削除を繰り返すループ、または kube-burner を使う。
raft のレプリケーションが加わることで、単体ベンチとは異なる fsync パターンになる。

- [x] 30分から60分の連続負荷をかける
- [x] `etcd_disk_wal_fsync_duration_seconds` の p99、p99.9、max を記録する
- [x] `etcd_disk_backend_commit_duration_seconds` の p99 を記録する
- [x] `etcd_server_leader_changes_seen_total` の増加を監視する
- [x] `etcd_server_proposals_failed_total` を監視する
- [x] **10ms を超える fsync の発生頻度**を記録する（判定を分けるのは最大値ではなく頻度である）
- [x] 負荷を止めた定常状態でも同じ指標を30分記録し、負荷時との差を取る

**USB NIC 起因との切り分け**

cp-1 と cp-2 は USB ドングルで接続する。
このステップの主判定である `etcd_server_leader_changes_seen_total` は、UFS の fsync 遅延だけでなく、raft のピア間通信が滞っても増える。
切り分けの手段を用意しないと、リーダー選出が起きたときに機種の判定そのものが下せない。

- [ ] `etcd_network_peer_round_trip_time_seconds` の p99 を記録する（ネットワーク側の遅延を fsync 側と分離する）
- [ ] 両ノードの USB NIC のリンクフラップを記録する（`LinkStatus` の VERSION 増加、または `talosctl dmesg` の carrier 変化）
- [ ] `leader_changes` が増えた場合、同時刻に fsync の外れ値があったのかリンクフラップがあったのかを突き合わせる

fsync の外れ値と無関係にリーダー選出が起きるなら、それは UFS ではなく USB NIC の問題であり、S100-WLP の可否判定には使えない。

- [x] `etcd_network_peer_round_trip_time_seconds` の p99 を記録する
- [x] 両ノードの USB NIC のリンクフラップを記録する
- [x] `leader_changes` が増えた場合の突き合わせ（増加しなかったため該当なし）

### Step 3 の結果

worker-1（MS-03）は投入していない。
etcd の fsync 判定にワーカーの有無は効かないため、cp-2 が揃った時点で先に実施した。
MS-03 は別途セットアップする。

```bash
talos/phase1/run-step.sh step3-2cp 1800 1800 192.168.20.31 192.168.20.32
```

事前に両メンバーで `talosctl etcd defrag` を実行した。
Step 2.5 の負荷で boltdb が 291MB まで膨らみ、利用率が 0.40% まで落ちていたためである。
断片化した状態のまま測ると、ディスクを測っているのか蓄積した断片化を測っているのか分からなくなる。
defrag 後は 1.2MB、利用率 100%、alarm なしから開始した。

**2026年8月30日の結果（cp-1 + cp-2、2メンバー、負荷 110 ops/s、30分）**

| 指標 | cp-1（morty / 256GB） | cp-2（jerry / 128GB） |
| --- | --- | --- |
| `wal_fsync` 観測数 | 176,608 | 174,722 |
| p50 | 1.55ms | 0.80ms |
| **p99** | **7.98ms** | **6.63ms** |
| p99.9 | 24.62ms | 31.32ms |
| 最大 | 128ms 以下 | 128ms 以下 |
| 8ms 超 | 0.962% | 0.871% |
| 16ms 超 | 0.166% | 0.596% |
| 32ms 超 | 0.043% | 0.078% |
| 64ms 超 | 9 件 (0.005%) | 2 件 (0.001%) |
| **`backend_commit` p99** | **20.72ms** | **28.11ms** |
| `backend_commit` p99.9 | 44.63ms | 56.87ms |
| `backend_commit` 25ms 超 | 1.356% | 2.836% |
| `peer_rtt` p99 | 25.30ms | 25.28ms |
| **`leader_changes_seen_total`** | **増加なし** | **増加なし** |
| **`proposals_failed_total`** | **増加なし** | **増加なし** |
| VIP の移動 | なし（cp-1 が保持） | — |
| リンクのフラップ | 0 回 | 0 回 |

同条件の定常30分では、cp-1 の 8ms 超が 4,391件中0件、cp-2 が 4,136件中3件だった。
外れ値は持続書き込みが誘発するものであり、UFS の定常的な性質ではない。

**外れ値は集中していない。**
15秒区間あたりの 8ms 超は、cp-1 が中央値13件・最大22件、cp-2 が中央値8件・最大25件だった。
最悪区間でも区間内 fsync の 1.6% 程度で、連続する heartbeat interval を埋める密度には遠い。
最大値も 128ms 以下であり、election timeout の既定 1000ms に対して1割強にとどまる。

**判定：主判定を両ノードで満たした。**
2メンバーの quorum では全コミットが両ノードの fsync 完了を待ち、リーダー選出の機会も存在する。
その条件で30分の持続負荷をかけてリーダー選出も提案失敗も発生しなかった。

副判定では `wal_fsync` p99 が両ノードとも 10ms を下回り、Step 2.5 の単一構成（10.69ms）より改善した。
外れたのは cp-2 の `backend_commit` p99 の 28.11ms（目安 25ms 未満）だけである。
plan.md の基準どおり、主判定を満たすため S100-WLP は使えると判定する。

### 判定の枠組みについて

合否基準は「S100-WLP か EliteDesk か」という機種の二択で書かれているが、この枠組みは実態に合っていない。

| 指標（定常30分、無負荷） | cp-1 / morty | cp-2 / jerry |
| --- | --- | --- |
| `wal_fsync` 8ms 超 | 0 件 / 4,391 | 3 件 / 4,136 |
| `wal_fsync` 最大 | 8ms 以下 | 64ms 以下 |
| `backend_commit` p99.9 | 4.26ms | 29.41ms |
| `backend_commit` 25ms 超 | 0 件 | 7 件 |

無負荷の時点で個体差が出ている。
UFS は morty が 256GB の `KLUEG8U1EA-B0C1`、jerry が 128GB の `KLUDG4U1EA-B0C1` で、容量も型番も異なる。
NIC について info.md が示したのと同じ構図が、ストレージにも現れている。

したがって判定は「機種として使えるか」ではなく「この個体を使うか」で下す。
S100-WLP という機種に etcd が耐えないという結論は、今回の測定からは出ない。

ここで主判定を満たさなければ Step 5 の緩和策に進む。
主判定は満たしたため、Step 5 には進まない。

### Step 4: コントロールプレーン3台への拡張と障害試験（実施しない）

コントロールプレーンを EliteDesk 800 G6 に置き換えるため、このステップは実施しない。
S100-WLP のリーダー選出時間を測っても、その値を使う構成が存在しないからである。
以下は当初の計画として残す。

Pi-hole の移設が済んでから実施する。
cp-3 を投入して3台構成にする。

3台化により quorum が 3 分の 2 になり、遅いノード1台の fsync を待たずにコミットが成立するようになる。
Step 3 より条件は緩む。
このステップの目的は、テールレイテンシの再評価ではなく、ノード障害時の挙動を測ることにある。

- [ ] Pi-hole の移設先を決めて移す
- [ ] cp-3 を投入し、3メンバーの etcd が正常化することを確認する
- [ ] コントロールプレーン1台を電源断し、リーダー選出に要する時間を測る
- [ ] 復帰後の再同期に要する時間を測る
- [ ] Step 3 と同じ負荷をかけた状態で電源断を繰り返す

### 合否基準

主判定で1つでも外れたら、Step 5 の緩和策を試す。
緩和策でも満たせないなら EliteDesk に置換する。

**主判定**

| 指標 | 合格ライン |
| --- | --- |
| `etcd_server_leader_changes_seen_total` | 30分の持続負荷中に増加しない |
| `etcd_server_proposals_failed_total` | 0 |

**副判定（傾向の把握）**

| 指標 | 目安 | 出典 |
| --- | --- | --- |
| `etcd_disk_wal_fsync_duration_seconds` p99 | 10ms 未満 | etcd 公式のハードウェア推奨 |
| 同 p99.9 および max | election timeout（既定 1000ms）に対して十分小さい | — |
| 10ms 超の fsync の発生頻度 | 連続する heartbeat interval（既定 100ms）を埋めない程度 | — |
| `etcd_disk_backend_commit_duration_seconds` p99 | 25ms 未満 | etcd 公式のハードウェア推奨 |

副判定を外れても主判定を満たすなら、S100-WLP は使える。
外れ値がリーダー選出に至らない範囲に収まっているという意味になる。

### Step 5: 主判定を外れた場合の緩和策

置換を決める前に、次を順に試す。

1. **etcd のタイミングパラメータを緩める**：`cluster.etcd.extraArgs` で `election-timeout` と `heartbeat-interval` を引き上げ、fsync の外れ値を吸収できるようにする。フェイルオーバー時間との引き換えになる。
2. **書き込み量を減らす**：自動 compaction の間隔と defrag のタイミングを調整する。
3. **コントロールプレーンのワークロードを排除する**：`node-role.kubernetes.io/control-plane:NoSchedule` の taint を確実に効かせ、etcd 以外の I/O を CP ノードから除く。

これらで主判定を満たせない場合、S100-WLP 3台を EliteDesk 3台に置き換える。

## Talos v1.14 への移行と talos-ufs の存廃

### 上流が UFS に対応した経緯

2026年9月3日にリリースされた Talos v1.14.0 で、標準カーネルが UFS ホストコントローラに対応した。

きっかけは `siderolabs/pkgs` の issue #1619 である。
S100 を名指しした報告で、UFS が唯一の内蔵ストレージである安価な x86 ミニ PC が増えているのに Talos ではディスクが見えずインストールできない、ドライバがモジュールとしてすら作られていないのでシステム拡張や Image Factory の schematic では回避できない、という内容だった。

対応は pkgs#1620 と talos#13793 に分かれており、どちらも v1.14 に入っている。

| リポジトリ | 変更 |
| --- | --- |
| `siderolabs/pkgs` | `CONFIG_SCSI_UFSHCD=m` と `CONFIG_SCSI_UFSHCD_PCI=m` を有効化 |
| `siderolabs/talos` | `hack/modules-amd64.txt` に `ufshcd-core.ko`、`ufshcd-pci.ko`、`governor_simpleondemand.ko` を追加 |

issue の要望は `=y`（組み込み）だったが、実装は `=m`（モジュール）になった。
Talos は `hack/modules-amd64.txt` に載っているモジュールを initramfs に含めて自動ロードするため、モジュールでも起動ディスクとして成立する。

報告者は修正後の実機確認を issue にコメントしている。
使われた個体は Intel N100 の Minisforum S100 で、UFS は Samsung `KLUEG8U1EA-B0C1` である。
cp-1（morty）と同じ型番である。
内蔵 UFS が `ufshcd` transport の `/dev/sd*` として現れ、インストールが通り、外部メディアなしで再起動を繰り返しても healthy を保ち、etcd を含む単一ノードクラスターが立ち上がったと報告されている。

### 2つのパッチが上流でどうなったか

`talos-ufs` が上流に当てているパッチは2つである。

**`kernel-config.patch`** は、UFS 関連の config を `=m` から `=y` へ引き上げる。
パッチの文脈行が示すとおり、当てる相手はすでに `=m` になった v1.14 の config である。
README にある「`=m` では動かない」という記述は、モジュールが `hack/modules-amd64.txt` に載っていなかった時点のものであり、v1.14 では成立しない。

**`efi-partition-size.patch`** は、`GrubEFISize()` を 100MiB から 512MiB に引き上げる。
4096バイトセクタのデバイスに FAT32 を作るには、最小クラスタ数 65525 を満たすために 256MiB 強が要るためである。

ただし S100 へのインストールは、このパッチが効く経路を通っていない。
Step 1 で記録したパーティション構成には BIOS も BOOT もなく、EFI が 2.6GB になっている。
これは UKI レイアウトであり、その EFI サイズは次の式で決まる。

```
UKIEFISize = GrubEFISize + GrubBIOSSize + GrubBootSize
```

パッチ後の値を入れると `512 + 1 + 2000 = 2513 MiB` で、10進の 2.6GB になる。
Step 1 の実測と一致する。
上流のままなら `100 + 1 + 2000 = 2101 MiB` で、これも 256MiB を大きく上回る。
`efi-partition-size.patch` は GRUB レイアウトに対する保険としては意味を持つが、S100 が通る UKI レイアウトでは効いていない。

上流のメンテナも `siderolabs/talos` の issue #13227 で、ISO や PXE から起動して通常どおりディスクにインストールする経路なら Talos は 4k セクタのディスクに正しくインストールできる、あの issue はディスクイメージだけの話である、と述べている。

机上では、v1.14 において `talos-ufs` の存在理由は失われている。
残るのは実機での確認である。

### 検証（cp-2 / jerry）

cp-2 を etcd から外し、標準 Talos v1.14 の検証に使う。
検証後にクラスターへ戻さない。

使う ISO は素の schematic（拡張もカーネル引数もなし、ID は `376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba`）のものである。

```
https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v1.14.0/metal-amd64.iso
```

**Stage B（非破壊）**

- [x] 標準 v1.14 の ISO から起動し、メンテナンスモードに入る
- [x] `talosctl get disks --insecure` に `sda` が transport `ufshcd` で現れる
- [x] `KernelModuleStatus`（v1.14 で追加。`LoadedKernelModule` は非推奨）で `ufshcd_pci` がロード済みである

**Stage C（インストール）**

- [x] 素の schematic の installer で machine config を適用し、インストールが完了する
- [x] ディスクから起動し `STAGE: running` に到達する
- [x] パーティション構成を記録する。EFI が 256MiB 以上であること
- [x] 再起動を数回繰り返しても安定していることを確認する

### 検証の結果（2026年9月6日、cp-2 / jerry）

**Stage B**：標準 v1.14.0 の ISO（SHA `9abd05af`、`-dirty` なし）でメンテナンスモードに入り、UFS ディスクが見えた。

| 確認項目 | 結果 |
| --- | --- |
| Talos バージョン | `v1.14.0`。上流の素のビルドで、パッチは当たっていない |
| UFS ディスク | `sda` / 128GB / transport `ufshcd` / `KLUDG4U1EA-B0C1` |
| Secure Boot | `false` |

`KernelModuleStatus` では、上流が `hack/modules-amd64.txt` に追加した3つがすべて `dynamic` かつ `live` だった。

```
governor_simpleondemand   dynamic   live
ufshcd_core               dynamic   live
ufshcd_pci                dynamic   live
```

talos-ufs の README にある「`=m` では動かない」は、モジュールが `hack/modules-amd64.txt` に載っていなかった時点の記述であり、v1.14 では成立しない。

**Stage C**：使い捨ての単一ノードクラスターとして構築し、インストールから起動、クラスター稼働までを通した。

インストール後のパーティション構成は次のとおりで、BIOS も BOOT もない UKI レイアウトである。

```
sda1  2.2 GB  vfat       EFI
sda2  1.0 MB  talosmeta  META
sda3  105 MB  xfs        STATE
sda4  126 GB  xfs        EPHEMERAL
```

**EFI の 2.2GB は `GrubEFISize 100 + GrubBIOSSize 1 + GrubBootSize 2000 = 2101 MiB` と一致する。**
talos-ufs を使った Step 1 の実測が 2.6GB だったのは、`GrubEFISize` を 512MiB に上げた差分そのものである。
上流の 100MiB のままでも、4096バイトセクタで FAT32 の最小クラスタ数 65525 を満たすのに必要な 256MiB 強を大きく上回る。
`efi-partition-size.patch` が S100 の経路で効いていないという机上の推定が、実測で裏付けられた。

クラスターとしても成立した。

| 確認項目 | 結果 |
| --- | --- |
| Node | `Ready`、Kubernetes `v1.37.0` |
| Talos | `v1.14.0`、カーネル `6.18.48-talos` |
| STAGE / READY | `running` / `true` |
| etcd | 3.7.1、単一メンバーでリーダー、healthy |
| システム Pod | CoreDNS 2つ、flannel、kube-proxy、apiserver、controller-manager、scheduler がすべて Running |
| ワークロード | nginx の Deployment と Service を作成し、クラスター内から HTTP 200 |
| 外部メディアなしの再起動 | USB を抜いた状態で3回繰り返し、いずれも `stage: RUNNING` に復帰。3回目のあとも Node は `Ready`、nginx も再スケジュールされて Running |

**判定：`talos-ufs` は役目を終えた。**

Stage B と Stage C の両方を満たした。
`talos-ufs` が当てている2つのパッチは、どちらも v1.14 の上流で不要になっている。

| パッチ | 上流での代替 | 実測による裏付け |
| --- | --- | --- |
| `kernel-config.patch` | `=m` と `hack/modules-amd64.txt` への登録 | 3つのモジュールが `dynamic` かつ `live`。UFS ディスクを認識 |
| `efi-partition-size.patch` | 不要。UKI レイアウトの EFI は 2101 MiB になる | EFI 実測 2.2GB |

アーカイブする際は、v1.14 以降は上流の標準イメージを使うよう README に案内を残す。
Verified Devices に載っているのは S100-WLP だけだが、他の UFS 機種の利用者が同じ判断を下せるようにするためである。

なお、この検証で cp-2 には使い捨ての単一ノードクラスター（`ufs-verify`）が載ったままである。
本番クラスターとは無関係で、S100-WLP を次の用途に回すときに消してよい。

### クラスターの移行手順

現在のクラスターは検証目的で組んだものであり、破壊的な変更を許容する。
etcd のスナップショットは取らない。
コントロールプレーンは数日中に EliteDesk 800 G6 へ全置換するため、いずれ再構築する。

**Phase 0：復旧**

- [ ] cp-1（morty）と cp-2（jerry）の電源を入れる
- [ ] 作業端末を VLAN 20 に載せる
- [ ] v1.13.9 のクラスターが2メンバーで戻ることを確認する

**Phase 1：cp-2 で標準 v1.14 を検証**

- [x] cp-2 を graceful reset でクラスターから外す（etcd が1メンバーに縮退する）
- [x] Stage B と Stage C を実施する
- [x] 結果をこのドキュメントに記録する

2メンバーの etcd は quorum が 2 であり、どちらを再起動してもクラスターが止まる。
cp-2 を先に外して1メンバーにしておけば、続く cp-1 のアップグレードで止まるのは cp-1 の再起動のあいだだけになる。

**Phase 2：cp-1 を v1.14 で作り直す**

当初は `talosctl upgrade` で talos-ufs から標準イメージへ乗り換える計画だった。
Stage C でクリーンインストールが通ったこと、そしてコントロールプレーンを EliteDesk 800 G6 に置き換える以上、アップグレード経路を確かめる価値が下がったことから、作り直す方針に変えた。
EliteDesk への移行のリハーサルにもなる。

- [x] `talconfig.yaml` の `talosVersion` を `v1.14.0`、`kubernetesVersion` を `v1.37.0` にする
- [x] cp-1 のインストーラーイメージを素の schematic に変える
- [x] cp-2 のノード定義を削除する（`wipe: true` パッチもここで外れる）
- [x] `talosctl reset --graceful=false --wipe-mode all` で cp-1 を消去する
- [x] 標準 v1.14 の ISO から起動し、生成した machine config を適用する
- [x] `talosctl bootstrap` でクラスターを起こす

**結果（2026年9月6日）**

| 項目 | 結果 |
| --- | --- |
| Node | `cp-1` が `Ready`、Kubernetes `v1.37.0` |
| Talos | `v1.14.0`、カーネル `6.18.48-talos` |
| EFI パーティション | 2.2GB。256GB の morty でも 128GB の jerry と同値 |
| etcd | 3.7.1、リーダー、healthy |
| VIP | cp-1 が保持。`kubectl` も VIP 経由で疎通 |

`talsecret.sops.yaml` を変えていないため、etcd のメンバー ID は再構築前と同じ `dd7677abffb26e5f` のままで、既存の talosconfig と kubeconfig がそのまま使える。

**talhelper は v1.14 の設定形式に対応している。**
3.1.17 のリリースは Talos v1.14.0 より前だが、v1.14 で独立ドキュメントに移った設定を正しく生成する。

| 設定 | v1.14 での行き先 |
| --- | --- |
| ホスト名 | `HostnameConfig` |
| ネームサーバー | `ResolverConfig` |
| `deviceSelector` | `LinkAliasConfig` |
| 静的アドレスと経路 | `LinkConfig` |
| VIP | `Layer2VIPConfig` |
| インストール先とイメージ | `machine.install`（v1alpha1 のまま） |

同じ設定を v1alpha1 と独立ドキュメントの両方に書くと、v1.14 は適用時に拒否する。
手書きでパッチを当てるときは、どちらか一方に寄せる必要がある。

**Phase 3：MS-03 を投入して2台体制**

- [x] `talos/schematics/ms03-schematic.yaml` を作成する
- [ ] MS-03 を v1.14.0 で構築する（手順は「MS-03 のセットアップ」）
- [ ] worker-1 がクラスターに参加し Ready になる
- [ ] 既定の Flannel のまま、単純な Deployment と Service をデプロイして疎通を確認する

`allowSchedulingOnControlPlanes` が `false` であるため、ワーカーがなければワークロードは動かない。
この検証は、MS-03 がクラスターに参加したこと自体の確認を兼ねる。

CNI を Cilium に差し替えるのはフェーズ2の課題として分離する。
ここで同時に入れると、Pod が動かなかったときに MS-03 側の問題か CNI 側の問題かを切り分けられなくなる。

MS-03 の ISO 作成からメンテナンスモードでの NIC とディスクの確認までは、Phase 1 および Phase 2 と並行して進められる。

### v1.14 で変わった点のうち、この構成に効くもの

| 変更 | 影響 |
| --- | --- |
| `ghcr.io/siderolabs/installer` がリリースで公開されなくなった | 標準 Talos を使う場合も Image Factory 経由のインストーラーイメージが要る。`talosctl gen config` の既定値が素の schematic（`376567...`）を指す `factory.talos.dev/metal-installer/376567...:v1.14.0` になっており、`--install-disk` も `/dev/sda`、`--kubernetes-version` も `1.37.0` が既定である。`factory.talos.dev/installer/` の旧パスも 200 を返すが、生成される正規のパスは `metal-installer` である |
| etcd が 3.7.1 になり、`/metrics` などの HTTP エンドポイントが 2383 に移動 | `listen-metrics-urls` を明示している場合は移動しない。フェーズ1のスクリプトが使う 2381 はそのまま効く |
| Kubernetes の既定が 1.37.0 | `kubernetesVersion` を v1.36.2 から上げる |
| `LoadedKernelModule` が非推奨、`KernelModuleStatus` を追加 | モジュールのロード確認は新しいリソースを使う |
| Linux が 6.18.44 から 6.18.48 へ | どちらも 6.18 系であり、MS-03 の RTL8127 に対する見込みは変わらない |

## MS-03 のセットアップ

MS-03 はワーカーノードとして確実に稼働させる。
コントロールプレーンの機種判定に依存しないため、フェーズ1と並行して本番構成のまま構築する。
成果物は Step 3 の worker-1 としてそのまま投入する。

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

Talos v1.14.0 のカーネルは Linux 6.18.48 である（v1.13.9 は 6.18.44）。
RTL8127 のメインライン対応は 6.15 で `r8169` に入り、6.18 でシャットダウン時のハング修正が加わっている。
バージョン上は動作するはずだが、対応が入って日が浅い。

トポロジ図では MS-03 を USW-Pro-XG-10-PoE の RJ-45 ポートに接続する想定になっており、この経路は RTL8127 に依存する。
実機で認識しなかった場合の退避先を用意しておく。
X710（SFP+）は i40e で長く枯れているため確実だが、USW-Pro-XG-10-PoE の SFP28 ポートは2口しかなく、うち1口は UCG-Fiber への上流で埋まる。
暫定策として i226-LM の 2.5GbE で運用を始める手もある。

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

### バージョンの整合

同じクラスターのノードであるため、Talos のバージョンを揃える必要がある。
採用するのは v1.14.0 である（2026年9月3日リリース、上流の最新安定版）。

cp-2 での検証が通ったため、全ノードのイメージが Image Factory に揃う。

| ノード | インストーラーイメージ |
| --- | --- |
| S100-WLP | `factory.talos.dev/metal-installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.14.0`（素の schematic） |
| MS-03 | `factory.talos.dev/metal-installer/b7f363548fe975dbb10e85983906f0c3f44ab3804b6246b677508ca1bb20d1f4:v1.14.0` |
| EliteDesk 800 G6 | 未定。拡張の要否を決めてから schematic を作る |

イメージが1系統に揃うため、talos-ufs の公開待ちにバージョンを縛られる制約も、2系統を Renovate で追ってずれる問題もなくなった。

`talosctl gen config` の既定値が素の schematic を指しているため、拡張が要らないノードでは `--install-image` を明示する必要すらない。

### 手順

- [x] `talos/schematics/ms03-schematic.yaml` を作成する
- [x] Image Factory に POST し、schematic ID をリポジトリに記録する
- [ ] ISO をダウンロードして USB に書き込む
- [ ] Secure Boot を無効化して起動し、メンテナンスモードに入る
- [ ] `talosctl get links --insecure` で4つの NIC が見えることを確認する（X710 x2、RTL8127、i226-LM）
- [ ] RTL8127 が認識されない場合の接続方法を決める（SFP+ か 2.5GbE 暫定運用）
- [ ] `talosctl get disks --insecure` で NVMe を確認し、インストール先を決める
- [ ] talhelper で machine config を生成し、`192.168.20.41` を固定で割り当てて適用する
- [ ] `talosctl get extensions` で5つの拡張がロードされていることを確認する
- [ ] 特権 Pod から `/dev/dri` を確認し、Xe3 の DRI デバイスが出ることを確認する
- [ ] 同じく `/dev/accel` を確認し、NPU のデバイスが出ることを確認する
- [ ] 10GbE で DS923+ との実効スループットを測る

Intel Quick Sync と NPU を使うワークロードは初期スコープ外である。
それでも `xe` と `intel-npu` を最初の ISO に含めるのは、後から拡張を足すと `talosctl upgrade` と再起動が要るためである。
カーネルモジュールとファームウェアは拡張が用意するが、コンテナからアクセラレータを使うためのユーザー空間は別途要る。
Intel Device Plugin が `xe` と NPU のデバイスをどう公開するかは、実際に使う段階で確認する。

## フェーズ2以降: 本構築

フェーズ1の判定結果に依存するため、方針と決定待ち事項の整理に留める。

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

### 決定待ち事項

| 項目 | 選択肢 | 依存する検証 |
| --- | --- | --- |
| S100-WLP 3台の行き先 | ワーカーとして使う / 退役させる | 2台目の MS-03 の調達時期。標準 Talos で動くことは検証済みのため、技術的な障害はない |
| Pi-hole の移設先 | Kubernetes 上 / 別ハードウェア | 未着手 |
| CNI | Cilium（kube-proxy 完全置換、eBPF モード） | ノード構成の確定後 |
| LoadBalancer | Cilium L2 Announcement（Pool: 192.168.20.200-250） | VLAN 20 確定済みのため着手可能 |
| Ingress | Traefik | CNI の稼働後 |
| MS-03 の接続 NIC | RTL8127（10G RJ-45）/ X710（SFP+）/ i226-LM（2.5G 暫定） | MS-03 セットアップの実機確認 |
| 監視 | kube-prometheus-stack | フェーズ1でも簡易構成が必要 |
| バックアップ | Git リポジトリ + DS923+ のスナップショット | 未着手 |
| Intel Quick Sync のパススルー | Intel Device Plugin | 初期スコープ外 |
| UniFi Protect の録画先 | UNVR / DS923+ / Kubernetes 上の NVR | 未着手 |

## リファレンス

- `plan_old.md`：前バージョンの計画。本構築フェーズの実装タスク案が残っている
- `physical-network-topology-plan.svg`：物理トポロジ図（将来導入する機器を含む）
- `/Users/ryoma/Documents/GitHub/talos-ufs/CLAUDE.md`：talos-ufs のビルド構成
- https://github.com/onedr0p/cluster-template：リポジトリ構成とソフトウェアスタックの参照元
- https://etcd.io/docs/latest/op-guide/hardware/：etcd のハードウェア要件
