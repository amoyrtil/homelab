# ナレッジ

homelab の構築過程で行った検証と、そこで得た知見の置き場である。
確定した構成は [../design.md](../design.md)、作業計画と未決定事項は [../plan.md](../plan.md) にある。

あちら側には決定した内容とこれからやることだけを書き、なぜそう決めたかの根拠と経緯はこちらに残す。
検証を1つ終えるごとにファイルを1つ足していく。

## 検証の記録

| ファイル | 内容 | 実施 |
| --- | --- | --- |
| [s100-etcd-evaluation.md](s100-etcd-evaluation.md) | MINISFORUM S100-WLP の UFS ストレージが etcd の fsync 要件に耐えるかの判定。fio による単体測定から、コントロールプレーン2台での持続書き込み負荷試験まで | 2026年8月 |
| [talos-v1.14-ufs.md](talos-v1.14-ufs.md) | Talos v1.14 で上流カーネルが UFS に対応したことを受け、`talos-ufs` のカスタムビルドが不要になったかを検証。あわせてクラスターを v1.14 へ移行し、MS-03 をワーカーとして投入した記録 | 2026年9月6日 |
| [cluster-template-evaluation.md](cluster-template-evaluation.md) | `onedr0p/cluster-template` をリポジトリ構成の出発点にするかの評価。派生して Ingress、CI/CD、内部 DNS の方式も決めた | 2026年9月6日 |
| [service-exposure.md](service-exposure.md) | R4 の着手前に調べた2件。LoadBalancer IP をノードと同じ VLAN に置いたまま BGP へ移せるかと、家庭 LAN 内とインターネットから同じ URL で届くか。前者は LB Pool 専用 VLAN を切る判断につながった | 2026年9月8日 |
| [bgp-peering.md](bgp-peering.md) | R4 の記録。Cilium の LoadBalancer IP を UCG-Fiber へ BGP で広告し、L2 Announcement を外すまで。UniFi の Zone-Based Firewall が BGP 経路の宛先をどう分類するかもここで確定した | 2026年9月9日 |
| [longhorn-on-talos.md](longhorn-on-talos.md) | R5 の記録。Longhorn をワーカーにのみ展開し、レプリカ1で PVC を通すまで。Talos 側に要る kubelet の bind mount と、コントロールプレーンを外す方法 | 2026年9月9日 |
| [flux-bootstrap.md](flux-bootstrap.md) | R6 の記録。Flux Operator を入れ、Longhorn を GitOps へ移し、SOPS で暗号化した Secret を Flux に復号させるまで。手で入れる鍵をどこで切るか | 2026年9月9日 |
| [terraform-provisioning.md](terraform-provisioning.md) | R8 の着手前に調べた provider の実力。UniFi と Cloudflare の provider が Zone-Based Firewall と Tunnel をどこまで扱えるか、手で作った既存リソースを import で回収できるか。Terraform と Flux と external-dns の所有権の境界もここで決めた | 2026年9月9日 |

## 横断的な知見

| ファイル | 内容 |
| --- | --- |
| [design-rationale.md](design-rationale.md) | [../design.md](../design.md) の決定ひとつひとつについて、なぜそう決めたか。VLAN 配置、システム拡張の取捨、SMB と Longhorn の使い分け、フェーズごとのレプリカ推移 |
| [cluster-bootstrap-order.md](cluster-bootstrap-order.md) | クラスターをゼロから立てる順序。R1 から R6 の手順を実行できる順に並べ、入れ替えられない依存関係をまとめたもの |
| [talos-operations.md](talos-operations.md) | 機種や個別の検証に依らない Talos の挙動。v1.14 の設定ドキュメント分割、Image Factory のイメージパス、`reset` の破壊範囲、Pod Security Admission、メンテナンスモードのアドレス取得 |

## 結論の要約

個別のファイルを開かずに済むよう、判定だけを並べる。

