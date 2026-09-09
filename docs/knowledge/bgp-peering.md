# Cilium BGP と UCG-Fiber の対向

リハーサルの R4 の記録である。
Cilium が払い出す LoadBalancer IP を UCG-Fiber へ BGP で広告し、L2 Announcement を外すまでを通した。
[service-exposure.md](service-exposure.md) が R4 に持ち越した2件の確認事項も、ここで決着した。

実施は 2026年9月9日、Cilium v1.20.1 と Talos v1.14.0 のコントロールプレーン1台ワーカー1台の構成である。

## Cilium 側に置く3つのリソース

`bgpControlPlane.enabled: true` で BGP の CRD が5種入る。
いずれも `cilium.io/v2` にあり、`v2alpha1` ではない。
LB IPAM と同様、BGPv2 の API は正式版に昇格している。

使うのは3つである。

- **`CiliumBGPClusterConfig`**：どのノードがどの相手と、どの ASN で張るか
- **`CiliumBGPPeerConfig`**：アドレスファミリと、どの広告を載せるか
- **`CiliumBGPAdvertisement`**：何を広告するか

残る `CiliumBGPNodeConfig` は operator が生成する。
`CiliumBGPClusterConfig` の `nodeSelector` にコントロールプレーンを除く条件を書いたところ、`worker-1` のぶんだけが作られた。

```
$ kubectl get ciliumbgpnodeconfig
NAME       AGE
worker-1   5s
```

`allowSchedulingOnControlPlanes` が `false` である以上、コントロールプレーンから広告しても next-hop の先にバックエンドがない。
ノードを増やしたときも、この `nodeSelector` がそのまま効く。

### 広告の selector を省くと何も出ない

`CiliumBGPAdvertisement` の `selector` は、CRD のスキーマ上は必須ではない。
省いても `kubectl apply` は通る。
しかし省くと広告は0件になる。

実際に外して確かめた。

```
$ kubectl patch ciliumbgpadvertisement default --type=json \
    -p='[{"op":"remove","path":"/spec/advertisements/0/selector"}]'
$ cilium bgp routes advertised ipv4 unicast
Node   VRouter   Peer   Prefix   NextHop   Age   Attrs
（空）
$ curl --max-time 5 http://192.168.120.100/
（タイムアウト）
```

省略が「全件」ではなく「0件」に倒れる。
全 Service を対象にしたいときは、存在しないラベルへの `NotIn` で全件にマッチさせる。

```yaml
selector:
  matchExpressions:
    - key: bgp.homelab/never-set
      operator: NotIn
      values:
        - never-used-value
```

Service を作っても LB IP に届かず、ピアは `established` のまま広告だけが0本、という状態になったらここを疑う。

## bgp listen range は UniFi に通る

[plan.md](../plan.md) は、`bgp listen range` を UniFi が受け付けるかを未確認としていた。
参考にした記事はいずれもノード IP を明示列挙しており、実例が見つからなかったためである。

通った。
明示列挙へのフォールバックは要らない。
ノードを増やしても UCG-Fiber 側の設定は変えずに済む。

投入した設定は `bootstrap/ucg-fiber-bgp.conf` にある。
UniFi 側では設定に名前を付ける必要があり、`Blackwall-BGP` とした。
リハーサル完了後にクラスターを `Blackwall` へ改名する予定に合わせている。

```
$ cilium bgp peers
Node       Local AS   Peer AS   Peer Address   Session State   Uptime    Family
worker-1   65001      65000     192.168.20.1   established     1h57m2s   ipv4/unicast
```

`no bgp ebgp-requires-policy` は最初から入れたため、これを落としたときの症状は観測していない。
RFC 8212 に従って FRR が eBGP に route-map を要求する挙動は変わっていないはずだが、実測はしていない。

ルーターからクラスターへの経路注入はない。
ローカル RIB に入るのは自分が広告した `/32` だけで、UCG-Fiber 側に `network` 文も再配布も書いていないためである。

## Zone-Based Firewall は宛先ネットワークで分類する

R4 に持ち越した確認事項の本題である。

広告された経路の next-hop はワーカーの `192.168.20.41`、つまり VLAN 20 にある。
宛先アドレス `192.168.120.100` は VLAN 120 のレンジにある。
UCG-Fiber がこのパケットを実際に出すインターフェースは VLAN 20 であり、VLAN 120 のインターフェースは通らない。

ここで ZBF が何を見てゾーンを決めるかによって、書けるポリシーが変わる。

| 判定の基準 | この `/32` の宛先ゾーン |
| --- | --- |
| 出力インターフェース | VLAN 20（Server） |
| 宛先ネットワーク | VLAN 120（Service） |

