# homelab 構築計画

## このドキュメントの位置づけ

homelab に Kubernetes クラスターと GitOps ベースの CI/CD を整備するための計画である。

前バージョンの計画は `plan_old.md` に退避した。
旧計画はハードウェア構成とネットワーク構成が未検証のまま、ファイル単位の実装タスクまで書き切っていた。
前提が覆れば計画全体が無効になる構造だったため、検証と設計を先に置く形に組み替えた。

このドキュメントでは、次の二つだけを確度高く固める。

- **ネットワーク設計**：将来導入する機器をすべて接続しても破綻しない VLAN 構成を、実装前に確定させる。
- **フェーズ1の検証**：MINISFORUM S100-WLP が etcd のコントロールプレーンノードとして使えるかを判定する。

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

S100-WLP は UFS ストレージを採用しており、標準の Talos Linux には UFS ドライバが含まれない。
そのため `talos-ufs` のカスタムビルドが必須になる。

このフェーズで判定するのは、UFS ストレージの fsync レイテンシが etcd に耐えるかである。
etcd はスループットではなく fsync 遅延で不安定になる。
判定結果に応じて、S100-WLP を継続するか Dell OptiPlex に置き換えるかを決める。

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

<!-- TODO: talos-ufs の installer イメージに拡張を後付けできるか（Talos の imager が使えるか）を確認する。フェーズ1では不要だが、フェーズ2で CP ノードに iscsi-tools などが要る場合に効く -->

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

- [ ] 30分から60分の連続負荷をかける
- [ ] `etcd_disk_wal_fsync_duration_seconds` の p99、p99.9、max を記録する
- [ ] `etcd_disk_backend_commit_duration_seconds` の p99 を記録する
- [ ] `etcd_server_leader_changes_seen_total` の増加を監視する
- [ ] `etcd_server_proposals_failed_total` を監視する
- [ ] **10ms を超える fsync の発生頻度**を記録する（判定を分けるのは最大値ではなく頻度である）
- [ ] 負荷を止めた定常状態でも同じ指標を30分記録し、負荷時との差を取る

**USB NIC 起因との切り分け**

cp-1 と cp-2 は USB ドングルで接続する。
このステップの主判定である `etcd_server_leader_changes_seen_total` は、UFS の fsync 遅延だけでなく、raft のピア間通信が滞っても増える。
切り分けの手段を用意しないと、リーダー選出が起きたときに機種の判定そのものが下せない。

- [ ] `etcd_network_peer_round_trip_time_seconds` の p99 を記録する（ネットワーク側の遅延を fsync 側と分離する）
- [ ] 両ノードの USB NIC のリンクフラップを記録する（`LinkStatus` の VERSION 増加、または `talosctl dmesg` の carrier 変化）
- [ ] `leader_changes` が増えた場合、同時刻に fsync の外れ値があったのかリンクフラップがあったのかを突き合わせる

fsync の外れ値と無関係にリーダー選出が起きるなら、それは UFS ではなく USB NIC の問題であり、S100-WLP の可否判定には使えない。

ここで主判定を満たさなければ Step 5 の緩和策に進む。
満たした場合も、Step 4 までは機種の決定を保留する。

### Step 4: コントロールプレーン3台への拡張と障害試験

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
緩和策でも満たせないなら OptiPlex に置換する。

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

これらで主判定を満たせない場合、S100-WLP 3台を OptiPlex 3台に置き換える。

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

Talos v1.13.9 のカーネルは Linux 6.18.48 である。
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
ISO         https://factory.talos.dev/image/b7f363548fe975dbb10e85983906f0c3f44ab3804b6246b677508ca1bb20d1f4/v1.13.9/metal-amd64.iso
installer   factory.talos.dev/installer/b7f363548fe975dbb10e85983906f0c3f44ab3804b6246b677508ca1bb20d1f4:v1.13.9
```

ID は schematic の内容から決まるため、拡張やカーネル引数を変えると別の ID になる。
schematic を変更したら ID もこのドキュメントで更新する。

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

MS-03 は標準 Talos、S100-WLP は talos-ufs のカスタムビルドを使う。
同じクラスターのノードであるため、Talos のバージョンを揃える必要がある。

talos-ufs は上流のリリースを日次で追って自動ビルドするが、ビルドに8時間から9時間かかるため公開は遅れる。
したがってクラスターの Talos バージョンは、talos-ufs が公開済みのものに合わせる。

2026年8月30日時点で talos-ufs の最新は `v1.13.9`、上流 Talos の最新安定版も v1.13.9 である。
現時点では揃っているため v1.13.9 を採用する。

talos-ufs のイメージタグに `-ufs` のようなサフィックスは付かない。
上流のバージョンをそのまま使う（`v1.13.9`）。
`v1.13.9-ufs` は ghcr 上に存在せず、レジストリが 404 を返す。

| ノード | インストーラーイメージ |
| --- | --- |
| cp-1 から cp-3（S100-WLP） | `ghcr.io/amoyrtil/talos-ufs-installer:v1.13.9` |
| worker-1（MS-03） | `factory.talos.dev/installer/<schematic-id>:v1.13.9` |

この2つを Renovate で個別に追跡すると、片方だけ更新されてバージョンがずれる。
同時に上げる運用にするか、Renovate の対象から外して手動で揃える。

### 手順

- [ ] `talos/schematics/ms03-schematic.yaml` を作成する
- [ ] Image Factory に POST し、schematic ID をリポジトリに記録する
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
- **コントロールプレーンのイメージ**：S100-WLP を採用する場合は `talos-ufs` のカスタムビルドを使う。標準 Talos では UFS ディスクにインストールできないことが検証済みのため、選択の余地はない。OptiPlex に置き換える場合は標準 Talos を使う
- **GitOps**：Flux v2。main ブランチへのマージをトリガーに反映する
- **ツール管理**：mise。ローカル環境の再現性を確保する
- **シークレット管理**：SOPS + age。暗号化済み Secret を Git にコミットする
- **リポジトリ構成**：`onedr0p/cluster-template` に準拠する
- **証明書**：cert-manager + Let's Encrypt。DNS-01 チャレンジに Cloudflare を使う
- **ワーカーノード**：MS-03。標準 Talos を Image Factory の schematic でカスタムして使う
- **Talos のバージョン**：talos-ufs が公開済みのバージョンに全ノードを揃える。現時点は v1.13.9
- **ストレージ**：大容量メディアは `csi-driver-smb` で DS923+ の SMB 共有へ。データベースとアプリケーションの状態は OpenEBS Local PV で MS-03 の NVMe へ

### 決定待ち事項

| 項目 | 選択肢 | 依存する検証 |
| --- | --- | --- |
| コントロールプレーンの機種 | S100-WLP x3 / OptiPlex x3 | フェーズ1 全体 |
| Pi-hole の移設先 | Kubernetes 上 / 別ハードウェア | Step 4 の前提条件 |
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
