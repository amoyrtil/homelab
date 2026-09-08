# サービス公開の到達性と名前解決

R4 で Cilium BGP に移る前に、2つの懸念を調べた記録である。

1つは、LoadBalancer IP をノードと同じ VLAN に置いたまま BGP へ移せるかどうか。
もう1つは、家庭 LAN 内とインターネットの両方から、同じ URL でサービスに届くかどうかである。

前者は**移せない**という結論になり、LB Pool 専用の VLAN を切ることになった。
後者は design.md の構成のままで成立するが、満たすべき条件が5つある。

調査は 2026年9月8日、Talos v1.14.0 と Cilium v1.20.1 のリハーサル環境（cp-1 と worker-1 の2台）で行った。

## LoadBalancer IP をノードと同じ VLAN に置けない

### L2 Announcement では届く

まず現状を測った。
`default` に nginx と `Service` を立て、プールから `192.168.20.201` を払い出させる。
VLAN 20 の外にいる作業端末（`192.168.1.118`）から `HTTP 200` が返る。

到達を成立させているのが何かは、worker-1 の `eno4np0` でパケットを取ると分かる。

```
21:56:43.362771 ARP, Announcement 192.168.20.201 (ff:ff:ff:ff:ff:ff)
21:56:43.807999 ARP, Request who-has 192.168.20.201 tell 192.168.20.1
21:56:43.808009 ARP, Reply   192.168.20.201 is-at 38:05:25:3b:cc:d3
21:56:49.678647 IP 192.168.1.118.54746 > 192.168.20.201.80: Flags [SEW]
21:56:49.691825 IP 192.168.20.201.80 > 192.168.1.118.54746: HTTP/1.1 200 OK
```

1行目は L2 Announcement が IP 払い出し直後に打つ Gratuitous ARP である。
2行目で UCG-Fiber が「192.168.20.201 は誰か」と尋ね、3行目で worker-1 が自分の MAC を返している。
`38:05:25:3b:cc:d3` は design.md の NIC 表にある `eno4np0`（X710 SFP+ #1）のものである。
ARP が解決して初めて TCP が始まっている。

ARP 応答がなければ届かないことは、対照実験で確認した。
プール内でまだ Service に割り当てていない `192.168.20.250` を叩くと、UCG-Fiber の ARP 要求が6回繰り返されるだけで応答が返らず、接続は成立しない。

```
curl 192.168.20.250 -> 到達不可 (HTTP 000)
curl 192.168.20.200 -> HTTP 200

22:00:26.305402 ARP, Request who-has 192.168.20.250 tell 192.168.20.1
22:00:27.376590 ARP, Request who-has 192.168.20.250 tell 192.168.20.1
（以下同じものが6回、Reply は一度もない）
```

### BGP に移すと届かなくなる

上のキャプチャで注目すべきは `tell 192.168.20.1` である。
UCG-Fiber は `192.168.20.1/24` を持つため、`192.168.20.201` を自分と同じセグメントの相手だと判断し、ルーティングせずに直接 ARP を出した。
これは DS923+（`192.168.20.20`）をはじめ、VLAN 20 に置いたあらゆる機器がまったく同じように下す判断である。

BGP に移した後、クライアントの位置によって挙動が分かれる。

| クライアント | 経路の判断 | 結果 |
| --- | --- | --- |
| UCG-Fiber | BGP で学習した `/32` が longest prefix match で勝つ | 届く |
| VLAN 30 など他 VLAN | ゲートウェイである UCG-Fiber に送り、そこで BGP 経路が効く | 届く |
| VLAN 20 の機器 | `192.168.20.0/24` は on-link と判断し、直接 ARP を出す | **届かない** |

BGP 経路を持つのは UCG-Fiber だけである。
VLAN 20 の他の機器はルーターに問い合わせず、自分で ARP を出し、誰からも応答を得られない。

Cilium の BGP Control Plane は経路を広告するだけで、ARP には応答しない。
ARP に応答するのは L2 Announcement 固有の働きである。

