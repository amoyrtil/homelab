# CLAUDE.md

This file provides guidance to Claude Code (claude.Claude/code) when working with code in this repository.

## 自宅サーバー向けk3sクラスタの要件

### 0. ハードウェア構成

#### コントロールプレーンノード（3台）
- **機種**: Minisforum S100
- **CPU**: Intel N100
- **RAM**: 8GB
- **Storage**: 128GB
- **Network**: 1x 2.5Gigabit RJ45 POE

#### ワーカーノード（2台）
- **機種**: Minisforum MS-02
- **CPU**: AMD Ryzen 9 7945HX
- **GPU**: NVIDIA RTX A400
- **RAM**: 32GB
- **Storage**: 512GB
- **Network**: 2x 2.5Gigabit RJ45, 2x 10Gigabit SFP+
- **IO**: 2x USB3.2 Gen2 Type-C

#### ネットワーク構成
- **各種ノードのCIDR、およびVIP**:
  - Control Plane: `${CONTROL_PLANE_CIDR}` (TBD)
  - Control Plane HA VIP: `${CONTROL_PLANE_VIP}` (TBD)
  - Worker Nodes: `${WORKER_NODES_CIDR}` (TBD)
- **ネットワーク機器**: 10GbE対応ルーター + L3スイッチ
- **NFS Server**: `${NFS_SERVER_IP}` (TBD)
- **NFS Export Path**: `${NFS_EXPORT_PATH}` (TBD)

### 1. リポジトリフォルダ構成案 (Claudeが生成するコード/設定の配置場所)

以下のフォルダ構造に従って、各種コード、マニフェスト、設定ファイル等を生成・配置することを目標とします。

```plClaudentext
.
├── .github/
│   └── workflows/                     # GitHub Actions ワークフロー定義
│       ├── lint-ansible.yml
│       ├── lint-yaml.yml
│       ├── lint-dockerfile.yml
│       ├── ci-app-build-test.yml
│       ├── cd-app-update-manifest.yml
│       └── cd-infra-k3s.yml
│
├── ansible/                           # Ansible: OS初期設定, k3sクラスタ基盤構成管理
│   ├── inventory/
│   │   └── production/
│   │       ├── hosts.yml
│   │       └── group_vars/
│   │           ├── all.yml
│   │           ├── k3s_control_plane.yml
│   │           └── k3s_worker.yml
│   ├── roles/
│   │   ├── common/
│   │   ├── k3s_common/
│   │   ├── k3s_control_plane/
│   │   ├── k3s_worker/
│   │   ├── nfs_client/
│   │   ├── nvidia_driver/
│   │   └── docker/ # (アプリケーションビルド等でDocker CLIが必要な場合)
│   ├── playbooks/
│   │   ├── 00_prepare_nodes.yml
│   │   ├── 01_install_k3s_cp.yml
│   │   ├── 02_install_k3s_worker.yml
│   │   └── site.yml
│   ├── files/
│   ├── templates/
│   └── ansible.cfg
│
├── kubernetes/                        # Kubernetes Manifests (Kustomizeベース)
│   ├── README.md
│   ├── bootstrap/                     # Argo CDや必須コンポーネントの初期デプロイ用
│   │   ├── argocd/
│   │   ├── namespaces/
│   │   └── sealed-secrets-controller/
│   ├── base/                          # 環境非依存の基本マニフェスト
│   │   ├── namespaces/
│   │   ├── apps/                      # 各ホスティングアプリケーション
│   │   │   ├── plex/
│   │   │   ├── home-assistant/
│   │   │   ├── pi-hole/
│   │   │   ├── wireguard/
│   │   │   ├── immich/
│   │   │   └── komga/
│   │   └── infra/                     # クラスタ内インフラコンポーネント
│   │       ├── actions-runner-controller/
│   │       ├── monitoring/              # Prometheus, Grafana
│   │       ├── logging/                 # Loki, Grafana
│   │       ├── ingress-traefik/
│   │       ├── nfs-subdir-external-provisioner/
│   │       ├── nvidia-gpu-operator/
│   │       ├── uptime-kuma/
│   │       └── cert-manager/            # (オプション)
│   ├── overlays/                      # 環境固有の設定上書き
│   │   └── production/
│   │       ├── kustomization.yaml
│   │       ├── common-patches/
│   │       ├── apps/                  # アプリケーション固有オーバーレイ
│   │       │   ├── plex/
│   │       │   └── ...
│   │       ├── infra/                 # インフラコンポーネント固有オーバーレイ
│   │       │   ├── monitoring/
│   │       │   └── ...
│   │       ├── argocd-applications/   # Argo CD Application CRD群
│   │       └── sealed-secrets/        # 暗号化されたSecretファイル
│   └── vendors/                       # (オプション) サードパーティManifests/Helm Charts
│
├── secrets/                           # 機密情報管理に関するドキュメント、鍵管理手順など
│   └── README.md
│
├── docs/                              # プロジェクト全体のドキュメント
│   ├── 01_architecture.md
│   ├── 02_initial_setup.md
│   ├── 03_ci_cd_pipeline.md
│   ├── 04_application_deployment.md
│   ├── 05_backup_restore.md
│   └── 06_conventions.md
│
├── scripts/                           # 便利スクリプト
│   ├── kustomize-build-all.sh
│   ├── sops-encrypt.sh                # (SOPS利用の場合)
│   └── seal-secret.sh                 # (Sealed Secrets利用の場合)
│
├── .gitignore
├── .ansible-lint
├── .hadolint.yaml                     # (Dockerfile lint用)
└── README.md
```

