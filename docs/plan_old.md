## 概要
homelab向けにk8sの環境構築と、CI/CDパイプラインを整備したい
具体的にどんなサービスをホスティングするかは後で決める
以降に記載する構成下で、k8sクラスターを起動させつつ、IaCでCI/CDが可能なベースの環境構築までを行いたい

## 実現したいこと
以下のソフトウェア群を活用する
- ベースのOS: talos linux
  - 特定のマシン向けにtalosのカスタムビルドを導入する
  - 詳細は/Users/ryoma/Documents/GitHub/talos-ufs/CLAUDE.mdを参照して欲しい
- CI/CDにはflux v2を導入する
- GitOpsを全面的に導入し、mainブランチへのPRとマージをフックに、CI/CDが実行される
- このプロジェクトの開発に必要なツール類は全てmiseで管理し、開発に必要なローカル環境のポータビリティも高く保つ

## ハードウェア構成
- コントロールプレーンノード: MINISFORUM S100-WLP x3台 HA構成にする
- ワーカーノード: 未定 x1台
  - Intel CPU
  - Intel Quick Sync Videoが利用可能。コンテナへのパススルーも想定（初期スコープ外、後から追加）
  - m.2 SSDを採用した一般的なx86マシン
  - 10gbe搭載
- その他: Synology DS923+
  - SSDキャッシュ 1TB
  - 10gbe搭載
  - 写真や動画、バックアップデータなどの保存/書き込み先として利用

## ネットワーク構成
- サブネット: 10.0.0.0/24
- コントロールプレーンノード: 10.0.0.11, 10.0.0.12, 10.0.0.13
- ワーカーノード: 10.0.0.21
- Talos VIP (k8s API): 10.0.0.100
- Cilium LB Pool: 10.0.0.200-250
- Synology DS923+: 10.0.0.50
- Pod CIDR: 10.244.0.0/16
- Service CIDR: 10.96.0.0/12
- 10GbE構成: 未定（後で決定）

## ソフトウェアスタック

### Talos Linux
- 設定管理: talhelper (talconfig.yaml)
- CPノード: talos-ufsカスタムイメージ（S100-WLPがUFSストレージのため）
- ワーカーノード: Talos標準イメージ
- HA: Talosネイティブ VIP機能 (10.0.0.100)
- CPノードはtaintあり（CP専用、ワークロード実行なし）

### CNI / ネットワーク
- CNI: Cilium（kube-proxy完全置換、eBPFモード）
  - Talos側でkube-proxyを無効化する設定をtalconfig.yamlに含める
- ロードバランサー: Cilium L2モード（IP Pool: 10.0.0.200-250）
- Ingress Controller: Traefik
  - サブドメイン方式（*.example.com → 各サービスにルーティング）
- DNS: ローカルDNSのみ（CoreDNS）
- ドメイン: Cloudflare管理の既存ドメインを使用

### ストレージ
- 外部ストレージ: democratic-csi (NFS) → Synology DS923+
  - Synology APIを通じてNFS共有を動的プロビジョニング
  - 写真、動画、バックアップデータなどの永続データ
- ローカルストレージ: OpenEBS Local PV → ワーカーノードm.2 SSD
  - DB等の高速I/Oが必要なワークロード

### セキュリティ / シークレット
- シークレット管理: SOPS + age
  - Flux native対応、Git内に暗号化済みSecretをコミット
- TLS証明書: cert-manager + Let's Encrypt
  - DNS-01チャレンジ（Cloudflare）
- DNSプロバイダー: Cloudflare（cert-managerのDNS-01チャレンジ用）

### GitOps / CI/CD
- GitOps: Flux v2
  - Helmチャート管理: HelmRelease CRD
  - ブートストラップ順序:
    1. Cilium (CNI)
    2. cert-manager
    3. Traefik
    4. SOPS / Secrets設定
    5. NFS CSI Driver
    6. OpenEBS Local PV
    7. Prometheus + Grafana
    8. アプリケーション
- 自動更新: Renovate（GitHub App）
  - HelmRelease / コンテナイメージタグの自動PR作成
- GitHub Actions CI: Lint + Validate（YAML lint, Flux validate, Kustomize build check）

### モニタリング
- Prometheus + Grafana（kube-prometheus-stack）
  - 初期構築のスコープに含める

### バックアップ
- 初期はGitOpsのみ（Gitリポジトリ自体がバックアップ）
- PVデータはSynologyのスナップショット機能で保護

## 開発環境
- ツール管理: mise
  - kubectl, talosctl, talhelper, flux, sops, age, helm, kustomize, k9s

