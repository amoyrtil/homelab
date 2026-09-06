# onedr0p/cluster-template の評価

リポジトリ構成の出発点として `onedr0p/cluster-template` を採用するかを評価した記録である。
2026年9月6日に実施した。

結論は **ジェネレーターとしては採用せず、ディレクトリ規約と一部の設計を借りる**である。

## テンプレートの正体

使えるリポジトリ構成ではなく、makejinja によるコードジェネレーターである。

`cluster.toml` を1つ書いて `just configure` を実行すると、`kubernetes/`、`talos/`、`bootstrap/` が生成される。
169ファイルのうち大半は `.j2` テンプレートで、生成後には残らない。

一度生成したら、その出力は自分のものになる。
テンプレート側の更新を取り込む経路は用意されていないため、価値は初回生成に集中している。

生成されるものは次のとおりである。

```
talos/            00-install, 01-hostname, 10-cluster, 20-network-links,
                  21-network, 22-time, 30-kubelet, 40-sysctls, 50-files,
                  60-encryption, 61-kernel-modules, 70-security, 71-filesystem
kubernetes/apps/  kube-system:  cilium, coredns, metrics-server, reloader, spegel
                  network:      envoy-gateway, k8s-gateway, cloudflare-dns, cloudflare-tunnel
                  cert-manager: cert-manager
                  flux-system:  flux-operator, flux-instance
                  default:      echo
kubernetes/components/sops/
bootstrap/helmfile/
```

## 計画との照合

| 項目 | テンプレート | この計画 | 判定 |
| --- | --- | --- | --- |
| CNI | Cilium | Cilium | 一致 |
| BGP | `[cilium.bgp]` で router_addr / router_asn / node_asn を指定 | Cilium BGP | 一致。第一級の選択肢として用意されている |
| GitOps | Flux Operator と FluxInstance | Flux v2 | 実質一致 |
| シークレット | SOPS と age | SOPS と age | 一致 |
| ツール管理 | mise | mise | 一致。`talosctl 1.14.0` と `kubectl 1.37.0` までそろう |
| ノード定義 | `mac_addr` と `schematic_id` をノードごとに持てる | MAC で deviceSelector、機種ごとに schematic | 一致 |
| Talos config 管理 | 自前のパッチを `topf` でマージ | talhelper | 不一致 |
| API VIP | kube-vip | Talos 内蔵の `Layer2VIPConfig` | 不一致 |
| ストレージ | なし | Longhorn | 不一致 |
| Ingress | Envoy Gateway | Cilium Gateway API | 不一致 |

## ジェネレーターとして採用しない理由

**talhelper を捨てることになる。**
talhelper で machine config を生成する構成が既に動いており、v1.14 の新しいドキュメント形式に対応していることも確認済みである。
テンプレートは `topf` でパッチをマージする別方式であり、乗り換える利益がない。

**kube-vip が入ってくる。**
Talos は VIP を OS 側で持てるため、Pod を1つ増やす理由がない。

**要らないものが付いてくる。**
spegel、reloader、echo、envoy-gateway は、この規模では不要か、既に入るコンポーネントで代替できる。
生成後に削る作業が発生する。

## 借りるもの

**ディレクトリ規約**が最大の収穫である。
`kubernetes/apps/<namespace>/<app>/{ks.yaml, app/}` という構造は Flux コミュニティで広く使われており、自分で考えるより従うほうが得である。

**Flux Operator と FluxInstance の方式**は、`flux bootstrap` で Flux 自身をクラスターに焼き込む旧来のやり方より扱いやすい。
Flux の更新も HelmRelease として管理できる。

**bootstrap を helmfile で行う流れ**は、Flux が動く前に必要な Cilium などを helmfile で入れ、その後 Flux に引き継ぐ順序である。
鶏と卵の問題を素直に解いている。

**mise のバージョン固定**は、そのまま持ってこられる。

## 派生して決まったこと

評価の過程で、テンプレートが採用しているものを見直して次を決めた。

**Ingress は Cilium の Gateway API 実装を使う。**
Gateway API は Ingress の後継として SIG-Network が設計したものであり、Cilium は Core conformance テストを全通過している。
前提条件は `kubeProxyReplacement=true` と `l7Proxy=true` で、どちらも元から満たす予定だった。
専用の Ingress コントローラーを1つも足さずに済むため、Envoy Gateway も Traefik も採らない。

**CI/CD は Flux の Webhook Receiver で行う。**
Flux は pull 型であり、GitHub Actions がクラスターに触る必要がない。
トンネルを通すのは webhook の受け口だけで、HMAC で署名検証する。
Kubernetes API を外部に開いて `kubectl apply` する構成は、pull 型を採用する利点である「CI に kubeconfig を渡さない」を自分で捨てることになるため採らない。

**内部の名前解決は external-dns の Pi-hole プロバイダーで行う。**
k8s-gateway という DNS サーバーを別途立てる案もあるが、Pi-hole が既にクラスター内にいるのにその隣にもう1つ DNS を置くのは冗長である。
external-dns は Cloudflare 向けに入れる予定であり、Pi-hole 向けはそのインスタンスを1つ増やすだけで済む。

## 記録しておく指摘

テンプレートの README のハードウェア章に、次の記述がある。

> Any **replicated storage** (e.g., Rook-Ceph, Longhorn) should always use **dedicated disks separate from control plane and etcd nodes**

コントロールプレーンと分けることは既に決めているが、MS-03 は 256GB の NVMe 1本を OS と Longhorn で共有する。
ワーカーに etcd は載らないため指摘の主眼からは外れるが、OS の書き込みと Longhorn のレプリカ書き込みが同じディスクに乗る点は留意する。
MS-03 は U.2 と PCIe x8 を持っているため、将来ディスクを足す余地はある。