前者だった場合、VLAN 120 をネットワークとして定義してもポリシーは効かない。
LB IP へのアクセス制御は Server ゾーンの規則に従うことになり、[design.md](../design.md) のゾーン間ポリシー表が前提から崩れる。

### VLAN 20 からの疎通では分類が分からない

最初に測ったのは、VLAN 20 に置いた検証端末（`192.168.20.32`）から `192.168.120.100` への疎通である。
届いた。

しかしこれは分類を教えてくれない。
送信元が Server ゾーンにいるため、宛先が Server と分類されるなら同一ゾーン内通信として無条件に通り、Service と分類されるならポリシー表の「Server から Service へは許可」で通る。
どちらでも同じ結果になる。

### VLAN 1 を送信元にすると分かれる

送信元を VLAN 1 の作業端末（`192.168.1.118`）に移し、UniFi 側で内部 VLAN 全般から Service ゾーンへのアクセスを一括で拒否するルールを1本入れて測った。

```
$ curl --max-time 6 http://192.168.120.100/
（3回とも exit 28、タイムアウト）
```

同時に、BGP セッションは `established` のまま uptime 1時間52分、広告も1本出たままである。
経路は生きており、落としているのはファイアウォールである。
TCP RST ではなくタイムアウトになるのは、drop されているためである。

ルールを削除すると、同じ端末から5回連続で `HTTP 200` に戻った。

**宛先ネットワークで分類している。**
BGP で学習した `/32` は、そのアドレスが属する定義済みネットワークのゾーンに入る。
出力インターフェースでは判定していない。

design.md のゾーン間ポリシー表は、この前提のまま成立する。
Untrusted と Guest からクラスター上のサービスに到達させない、という設計もそのまま書ける。

なお、このブロック中も `192.168.120.1` への ping は通っていた。
矛盾ではない。
UniFi はルーター自身のインターフェース IP を Gateway ゾーンとして扱うため、Service ゾーンのポリシーの対象外である。

LB IP への ICMP は、ブロックの有無にかかわらず応答しない（[service-exposure.md](service-exposure.md) の「LoadBalancer IP は ping に応答しない」）。
この実験で ICMP は判定に使えない。

## L2 Announcement から BGP へ移す順序

プールを VLAN 120 に変えた時点で、L2 Announcement は役に立たなくなる。
ワーカーの VLAN 20 側 NIC で VLAN 120 の IP に ARP 応答しても、UCG-Fiber はその IP を自分の VLAN 120 インターフェース側にあると考えるため、届かない。

つまりプールの切り替えは、BGP が経路を運べるようになってから行う。

1. BGP のピア確立を確認する
2. `CiliumLoadBalancerIPPool` を `192.168.120.100-250` に変える
3. Service を作り、新プールの IP への到達を確認する
4. `CiliumL2AnnouncementPolicy` を削除し、Helm values の `l2announcements` を外す

`default` namespace が空のうちに済ませれば、切り替えでダウンタイムは出ない。

`l2announcements` を外しても `CiliumL2AnnouncementPolicy` の CRD は残る。
Cilium が CRD の登録自体は常に行うためである。
無効になったかは ConfigMap で見る。

```bash
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-l2-announcements}'
```

あわせて `k8sClientRateLimit`（qps 50、burst 100）も外した。
L2 Announcement の leader election が既定のレート制限で失敗しやすいために入れた値であり、根拠がなくなったためである。
BGP の status report にも API 書き込みはあるが、2ノードでは既定値で足りている。
operator のログにスロットリングは出ていない。

## エージェントの再起動でセッションが張り直される

`helm upgrade` に伴うロールアウトのたびに、`cilium bgp peers` の uptime が 0 に戻った。
Graceful Restart を設定していないためである。

リハーサル環境では即座に復帰し、実害は出ていない。
本番では `CiliumBGPPeerConfig` に `gracefulRestart` を入れるかを検討する余地がある。
UCG-Fiber 側の FRR が対応している必要があり、そこは未確認である。

## 実測値

| 確認項目 | 結果 |
| --- | --- |
| BGP CRD の API バージョン | `cilium.io/v2`（5種） |
| `CiliumBGPNodeConfig` の生成 | `worker-1` のみ。コントロールプレーンには作られない |
| ピア確立 | `established`。`bgp listen range` で成立 |
| 広告される経路 | `192.168.120.100/32`、next-hop `192.168.20.41`、AsPath 65001 |
| LB Pool | `192.168.120.100-250`、151 IP |
| VLAN 1 から LB IP へ | 5回連続 `HTTP 200` |
| VLAN 20 から LB IP へ | 到達（`192.168.20.32` から） |
| ZBF の分類 | 宛先ネットワーク。Service ゾーンのポリシーが効く |
| Service 削除時 | 広告が0本に戻る |
| Cilium の健全性 | `Modules Health: OK(91)`、`Controller Status: 17/17 healthy` |
