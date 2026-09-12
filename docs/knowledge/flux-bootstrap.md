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

## 復号できる鍵は2本ある

R9 の監査（2026年9月11日）まで、recipient は `age1k03m…` の1本だけだった。
`.sops.yaml` にも、暗号化済みの7ファイルにも、同じ鍵しか書かれていなかった。

**1本だと、失った時点で `talsecret.sops.yaml` が開けなくなる。**
Terraform の state はパスフレーズを失っても import で回収し直せるが、
クラスターの CA 秘密鍵、etcd の CA、service account の鍵は復旧できない。
クラスターの作り直しになる。

バックアップ用の鍵を作り、2本目の recipient として全ファイルに足した。

```bash
umask 077
age-keygen -o ~/.config/sops/age/backup.agekey
age-keygen -y ~/.config/sops/age/backup.agekey   # 公開鍵だけを取り出す
```

`.sops.yaml` の `age` はカンマ区切りで複数を取る。

```yaml
    age: >-
      age1k03mxpgxqe2kn2m4njawxjjd9mt70t90q6qzvrwn4eeqxpk6ad5sy9pm0j,
      age13n75cytyd93xp44meu7arr3rn0n9m2pwps9h4vmd9jzx9cxhhuuqvkyzg4
```

**`.sops.yaml` を書き換えただけでは既存のファイルに効かない。**
作成ルールは新しく暗号化するときにしか読まれない。
既存のファイルは `updatekeys` で反映する。

```bash
for f in $(git ls-files | grep -E '\.sops\.(ya?ml|env)$'); do
  sops updatekeys -y "$f"
done
```

反映を確かめる。

```bash
# 主鍵で開く
sops -d terraform/secrets.sops.env | cut -d= -f1

# バックアップ鍵だけで開く
SOPS_AGE_KEY_FILE=~/.config/sops/age/backup.agekey \
  sops -d terraform/secrets.sops.env | cut -d= -f1
```

`cut` や `grep` に通してキー名だけを見る。
値を画面に出す必要はない。

**クラスターの `sops-age` は触らなくてよい。**
主鍵が recipient に残っている限り、kustomize-controller はそのまま復号できる。
主鍵を外すときだけ Secret の入れ替えが要る。

**バックアップ鍵はオフラインに置く。**
作業マシンの `~/.config/sops/age/` に主鍵と並べておくと、2本ある意味が無い。
マシンごと失えば両方失う。

家庭のオーガナイゼーションへ移したあとは、この2本目を別の人の鍵にする道もある。
同じ手順で recipient を足すだけであり、いま作ったバックアップ鍵と併存できる。

## 公開したものは private 化しても取り消せない

リポジトリはここまで public であり、暗号化済みの7ファイルは誰でも取得できた。

| ファイル | 中身 |
| --- | --- |
| `talos/talsecret.sops.yaml` | cluster CA、etcd CA、k8s aggregator CA、service account の鍵 |
| `kubernetes/apps/network/cloudflared/app/credentials.sops.yaml` | Tunnel の secret |
| `terraform/secrets.sops.env` | Cloudflare と UniFi の API トークン、R2 の資格情報、state のパスフレーズ |
| ほか3つ | cert-manager と external-dns の Cloudflare トークン、webhook の HMAC トークン |

暗号は破れていない。
それでも **private 化は、これから公開されるものにしか効かない**。
git 履歴に入った暗号文は、すでに誰かの手元にある前提で扱う。

**作り直すのが唯一の消し方である。**
フェーズ1でクラスターをどのみち組み直すため、そのとき talsecret を新しく生成する。
API トークンも同じ回で Roll する。追加のコストがほとんど無い。

作り直す対象と手段を並べる。

| 対象 | 手段 |
| --- | --- |
| `talsecret.sops.yaml` | `talhelper gensecret` で作り直す。クラスターの再構築が前提 |
| Cloudflare の API トークン3種 | ダッシュボードで Roll する。値だけが変わり、権限は継がれる |
| UniFi の API キー | Terraform 専用の管理者から再発行する |
| Tunnel の secret | Tunnel を作り直すか、`credentials.json` を再生成する |
| R2 の資格情報 | 新しいトークンを発行し、古いものを失効させる |
| state のパスフレーズ | 変えるなら state を復号して入れ直す。リソースは import で回収できる |
| webhook の HMAC トークン | 新しい値にして GitHub の webhook 側も差し替える |

