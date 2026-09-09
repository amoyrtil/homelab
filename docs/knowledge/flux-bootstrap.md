# Flux Operator と SOPS

リハーサルの R6 の記録である。
Flux Operator を入れ、Longhorn を GitOps の管理下へ移し、SOPS で暗号化した Secret を Flux に復号させるところまでを通した。

実施は 2026年9月9日、flux-operator 0.59.0 と Flux v2.9.5 の構成である。

## 鍵はクラスターに手で入れる

GitOps は Git を正とするが、その Git を読む鍵と、Git の中身を復号する鍵だけは Git に置けない。
循環するためである。
**secret zero** と呼ばれる問題で、Flux 公式のガイドも `kubectl create secret` で入れる手順を示している。

この構成で手で入れるのは1つだけである。

```bash
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
```

キー名は `age.agekey` でなければならない。
kustomize-controller はこの名前で秘密鍵を探す。

Git の認証情報が要らないのは、リポジトリが public だからである。
private にするとき、またはオーガナイゼーションへ移すときは、Secret を作って `FluxInstance` から指す。

```yaml
spec:
  sync:
    url: ssh://git@github.com/<owner>/homelab.git
    pullSecret: flux-git-auth
```

Secret は `flux create secret git --url=ssh://git@github.com/<owner>/homelab --name=flux-git-auth` で作り、出力される公開鍵を GitHub の Deploy keys に read-only で登録する。
このとき手で入れる鍵は2つになる。

## GitRepository の名前は FluxInstance の名前と一致しない

flux-operator は、**FluxInstance の名前によらず `flux-system` という名前で** GitRepository と入口の Kustomization を作る。

`FluxInstance` を `flux` という名前にしたため、`sourceRef.name: flux` と書いた Kustomization が解決できなかった。

```
NAME   READY   STATUS
apps   False   GitRepository.source.toolkit.fluxcd.io "flux" not found
```

エラーは正確に出るため気付ける。
`sourceRef` は `flux-system` を指す。

## Kubernetes の Secret は data と stringData だけ暗号化する

`.sops.yaml` の作成ルールに `encrypted_regex` を書かないと、ファイル全体が暗号化される。
`apiVersion` と `kind` と `metadata` まで隠れるため、kustomize がリソースとして読めない。

```yaml
creation_rules:
  - path_regex: kubernetes/.*\.sops\.ya?ml$
    encrypted_regex: ^(data|stringData)$
    age: age1...
  - path_regex: .*\.sops\.ya?ml$
    age: age1...
```

ルールは上から順に照合され、最初に一致したものが使われる。
`kubernetes/` 以下を先に置く。

Kubernetes のリソースでないもの（`talos/talsecret.sops.yaml` など）は、全体を暗号化してよい。
むしろそちらのほうが漏れがない。

暗号化後もこう読める。

```yaml
apiVersion: v1
kind: Secret
metadata:
    name: sops-test
stringData:
    message: ENC[AES256_GCM,data:...]
```

差分がレビューできる利点もある。
どのキーが増えたかは見え、値だけが隠れる。

## helm から Flux へ移すときの落とし穴

### Longhorn は削除に確認フラグを要求する

`helm uninstall` は uninstall ジョブを走らせるが、既定では失敗する。

```
level=fatal msg="cannot uninstall Longhorn because deleting-confirmation-flag is set to `false`."
```

誤削除を防ぐための保護である。
先にフラグを立てる。

```bash
kubectl -n longhorn-system patch settings.longhorn.io deleting-confirmation-flag \
  --type=merge -p '{"value":"true"}'
```

失敗したジョブは残るため、再実行の前に消す。

```bash
kubectl -n longhorn-system delete job longhorn-uninstall
```

ボリュームが存在する状態でこれを行うとデータが消える。
移行の前に `kubectl -n longhorn-system get volumes.longhorn.io` で0本であることを確かめる。

### StorageClass が残る

`helm uninstall` の後も `longhorn-static` が残った。
Flux が入れ直すときに同名で作り直そうとするため、先に消しておく。

## defaultReplicaCount はデータエンジンごとに持つ

Longhorn 1.12 の `default-replica-count` は、v1 と v2 のデータエンジンごとの値になっている。

```
$ kubectl -n longhorn-system get settings.longhorn.io default-replica-count -o jsonpath='{.value}'
{"v1":"1","v2":"1"}
```

Helm の `defaultSettings.defaultReplicaCount: 1` を渡すと両方に反映される。
値を確かめるとき、単なる `1` を期待すると読み違える。

## ディレクトリの構成

`onedr0p/cluster-template` から借りた規約に従う（[cluster-template-evaluation.md](cluster-template-evaluation.md)）。

```
bootstrap/
  flux-instance.yaml            FluxInstance。Flux 自身は Flux で管理できない
kubernetes/
  flux/cluster/
    kustomization.yaml
    apps.yaml                   kubernetes/apps を読む Kustomization
  apps/
    kustomization.yaml          各アプリの ks.yaml を列挙する
    <namespace>/<app>/
      ks.yaml                   Flux Kustomization
      app/                      実体（HelmRelease、Namespace など）
```

SOPS の復号設定は、共有の kustomize component を挟まず各 `ks.yaml` に直接書いた。
対象が少ないうちは、間接参照を1段増やすより読みやすい。
アプリが増えて重複が目立ってきたら component に切り出す。

## 実測値

| 確認項目 | 結果 |
| --- | --- |
| flux-operator | `flux-operator` が Running |
| コントローラー | source、kustomize、helm、notification の4つが Running |
| `FluxInstance` | `READY: True`、`v2.9.5` |
| `GitRepository` | `True`。認証なしで public リポジトリを取得 |
| Kustomization | `flux-system`、`apps`、`longhorn` がすべて `True` |
| Longhorn の再導入 | Flux 経由で 19 Pod が worker-1 に。cp-1 は0件 |
| HelmRelease の values | `defaultReplicaCount` と `defaultDataPath` が反映 |
| PVC | `Bound`、書き込みと読み出しが成功 |
| SOPS の復号 | Git 上の暗号化 Secret がクラスターで平文になる |
| prune | Git から消すとクラスターからも消える |

## R7 に持ち越すもの

**Webhook Receiver。**
GitHub の push を Flux が直接受ける構成にするには、受け口を外に出す必要がある。
Cloudflare Tunnel を入れる R7 で行う。
それまでは `GitRepository` のポーリング（既定 1分）で反映される。

**`FluxInstance` の同期先。**
検証のあいだは作業ブランチを指し、マージ後に `refs/heads/main` へ戻した。
リポジトリをオーガナイゼーションへ移す場合は、この URL も変える。