---

### 2. Claude担当開発タスク一覧 (依存関係考慮)

以下に、Claudeが担当するコーディング関連のタスクを、おおよその実行フェーズと依存関係を考慮してリストアップします。
フェース1から順に実装を進めてください。
なお、各フェーズ内のタスクはある程度並行して進められるものもあります。

**フェーズ1: OS設定・k3sクラスタ基盤構築 (Ansible)**
* **タスク1.1:** ✅ Ansible `common` ロールの作成 (全ノード共通のOS初期設定: timezone, ntp, user, sshd, 基本パッケージ等)。
* **タスク1.2:** ✅ Ansible `k3s_common` ロールの作成 (k3sインストール前の共通準備: カーネルモジュール有効化, sysctl設定等)。
* **タスク1.3:** ✅ Ansible `k3s_control_plane` ロールの作成 (k3sサーバーのインストール、HAクラスタ初期化、トークン取得等)。
* **タスク1.4:** ✅ Ansible `k3s_worker` ロールの作成 (k3sエージェントのインストール、クラスタへの参加)。
* **タスク1.5:** ✅ Ansible `nfs_client` ロールの作成 (ワーカーノードへのNFSクライアントパッケージインストールと設定)。
* **タスク1.6:** ✅ Ansible `nvidia_driver` ロールの作成 (MS-02ワーカーノードへのNVIDIAドライバ、CUDA Toolkitインストール)。
* **タスク1.7:** ✅ (オプション) Ansible `docker` ロールの作成 (アプリケーションビルド等でホストにDocker CLIが必要な場合)。
* **タスク1.8:** ✅ Ansible Playbook群の作成 (`00_prepare_nodes.yml`, `01_install_k3s_cp.yml`, `02_install_k3s_worker.yml`, `site.yml`)。
* **タスク1.9:** ✅ Ansibleインベントリファイル (`inventory/production/hosts.yml`, `group_vars/*`) および `ansible.cfg` のテンプレート作成。

**フェーズ2: Kubernetesクラスタ基本設定 (Manifests)**
*(依存: フェーズ1完了)*
* **タスク2.1:** Kustomizeによる基本ディレクトリ構造 (`kubernetes/base`, `kubernetes/overlays/production` 等) の作成。
* **タスク2.2:** Kubernetes Namespaceリソース定義マニフェストの作成 (`argocd`, `sealed-secrets`, `home-services`, `media` 等、`kubernetes/bootstrap/namespaces/` および `kubernetes/base/namespaces/`)。
* **タスク2.3:** NFSベースのStorageClass定義マニフェストの作成 (`kubernetes/base/infra/storage/` など)。
* **タスク2.4:** NFS Subdir External Provisionerのデプロイマニフェスト作成 (`kubernetes/base/infra/nfs-subdir-external-provisioner/`)。
* **タスク2.5:** Sealed Secretsコントローラーのデプロイマనిフェスト作成 (`kubernetes/bootstrap/sealed-secrets-controller/`)。