## CI は鍵を持たずに検証できる

R9（2026年9月11日）で `.github/workflows/validate.yaml` を入れた。
design.md が「CI 側の仕事はマニフェストの検証と Renovate による更新 PR に限る」と宣言していたが、実装が無かった。

**復号鍵を CI に置く必要はない。**
`.sops.yaml` が `encrypted_regex: ^(data|stringData)$` で値だけを暗号化しており、
`apiVersion`、`kind`、`metadata` は平文で残る。
`kustomize build` はそのまま通る。

置換前のマニフェストを kubeconform に流すと、**偽陽性が2種類出る**。

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| `'*.${SECRET_DOMAIN}' does not match pattern` | Flux の `postBuild.substituteFrom` は apply 時に解決する。CI の時点では変数のまま | `sed` でダミーのドメインに置き換えてから流す |
| `additional properties 'sops' not allowed` | SOPS が Secret のトップレベルに `sops` キーを足す。`-strict` がこれを弾く | `-skip Secret` を付ける。値は暗号化されており、どのみち検証できない |

`-strict` は Secret 以外に効かせる。
属性名の打ち間違いを拾えるのが `-strict` の値であり、丸ごと外すと検証が薄くなる。

CRD のスキーマは [CRDs-catalog](https://github.com/datreeio/CRDs-catalog) から引く。
`-ignore-missing-schemas` を付けて、カタログに無い CRD は飛ばす。

```bash
kustomize build "$dir" \
  | sed -E 's/\$\{SECRET_DOMAIN\}/example\.com/g; s/\$\{SECRET_[A-Z0-9_]+\}/placeholder/g' \
  | kubeconform -strict -ignore-missing-schemas -skip Secret \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

**パイプの終了コードは最後のコマンドのものである。**
`| tail -1` で要約だけを出すように書くと、kubeconform が失敗しても `tail` が成功して CI が通ってしまう。
`set -o pipefail` を立て、`|| fail=1` で拾う。

Terraform 側は `init -backend=false` で回す。
R2 の資格情報を CI に置かずに、provider のスキーマだけを取って構文と型を見られる。

**Renovate は bootstrap 層を拾えない。**
Cilium、flux-operator、Gateway API CRD のバージョンは、いまどのファイルにも無く、
[cluster-bootstrap-order.md](cluster-bootstrap-order.md) の `helm install` 行にしか出てこない。
helmfile へ移せば、そのまま Renovate の対象になる。

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

## リポジトリを移すときに更新するもの

リポジトリを別の名前に変える、オーガナイゼーションへ移す、private にする、のいずれでも更新が要る箇所がある。
どれも移動そのものでは壊れず、次に Flux が同期するときや次に push したときに黙って効かなくなる。

| 対象 | 何を変えるか |
| --- | --- |
| `bootstrap/flux-instance.yaml` の `sync.url` | 新しいリポジトリを指す。`FluxInstance` は手で適用するため、Flux 自身では追随しない |
| GitHub の webhook | hook はリポジトリごとに持つため、移動先で作り直す。`Receiver` のパスは変わらないので URL は同じでよい |
| `.github/workflows/approve-pr-from-owner.yaml` | `github.repository_owner` と PR 作成者の login を比較している。オーガナイゼーションへ移すと両者が一致しなくなり、自動承認が止まる |
| `.github/CODEOWNERS` | `@amoyrtil` のままでは org のレビュー割り当てに載らない。チームに変える |
| `terraform/*/variables.tf` と `.mise/tasks/terraform` | 「リポジトリが public であるため Git には置かない」という理由が5箇所ある。private 化すると理由が偽になる。値を Git に置かない判断は維持し、理由だけを書き換える |

リポジトリの URL を持つのは `bootstrap/flux-instance.yaml` の `sync.url` だけである。
`docs/` 本文には無い。

private にする場合は、これに加えて Git 認証用の Secret を作り、`sync.pullSecret` で指す。
手でクラスターに入れる鍵が `sops-age` の1つで済まなくなり、2つ目が増える。

## R7 で回収したもの

**Webhook Receiver を入れた。**
GitHub の push を Cloudflare Tunnel 経由で受け、`GitRepository` の取得を即座に走らせる。
記録は [gateway-and-tunnel.md](gateway-and-tunnel.md) にある。
