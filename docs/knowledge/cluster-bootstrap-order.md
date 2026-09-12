# クラスターを立てる順序

リハーサル R1 から R6 で通した手順を、実行できる順に並べたものである。
個々の落とし穴は各ファイルに書いてあり、ここには順序と、その順序でなければならない理由だけを置く。

対象は Talos v1.14.0、Kubernetes v1.37.0、Cilium v1.20.1、Longhorn 1.12.1、flux-operator 0.59.0 である。

## 全体の形

**bootstrap が Cilium と flux-operator を入れ、残りは Flux が入れる。**

Flux が動くには CNI が要り、Flux 自身は Flux で管理できない。
この2つだけを外から入れ、そこから先は Git を正とする。

手でクラスターに入れるものは8つある。
Gateway API の CRD、Cilium の Helm リリース、LB プール、BGP の3リソース、`flux-system` namespace、flux-operator の Helm リリース、`sops-age` Secret、`FluxInstance` である。
どれもクラスターを作り直すたびに再実行する。

このうち **LB プールと BGP は Flux に移せる**。
Cilium が動いたあとの通常の CR であり、Flux が Git を pull するのに LoadBalancer IP は要らない。
移せないのは、CNI が無いと動かないもの（Gateway API の CRD、Cilium）と、Flux 自身（flux-operator、`FluxInstance`）と、secret zero（`sops-age`）である。

## 1. machine config を生成する

```bash
cd talos && talhelper genconfig
```

`talos/clusterconfig/` は gitignore 対象で、消えていればここで再生成する。
age の秘密鍵は `~/.config/sops/age/keys.txt` にある。

`talconfig.yaml` で押さえるところは3つある。

- `cniConfig: name: none` と `KubeProxyConfig` の `enabled: false`。**どちらもクラスター構築時にしか効かない**ため、後から変えるとノードの作り直しになる
- worker の kubelet に `/var/lib/longhorn` の `extraMounts`。Longhorn の前提である
- `additionalApiServerCertSans` に、後から足すコントロールプレーンのアドレスも含める

詳細は [talos-operations.md](talos-operations.md) と [longhorn-on-talos.md](longhorn-on-talos.md) にある。

## 2. ノードにインストールして bootstrap する

この段階では両ノードが `NotReady` になる。
理由は `cni plugin not initialized` であり、CNI を入れていないのだから正常である。
CoreDNS も `Pending` のまま止まる。

## 3. Gateway API の CRD を入れる

**Cilium より先に入れる。**
`gatewayAPI.enabled: true` の Cilium operator は、起動時に CRD の存在を検査する。
足りないと `GatewayClass` が `Waiting for controller` のまま止まり、原因は operator のログにしか出ない。

```bash
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/experimental-install.yaml
```

**experimental チャネルを使う。**
standard には `tlsroutes` がなく、使う予定がなくても Cilium は7種すべてを要求する。

`--server-side` が要るのは、`httproutes` の CRD の annotation が `kubectl apply` の上限（262144 バイト）を超えるためである。

## 4. Cilium を入れる

```bash
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --version 1.20.1 -n kube-system \
  -f bootstrap/cilium-values.yaml --wait
```

ここで両ノードが `Ready` になる。

values で押さえるところは [design.md の「Talos と Cilium の必須設定」](../design.md#talos-と-cilium-の必須設定)にある。
**`bpf.autoMount.enabled` を `false` にしない**ことと、`rollOut` 系を3つとも有効にすることが要点である。

## 5. Cilium のネットワークリソースを入れる

```bash
kubectl apply -f bootstrap/cilium-networks.yaml   # LoadBalancer IP Pool
kubectl apply -f bootstrap/cilium-bgp.yaml        # BGP の3リソース
```

ルーター側の FRR 設定（`terraform/unifi/ucg-fiber-bgp.conf`）は UCG-Fiber に投入済みで、クラスターを作り直しても残る。
投入は Terraform が行う。
`bgp listen range` でノードを待ち受けるため、ノードの IP が変わっても追従する。

`cilium bgp peers` が `established` になれば通っている。
詳細は [bgp-peering.md](bgp-peering.md) にある。

## 6. flux-operator を入れる

```bash
kubectl create namespace flux-system
kubectl label namespace flux-system homelab/expose=true
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --version 0.59.0 -n flux-system --wait
```

values は既定のままでよい。

**`homelab/expose=true` のラベルが要る。**
external Gateway の `allowedRoutes` が `Selector` になっており、このラベルを持つ namespace からの `HTTPRoute` しか受け付けない。
付けないと Webhook Receiver の `HTTPRoute` が external に繋がらず、GitHub の push が届かなくなる。
症状は「壊れない」ことである。Flux は `FluxInstance` の間隔（1時間）で同期し続けるため、反映が遅いことにしか気付けない。

ラベルを namespace に手で付けるのは、`flux-system` が flux-operator の管理下にあるためである。
Flux のマニフェストから同じ namespace を宣言すると、`prune` でこの namespace を消しに行く経路ができる。

## 7. age の秘密鍵をクラスターに入れる

```bash
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
```

キー名は `age.agekey` でなければならない。
kustomize-controller はこの名前で秘密鍵を探す。

**`FluxInstance` より先に入れる。**
後でも復旧はするが、その間 Kustomization が復号に失敗し続ける。

## 8. FluxInstance を適用する

```bash
kubectl apply -f bootstrap/flux-instance.yaml
```

ここから先は Flux が `kubernetes/` を反映する。

```bash
kubectl -n flux-system get kustomization
```

`flux-system`、`apps`、および各アプリの Kustomization がすべて `True` になれば完了である。
詳細は [flux-bootstrap.md](flux-bootstrap.md) にある。

## 順序を入れ替えられないところ

| 前 | 後 | 理由 |
| --- | --- | --- |
| `cniConfig: none` と kube-proxy 無効 | クラスター構築 | 構築時にしか効かない。後から変えるとノードの作り直しになる |
| Gateway API の CRD | Cilium | operator が起動時に CRD の存在を検査する |
| Cilium | flux-operator | Pod ネットワークがなければコントローラーが動かない |
| `sops-age` | `FluxInstance` | 先に入れないと復号に失敗し続ける |

**ZBF を先に入れておくなら、BGP の確認を組み直しの直後に行う。**
[design.md](../design.md#ポリシー) は「Gateway ゾーンは既定で許可される」ことを前提に、Server から `192.168.20.1:179` へのポリシーを書いていない。
これは組み込みゾーンの既定の挙動であり、**VLAN 20 をカスタムゾーンへ移したあとでは確かめていない**。
R4 で BGP が張れたのは全 VLAN が Internal にいた時点の実測であり、この前提の裏付けにはならない。
`cilium bgp peers` が `established` にならなければ、Server → Gateway の 179 を明示的に許可する。

Longhorn は Flux が入れるため、bootstrap の手順には現れない。
ただしワーカーの schematic に `iscsi-tools` と `util-linux-tools` が要り、kubelet の `extraMounts` も要る。
どちらも手順1で決まる。

## リハーサル環境と本番の違い

リハーサル環境では、クラスター名を `homelab`、ノードを `cp-1`（S100-WLP）と `worker-1`（MS-03）としている。
本番では EliteDesk 800 G6 をコントロールプレーンにし、クラスター名を `Blackwall` に改める予定である。
命名規約は [plan.md](../plan.md) の手順4で整理する。

UCG-Fiber 側の設定（VLAN 120、BGP）はクラスターと独立しており、作り直しても残る。