**フェーズ3: CI/CD基盤構築とGitOps導入 (Workflows, Manifests)**
*(依存: フェーズ2完了)*
* **タスク3.1:** Argo CDのデプロイマニフェスト作成 (`kubernetes/bootstrap/argocd/`)。
* **タスク3.2:** `actions-runner-controller` (ARC) のデプロイマニフェスト作成 (`kubernetes/base/infra/actions-runner-controller/`)。
* **タスク3.3:** GitHub Actionsワークフローファイルの作成:
    * `lint-ansible.yml` (Ansible Playbookの静的解析とdry-run)。
    * `lint-yaml.yml` (Kubernetesマニフェスト等のYAML静的解析)。
    * `lint-dockerfile.yml` (Dockerfileの静的解析)。
    * `cd-infra-k3s.yml` (k3sクラスタ基盤構成変更の自動実行)。
    * `ci-app-build-test.yml` (アプリケーションのビルド、テスト、コンテナイメージ作成・プッシュ)。
    * `cd-app-update-manifest.yml` (アプリケーションデプロイのためのマニフェスト更新)。
* **タスク3.4:** Renovate設定ファイル (`renovate.json`等) の作成と、関連するGitHub Actionsワークフロー連携の提案。
* **タスク3.5:** 各アプリケーション用Dockerfileの作成。

**フェーズ4: インフラ系アプリケーションのデプロイ (Manifests, Argo CD Applications)**
*(依存: フェーズ3完了、Argo CD稼働)*
* **タスク4.1:** Argo CD Application CRDテンプレートの作成 (`kubernetes/overlays/production/argocd-applications/`)。
* **タスク4.2:** 以下インフラ系アプリケーションのKustomizeベースマニフェスト作成 (`kubernetes/base/infra/`) および対応するArgo CD Application CRD作成:
    * Prometheus & Grafana (kube-prometheus-stack Helm Chartベース)。
    * Loki & Grafana (loki-stack Helm Chartベース)。
    * NVIDIA GPU Operator (Helm Chartベース)。
    * Uptime Kuma。
    * WireGuard VPNサーバー。
    * Pi-hole。
    * (オプション) Cert-Manager。
    * (SSO用) oauth2-proxy等の認証プロキシ (必要な場合)。
* **タスク4.3:** Grafanaダッシュボード定義のJSONモデル作成支援 (主要システムメトリクス等)。
* **タスク4.4:** Prometheus AlertmanagerまたはGrafana Alertingを利用したSlackへのアラート通知設定（設定ファイルテンプレートまたは手順提示）。
* **タスク4.5:** k3sデフォルトのTraefik Ingressに関する追加設定マニフェスト作成 (`kubernetes/base/infra/ingress-traefik/`)。

**フェーズ5: ユーザーアプリケーションのデプロイ (Manifests, Argo CD Applications)**
*(依存: フェーズ4完了)*
* **タスク5.1:** 以下ユーザーアプリケーションのKustomizeベースマニフェスト作成 (`kubernetes/base/apps/`) および対応するArgo CD Application CRD作成:
    * Plex Media Server (GPU設定、永続ストレージ設定、Cloudflare Tunnel用Ingress設定含む)。
    * Home Assistant (永続ストレージ設定、Cloudflare Tunnel用Ingress設定含む)。
    * Immich (永続ストレージ設定、Cloudflare Tunnel用Ingress設定含む)。
    * Komga (永続ストレージ設定、Cloudflare Tunnel用Ingress設定含む)。
* **タスク5.2:** Cloudflare Tunnel用`cloudflared`コネクタのデプロイマニフェスト作成および関連Ingressリソースのマニフェスト作成 (`kubernetes/base/infra/cloudflared/` など)。

**フェーズ6: セキュリティ・その他設定 (Manifests, Ansible, 手順支援)**
*(依存: 適宜、各コンポーネントデプロイ後)*
* **タスク6.1:** Kubernetes NetworkPolicyリソースのマニフェスト作成 (初期セット、デフォルトDenyポリシー検討)。
* **タスク6.2:** Kubernetes RBACリソースのマニフェスト作成 (初期管理者用ClusterRoleBindingなど)。
* **タスク6.3:** Ansible PlaybookによるSSHパスワード認証無効化タスクの作成。
* **タスク6.4:** Sealed Secrets/SOPS利用手順のドキュメント化および関連スクリプトテンプレートの提供。
* **タスク6.5:** k3sクラスタのバックアップ・リストア手順のドキュメント化および関連スクリプトテンプレートの提供。

