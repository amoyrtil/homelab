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

**precheck は `region2` で失敗する。**
`region1.v2.argotunnel.com` への QUIC と HTTP/2 は成功し、`region2` は両方失敗する。
コネクション4本は正常に登録され、通信にも影響はない。
UCG-Fiber 側で `region2` の宛先が塞がれている可能性があるが、追っていない。

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

## 未回収

**HTTP から HTTPS へのリダイレクトに `:443` が付く。**
`RequestRedirect` フィルターにポートを書いていないが、Cilium は `https://foo.example.com:443/` を返す。
動作に問題はないが、リダイレクト先の URL としては冗長である。

**cloudflared の egress を絞る NetworkPolicy を入れていない。**
Cilium の Gateway API はデータプレーンが Pod endpoint ではなく、Envoy がノード上で受ける。
`CiliumNetworkPolicy` の `toEndpoints` で外部 Gateway を選べないため、`toServices` か CIDR で書くことになる。
書き方を単独で検証してから入れる。

これがないと、cloudflared の Pod はクラスター内の任意のアドレスへプロキシできる状態にある。
トンネルの資格情報が漏れた場合に攻撃者が得るのは「自分でトンネルを動かせること」であって、クラスターへの侵入経路ではない。
危ないのは cloudflared 自身が中継器として使えることのほうである。
