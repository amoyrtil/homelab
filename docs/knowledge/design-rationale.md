# 設計判断の根拠

[../design.md](../design.md) に書いた決定について、なぜそう決めたかを残す。
決定そのものを知りたいだけなら design.md で足りる。
このファイルを開くのは、決定を覆したくなったときと、同じ判断を別の場所で繰り返すときである。

## ネットワーク

### VLAN 番号の振り方

番号は小さいほど基幹に近い。
Management を先頭に置き、Server、Trusted と続け、信頼度が下がるにつれて番号を増やす。

Guest だけを 99 に離してあるのは、今後 VLAN を追加しても Guest が最下位に留まるようにするためである。
それ以外は 10 番刻みで空けてあるので、たとえば Server と Trusted の間に別の層を挟む余地が残る。

### Kubernetes ノードと DS923+ を VLAN 20 に統合する

分離した場合、NFS と CSI のトラフィックがすべて UCG-Fiber の L3 転送を経由し、配線を 10GbE にしてもゲートウェイのルーティング性能が上限になる。
Cilium の L2 Announcement も、LoadBalancer IP Pool がノードと同一 L2 ドメインにあることを要求する。
この二つの制約から、ノード、ストレージ、LB Pool は同一 VLAN に置く。

### Backup DNS と Log Server を VLAN 20 に置く

Management VLAN はネットワーク機器の管理専用とし、インフラサービスはサーバー側に寄せる。

### Apple TV、PS5、Switch 2、HTPC を VLAN 30 に置く

これらを Untrusted VLAN に分けると、VLAN 30 のクライアントからの AirPlay や画面共有のたびに VLAN 越えが発生する。
VLAN 40 は照明やセンサーなど、インターネット接続以外の権限を与えたくない機器のためのものとする。

この配置の代償として、HomeKit と Matter が使う mDNS が VLAN 30 と VLAN 40 をまたぐ。
UniFi の mDNS リフレクタを両 VLAN で有効化して対処する。

### 部屋の LAN ドロップは VLAN 30 とする

壁の LAN 端子に到達できる時点で物理アクセスが成立しており、そこだけを低信頼として扱う実益がない。

## コントロールプレーン（HP EliteDesk 800 G6）

### S100-WLP ではなく EliteDesk を使う

S100-WLP はコントロールプレーンの候補として評価し、UFS ストレージが etcd の fsync 要件に耐えることを確認した。
それでも EliteDesk に置き換えたのは、同じ機種でも個体によって定常時のレイテンシに差が出たためである。
EliteDesk は SATA と NVMe で、UFS の制約自体を受けない。

測定と判定の詳細は [s100-etcd-evaluation.md](s100-etcd-evaluation.md) にある。

### RAM 8GB で足りる

Talos 本体、etcd、apiserver、controller-manager、scheduler、kubelet、containerd、CNI を合わせて 3GB から 4GB の見込みである。
`allowSchedulingOnControlPlanes` を `false` に保つ限り余裕がある。

逆にコントロールプレーンにもワークロードを載せる構成にするなら、ここが最初に詰まる。

### NIC が 1GbE でよい

ワーカーの 10GbE と差があるが、etcd はスループットではなく fsync レイテンシで不安定になるため、この差は効かない。

### 拡張を `intel-ucode` だけに絞る

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

### コントロールプレーンでは拡張を焼き込まなくてよい

**拡張を後から足すことはできる。**
`talosctl upgrade` とインストーラーイメージの差し替えで再起動が要るが、コントロールプレーン3台なら1台ずつローリングで上げられる。

MS-03 で必要になりうる拡張を最初に焼き込んだのは、ワーカーが1台しかなく再起動がワークロード停止に直結したためである。
3台構成のコントロールプレーンにはその制約がない。

## ワーカー（MINISFORUM MS-03）

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

### アクセラレータは焼き込むが、使うのは先になる

Intel Quick Sync と NPU を使うワークロードは初期スコープ外である。
それでも `xe` と `intel-npu` を最初の ISO に含めるのは、後から拡張を足すと `talosctl upgrade` と再起動が要るためである。