---

### 3. 機能要件

#### 3.1. Kubernetesクラスタ基盤
* k3sコントロールプレーンHA構成およびワーカーノード参加を実現するためのAnsible Playbook群の作成。
* OS基本設定およびk3sインストール/アップグレード自動化のためのAnsible Playbook群の作成。

#### 3.2. ネットワーク機能
* Pi-holeデプロイ用Kubernetesマニフェストの作成。

#### 3.3. ストレージ機能
* NFS Subdir External Provisionerデプロイ用Kubernetesマニフェストの作成。
* NFSベースStorageClass定義マニフェストの作成。

#### 3.4. CI/CD機能
* 各種GitHub Actionsワークフローファイル（lint、インフラCI/CD、アプリCI/CD）の作成。
* `actions-runner-controller` (ARC) デプロイ用Kubernetesマニフェストの作成。
* Argo CDデプロイ用KubernetesマニフェストおよびApplication CRDテンプレートの作成。
* Kustomizeによるマニフェスト管理構造および`kustomization.yaml`テンプレートの作成。
* Renovate設定ファイルの作成と関連ワークフロー連携の提案。
* アプリケーション用Dockerfileの作成。

#### 3.5. GPU利用機能
* NVIDIA GPU Operatorデプロイ用Kubernetesマニフェストの作成。
* PlexデプロイマニフェストへのGPUアクセラレーション設定記述。

#### 3.6. ホスティングアプリケーション要件
* 指定された各アプリケーション（Plex, Home Assistant, Pi-hole, WireGuard, Immich, Komga, Prometheus/Grafana, Loki/Grafana, Uptime Kuma）のデプロイ用Kubernetesマニフェスト作成。
* Google Workspaceのアカウント認証を基盤としたSSO連携のためのoauth2-proxy等のデプロイマニフェスト作成、および関連アプリケーション設定変更支援。

#### 3.7. モニタリング・ロギング・アラート機能
* Prometheus/GrafanaスタックおよびLoki/Grafanaスタックのデプロイマニフェスト作成。
* Uptime Kumaデプロイマニフェスト作成。
* Grafanaダッシュボード定義JSONモデル作成支援。
* Slackへのアラート通知設定（Alertmanager/Grafana Alerting）のテンプレート/手順提示。

### 4. 外部インターフェース要件

#### 4.1. ユーザーインターフェース
* 各種Web UIアクセス用Kubernetes IngressリソースおよびServiceリソースのマニフェスト作成。
* (オプション) Kubernetes Dashboardデプロイ用マニフェスト作成。

#### 4.4. 通信インターフェース
* 外部公開Webサービス用IngressリソースへのHTTPS強制設定記述。
* SSH公開鍵認証強制のためのAnsible Playbookタスク作成。

#### 4.5. 外部アクセス要件
* `cloudflared`コネクタデプロイ用Kubernetesマニフェストおよび関連Ingressマニフェスト作成。
* WireGuardサーバーデプロイ用Kubernetesマニフェストおよびクライアントコンフィグ生成スクリプトテンプレート提供。

### 5. 非機能要件

#### 5.1. パフォーマンス要件
* PlexデプロイマニフェストへのGPUリソース割り当て設定記述。
* 各アプリケーションデプロイマニフェストへの適切なリソース要求/制限の初期値提案。

#### 5.2. セキュリティ要件
* Kubernetes NetworkPolicyリソースのマニフェスト作成。
* Kubernetes RBACリソースのマニフェスト作成（初期管理者用）。
* Sealed Secretsコントローラーデプロイ用マニフェスト作成、および暗号化/復号手順のスクリプトテンプレート/手順提示。

#### 5.3. 可用性・信頼性要件
* アプリケーションデプロイマニフェストへのReplicaSet設定記述。
* k3sクラスタバックアップ・リストア手順のスクリプトテンプレート/手順提示。

#### 5.4. 保守性・運用性要件
* Grafanaダッシュボード定義JSONモデルまたはGrafana as Code設定支援。
* Slackへのアラート通知設定（Alertmanager/Grafana Alerting）テンプレート/手順提示。

#### 5.5. データ保全要件
* PersistentVolumeClClaudem, PersistentVolume (NFS Provisioner利用時), StorageClassのマニフェスト作成。
