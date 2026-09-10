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
中身を Terraform に載せても評価順は UI に残るため、1つの関心事の所有者が2つになる。

**この制約を理由に、Zone-Based Firewall は Terraform の管理対象から外した。**
design.md の VLAN 間ポリシー表は設計の記述として残し、実装は UI で行う。

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
| UniFi の VLAN、BGP | Terraform |
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

### 何を Terraform に載せるか

所有者を決める前に、そもそも載せるかを決める。
条件は2つあり、どちらかを満たすものだけを対象とする。

| 条件 | 例 |
| --- | --- |
| homelab のためだけに存在する | Cloudflare Tunnel、BGP のピアリング |
| 同じ形のものを量産する必要がある | VLAN、Cloudflare のゾーン設定 |

**スイッチのポートプロファイルは対象外とした。**
宅内のスイッチの設定であって homelab に固有ではなく、ポートの種類も増えない。
1度作れば済むものをコードに写しても、state と UI の二重管理が増えるだけで得るものがない。

**Zone-Based Firewall も対象外とした。**
ポリシーは量産する要素であり、条件のうえでは当てはまる。
外したのは provider が評価順を扱えないためである。
「[ポリシーの順序は provider から管理できない](#ポリシーの順序は-provider-から管理できない)」にある。

ゾーン（`unifi_firewall_zone`）には順序の制約がない。
ただし数が増えず homelab 固有でもないため、この基準では同じく対象外になる。
ポリシーだけを外してゾーンを残す形も、片方だけをコードにする分かりにくさが残る。

`ubiquiti-community/unifi` は `unifi_setting` や `unifi_wlan` のように、
コントローラーのほとんどの設定を扱えるだけのリソースを持っている。
扱えることと載せるべきことは別である。

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
`tunnel_secret` は provider の入力属性であり、API から読み出せない。
その値は `cloudflared tunnel create` が書く credentials ファイルにあり、同じものがクラスターの `cloudflared-credentials` として SOPS 暗号化で Git に入っている。

ただし、実際に回収したときには渡さないほうがよいと分かった。
「[Tunnel の回収](#tunnel-の回収)」にある。

調査の時点では VLAN 10、30、40、50、60 が未着手であり、Terraform の最初の対象をそこに置く前提だった。
実際に着手したときには7つとも UI で作り終えていたため、全数を import で回収する形になった。

## 実行バイナリは OpenTofu にした

ここから下は 2026年9月10日、R8 で実際に組んだときの記録である。

Terraform と OpenTofu は provider レジストリを共有しており、`ubiquiti-community/unifi` も `cloudflare/cloudflare` もどちらからでも同じものが入る。
ライセンスは OpenTofu が MPL-2.0、Terraform が BSL 1.1 である。

決め手は state の暗号化だった。
OpenTofu は state と plan の暗号化を本体に持つ。
この構成の state には Tunnel の `tunnel_secret` が平文で入るため、R2 のトークンが漏れた時点で資格情報まで漏れる。
本体で暗号化しておけば、その露出を潰せる。

名前は「terraform」に寄せる。
バイナリ名が `tofu` である一方、ディレクトリ名、バケット名、state のキー、mise のタスク名は自由に決められる。
これらを「terraform」で揃え、`tofu` はコマンドを打つときだけ現れるようにした。

## root モジュールを provider ごとに分ける

`terraform/cloudflare/` と `terraform/unifi/` を別の root モジュールにし、state のキーも `cloudflare/terraform.tfstate` と `unifi/terraform.tfstate` に分ける。

UniFi provider は controller への到達を要求する。
単一の root に両方を置くと、UniFi のリソースが1つ入った時点で、Cloudflare だけを変えるときにも controller への到達と認証情報が要るようになる。
宅内にいなければ Cloudflare の `plan` すら回らない。

## 実行と認証情報

手元から回す。
UniFi provider が controller のローカル管理者アカウントと宅内 LAN への到達を要求するため、CI からは UniFi 側が原理的に届かない。
実行場所を provider ごとに分けると、認証情報の置き場所も2つに分かれる。

資格情報は `terraform/secrets.sops.env` に dotenv 形式で置き、SOPS で暗号化して Git に入れる。
`.sops.yaml` に `.*\.sops\.env$` のルールを足した。
呼び出しは mise のタスクにまとめてある。

```console
$ mise run terraform cloudflare init
$ mise run terraform cloudflare plan
```

第1引数が root モジュール名であり、残りはそのまま `tofu` に渡る。

### 資格情報のファイルを作る

平文をリポジトリにも会話にも残さずに作る。

`sops terraform/secrets.sops.env` は、そのファイル名で `.sops.yaml` のルールに当たり、エディタを開いて保存時に暗号化する。
平文はディスクに残らない。
`terraform/secrets.example.env` の中身を貼り、値を埋めればよい。

先に平文で書きたい場合は `terraform/secrets.env` を使う。
gitignore 対象であり、暗号化したら消す。

```console
$ sops --encrypt --filename-override terraform/secrets.sops.env \
    --input-type dotenv --output-type dotenv terraform/secrets.env \
    > terraform/secrets.sops.env
$ rm terraform/secrets.env
```

`--filename-override` が要る。
`.sops.yaml` のルールは入力ファイルのパスに対して当たるため、これがないと `secrets.env` では規則に当たらない。

どの鍵が入っているかは、値を出さずに確かめられる。

```console
$ sops -d terraform/secrets.sops.env | cut -d= -f1
```

`CLOUDFLARE_ACCOUNT_ID` と `CLOUDFLARE_TUNNEL_ID` は、クラスターの `cloudflared-credentials` にある `credentials.json` の `AccountTag` と `TunnelID` から取れる。

```console
$ sops -d kubernetes/apps/network/cloudflared/app/credentials.sops.yaml
```

`jq` に通せば、画面に出さずに書き込める。

### 環境変数から AWS の名前を消す

R2 は S3 互換 API を提供しており、OpenTofu からは `backend "s3"` で使う。
その backend は資格情報を `AWS_ACCESS_KEY_ID` と `AWS_SECRET_ACCESS_KEY` からしか読まない。
AWS を使っていないのにその名前が出てくると、読むたびに何の話かを確かめ直すことになる。

`.mise/tasks/terraform` が名前を写し、AWS の語をこのスクリプトの中だけに閉じ込める。

| `secrets.sops.env` が持つ名前 | 写す先 |
| --- | --- |
| `CLOUDFLARE_TERRAFORM_API_TOKEN` | `CLOUDFLARE_API_TOKEN` |
| `CLOUDFLARE_R2_ACCESS_KEY_ID` | `AWS_ACCESS_KEY_ID` |
| `CLOUDFLARE_R2_SECRET_ACCESS_KEY` | `AWS_SECRET_ACCESS_KEY` |
| `TERRAFORM_STATE_PASSPHRASE` | `TF_VAR_state_passphrase` |
| `CLOUDFLARE_ACCOUNT_ID` | `TF_VAR_state_endpoint`（URL に組み立てる）、`TF_VAR_cloudflare_account_id` |
| `CLOUDFLARE_TUNNEL_ID` | `TF_VAR_tunnel_id` |
| `CLOUDFLARE_ZONE_ID` | `TF_VAR_cloudflare_zone_id` |
| `UNIFI_TERRAFORM_API_KEY` | `UNIFI_API_KEY` |

`TF_VAR_` は宣言のない変数に対しては黙って無視される。
両方の root モジュールに同じ環境変数を撒いても、Cloudflare 用の3つが UniFi 側で警告になることはない。

**state の置き場のアカウント ID も同じ扱いにする。**
backend のエンドポイントは `https://<アカウント ID>.r2.cloudflarestorage.com` であり、
当初は両モジュールが `var.cloudflare_account_id` からこれを組み立てていた。
その形だと、UniFi しか触らない root モジュールが `cloudflare_account_id` という名前の入力を要求することになる。
state の置き場の都合が、管理対象の名前空間に漏れている。

URL の組み立てをタスクに移し、`TF_VAR_state_endpoint` として渡す。
root モジュールが受け取るのは「S3 互換ストレージのエンドポイント」までになった。
`backend` の `skip_*` 群は R2 が持たない機構を切るためのもので、これは R2 固有の事情であるからモジュール側に残す。
閉じ込めたのは値と変数の名前である。

名前を完全に消す道もあるが、採らない。
backend ブロックに変数で資格情報を書けば `AWS_` を使わずに済む一方、OpenTofu 自身がその方法を推奨していない。
`init` が backend の設定を `.terraform/terraform.tfstate` へ平文で書き出すため、名前を消す代わりに資格情報がディスクに残る。

## R2 バックエンド

R2 が持たない S3 の機構を順に切る。
資格情報の検証、メタデータ API、リージョン名の検証、アカウント ID の照会、チェックサム、仮想ホスト形式の URL の6つである。
`region` には S3 互換 API の必須項目を埋めるためだけに `auto` を置く。

ロックは `use_lockfile` の条件付き書き込みで行う。
DynamoDB 相当の外部テーブルは要らない。

エンドポイントの URL にはアカウント ID が入る。
リポジトリが public であるため、値は変数から与える。
OpenTofu は backend ブロックで変数と local を使えるので、`init` の時点で解決できる値であれば書ける。
偽のアカウント ID で `init` を回し、エンドポイントが展開されて TLS の握手まで到達することを確認した。

### バケットは Terraform で管理しない

state を置く器を state で管理すると、壊したときに足場がなくなる。
バケット（`homelab-terraform-state`）は手で作り、コードの管理対象から外す。

## state の暗号化

`key_provider "pbkdf2"` でパスフレーズから鍵を作り、`method "aes_gcm"` で state と plan の両方を暗号化する。
どちらにも `enforced = true` を立てる。
空のバケットから始めるため、平文の state を読むための `fallback` は要らない。

パスフレーズを失うと state を読めなくなる。
ただし、ここで管理するリソースはすべて import で回収できるため、復旧はできる。

## Tunnel の回収

Tunnel の名前は `blackwall` である。
UUID は `mise run terraform cloudflare output tunnel_id` で確認できる。
`config_src` に `local` を指定し、`cloudflare_zero_trust_tunnel_cloudflared_config` は作らない。
ingress ルールはクラスターの ConfigMap が持ち、Flux が反映する。
`_config` を作ると Zero Trust ダッシュボード側にも設定が生まれ、所有者が2つになる。

`tunnel_secret` は渡さない。
API から読み出せない値であり、import しても state に入らないため、当初は手元の値を与える前提で書いていた。
両方を実測して比べた。

| `tunnel_secret` | `plan` の結果 |
| --- | --- |
| 渡す | `1 to import, 0 to add, 1 to change, 0 to destroy` |
| 渡さない | `1 to import, 0 to add, 0 to change, 0 to destroy` |

渡した場合の1件は置き換えではなく in-place の更新であり、トンネルが落ちるものではなかった。
それでも渡さないほうを採る。
稼働中の Tunnel への書き込みが起きず、state に秘密が入らないためである。
値はクラスターの `cloudflared-credentials` にあり、Tunnel を作り直す段になれば取り出せる。

import には `import` ブロックを使う。
`id` に `${var.cloudflare_account_id}/${var.tunnel_id}` を書けば、アカウント ID と Tunnel の UUID を Git に置かずに済む。
CLI の `tofu import` では、資格情報を復号するラッパーの中で引数を組み立てることになり、この2つが平文で残る。

### cloudflared の CLI は使わない

Tunnel の所有者を Terraform に一本化した以上、CLI が使える状態にあることは所有権の境界を崩す経路を1本残すことになる。
mise から外し、`~/.cloudflared` も消した。

| 用途 | 代替 |
| --- | --- |
| Tunnel の作成 | `cloudflare_zero_trust_tunnel_cloudflared` |
| UUID の確認 | `mise run terraform cloudflare output tunnel_id` |
| コネクション数の確認 | API の `/accounts/<account_id>/cfd_tunnel/<tunnel_id>` |

資格情報は失われない。
`AccountTag`、`Endpoint`、`TunnelID`、`TunnelSecret` の4つとも `cloudflared-credentials` に入っており、Tunnel を作り直すときはここから `credentials.json` を組み立てられる。

### 回収の実測（2026年9月10日）

| 確認項目 | 結果 |
| --- | --- |
| `apply` | `1 imported, 0 added, 0 changed, 0 destroyed` |
| 直後の `plan` | `No changes` |
| トンネルのコネクション | 4本を維持（`nrt09` `nrt12` `nrt14` `nrt15`） |
| cloudflared の Pod | 再起動なし。再接続のログもなし |
| R2 の state | 誤ったパスフレーズで `cipher: message authentication failed`。保管時に暗号化されている |
| 公開 URL | Cloudflare Edge からオリジンまで到達。HTTP から HTTPS へ `301` |

## ゾーン設定の回収

`cloudflare_zone_setting` は設定1つで1リソースであり、挙げなかったものは UI の管理のまま残る。
この構成の正しさに関わる7つだけを持つ。

値は API で現在値を読み、その値のままコードに書いた。
推測で書くと、`ssl` を取り違えた時点で公開中のサイトが壊れる。

| 設定 | 値 |
| --- | --- |
| `always_use_https` | `on` |
| `automatic_https_rewrites` | `on` |
| `min_tls_version` | `1.0` |
| `security_level` | `medium` |
| `ssl` | `flexible` |
| `tls_1_3` | `on` |
| `websockets` | `on` |

型が7つとも文字列であるため、`locals` のマップと `for_each` で書ける。
`import` ブロックも `for_each` を取れるので、7件を2ブロックで回収できた。

**`ssl` と `min_tls_version` は見直す価値がある。**
Cloudflare がトンネル構成に推奨するのは Full 系であり、TLS 1.0 と 1.1 は非推奨である。
ただし R8 はコード化であって設定の変更ではない。
現在値のまま取り込み、判断は R9 の監査に送る。

`apply` は `7 imported, 0 added, 0 changed, 0 destroyed` で、直後の `plan` は `No changes`。
API で読み直した7つの値は apply の前後で変わらず、公開 URL も `301` と `404` のまま応答した。

### アカウント所有のトークンは /user/tokens/verify で弾かれる

トークンが通らないとき、`GET /client/v4/user/tokens/verify` で確かめたくなる。
このエンドポイントはユーザー所有のトークンしか受け付けない。
アカウント所有のトークンは、有効であっても `Invalid API Token` を返す。
`GET /client/v4/accounts/<account_id>/tokens/verify` を使う。

権限の過不足は、実際に使うエンドポイントを叩いて切り分けるのが速い。

```console
$ curl -s -H "Authorization: Bearer $TOKEN" \
    "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/cfd_tunnel/$TUNNEL" \
    | jq -r 'if .success then "OK" else .errors[0].message end'
```

`Invalid API Token` は値が無効、`Not authorized` は値が有効で権限が足りない、と読み分けられる。
Roll は値だけを差し替えるため、`Not authorized` を Roll で直そうとしても変わらない。

### sops unset はその場で書き換える

`sops unset` は標準出力に何も出さず、対象のファイルを直接書き換える。
出力をリダイレクトして書き戻す形で使うと、空のファイルで上書きすることになる。
一度これで暗号化済みの資格情報を失った。
鍵を1つ消したいときは `sops unset <file> '["KEY"]'` だけを実行する。

## VLAN の回収

調査の時点で残っていた VLAN は着手までに UI で作り終えていたため、7つ（10、20、30、40、50、60、120）を全数 import した。
Terraform に載せるのは VLAN を持つものだけである。
Default（VLAN 1）は機器を収容せず、WAN は `unifi_wan` という別のリソースを持つため、どちらも UI の管理のまま残した。

### 認証は Terraform 専用の管理者から発行した API キー

provider は `api_key`、`username`、`password` の3つを取り、`api_key` を与えると残り2つを無視する。
Terraform 専用のローカル管理者を作り、その管理者から API キーを発行した。
キーは発行元の管理者の権限を継ぐため、権限の範囲と失効を1か所で扱える。

**TLS の検証は切ることになる。**
UCG-Fiber は `CN=unifi.local` の自己署名証明書を出し、発行者も自分自身であるため、ホスト名で繋いでも検証は通らない。
provider は `ca_cert` に相当する属性を持たず、`allow_insecure` しかない。

検証を切ると API キーが未検証の TLS に載る。
宅内 LAN の1本に閉じるため許容した。
外すにはコントローラーに正式な証明書を載せることになる。

### import ID は名前で指せる

`unifi_network` の import ID は3つの形を取る。

| 形 | 例 |
| --- | --- |
| ID | `5dc28e5e9106d105bdc87217` |
| サイト付きの ID | `bfa2l6i7:5dc28e5e9106d105bdc87217` |
| 名前 | `name=LAN` |

`name=` を使う。
ObjectId でも指せるが、コードを読んだときにどの VLAN の話か分からない。

### 現在値から設定を起こす

`tofu plan -generate-config-out=<file>` が import ブロックの対象を読み、HCL を書き出す。
UI で作ったものをコード化するとき、属性を1つずつ API と突き合わせずに済む。

**ただし生成物はそのままでは `validate` を通らない。**
コントローラーが `domain_name` を持たない VLAN に対して、生成された設定は `domain_name = ""` を書く。
provider のバリデータは空文字を拒否するため、7件すべてがエラーになる。
この属性は Optional かつ Computed であり、省略すればコントローラーの値に従うので、消せばよい。

生成物は属性を50個ほど並べる。
そのうち実際にリソースごとに違うのは `name`、`vlan`、`subnet`、`purpose`、`setting_preference`、`dhcp_server`、`dhcp_guarding` だけだった。
残りは全件で同じ値であり、Optional かつ Computed であるから書かなくてよい。
`locals` のマップと `for_each` で7件を1つのリソースブロックに畳んである。

### auto_scale は Computed でも既定値が当たる

**省略すると現在値を読まず、`true` を当てる。**
7つとも `false` であるため、書かずに import すると `plan` が `7 to import, 0 to add, 7 to change, 0 to destroy` になる。
取り込んだ直後に更新をかける plan であり、import としては失敗している。

スキーマ上は Optional かつ Computed であり、省略すれば現在値に従うと読める。
実際には provider が既定値を持っており、そちらが勝つ。
`auto_scale = false` を明示して差分ゼロにした。

**Computed であることは現在値が読まれる保証にならない。**
同じ罠が他の属性にもあり得る。
`-generate-config-out` の生成物と `plan` の差分を突き合わせて、消してよい属性かを1つずつ確かめるのが速い。

### Guest の purpose はゾーンと結合している

VLAN 60 は `purpose = "guest"` である。
Zone-Based Firewall のコントローラーでは、この値を保てるのはそのネットワークが guest ゾーンに属しているあいだだけである。
ゾーンから外すとコントローラーが `corporate` に書き戻し、apply が inconsistent result で落ちる。

ゾーンはまだ Terraform に載せていない。
`unifi_firewall_zone` を入れるまで UI の管理のまま置く。

### 回収の実測（2026年9月10日）

| 確認項目 | 結果 |
| --- | --- |
| `apply` 前の `plan` | `7 to import, 0 to add, 0 to change, 0 to destroy` |
| `apply` | `7 imported` |
| 直後の `plan` | `No changes` |
| コントローラーの `networkconf` | apply の前後で10件を全フィールド比較して差分なし |
| R2 の state | 誤ったパスフレーズで `cipher: message authentication failed` |

import は読み取りだけで完結する。
`0 to change` の plan であれば、コントローラーへの書き込みは1本も出ない。

### 設計と現状の差分は R9 に送る

コード化と設定の変更を混ぜない。
Cloudflare の `ssl = flexible` と同じ扱いで、現在値のまま取り込んだ。

| 項目 | design.md / plan.md の記述 | コントローラーの現在値 |
| --- | --- | --- |
| DHCP プール | VLAN 20 のみ `.150-.250` と規定 | VLAN 20 以外は UniFi 既定の `.6-.254` |
| mDNS | 「VLAN 30 と 40 で有効化する」 | 全 VLAN で有効 |
| DHCP Guarding | 「VLAN 30 と 60 に価値がある」 | VLAN 20 のみ有効 |