## リポジトリ構造（onedr0p/cluster-template準拠）
```
homelab/
├── kubernetes/
│   ├── apps/              # アプリケーション定義（namespace単位）
│   │   ├── default/
│   │   ├── kube-system/
│   │   ├── networking/
│   │   └── monitoring/
│   ├── bootstrap/         # 初回ブートストラップ
│   │   ├── flux/
│   │   └── talos/
│   └── flux/              # Flux設定
│       ├── config/
│       └── vars/
├── talos/                 # Talos設定
│   ├── talconfig.yaml
│   └── patches/
├── .mise.toml
└── .sops.yaml
```

## 初期スコープ外（後から追加）
- Intel Quick Sync Videoのパススルー（Intel Device Plugin）
- 10GbEネットワーク構成の詳細
- 具体的なアプリケーションのデプロイ
- Velero等の本格的なバックアップソリューション

## リファレンス
一部talosのカスタムビルドを採用する点で異なるが、ソフトウェアとしての基本思想は同じ
https://github.com/onedr0p/cluster-template

---

## 実装タスク

### 決定事項
- 設定管理: 直接YAML（makejinjaテンプレートは使わない）
- タスクランナー: Taskfile導入（mise経由でtaskをバージョン管理）
- Fluxブートストラップ: `flux bootstrap github`（公式CLI方式）
- HW固有情報（ディスクパス、MACアドレス、ドメイン名等）: placeholder/TODOで埋め、後から置換

### Phase 1: 開発環境セットアップ
- [ ] `.mise.toml` 作成
  - kubectl, talosctl, talhelper, flux, sops, age, helm, kustomize, k9s, task のバージョン固定
  - 環境変数: KUBECONFIG, SOPS_AGE_KEY_FILE, TALOSCONFIG
- [ ] `.sops.yaml` 作成
  - age暗号化ルール（kubernetes/, talos/ 配下の `*.sops.yaml` を対象）
  - age公開鍵はplaceholder
- [ ] `Taskfile.yaml` 作成
  - talos: talhelper genconfig, apply-config, upgrade等
  - flux: reconcile, bootstrap
  - validate: kustomize build, flux build

### Phase 2: Talos設定
- [ ] `talos/talconfig.yaml` 作成（talhelper用クラスター定義）
  - クラスター名、エンドポイント: https://10.0.0.100:6443
  - CPノード x3（10.0.0.11-13, VIP 10.0.0.100）
    - カスタムイメージ: ghcr.io/<owner>/talos-ufs-installer:<version> (placeholder)
  - ワーカーノード x1（10.0.0.21, 標準Talosイメージ）
  - kube-proxy無効化（Cilium置換）
  - Pod CIDR: 10.244.0.0/16, Service CIDR: 10.96.0.0/12
  - CPノードtaint: node-role.kubernetes.io/control-plane:NoSchedule
  - ディスクパス、MACアドレス: placeholder
- [ ] `talos/patches/` 必要に応じたカスタムパッチ
  - Cilium用: enable bpf, disable kube-proxy等のinline patch

### Phase 3: Fluxディレクトリ構造・設定
- [ ] `kubernetes/flux/config/kustomization.yaml` 作成
  - Flux Kustomization CRD: kubernetes/apps配下を再帰的に監視
  - SOPS decryption provider設定
  - HelmReleaseへの共通パッチ（retry, remediation等）
- [ ] `kubernetes/flux/vars/cluster-settings.yaml` 作成
  - ConfigMap: クラスター共通変数（ドメイン名、CIDRなど）
- [ ] `kubernetes/flux/vars/cluster-secrets.sops.yaml` 作成
  - SOPS暗号化Secret: Cloudflare APIトークン等（placeholder）
- [ ] `kubernetes/bootstrap/` ブートストラップ手順用ファイル
  - age鍵Secret、GitHubデプロイキー等のマニフェスト

### Phase 4: インフラコンポーネント（kubernetes/apps/）

各コンポーネントは以下の構造で作成:
```
kubernetes/apps/<namespace>/<app>/
├── ks.yaml          # Flux Kustomization (依存関係定義)
└── app/
    ├── kustomization.yaml
    ├── helmrelease.yaml
    └── (その他リソース)
```

- [ ] `kubernetes/apps/kube-system/cilium/` — CNI
  - HelmRelease: cilium/cilium
  - eBPFモード、kube-proxy完全置換
  - L2 Announcement + CiliumLoadBalancerIPPool (10.0.0.200-250)
- [ ] `kubernetes/apps/kube-system/coredns/` — DNS
  - HelmRelease: coredns/coredns
  - dependsOn: cilium
