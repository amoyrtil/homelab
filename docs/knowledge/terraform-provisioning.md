# インフラのプロビジョニングを Terraform に移す

UniFi の VLAN とファイアウォール、Cloudflare の Tunnel と DNS は、ここまで UI と CLI で手作業で作ってきた。
これを Terraform に移すため、provider の実力と既存リソースの回収方法を調べた。
調査は 2026年9月9日である。

## provider の選定

| provider | 最新 | 判定 |
| --- | --- | --- |
| [`ubiquiti-community/unifi`](https://registry.terraform.io/providers/ubiquiti-community/unifi) | 0.55.0（2026年7月10日） | 採用する |
| `paultyng/unifi` | 0.41.0（2023年3月10日） | 採用しない |
| [`cloudflare/cloudflare`](https://registry.terraform.io/providers/cloudflare/cloudflare) | 5.24.0（2026年8月24日） | 採用する |

**UniFi の provider は `paultyng` から `ubiquiti-community` に移っている。**
`paultyng/unifi` は 2023年3月で更新が止まっており、UniFi OS 4.x で入った Zone-Based Firewall を扱えない。
検索で見つかる記事はほぼこちらを指すため、コードをそのまま持ってくると動かない。

## UniFi provider が扱える範囲

`ubiquiti-community/unifi` 0.55.0 は次のリソースを持つ。

| リソース | 対象 |
| --- | --- |
| `unifi_network` | VLAN、DHCP プール |
| `unifi_firewall_zone`、`unifi_firewall_policy` | Zone-Based Firewall のゾーンとポリシー |
| `unifi_firewall_group` | アドレスグループとポートグループ |
| `unifi_bgp` | BGP。生の FRR config か、`asn` と `router_id` と `peers` の構造化属性 |
| `unifi_port_profile` | スイッチポートのプロファイル |
| `unifi_static_route`、`unifi_traffic_route` | 経路 |
| `unifi_dns_record` | UniFi の Local DNS Records |
| `unifi_setting` | 各種設定 |

**`unifi_bgp` は現在の構成をそのまま受け取れる。**
公式ドキュメントの例が Cilium 向けの peer-group と `bgp listen range` そのものであり、UCG-Fiber に手で入れた `Blackwall-BGP` の内容を `config` 属性に移すだけで済む。

### ポリシーの順序は provider から管理できない

`unifi_firewall_policy` の `index` は read-only である。
ポリシーは常にそのゾーンペアの末尾に追加され、supported API に並べ替えの操作がないため、provider からは順序を指定できない。

Zone-Based Firewall のポリシーは評価順に意味がある。
したがって、順序に依存しないポリシーの集合として設計するか、順序が必要な箇所は UI で並べ替える運用になる。
design.md のゾーン間ポリシー表を書くときにこの制約が効く。

## Cloudflare provider

**v5 でリソース名が総入れ替えになった。**
`cloudflare_record` は `cloudflare_dns_record`、`cloudflare_tunnel` は `cloudflare_zero_trust_tunnel_cloudflared` になっている。
v4 時代の記事のコードは書き換えが要る。

Tunnel 周りは `zero_trust_tunnel_cloudflared` と `_config` と `_route` に分かれている。
`config_src` を `local` にすると、ingress ルールの管理はオリジン側に残る。
クラスターの ConfigMap で ingress ルールを持つ構成は、この設定で成立する。

## 所有権の境界

Terraform と Flux と external-dns が同じリソースを触ると壊れる。
所有者を1つに決める。

| リソース | 所有者 |
| --- | --- |
| UniFi の VLAN、Zone-Based Firewall、BGP、ポートプロファイル | Terraform |
| Cloudflare のゾーン設定、Tunnel、API トークン、Access のアプリとポリシー | Terraform |
| Cloudflare のサービス用 DNS レコード | external-dns |
| Tunnel の ingress ルール | クラスターの ConfigMap（Flux） |
| クラスター内のすべて | Flux |

**DNS レコードの所有者は1つでなければならない。**
external-dns は TXT レジストリで自分が作ったレコードを記録し、記録にないものを管理外と見なす。
Terraform が同じ名前を握ると、互いのレコードを消し合う。
Terraform が持てるのは apex や MX、各種の検証レコードのように external-dns が触らないものだけである。

これは [service-exposure.md](service-exposure.md) の「external-dns 2系統の `txtOwnerId` を分ける」と同じ問題である。
ゾーンに書き込む主体が3つに増えた。

**cert-manager と external-dns のランタイム用トークンと、Terraform 用のトークンは分ける。**
前者に要るのは `Zone:DNS:Edit` と `Zone:Zone:Read` で、後者は Tunnel を作るため `Account:Cloudflare Tunnel:Write` を含む。
権限の範囲もライフサイクルも違う。

## state をどこに置くか

**クラスター内には置けない。**
Terraform はクラスターが前提とするネットワークを作るため、state をクラスターに置くと循環依存になる。
Longhorn 上に MinIO を立てる案はこの理由で採れない。

**Cloudflare R2 に置く。**
S3 互換であり、Cloudflare のアカウントは Tunnel と DNS で既に使う。
新しい依存先が増えず、ロックも DynamoDB 相当を用意せずに lockfile 方式で済む。

DS923+ の S3 互換ストレージも宅内で完結する点では候補になるが、DS923+ を VLAN 20 に載せる予定であり、その VLAN を Terraform が作る順序と噛み合わない。

## 既存リソースの回収

手で作ったものは `terraform import` で回収できる。

| 対象 | 回収先 | 備考 |
| --- | --- | --- |
| VLAN 20、VLAN 120 | `unifi_network` | |
| `Blackwall-BGP` | `unifi_bgp` | FRR config は `bootstrap/ucg-fiber-bgp.conf` にある |
| Cloudflare Tunnel | `cloudflare_zero_trust_tunnel_cloudflared` | secret の指定が要る |

**CLI で作った Tunnel も import できる。**
`tunnel_secret` は provider の入力属性であり、その値は `cloudflared tunnel create` が書く `~/.cloudflared/<UUID>.json` の `TunnelSecret` である。
API から読み出せない値だが、手元のファイルに残っているため import 後に指定できる。

未着手の VLAN 10、30、40、50、60 は import が要らない。
Terraform の最初の対象をここに置けば、既存の状態と突き合わせずに provider の挙動を確かめられる。
