# Gateway と Cloudflare Tunnel でサービスを出す

R7 の記録である。
cert-manager で証明書を取り、Cilium の Gateway を2本立て、Cloudflare Tunnel と external-dns を通して、同じ URL が宅内とインターネットの両方から届く状態を作った。
実施は 2026年9月9日である。

設計の前提は [service-exposure.md](service-exposure.md) にある。
あちらが「成立するか」を調べたもので、こちらは「実際に通した」記録である。

## 実測

| 確認項目 | 結果 |
| --- | --- |
| ClusterIssuer | staging と production の両方が `Ready`。ACME アカウント登録に成功 |
| DNS-01 チャレンジ | `kaeritei.com` と `*.kaeritei.com` の2本とも `valid` |
| 証明書 | staging で発行。SAN は `*.kaeritei.com` と `kaeritei.com` |
| Gateway | internal が `192.168.120.101`、external が `192.168.120.100`。両方 `PROGRAMMED: True` |
| トンネル | コネクション4本を `nrt10` `nrt12` `nrt14` `nrt15` に登録 |
| external Gateway に繋いだ HTTPRoute | CNAME と TXT が作られ、インターネットから連続5回すべて `HTTP 200` |
| internal だけに繋いだ HTTPRoute | 公開 DNS に載らない。LAN 内からは `HTTP 200` |
| LAN 内の TLS | Gateway が staging のワイルドカード証明書を出す |
| HTTP から HTTPS へのリダイレクト | `301` |
| HTTPRoute の削除 | CNAME と TXT が消え、公開 DNS から引けなくなる |
| 未登録のホスト名 | Cloudflare Edge が `530` を返す |

## Gateway を internal と external の2本に分ける

**公開のスイッチを `HTTPRoute` の `parentRefs` に持たせた。**
external-dns（Cloudflare 系統）に `--gateway-label-filter=homelab/scope=external` を与え、`homelab/scope: external` のラベルを持つ Gateway に繋がった `HTTPRoute` だけを見せる。
external に繋がなければ公開 DNS にレコードが作られず、インターネットからは名前解決の段階で届かない。

アノテーションで公開を制御する方法もあるが、`parentRefs` なら `HTTPRoute` 単体を読んで公開の有無が判断できる。

### スイッチを2つにする

R9 の監査で、`parentRefs` だけだと**どの namespace からでも1行足すだけで公開側に繋がる**ことを指摘した。
external Gateway の `allowedRoutes` が `from: All` だったためである。

実際の到達は塞げている。
cloudflared の egress が backend を列挙する形になっており、許可の無い backend は `403` になる（後述）。
塞げていないのは**名前の公開**である。
external-dns は Gateway に繋がった時点でレコードを書くため、届かないサービスでも FQDN が公開 DNS に出る。

namespace 側にも許可を要求する形にした。

```yaml
allowedRoutes:
  namespaces:
    from: Selector
    selector:
      matchLabels:
        homelab/expose: "true"
```

internal は `All` のままでよい。
宅内からの到達は塞ぐ対象ではなく、`HTTPRoute` を書いたなら繋がってよい。

**`flux-system` のラベルは `FluxInstance` の patch で付ける。**

```yaml
# bootstrap/flux-instance.yaml
kustomize:
  patches:
    - target:
        kind: Namespace
        name: flux-system
      patch: |
        - op: add
          path: /metadata/labels/homelab~1expose
          value: "true"
```

`~1` は JSON Pointer における `/` のエスケープである。
`homelab/expose` をそのまま書くと階層として解釈される。

### ラベルを手で付けると剥がれる

最初は `kubectl label` で付けた。**6時間ほどで消え、公開 URL が落ちた。**

`flux-system` Namespace は flux-operator が自分の inventory に持っている。

```console
$ kubectl -n flux-system get fluxinstance flux -o json \
    | jq -r '.status.inventory.entries[].id' | grep -i namespace
_flux-system__Namespace
```