> this feature will respond to ARP/NDP queries for ExternalIPs and/or LoadBalancer IPs
> This feature is primarily intended for on-premises deployments within networks without BGP based routing
> ([Cilium: L2 Announcements](https://docs.cilium.io/en/stable/network/l2-announcements/))

しかも両者は Service 単位で排他である。

> A service must have `loadBalancerClass` unspecified or set to `io.cilium/l2-announcer` to be selected by a policy for announcement.

つまり BGP で広告する Service を L2 Announcement が肩代わりすることはない。
実機でも裏を取った。
`loadBalancerClass: io.cilium/bgp-control-plane` を指定した Service を作ると、BGP が未設定のため LB IP がそもそも払い出されず、`EXTERNAL-IP` は `<pending>` のままだった。

### LB Pool 専用の VLAN を切る

対処は、LB IP プールを VLAN 20 の外の独立したサブネットに移すことである。
そうすれば VLAN 20 の機器も「自分のサブネット外」と判断してデフォルトゲートウェイに送るため、UCG-Fiber の BGP 経路で解決される。
通信が LAN 内で完結する点は変わらない。

**VLAN 120（`192.168.120.0/24`）を LB Pool 専用に切る。**

番号は、機器を収容する VLAN の番号に 100 を足したものとする。
LB Pool は VLAN 20 の Server 上で動くアプリケーションのアドレスだから 120 になる。
将来 Management（VLAN 10）で同じことをしたくなれば 110 を切ればよい。

この採り方には2つの効果がある。
第3オクテットが2桁ならハードウェアを収容する VLAN、3桁ならその上で動くアプリケーションの VLAN だと桁数で判別できる。
さらに下2桁を見れば、そのアプリケーションがどの VLAN のハードウェア上で動いているかまで分かる。
「第3オクテットと VLAN ID を一致させる」という既存のアドレス方針も、そのまま保たれる。

この VLAN は機器を収容しない。
UniFi にはネットワークとして定義してゲートウェイ IP だけを持たせ、DHCP は動かさない。
実体は Cilium が BGP で広告する `/32` の集合である。

同じ構成は [Stonegarden](https://blog.stonegarden.dev/articles/2025/11/bgp-cilium-unifi/) の UniFi + Cilium BGP の記事でも採られている。
ノードを `192.168.1.0/24` に置き、Cilium の IP-Pool は別 VLAN の `172.20.10.0/24` に分けている。

### 覆った前提

[design-rationale.md](design-rationale.md) の「Kubernetes ノードと DS923+ を VLAN 20 に統合する」は、LB Pool を同居させる根拠として L2 Announcement の制約を挙げていた。

> Cilium の L2 Announcement も、LoadBalancer IP Pool がノードと同一 L2 ドメインにあることを要求する。

L2 Announcement については正しい。
しかし BGP に移るなら制約は逆に働き、同一 L2 に置くことが障害になる。
ノードとストレージを統合する判断そのものは、L3 転送を避けるという別の根拠で維持される。
失われたのは LB Pool を同居させる根拠だけである。
design-rationale.md 側は改訂済みである。

## 同じ URL で LAN 内とインターネットの両方から届く

### 仕組み

成立する。
design.md が external-dns を2系統立てる構成にしているのは、split-horizon DNS（split-brain DNS とも呼ぶ）そのものである。

| 経路 | 名前解決 | 応答 | 通信経路 |
| --- | --- | --- | --- |
| LAN 内 | 内部 DNS | A レコード。Gateway の LB IP | クライアントから Gateway へ直接。LAN 内で完結する |
| インターネット | Cloudflare の権威 DNS | CNAME。`<UUID>.cfargotunnel.com` | Cloudflare Edge から Tunnel を通り cloudflared へ |

同じ FQDN が、どの DNS に尋ねるかによって別の宛先に解決される。
`HTTPRoute` の `hostname` は1つのままで、両方の経路を受けられる。

### 成立の条件

**LAN 内のクライアントが必ず内部 DNS を引くこと。**
ここが最も破れやすい。
ブラウザの DoH（Firefox や Chrome の Secure DNS）、iOS と Android の Private DNS、DNS サーバーをハードコードした機器は内部 DNS を迂回し、Cloudflare 経由の応答を受け取る。
UCG-Fiber で外向きの 53 番をリダイレクトし、既知の DoH エンドポイントを塞ぐ必要がある。
塞がないと、LAN 内アクセスをインターネットに出さないという前提が、気付かないうちに崩れる。

**内部アクセス用の TLS 証明書。**
LAN 内は Cloudflare を通らないため、Gateway 自身が有効な証明書を出す。
design.md の cert-manager と Let's Encrypt の DNS-01 チャレンジで満たせる。
DNS-01 は外部からの到達性を必要としないため、内部専用のホスト名でも証明書が取れる。

**Cloudflare Access と WAF は LAN 内から効かない。**
内部アクセスは Cloudflare を経由しないため、認証もレート制限も適用されない。
受け入れるか、内部にも別の認証を置くかを決めておく。

**external-dns 2系統の所有権を分ける。**
Cloudflare 用と内部 DNS 用に、別々の `txtOwnerId` を与える。

> Deployments in different clusters but sharing a DNS zone need to use different owner IDs.
> ([external-dns: Registries](https://kubernetes-sigs.github.io/external-dns/latest/docs/registry/registry/))

同じ owner ID のままだと、互いのレコードを自分の管理外と見なして削除し合う。

**内部 DNS の可用性。**
Pi-hole をクラスター上に置くと、クラスターが落ちたときに LAN の名前解決ごと落ちる。
plan.md の未決定事項「DNS の常用系と待機系の役割分担」がこれに当たる。
これをどう受けるかは次節で決める。

### 内部 DNS は Pi-hole に置き、Backup DNS で受ける

代替として、内部 DNS を UniFi Network の Local DNS Records に寄せる案を検討した。
external-dns の webhook provider（[external-dns-unifi-webhook](https://github.com/home-operations/external-dns-unifi-webhook)）から書き込める。
UCG-Fiber はクラスターと無関係に動き続けるため、循環依存そのものが生まれない。
[Ivan Tomica の記事](https://www.tomica.net/blog/2026/07/external-dns-with-unifi-and-cilium-bgp/)が、Cilium BGP と組み合わせたこの構成を実装している。

これは採らない。
Backup DNS が Pi-hole の設定を同期して保持するため、クラスターが落ちても名前解決は続くからである。
primary が応答しなくなればクライアントは secondary に問い合わせ、同期済みのレコードはそこで解決される。
広告ブロックも Pi-hole に残せる。

ただし、この構成が成立するには2つの前提が要る。

**external-dns が書いた Custom DNS のレコードを、同期の対象に含める。**
含めなければ Backup DNS はクラスター上のサービス名を1つも解決できず、待機系として機能しない。
plan.md の「Pi-hole の冗長化」には、この判断を意図を持って決めると書いてある。
ここで対象に含めることが確定した。

**クライアントに primary と secondary の両方を配る。**
DHCP で2つ配らなければ、primary が落ちた時点で名前解決ごと止まる。

primary が落ちているあいだ、Backup DNS の内容は最後に同期した時点で固定される。
新しいレコードは増えないが、クラスターが落ちているあいだは新しいサービスも現れないため、実害はない。

## 付随して分かったこと

**LoadBalancer IP は ping に応答しない。**
`192.168.20.200` への ICMP は 100% loss になる一方、同じ IP への HTTP は 200 を返す。
Cilium が LB IP に対する ICMP を実装していないためで、[cilium#14118](https://github.com/cilium/cilium/issues/14118) が open のままである。
疎通確認は必ず TCP で行う。
ping が通らないことを障害と読み違えると、切り分けを誤る。

**リハーサル環境の Cilium は VXLAN で動いている。**
`cilium-config` は `routing-mode=tunnel`、`tunnel-protocol=vxlan` である。
plan.md の R2 の結果表に「`KubeProxyReplacement` が `True`（Direct Routing）」とあるが、この "Direct Routing" は `cilium status` が kube-proxy 置換のバックエンド到達方式として表示するものであり、Pod ネットワークのルーティングモードではない。

**VLAN 設計はまだ実装の途中である。**
調査時点で作業端末は `192.168.1.118`、ゲートウェイと DNS はいずれも `192.168.1.1` だった。
design.md の「VLAN 1 には機器を収容しない」は未適用で、VLAN 20 だけが先に切られている。
VLAN 20 で応答したのは `.1`（UCG-Fiber）、`.20`（DS923+）、`.31`（cp-1）、`.41`（worker-1）、`.100`（VIP）の5つである。

## R4 に持ち越す確認事項

**UniFi の Zone-Based Firewall が、BGP で学習した経路の宛先をどう分類するか。**
VLAN 120 を UniFi 上のネットワークとして定義すれば、そのゾーンに対するポリシーを書ける見込みだが、実機で確かめていない。
BGP で受け取った `/32` が定義済みネットワークのゾーンに属するのか、それとも別扱いになるのかによって、VLAN 間ポリシーの書き方が変わる。
文献では確認できなかったため、BGP を疎通させた直後に測る。

**VLAN 20 の機器から VLAN 120 の LB IP へ実際に届くか。**
今回は VLAN 20 に検証用のホストを置けなかった。
DS923+ は SSH が閉じており、UCG-Fiber は BGP を喋る側であるため、一般の機器の代理にならない。
BGP を入れた後、VLAN 20 のいずれかの機器から実測して確かめる。
