# homelab 構成設計

## このドキュメントの位置づけ

homelab のクラスターについて、**すでに決まっている構成**だけを置く。
決定の一覧として引けることを優先し、なぜそう決めたかは書かない。

- 根拠と経緯 → [knowledge/design-rationale.md](knowledge/design-rationale.md)
- 検証の記録と運用知見 → [knowledge/](knowledge/)
- 現在地、作業計画、未決定事項 → [plan.md](plan.md)

ここに書いたものを変えるときは、根拠を `knowledge/` に残してから書き換える。

## 技術判断の基準

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

S100-WLP には制約が2つある。
3台のうち2台は内蔵 I226-V に物理層障害があり、該当機は USB Ethernet ドングルで接続する。
1台は Ubuntu で Pi-hole を稼働させており、転用には Pi-hole の移設先を先に決める必要がある。

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

## ネットワーク設計

### アドレス方針

`192.168.<VLAN ID>.0/24` を採用する。
第3オクテットと VLAN ID を一致させることで、アドレスを見た時点で所属 VLAN が判別できる。

VLAN 番号は2桁と3桁で層を分ける。
2桁は機器を収容する VLAN、3桁はその上で動くアプリケーションの VLAN とする。
アプリケーション側の番号は、機器を収容する VLAN の番号に 100 を足す。
Cilium の LoadBalancer IP Pool は VLAN 20 の Server 上で動くため VLAN 120 に置く。
下2桁を見れば、そのアプリケーションがどの VLAN のハードウェア上で動いているかが分かる。

Kubernetes の内部 CIDR は既定値を維持する。
Pod CIDR に `10.244.0.0/16`、Service CIDR に `10.96.0.0/12` を使う。
ホスト側が `192.168.0.0/16` のため、重複は発生しない。

### VLAN 一覧

| VLAN | CIDR | 名前 | 収容する機器 |
| --- | --- | --- | --- |
| 10 | 192.168.10.0/24 | Management | UCG-Fiber、USW 4台、U7 3台 |
| 20 | 192.168.20.0/24 | Server | Kubernetes ノード全台、MS-03 x2、DS923+、Backup DNS、Log Server |
| 30 | 192.168.30.0/24 | Trusted | Windows PC、Mac mini、MacBook Pro、モバイル端末、Apple TV、PS5、Switch 2 x2、HTPC、部屋の LAN ドロップ 3系統 |
| 40 | 192.168.40.0/24 | Untrusted | 信頼度の低い IoT 家電 |
| 50 | 192.168.50.0/24 | Camera | G5 Turret Ultra、G6 Entry、NVR |
| 60 | 192.168.60.0/24 | Guest | ゲスト WiFi |
| 120 | 192.168.120.0/24 | Service | Cilium LoadBalancer IP Pool。機器は収容しない |

VLAN 1（UniFi の既定 VLAN）には機器を収容しない。

VLAN 120 は UniFi にネットワークとして定義し、ゲートウェイ IP だけを持たせる。
DHCP は動かさない。
実体は Cilium が BGP で広告する `/32` の集合である。

### VLAN 20 のアドレス割り当て

```
192.168.20.1          UCG-Fiber（デフォルトゲートウェイ）
192.168.20.10-19      インフラサービス（Backup DNS: .10, Log Server: .11）
192.168.20.20-29      ストレージ（DS923+: .20）
192.168.20.31-39      Kubernetes コントロールプレーンノード（.31, .32, .33）
192.168.20.41-49      Kubernetes ワーカーノード（.41, .42）
192.168.20.100        Talos VIP（Kubernetes API エンドポイント）
192.168.20.150-250    DHCP プール（一時利用、検証機）
```

サーバー機は全台 DHCP 予約または静的割り当てとし、DHCP プールから払い出さない。
`.50-.99` と `.101-.149` は空けてある。ノードやストレージが `.31-.49` に収まらなくなったときの拡張余地である。

### VLAN 120 のアドレス割り当て

```
192.168.120.1         UCG-Fiber（ゲートウェイ）
192.168.120.100-250   Cilium LoadBalancer IP Pool
```

100 番から始めるのは、VLAN 20 の `.100`（Kubernetes API の VIP）と対応させるためである。
どちらもクラスターが提供する仮想アドレスであり、実体のあるノードやストレージの割り当てとは性質が違う。

`.2-.99` は空けてある。
用途別に IP プールを分けたくなったとき、`serviceSelector` を持つ `CiliumLoadBalancerIPPool` を追加で置く帯として使う。

### VLAN 間ポリシー