- **S100-WLP の UFS は etcd に耐える。** 2メンバー構成の 30分持続負荷でリーダー選出も提案失敗も発生しなかった。ただし同じ機種でも個体によって定常時のレイテンシに差が出る。
- **`talos-ufs` は役目を終えた。** Talos v1.14 の標準イメージで S100-WLP にインストールでき、起動する。カーネルの UFS 対応とパーティションサイズの両方が上流で解決している。
- **MS-03 の NIC は4つとも Talos が認識する。** RTL8127 も `r8169` が掴む。一方 NPU は `intel_vpu` の probe が失敗し、デバイスノードが作られない。
- **`onedr0p/cluster-template` はジェネレーターとしては採用しない。** ディレクトリ規約、Flux Operator 方式、helmfile ブートストラップ、mise のバージョン固定だけを借りる。
- **LoadBalancer IP Pool をノードと同じ VLAN に置いたまま BGP へは移せない。** BGP は経路を広告するだけで ARP に応答しないため、同一 VLAN の機器は ARP 解決に失敗して届かなくなる。LB Pool 専用に VLAN 120（物理 VLAN の番号 + 100）を切る。
- **同じ URL で LAN 内とインターネットの両方から届く。** external-dns 2系統による split-horizon DNS で成立する。ただし LAN 内のクライアントが DoH などで内部 DNS を迂回しないことが前提になる。
- **UniFi の Zone-Based Firewall は宛先ネットワークでゾーンを決める。** BGP で学習した `/32` は、next-hop が別 VLAN にあっても、アドレスの属する VLAN のゾーンに入る。LB IP のアクセス制御を VLAN 120 のゾーンポリシーで書ける。
- **`bgp listen range` は UniFi に通る。** UCG-Fiber 側にノード IP を列挙する必要はなく、ノードを増やしてもルーターの設定は変えずに済む。
- **Cilium は values を変えても Pod を入れ替えない。** `rollOutCiliumPods` と `operator.rollOutPods` と `envoy.rollOutPods` を有効にしないと、`helm upgrade` が成功したまま設定が効かない。
- **Longhorn は Talos の kubelet に `/var/lib/longhorn` の bind mount を要求する。** `rshared` で伝播させないと CSI のマウントが kubelet に見えない。適用にノードの再起動は要らない。
- **Longhorn をワーカーに限定するのに `nodeSelector` は要らない。** チャートの `taintToleration` が既定で空であり、コントロールプレーンの taint を許容しないためである。
- **flux-operator は `FluxInstance` の名前によらず `flux-system` という名前で GitRepository を作る。** `sourceRef` はそちらを指す。
- **Kubernetes の Secret は `encrypted_regex: ^(data|stringData)$` で暗号化する。** ファイル全体を暗号化すると `kind` まで隠れ、kustomize がリソースとして読めない。
- **手でクラスターに入れる鍵は `sops-age` の1つだけ。** リポジトリが public のため Git 認証が要らない。private 化やオーガナイゼーション移行のときに2つ目が要る。
- **クラスターを立てる順序は4箇所で入れ替えられない。** `cniConfig: none` は構築時にしか効かず、Gateway API の CRD は Cilium より先、Cilium は flux-operator より先、`sops-age` は `FluxInstance` より先である。
- **UniFi の Terraform provider は `ubiquiti-community/unifi` に移っている。** `paultyng/unifi` は 2023年で更新が止まり、Zone-Based Firewall を扱えない。
- **`unifi_firewall_policy` の順序は Terraform から管理できない。** `index` が read-only であり、ポリシーはゾーンペアの末尾に追加される。順序に依存しない設計にするか、UI で並べ替える。
- **Cloudflare の Tunnel は CLI で作っても import できる。** `tunnel_secret` は provider の入力属性で、その値は `cloudflared tunnel create` が書く credentials ファイルに残っている。
- **Terraform の state はクラスター内に置けない。** クラスターの前提となるネットワークを Terraform が作るため循環依存になる。Cloudflare R2 に置く。
- **Cloudflare のサービス用 DNS レコードは external-dns の所有物である。** Terraform が同じ名前を握ると互いに消し合う。Terraform が持つのは apex や MX のように external-dns が触らないものだけ。