カーネルモジュールとファームウェアは拡張が用意するが、コンテナからアクセラレータを使うためのユーザー空間は別途要る。
Intel Device Plugin が `xe` と NPU のデバイスをどう公開するかは、実際に使う段階で確認する。

### NPU が使えない

NPU は PCI デバイスとして見えており `intel_vpu` もロードされるが、probe が `-EIO` で失敗し `/dev/accel` が作られない。
Linux 6.18 のドライバが Panther Lake 世代を扱いきれていないと見ている。

NPU を使うワークロードは初期スコープ外のため、当面は支障にならない。
詳細は [talos-v1.14-ufs.md](talos-v1.14-ufs.md) にある。

## ストレージ

### SMB でどこまで賄えるか

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

### democratic-csi ではなく csi-driver-smb を使う

democratic-csi が Synology 向けに持つドライバは `synology-iscsi`（experimental）だけで、NFS 版は存在しない。
`plan_old.md` にある「Synology API を通じて NFS 共有を動的プロビジョニング」という記述はこの点で誤りである。

### Longhorn が iscsi-tools と util-linux-tools を要る

Longhorn は DS923+ の LUN に iSCSI で繋ぐためのものではない。
ボリュームをノードにアタッチする際に Longhorn 自身がイニシエータとターゲットの役割を果たすため、ノードに `iscsid` と `iscsiadm` が要る。
`util-linux-tools` はボリュームの trim に使う `fstrim` のために要る。

どちらも Longhorn の Talos 向けドキュメントが前提条件として挙げているものである。

### Longhorn をワーカーに限定する

コントロールプレーンには taint があってワークロードが載らないため、そこにレプリカを置く意味がない。
DaemonSet が control-plane の taint を許容しないよう設定し、コントロールプレーンの schematic には `iscsi-tools` を含めない。

## Cilium

### k8sServiceHost に KubePrism を使う

KubePrism は Talos が各ノードの `127.0.0.1:7445` で提供する API プロキシで、コントロールプレーンが増えても追従する。
実 IP を直書きするとフェーズ2で3台に増やしたときに書き換えが要るため、こちらが適する。

`machine.features.kubePrism` は既定で有効であり、`KubePrismStatus` リソースで healthy を確認できる。

### Gateway API の CRD に experimental チャネルが要る

Cilium は `tlsroutes` と `backendtlspolicies` を含む7種を必須として要求し、`tlsroutes` は standard チャネルに存在しない。

### bpf.autoMount.enabled を false にしたときの罠

Talos が既に bpffs を提供しているため `false` にするのだが、この状態では `cilium-envoy` から BPF マップが見えなくなる。
CNI としての疎通は正常なまま Gateway だけが 500 を返すため、Gateway API を入れるまで気付けない。

回避策は [talos-operations.md](talos-operations.md) にある。

## フェーズ

### Longhorn のレプリカ数を 1 → 2 → 2 で推移させる

フェーズ2で S100-WLP を1台に留めるのは、この推移を単調にするためである。
2台入れてレプリカを 3 まで上げると、フェーズ3で 2 に落とす際にレプリカを削る操作が要る。

フェーズ2からフェーズ3への移行では、先に MS-03 の2台目を投入してワーカーを一時的に3台にする。
そのうえで S100-WLP のレプリカを退避させてから外せば、レプリカ数 2 を保ったまま入れ替えられる。

### etcd のメンバー数はフェーズ1で 1 になる

フェーズ1でコントロールプレーンが落ちると API が使えなくなるが、ワーカー上で動いている Pod は動き続ける。

### フェーズ1の可用性

フェーズ1はワーカーが MS-03 1台だけであり、Longhorn のレプリカも1つである。
このノードが落ちれば、その上のワークロードとボリュームは復旧まで到達できない。

家庭の DNS を担う Pi-hole をフェーズ1でクラスターに載せるため、**クラスター外に副の DNS を用意することが前提条件になる**。
UCG-Fiber 自身の DNS を副として配るか、別途 Backup DNS を立てる。
これはクラスターの構築対象外として扱う。
