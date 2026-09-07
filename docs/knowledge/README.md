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

## 横断的な知見

| ファイル | 内容 |
| --- | --- |
| [design-rationale.md](design-rationale.md) | [../design.md](../design.md) の決定ひとつひとつについて、なぜそう決めたか。VLAN 配置、システム拡張の取捨、SMB と Longhorn の使い分け、フェーズごとのレプリカ推移 |
| [talos-operations.md](talos-operations.md) | 機種や個別の検証に依らない Talos の挙動。v1.14 の設定ドキュメント分割、Image Factory のイメージパス、`reset` の破壊範囲、Pod Security Admission、メンテナンスモードのアドレス取得 |

## 結論の要約

個別のファイルを開かずに済むよう、判定だけを並べる。

- **S100-WLP の UFS は etcd に耐える。** 2メンバー構成の 30分持続負荷でリーダー選出も提案失敗も発生しなかった。ただし同じ機種でも個体によって定常時のレイテンシに差が出る。
- **`talos-ufs` は役目を終えた。** Talos v1.14 の標準イメージで S100-WLP にインストールでき、起動する。カーネルの UFS 対応とパーティションサイズの両方が上流で解決している。
- **MS-03 の NIC は4つとも Talos が認識する。** RTL8127 も `r8169` が掴む。一方 NPU は `intel_vpu` の probe が失敗し、デバイスノードが作られない。
- **`onedr0p/cluster-template` はジェネレーターとしては採用しない。** ディレクトリ規約、Flux Operator 方式、helmfile ブートストラップ、mise のバージョン固定だけを借りる。