| 送信元 | 宛先 | 方針 |
| --- | --- | --- |
| Trusted | Management | 許可（UniFi 管理 UI） |
| Trusted | Server | 許可（kubectl、NAS、各サービスの Web UI） |
| Trusted | Service | 許可（クラスター上のサービス） |
| Trusted | Untrusted | 許可（家電の操作） |
| Server | Service | 許可（VLAN 20 の機器からクラスター上のサービスへ） |
| Server | Trusted | 応答を除き拒否 |
| Server | インターネット | 許可 |
| Untrusted | 内部 VLAN 全般 | 応答と DNS を除き拒否 |
| Untrusted | インターネット | 許可 |
| Camera | NVR | 許可 |
| Camera | インターネット | 拒否 |
| Guest | 内部 VLAN 全般 | DNS を除き拒否 |
| Guest | インターネット | 許可 |

「内部 VLAN 全般」には VLAN 120 を含む。
Untrusted と Guest からクラスター上のサービスには到達させない。

この表は、BGP で学習した `/32` が VLAN 120 のゾーンに分類されることを前提にしている。
next-hop がワーカーのいる VLAN 20 にあっても宛先ネットワークで判定されることは、実機で確認済みである（[knowledge/bgp-peering.md](knowledge/bgp-peering.md)）。