reconcile のたびに自分の desired state を Apply するため、余所が付けたラベルは落ちる。
実際、Namespace の field manager は `flux-operator / Apply` の1つだけである。

**症状は「壊れない」ことである。**
クラスター側は何も落ちない。`HTTPRoute` は external に対して `Accepted: True` のままで、Kustomization も全部 `True` だった。
落ちたのは公開 DNS のほうである。

```
external-dns: Changing record. action=DELETE record=flux-webhook.<domain> type=CNAME
external-dns: Changing record. action=DELETE record=k8s.cname-flux-webhook.<domain> type=TXT
（以降ずっと）All records are already up to date
```

**external-dns は `allowedRoutes` を自分で評価する。**
Gateway API の `status` が `Accepted: True` でも、external-dns 側が namespace のラベルを見て「繋がっていない」と判断すれば、`policy: sync` がレコードを消す。
そして一度消したあとは「up to date」と言い続ける。

切り分けは external-dns のログを見るのが速い。
`action=DELETE` が出ていれば、クラスターではなくレコードの側の問題である。
Pod の再起動では直らない（キャッシュではなく判定だから）。

なお、消えた直後に手元から引くと [NXDOMAIN のネガティブキャッシュ](#未回収)を踏む。
復旧の確認は `dig @1.1.1.1` と `curl --resolve` で行う。

listener の構成は2本で違う。
internal は宅内からの経路であり、Cloudflare を通らないため Gateway 自身が TLS を終端する。
external は Cloudflare Edge が TLS を終端するため、listener は HTTP だけでよい。

公開するサービスは両方に繋ぐ。
`hostname` は1つのままで、split-horizon DNS がどちらの経路に流すかを決める。

## external-dns の target をトンネルに向ける

**`--default-targets` では上書きできない。**
このフラグはソースが target を出さなかった場合にしか適用されない。
`gateway-httproute` ソースは Gateway のアドレス、つまり VLAN 120 の LB IP を target として出すため、フラグは無視される。
上書きするには `--force-default-targets` が要るが、こちらは deprecated である。

**Gateway 側の `target` アノテーションを使う。**

```yaml
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/target: "<UUID>.cfargotunnel.com"
```

`source/gateway.go` は Gateway のアノテーションを `overrides` として読み、Gateway のアドレスの代わりに使う。
アノテーションは external Gateway に1箇所書けば、そこに繋がるすべての `HTTPRoute` に効く。

**`--cloudflare-proxied` が要る。**
`cfargotunnel.com` への CNAME は proxied でなければトンネルに入らない。
proxied なので、公開 DNS を引くと Cloudflare の anycast アドレスが返る。

**`txtPrefix` を付けないと CNAME と TXT が衝突する。**
同じ名前に CNAME と TXT を共存させられないためである。
`txtPrefix: k8s.` を与えると、CNAME `foo.example.com` に対する TXT は `k8s.cname-foo.example.com` になる。
`cname-` の部分はレコード種別ごとに external-dns が付ける。

## cert-manager

**DNS-01 の自己確認に権威 DNS を直接引かせる。**

```yaml
dns01RecursiveNameservers: "1.1.1.1:53,9.9.9.9:53"
dns01RecursiveNameserversOnly: true
```

宅内は split-horizon であり、内部 DNS に尋ねると自分が置いた TXT を見つけられずチャレンジが止まる。

**staging で1回通してから production に切り替える。**
production はレート制限が厳しく、設定を誤ると週次の上限を使い切る。
ワイルドカード1枚のために `kaeritei.com` と `*.kaeritei.com` の2本のチャレンジが走り、どちらも同じ `_acme-challenge.kaeritei.com` に TXT を置く。

**API トークンは用途ごとに分ける。**
cert-manager と external-dns のランタイム用は `Zone:DNS:Edit` と `Zone:Zone:Read` を対象ゾーンだけに絞る。
Terraform 用には Tunnel を作れるトークンを別に与える（[terraform-provisioning.md](terraform-provisioning.md)）。

同じトークンを cert-manager と external-dns の2つの namespace で使うため、暗号化した Secret を2つ置いている。
namespace 間で Secret を複製する仕組みは入れていない。

## Cloudflare Tunnel

**locally-managed で作る。**
`cloudflared tunnel create` が作る資格情報を SOPS で暗号化して Git に置き、ingress ルールは ConfigMap に持つ。
Tunnel そのものは R8 で Terraform の管理下に移し、CLI は使わなくなった（[terraform-provisioning.md](terraform-provisioning.md)）。
Zero Trust ダッシュボードで設定を持たせる remotely-managed だと、何を公開しているかが Git に残らない。

ingress ルールは自分のドメインだけを外部 Gateway に流し、末尾を `http_status:404` で閉じる。

```yaml
ingress:
  - hostname: "*.example.com"
    service: http://cilium-gateway-external.network.svc.cluster.local:80
  - service: http_status:404
```

Cilium は Gateway ごとに `cilium-gateway-<Gateway 名>` という Service を作る。
cloudflared はこれを宛先にする。

**未登録のホスト名は cloudflared に届かない。**
Cloudflare Edge が `530` を返して落とすため、末尾の `404` は保険として残る。

**`region2` の precheck 失敗は一時的なものだった。**
初回の起動では `region2.v2.argotunnel.com` への QUIC と HTTP/2 が両方失敗したが、後の起動では両方成功している。
経路の問題ではない。

## Flux の Webhook Receiver

GitHub の push を受け、`GitRepository` の取得を即座に走らせる。
受け口は external Gateway に繋ぎ、パスを `/hook/` に絞る。
`Receiver` の `status.webhookPath` が `/hook/<sha256>` を返し、これが webhook の URL になる。

**flux-operator の NetworkPolicy が Gateway 経由の要求を落とす。**
`cluster.networkPolicy: true` で入る `allow-webhooks` は、ingress の `from` を `namespaceSelector` に限っている。
Cilium から見て Gateway 経由の要求は Pod ではなく world の identity を持つため、この条件に当たらない。

症状は Gateway が `503` を返すことである。
`/hook/` 以外のパスは `404` になり、Pod から Service を直接叩くと `400`（署名なしの正しい応答）が返る。
つまり経路もルーティングも正しく、backend への接続だけが落ちている。
internal と external の両方で `503` になることが、トンネル側の問題ではない証拠になった。

`from` を書かない NetworkPolicy を1つ足して解消した。

```yaml
spec:
  podSelector:
    matchLabels:
      app: notification-controller
  policyTypes: [Ingress]
  ingress:
    - ports: [{ protocol: TCP, port: 9292 }]
```

公開しても差し支えないのは、パスが推測できない hash であり、本文の HMAC 署名を notification-controller が検証するためである。
GitHub が hook 作成時に送る `ping` が `200 OK` で通り、`GitRepository/flux-system` に annotation が付くところまで確認した。

**レコードを作った直後の確認では NXDOMAIN のネガティブキャッシュを踏む。**
Cloudflare のゾーンは SOA の最小 TTL が 1800 秒である。
external-dns の同期（既定 1分間隔）より先に名前を引くと、宅内のリゾルバが最大 30 分そのネガティブ応答を返し続ける。
外部から確認するときは `dig @1.1.1.1` で権威側を引き、`curl` には `--resolve` を渡す。

## cloudflared の egress を絞る

目的は cloudflared のプロセスが乗っ取られた場合の被害を限ることである。
ConfigMap や Git を書ける相手には効かない。同じ場所にあるポリシーも書き換えられる。

**Edge へのポートは 443 ではなく 7844 である。**
`world` 宛の 443 だけを許して 7844 を落とすと `failed to dial to edge with quic: timeout: no recent network activity` でコネクションが切れる。
Hubble には `world:7844 (UDP) Policy denied DROPPED` が残る。

**443 は開けない。**
Cloudflare のドキュメントは 7844 の TCP と UDP を必須とし、443 は optional として用途を自動更新の確認と PQ 鍵交換のエラー報告に限っている。
`no-autoupdate: true` のこの構成では両方とも要らない。
起動時の precheck が `api.cloudflare.com:443` に届かず `status=fail` と出るが `hard_fail=false` である。
world への 443 は、侵入された側から見て最も使いやすい持ち出し経路になるため開けない。

### Gateway 宛は L4 では止まらないが backend 単位で止まる

**ここは一度読み違えたので、順に書く。**

Cilium は Gateway 宛のパケットを L7 LB へ先に回し、L3/L4 の egress 判定を飛ばす。
`bpf/bpf_lxc.c` に `Forward to L7 LB first before applying network policy` というコメントとともに書かれている。
したがって Gateway そのものを `toServices` や `toCIDRSet` で指定しても一致しない。
socket LB の副作用ではないため、`socketLB` を切っても変わらない。

ここまでは正しい。
ここから「Gateway 宛は塞げない」と結論したのが誤りだった。

**Envoy が upstream を選んだ時点で、送信元 Pod の egress ポリシーがその backend に対して評価される。**
許可がなければ `403` と本文 `Access denied` を返す。
つまり公開する `HTTPRoute` の backend を列挙するのが正しい書き方であり、Gateway を区別する必要はない。

読み違えた原因は、probe Pod が受けた `404` の解釈である。
`404` は `HTTPRoute` に一致しなかったときに Envoy 自身が返す応答であり、upstream が選ばれていない。
評価が一度も走っていない状態を「到達できた」と読んでいた。

ホスト名を実在のルートに合わせて測り直すと、区別が出る。

```
internal Gateway 経由、許可していない backend : 403 Access denied
internal Gateway 経由、許可済みの backend     : 到達する
external-dns の ClusterIP                    : 000（L4 で拒否）
Kubernetes API 10.96.0.1                     : 000（L4 で拒否）
```

Webhook Receiver でも同じ順序で確認できた。

| ポリシー | GitHub の配送 |
| --- | --- |
| 無し | `200` |
| 有り、backend 許可なし | `403` |
| 有り、backend 許可あり | `200` |

**運用上の結合が生まれる。**
external Gateway に `HTTPRoute` を足すたびに、その backend を cloudflared の egress へ足す必要がある。
手間だが、トンネルから触れる先が1つのファイルに列挙されるという利点がある。

`toServices` が一致しない理由は、両方の Gateway の EndpointSlice がどちらも `192.192.192.192` という Cilium のダミーを1つ持つだけで、実体の Pod がないためである。
`pkg/policy/k8s/service.go` が `toServices` を backend の prefix から `ToCIDRSet` へ展開するため、ダミーだけが展開される。

Gateway を identity で区別する道は今も無い。
区別すべきは Gateway ではなく backend である。

### 403 Access denied を Cloudflare の WAF と読み違えた

**この `403` は Cilium の Envoy が返している。**
`Access denied` は Cilium の既定の応答本文であり、`--http-403-msg` で変えられる。

紛らわしいのは、トンネル経由の応答には Cloudflare が必ず `Server: cloudflare` を付けることである。
応答ヘッダだけでは WAF の 403 と区別できない。
実際、WAF が落としていると判断して plan.md に未回収として立ててしまった。

切り分けは Cloudflare を通さずに行う。
cloudflared と同じラベルを付けた probe Pod から Gateway を直接叩き、`Server` ヘッダの有無を見る。
ポリシーを外して配送が通るかを見るのも早い。

### :2000 は /config を無認証で返す

`metrics: 0.0.0.0:2000` で立つ cloudflared のメトリクスサーバは、`/ready` と `/metrics` のほかに `/config` と `/debug/pprof/` を返す。
`/config` はトンネルの ingress ルール、つまり公開しているホスト名と backend の Service 名を含む。
クラスター内の任意の Pod から読める状態だった。

ingress を1つ書き、`fromEntities: [host]` で kubelet の probe だけを通す。
Cilium は方向ごとに既定拒否になるため、egress だけを書いていると ingress は無制限のままである。
probe は `host` だけで通り、Pod は Ready を保った。

Prometheus を入れるときはスクレイパをここへ足す。
足し忘れるとスクレイプが黙って落ちる。

### 実例との比較

home-operations 系のリポジトリに cloudflared の egress ポリシーの実例は無い。
この界隈のデファクトは「当てていない」である。

個人リポジトリやブログの実例では、ポートを指定している例のすべてが world への 443 を開けている。
ただし理由を正しく書けているものは少なく、registration に要る、TLS のフォールバックに要る、といった Cloudflare のドキュメントに裏付けのない説明が混ざる。
多いことと検証されていることは別である。

`toFQDNs` で `*.argotunnel.com` に絞る例もある。
採らなかったのは、クラスターの唯一の入口の可用性を Cilium の DNS proxy に依存させることになるためである。
加えて cloudflared は既定リゾルバが失敗すると `1.1.1.1:853` へ直接 DoT で SRV を引き、この経路は DNS proxy を通らないため IP が学習されず、結果として 7844 が拒否される。

## ゾーン設定を引き上げる

R8 は現在値のままコード化し、`ssl = flexible` と `min_tls_version = 1.0` の判断を R9 へ送った。
R9（2026年9月11日）で両方を引き上げた。

| 設定 | 前 | 後 |
| --- | --- | --- |
| `ssl` | `flexible` | `strict` |
| `min_tls_version` | `1.0` | `1.2` |

### Tunnel を使うと SSL モードは実質バイパスされる

ゾーンの SSL/TLS モードが決めるのは、Cloudflare Edge からオリジンまでの1ホップである。
Tunnel の場合、そのホップは cloudflared への QUIC 接続であり、モードに関わらず常に暗号化されている。
`cloudflared` が宅内のサービスへ何で繋ぐかは ingress ルールの `service:` が決める。

つまり **`http://cilium-gateway-external…:80` を向いたまま `strict` にしても壊れない**。
実際に壊れないことを apply の前後で確かめた。

| 確認項目 | 結果 |
| --- | --- |
| `apply` | `0 added, 2 changed, 0 destroyed` |
| 直後の `plan` | `No changes` |
| 公開 URL（連続3回） | `HTTP 404`。apply 前と同じ応答 |
| TLS 1.1 で接続 | `HTTP 000`。拒否される |
| TLS 1.2 で接続 | `HTTP 404`。通る |

### では何のために上げるのか

バイパスされるなら `flexible` のままでもよさそうに見える。
上げる理由は、**これがゾーン全体に効く設定だから**である。

| `flexible` のまま残す危険 | 内容 |
| --- | --- |
| 将来の非 Tunnel オリジン | Tunnel を通さない proxied レコードを1本足した瞬間、Cloudflare が平文で origin へ繋ぐ |
| Authenticated Origin Pull | `Off` と `Flexible` では使えない |
| ポートによる挙動の変化 | `flexible` は 443 以外の HTTPS で `full` にフォールバックする |

Cloudflare 自身もこう書いている。

> If possible, Cloudflare strongly recommends using **Full** or **Full (strict)** modes to prevent malicious connections to your origin.
> If your application contains sensitive information (personalized data, user login), use **Full** or **Full (Strict)** modes instead.
> ([Cloudflare: Encryption modes](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/))

`full` ではなく `strict` を選んだのは、Tunnel をやめて直接公開へ戻す日が来たときに、
オリジン証明書の検証が最初から要求される状態にしておくためである。
いま得ているものは何も無いが、失うものも無い。

`min_tls_version` は 1.2 にした。
このゾーンが serve するのは Tunnel 経由の自分のサービスだけで、古い機器がここを引くことはない。
互換性を気にする相手が居ない。

## 未回収


**HTTP から HTTPS へのリダイレクトに `:443` が付く。**
`RequestRedirect` フィルターにポートを書いていないが、Cilium は `https://foo.example.com:443/` を返す。
動作に問題はないが、リダイレクト先の URL としては冗長である。