- [ ] `kubernetes/apps/cert-manager/cert-manager/` — 証明書管理
  - HelmRelease: jetstack/cert-manager
  - ClusterIssuer: letsencrypt-production (DNS-01, Cloudflare)
  - dependsOn: coredns
- [ ] `kubernetes/apps/networking/traefik/` — Ingress
  - HelmRelease: traefik/traefik
  - Cilium LBからIPを取得
  - dependsOn: cert-manager
- [ ] `kubernetes/apps/kube-system/democratic-csi/` — 外部ストレージ
  - HelmRelease: democratic-csi/democratic-csi
  - NFS provisioner → Synology DS923+ (10.0.0.50)
  - dependsOn: coredns
- [ ] `kubernetes/apps/kube-system/openebs/` — ローカルストレージ
  - HelmRelease: openebs/openebs (localpv-provisioner)
  - dependsOn: coredns
- [ ] `kubernetes/apps/monitoring/kube-prometheus-stack/` — 監視
  - HelmRelease: prometheus-community/kube-prometheus-stack
  - Prometheus + Grafana
  - dependsOn: traefik, openebs

### Phase 5: Namespace Kustomization定義
- [ ] 各namespace配下に `kustomization.yaml` + `namespace.yaml` 作成
  - `kubernetes/apps/kube-system/`
  - `kubernetes/apps/cert-manager/`
  - `kubernetes/apps/networking/`
  - `kubernetes/apps/monitoring/`
- [ ] ルートKustomization (`kubernetes/flux/config/ks.yaml`) で全namespace束ねる
  - 依存チェーン: Cilium → CoreDNS → cert-manager → Traefik → Storage → Monitoring

### Phase 6: CI/CD
- [ ] `.github/workflows/flux-validate.yaml` 作成
  - トリガー: PR (paths: kubernetes/**)
  - yamllint
  - kustomize build --dry-run
  - flux build kustomization の検証
- [ ] `.renovaterc.json5` 作成
  - HelmRelease / コンテナイメージタグの自動PR作成
  - SOPS暗号化ファイルを除外
  - minor/patch自動マージ設定

### Phase 7: ドキュメント・仕上げ
- [ ] `CLAUDE.md` 作成（プロジェクト構造、コマンド、コンテキスト）
- [ ] `README.md` 更新（セットアップ手順、ブートストラップ手順）

### 検証
- [ ] `mise install` で全ツールがインストールされること
- [ ] `talhelper genconfig` でTalos設定ファイルが正常生成されること
- [ ] `kustomize build` で各kubernetes/apps配下がビルドできること
- [ ] GitHub Actions CIがPRで正常動作すること（lint/validate）
- [ ] placeholder箇所を実値に置換後、実クラスターでブートストラップが通ること

### 作成ファイル一覧
```
homelab/
├── .mise.toml
├── .sops.yaml
├── Taskfile.yaml
├── CLAUDE.md
├── kubernetes/
│   ├── apps/
│   │   ├── kube-system/
│   │   │   ├── kustomization.yaml
│   │   │   ├── namespace.yaml
│   │   │   ├── cilium/
│   │   │   │   ├── ks.yaml
│   │   │   │   └── app/
│   │   │   │       ├── kustomization.yaml
│   │   │   │       └── helmrelease.yaml
│   │   │   ├── coredns/
│   │   │   │   ├── ks.yaml
│   │   │   │   └── app/
│   │   │   ├── democratic-csi/
│   │   │   │   ├── ks.yaml
│   │   │   │   └── app/
│   │   │   └── openebs/
│   │   │       ├── ks.yaml
│   │   │       └── app/
│   │   ├── cert-manager/
│   │   │   ├── kustomization.yaml
│   │   │   ├── namespace.yaml
│   │   │   └── cert-manager/
│   │   │       ├── ks.yaml
│   │   │       └── app/
│   │   ├── networking/
│   │   │   ├── kustomization.yaml
│   │   │   ├── namespace.yaml
│   │   │   └── traefik/
│   │   │       ├── ks.yaml
│   │   │       └── app/
│   │   └── monitoring/
│   │       ├── kustomization.yaml
│   │       ├── namespace.yaml
│   │       └── kube-prometheus-stack/
│   │           ├── ks.yaml
│   │           └── app/
│   ├── bootstrap/
│   │   └── flux/
│   └── flux/
│       ├── config/
│       │   ├── kustomization.yaml
│       │   └── ks.yaml
│       └── vars/
│           ├── cluster-settings.yaml
│           └── cluster-secrets.sops.yaml
├── talos/
│   ├── talconfig.yaml
│   └── patches/
├── .github/workflows/
│   └── flux-validate.yaml
└── .renovaterc.json5
```