NVR をクラスター上に置く場合は Camera から VLAN 120 への許可が要る。
録画先が決まっていないため、現時点では拒否のままにする（[plan.md](plan.md#いずれ回収する項目) の「UniFi Protect の録画先」）。

全 VLAN から `192.168.20.10`（Backup DNS）への 53/udp と 53/tcp を個別に許可する。

### BGP

Cilium が払い出した LoadBalancer IP を、UCG-Fiber に `/32` で広告する。

| | ASN |
| --- | --- |
| UCG-Fiber | 65000 |
| Kubernetes クラスター | 65001 |

プライベート ASN（64512-65534）から選び、eBGP で対向する。
ルーター側を 65000 に固定し、クラスターを増やす場合は 65002 以降を振る。

**両側ともノードの台数変化に追従させる。**
UCG-Fiber は `bgp listen range` で VLAN 20 からの接続を待ち受け、ノードの IP を列挙しない。
Cilium は `nodeSelector` で対象ノードを選ぶ。
接続を開始するのは Cilium 側であり、ルーターは待つだけでよい。
コントロールプレーンやワーカーを増やしても、どちらの設定も変えずに済む。

広告するのはワーカーのみとする。
`allowSchedulingOnControlPlanes` が `false` であり、コントロールプレーンにワークロードを載せないためである。

`bgp listen range` を UniFi が受け付けることは実機で確認済みである（[knowledge/bgp-peering.md](knowledge/bgp-peering.md)）。
ルーター側の設定は `bootstrap/ucg-fiber-bgp.conf` に置き、UniFi 上では `Blackwall-BGP` という名前で登録する。
Cilium 側の3つのリソースは `bootstrap/cilium-bgp.yaml` にある。

### 必要な設定

UniFi の mDNS リフレクタを VLAN 30 と VLAN 40 で有効化する。
HomeKit と Matter が使う mDNS が両 VLAN をまたぐためである。

## ノードのイメージ

全ノードで Talos v1.14.0、Kubernetes v1.37.0 を使う。
イメージは Image Factory の schematic に揃える。

| ノード | インストーラーイメージ | 拡張 |
| --- | --- | --- |
| EliteDesk 800 G6 | `factory.talos.dev/metal-installer/2d61dd07b20062062ea671b4d01873506103b67c0f7a4c3fb6cf4ee85585dcb8:v1.14.0` | `intel-ucode` |
| MS-03 | `factory.talos.dev/metal-installer/b7f363548fe975dbb10e85983906f0c3f44ab3804b6246b677508ca1bb20d1f4:v1.14.0` | `intel-ucode`、`xe`、`intel-npu`、`iscsi-tools`、`util-linux-tools` |
| S100-WLP | `factory.talos.dev/metal-installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.14.0` | なし（素の schematic） |

ISO は同じ ID から `https://factory.talos.dev/image/<ID>/v1.14.0/metal-amd64.iso` で引ける。

**ID は schematic の内容から決まる。**
拡張やカーネル引数を変えると別の ID になり、Talos のバージョンを変えても ID は変わらない。
schematic を変更したら、このドキュメントの ID も更新する。

S100-WLP をワーカーに回す場合は、Longhorn の前提条件を満たすために `iscsi-tools` と `util-linux-tools` を含む schematic に差し替える。

### コントロールプレーン（HP EliteDesk 800 G6）

3台とも同一構成である。

| 項目 | 内容 | Talos 側 |
| --- | --- | --- |
| CPU | Intel Core i5-10500T（Comet Lake、6コア12スレッド、TDP 35W） | `siderolabs/intel-ucode` |
| RAM | 8GB | — |
| ストレージ | 256GB SSD | 実機で NVMe か SATA かを確認する |
| NIC | 内蔵 1GbE（Intel I219-LM 想定） | `e1000e`。カーネルに組み込み済み |

schematic は `talos/schematics/elitedesk-schematic.yaml`。

```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/intel-ucode
```

`allowSchedulingOnControlPlanes` は `false` に保つ。

### ワーカー（MINISFORUM MS-03）

| 項目 | 内容 | Talos 側 |
| --- | --- | --- |
| CPU | Intel Core Ultra 9 386H（Panther Lake） | `siderolabs/intel-ucode` |
| iGPU | Xe3 4コア | `siderolabs/xe`（`i915` ではない） |
| NPU | Panther Lake 内蔵 | `siderolabs/intel-npu` |
| NIC | Intel X710 10GbE SFP+ x2 | `i40e` |
| NIC | Realtek RTL8127 10GbE RJ-45 | `r8169` |
| NIC | Intel i226-LM 2.5GbE RJ-45 | `igc` |
| 拡張スロット | PCIe x8、U.2 | 初期スコープ外 |
| ストレージ | NVMe SKHynix HFS256GDE9X081N 256GB | インストール先 `/dev/nvme0n1` |

schematic は `talos/schematics/ms03-schematic.yaml`。

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

**NIC は4つとも Talos が認識する。**
インターフェース名は起動順で入れ替わりうるため、`deviceSelector` は MAC で指定する。

| インターフェース | MAC | ドライバ | Vendor:Device | チップ |
| --- | --- | --- | --- | --- |
| `eno2` | `38:05:25:3b:cc:d2` | `igc` | 8086:125b | Intel i226-LM 2.5GbE |
| `eno3` | `38:05:25:3b:cc:d5` | `r8169` | 10ec:8127 | Realtek RTL8127 10GbE RJ-45 |
| `eno4np0` | `38:05:25:3b:cc:d3` | `i40e` | 8086:1572 | Intel X710 SFP+ #1 |
| `eno5np1` | `38:05:25:3b:cc:d4` | `i40e` | 8086:1572 | Intel X710 SFP+ #2 |

iGPU は `xe` により `/dev/dri` に `card0` と `renderD128` が現れる。
NPU は現時点で使えない（[knowledge/design-rationale.md](knowledge/design-rationale.md#npu-が使えない)）。

## ストレージ

| 層 | ドライバ | バックエンド | 必要な拡張 |
| --- | --- | --- | --- |
| メディア（大容量、共有） | `csi-driver-smb` | DS923+ の SMB 共有 | なし（`mount.cifs` はドライバ Pod 内で動く） |
| ブロック（DB、アプリ状態） | Longhorn | ワーカーのローカルディスク | `iscsi-tools`、`util-linux-tools` |

データベースとアプリケーションの状態は SMB に置かない。
`CONFIG_CIFS_POSIX` が無効で POSIX ロックが効かず、SQLite や PostgreSQL でデータ破損の危険がある。
大容量メディアはこの制約に当たらないため、**DS923+ の SMB 運用は維持する**。

**Longhorn はワーカーにのみ展開する。**
DaemonSet が control-plane の taint を許容しないよう設定し、コントロールプレーンの schematic には `iscsi-tools` を含めない。

Longhorn の namespace には `pod-security.kubernetes.io/enforce=privileged` を設定する。
Talos は既定で `baseline` を強制するため、これを入れないと動かない。

## ソフトウェア構成

### 確定している方針

- **OS**：Talos Linux。設定管理は talhelper（`talconfig.yaml`）
- **CNI**：Cilium。kube-proxy を完全に置換し、eBPF モードで動かす。フェーズ1から入れる
- **Ingress**：Cilium の Gateway API 実装を使う。専用の Ingress コントローラーを足さない。前提として `kubeProxyReplacement=true` と `l7Proxy=true` が要る
- **LoadBalancer**：Cilium BGP。UCG-Fiber は UniFi OS 4.1.13 以降で BGP に対応しており、FRR 形式の設定ファイルをアップロードして構成する（Settings → Routing → BGP）。LB IP は VLAN 120 から払い出す。ノードと同じ VLAN には置けない（[knowledge/service-exposure.md](knowledge/service-exposure.md)）
- **外部公開**：Cloudflare Tunnel。ルーターのポートを開けない
- **証明書**：cert-manager + Let's Encrypt。DNS-01 チャレンジに Cloudflare を使う
- **内部の名前解決**：external-dns の Pi-hole プロバイダーで、クラスターのホスト名を Pi-hole の Custom DNS に書き込む。DNS サーバーを別途立てない
- **ストレージ**：「ストレージ」節のとおり。フェーズ1から入れる
- **GitOps**：Flux v2。Flux Operator と FluxInstance で管理する。main ブランチへのマージをトリガーに反映する
- **CI/CD**：Flux の Webhook Receiver を使う。GitHub Actions はクラスターに触らない。push イベントを Cloudflare Tunnel 経由で受け、Flux が即座に Git を pull する。CI 側の仕事はマニフェストの検証と Renovate による更新 PR に限る
- **シークレット管理**：SOPS + age。暗号化済み Secret を Git にコミットする
- **リポジトリ構成**：`onedr0p/cluster-template` に準拠する
- **ツール管理**：mise。ローカル環境の再現性を確保する

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

判断の根拠は [knowledge/cluster-template-evaluation.md](knowledge/cluster-template-evaluation.md) にある。

### Talos と Cilium の必須設定

リハーサル R1 から R4 で実証した設定である（結果は [plan.md](plan.md#完了した検証) にある）。

**クラスター構築時に効く設定**

後から変えるとノードの作り直しになるため、初回のクラスター生成時に入れる。

```yaml
# talconfig.yaml
cniConfig:
  name: none
```

```yaml
# コントロールプレーンのパッチ（KubeProxyConfig ドキュメント）
cluster:
  proxy:
    disabled: true
```

v1alpha1 の `cluster.proxy.disabled` ではなく `KubeProxyConfig` ドキュメントの `enabled: false` を使う。

**Cilium の値**

| 設定 | 値 | 理由 |
| --- | --- | --- |
| `ipam.mode` | `kubernetes` | Talos の要求 |
| `kubeProxyReplacement` | `true` | kube-proxy を置換する |
| `l7Proxy` | `true` | Gateway API の前提条件 |
| `k8sServiceHost` | `127.0.0.1` | KubePrism 経由で API に到達する。コントロールプレーンが増えても追従する |
| `k8sServicePort` | `7445` | 同上 |
| `cgroup.autoMount.enabled` | `false` | Talos が既に cgroupv2 を提供している |
| `securityContext.capabilities` | `SYS_MODULE` を除く | Talos はワークロードにカーネルモジュールのロードを許さない |
| `bgpControlPlane.enabled` | `true` | LoadBalancer IP を BGP で広告する |

**`bpf.autoMount.enabled` は指定しない。**
公式ガイドは Talos が bpffs を提供済みであることを理由に `false` を挙げているが、このフラグは hostPath ボリュームの定義ごと落とすため、`cilium-envoy` から BPF マップが見えなくなる。
経緯は [knowledge/talos-operations.md](knowledge/talos-operations.md) にある。

**設定変更を Pod に反映させる**

`rollOutCiliumPods`、`operator.rollOutPods`、`envoy.rollOutPods` を `true` にする。
既定では values を変えても ConfigMap が書き換わるだけで Pod は入れ替わらず、変更が黙って効かないまま残る。

**Gateway API の CRD**

**experimental チャネル**の v1.6.1 を使う。standard チャネルには `tlsroutes` がない。

**LoadBalancer の IP プール**

`CiliumLoadBalancerIPPool` は `bootstrap/cilium-networks.yaml` に置く。
プールは `192.168.120.100-250`（「VLAN 120 のアドレス割り当て」で確保した帯）。

**プールをノードと同じ VLAN に置くと、BGP に移したときに同一 VLAN の機器から到達できなくなる。**
BGP は経路を広告するだけで ARP に応答しないため、その VLAN の機器は宛先を on-link と判断して ARP を出し、応答を得られない。
実測と対処の経緯は [knowledge/service-exposure.md](knowledge/service-exposure.md) にある。

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
フェーズ間で変わるのは台数と、それに伴うレプリカ数だけにする。

**フェーズ1では Pi-hole がワーカー1台に載る。**
クラスター外に副の DNS を用意することが前提条件になる。これはクラスターの構築対象外として扱う。

作業手順は [plan.md](plan.md#構築の作業)、レプリカ推移と可用性の考え方は [knowledge/design-rationale.md](knowledge/design-rationale.md#フェーズ) にある。

## リファレンス

- [plan.md](plan.md)：現在地と作業計画、未決定事項
- [knowledge/design-rationale.md](knowledge/design-rationale.md)：ここに書いた決定の根拠
- [knowledge/](knowledge/)：検証の記録と Talos の運用知見
- `physical-network-topology-plan.svg`：物理トポロジ図（将来導入する機器を含む）
- https://github.com/onedr0p/cluster-template：リポジトリ構成とソフトウェアスタックの参照元
