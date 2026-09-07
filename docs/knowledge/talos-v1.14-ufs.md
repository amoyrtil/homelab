# Talos v1.14 と talos-ufs の存廃

Talos v1.14.0 で上流カーネルが UFS ホストコントローラに対応した。
これにより `talos-ufs` のカスタムビルドが不要になったかを実機で検証し、不要と判定した記録である。

検証は 2026年9月6日に cp-2（jerry / S100-WLP 128GB）で実施した。
あわせて cp-1（morty）を標準 Talos v1.14 で作り直し、MS-03 をワーカーとして投入するところまでを記録する。

## 上流が UFS に対応した経緯

2026年9月3日にリリースされた Talos v1.14.0 で、標準カーネルが UFS ホストコントローラに対応した。

きっかけは `siderolabs/pkgs` の issue #1619 である。
S100 を名指しした報告で、UFS が唯一の内蔵ストレージである安価な x86 ミニ PC が増えているのに Talos ではディスクが見えずインストールできない、ドライバがモジュールとしてすら作られていないのでシステム拡張や Image Factory の schematic では回避できない、という内容だった。

対応は pkgs#1620 と talos#13793 に分かれており、どちらも v1.14 に入っている。

| リポジトリ | 変更 |
| --- | --- |
| `siderolabs/pkgs` | `CONFIG_SCSI_UFSHCD=m` と `CONFIG_SCSI_UFSHCD_PCI=m` を有効化 |
| `siderolabs/talos` | `hack/modules-amd64.txt` に `ufshcd-core.ko`、`ufshcd-pci.ko`、`governor_simpleondemand.ko` を追加 |

issue の要望は `=y`（組み込み）だったが、実装は `=m`（モジュール）になった。
Talos は `hack/modules-amd64.txt` に載っているモジュールを initramfs に含めて自動ロードするため、モジュールでも起動ディスクとして成立する。

報告者は修正後の実機確認を issue にコメントしている。
使われた個体は Intel N100 の Minisforum S100 で、UFS は Samsung `KLUEG8U1EA-B0C1` である。
cp-1（morty）と同じ型番である。
内蔵 UFS が `ufshcd` transport の `/dev/sd*` として現れ、インストールが通り、外部メディアなしで再起動を繰り返しても healthy を保ち、etcd を含む単一ノードクラスターが立ち上がったと報告されている。

## 2つのパッチが上流でどうなったか

`talos-ufs` が上流に当てているパッチは2つである。

**`kernel-config.patch`** は、UFS 関連の config を `=m` から `=y` へ引き上げる。
パッチの文脈行が示すとおり、当てる相手はすでに `=m` になった v1.14 の config である。
README にある「`=m` では動かない」という記述は、モジュールが `hack/modules-amd64.txt` に載っていなかった時点のものであり、v1.14 では成立しない。

**`efi-partition-size.patch`** は、`GrubEFISize()` を 100MiB から 512MiB に引き上げる。
4096バイトセクタのデバイスに FAT32 を作るには、最小クラスタ数 65525 を満たすために 256MiB 強が要るためである。

ただし S100 へのインストールは、このパッチが効く経路を通っていない。
Step 1 で記録したパーティション構成には BIOS も BOOT もなく、EFI が 2.6GB になっている。
これは UKI レイアウトであり、その EFI サイズは次の式で決まる。

```
UKIEFISize = GrubEFISize + GrubBIOSSize + GrubBootSize
```

パッチ後の値を入れると `512 + 1 + 2000 = 2513 MiB` で、10進の 2.6GB になる。
Step 1 の実測と一致する。
上流のままなら `100 + 1 + 2000 = 2101 MiB` で、これも 256MiB を大きく上回る。
`efi-partition-size.patch` は GRUB レイアウトに対する保険としては意味を持つが、S100 が通る UKI レイアウトでは効いていない。

上流のメンテナも `siderolabs/talos` の issue #13227 で、ISO や PXE から起動して通常どおりディスクにインストールする経路なら Talos は 4k セクタのディスクに正しくインストールできる、あの issue はディスクイメージだけの話である、と述べている。

机上では、v1.14 において `talos-ufs` の存在理由は失われている。
残るのは実機での確認である。

## 検証（cp-2 / jerry）

cp-2 を etcd から外し、標準 Talos v1.14 の検証に使う。
検証後にクラスターへ戻さない。

使う ISO は素の schematic（拡張もカーネル引数もなし、ID は `376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba`）のものである。

```
https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v1.14.0/metal-amd64.iso
```

**Stage B（非破壊）**

- [x] 標準 v1.14 の ISO から起動し、メンテナンスモードに入る
- [x] `talosctl get disks --insecure` に `sda` が transport `ufshcd` で現れる
- [x] `KernelModuleStatus`（v1.14 で追加。`LoadedKernelModule` は非推奨）で `ufshcd_pci` がロード済みである

**Stage C（インストール）**

- [x] 素の schematic の installer で machine config を適用し、インストールが完了する
- [x] ディスクから起動し `STAGE: running` に到達する
- [x] パーティション構成を記録する。EFI が 256MiB 以上であること
- [x] 再起動を数回繰り返しても安定していることを確認する

## 検証の結果（2026年9月6日、cp-2 / jerry）

**Stage B**：標準 v1.14.0 の ISO（SHA `9abd05af`、`-dirty` なし）でメンテナンスモードに入り、UFS ディスクが見えた。

| 確認項目 | 結果 |
| --- | --- |
| Talos バージョン | `v1.14.0`。上流の素のビルドで、パッチは当たっていない |
| UFS ディスク | `sda` / 128GB / transport `ufshcd` / `KLUDG4U1EA-B0C1` |
| Secure Boot | `false` |

`KernelModuleStatus` では、上流が `hack/modules-amd64.txt` に追加した3つがすべて `dynamic` かつ `live` だった。

```
governor_simpleondemand   dynamic   live
ufshcd_core               dynamic   live
ufshcd_pci                dynamic   live
```

talos-ufs の README にある「`=m` では動かない」は、モジュールが `hack/modules-amd64.txt` に載っていなかった時点の記述であり、v1.14 では成立しない。

**Stage C**：使い捨ての単一ノードクラスターとして構築し、インストールから起動、クラスター稼働までを通した。

インストール後のパーティション構成は次のとおりで、BIOS も BOOT もない UKI レイアウトである。

```
sda1  2.2 GB  vfat       EFI
sda2  1.0 MB  talosmeta  META
sda3  105 MB  xfs        STATE
sda4  126 GB  xfs        EPHEMERAL
```

**EFI の 2.2GB は `GrubEFISize 100 + GrubBIOSSize 1 + GrubBootSize 2000 = 2101 MiB` と一致する。**
talos-ufs を使った Step 1 の実測が 2.6GB だったのは、`GrubEFISize` を 512MiB に上げた差分そのものである。
上流の 100MiB のままでも、4096バイトセクタで FAT32 の最小クラスタ数 65525 を満たすのに必要な 256MiB 強を大きく上回る。
`efi-partition-size.patch` が S100 の経路で効いていないという机上の推定が、実測で裏付けられた。

クラスターとしても成立した。

| 確認項目 | 結果 |
| --- | --- |
| Node | `Ready`、Kubernetes `v1.37.0` |
| Talos | `v1.14.0`、カーネル `6.18.48-talos` |
| STAGE / READY | `running` / `true` |
| etcd | 3.7.1、単一メンバーでリーダー、healthy |
| システム Pod | CoreDNS 2つ、flannel、kube-proxy、apiserver、controller-manager、scheduler がすべて Running |
| ワークロード | nginx の Deployment と Service を作成し、クラスター内から HTTP 200 |
| 外部メディアなしの再起動 | USB を抜いた状態で3回繰り返し、いずれも `stage: RUNNING` に復帰。3回目のあとも Node は `Ready`、nginx も再スケジュールされて Running |

**判定：`talos-ufs` は役目を終えた。**

Stage B と Stage C の両方を満たした。
`talos-ufs` が当てている2つのパッチは、どちらも v1.14 の上流で不要になっている。

| パッチ | 上流での代替 | 実測による裏付け |
| --- | --- | --- |
| `kernel-config.patch` | `=m` と `hack/modules-amd64.txt` への登録 | 3つのモジュールが `dynamic` かつ `live`。UFS ディスクを認識 |
| `efi-partition-size.patch` | 不要。UKI レイアウトの EFI は 2101 MiB になる | EFI 実測 2.2GB |

アーカイブする際は、v1.14 以降は上流の標準イメージを使うよう README に案内を残す。
Verified Devices に載っているのは S100-WLP だけだが、他の UFS 機種の利用者が同じ判断を下せるようにするためである。

なお、この検証で cp-2 には使い捨ての単一ノードクラスター（`ufs-verify`）が載ったままである。
本番クラスターとは無関係で、S100-WLP を次の用途に回すときに消してよい。

## クラスターの移行手順

現在のクラスターは検証目的で組んだものであり、破壊的な変更を許容する。
etcd のスナップショットは取らない。
コントロールプレーンは数日中に EliteDesk 800 G6 へ全置換するため、いずれ再構築する。

**Phase 0：復旧**

- [ ] cp-1（morty）と cp-2（jerry）の電源を入れる
- [ ] 作業端末を VLAN 20 に載せる
- [ ] v1.13.9 のクラスターが2メンバーで戻ることを確認する

**Phase 1：cp-2 で標準 v1.14 を検証**

- [x] cp-2 を graceful reset でクラスターから外す（etcd が1メンバーに縮退する）
- [x] Stage B と Stage C を実施する
- [x] 結果をこのドキュメントに記録する

2メンバーの etcd は quorum が 2 であり、どちらを再起動してもクラスターが止まる。
cp-2 を先に外して1メンバーにしておけば、続く cp-1 のアップグレードで止まるのは cp-1 の再起動のあいだだけになる。

**Phase 2：cp-1 を v1.14 で作り直す**

当初は `talosctl upgrade` で talos-ufs から標準イメージへ乗り換える計画だった。
Stage C でクリーンインストールが通ったこと、そしてコントロールプレーンを EliteDesk 800 G6 に置き換える以上、アップグレード経路を確かめる価値が下がったことから、作り直す方針に変えた。
EliteDesk への移行のリハーサルにもなる。

- [x] `talconfig.yaml` の `talosVersion` を `v1.14.0`、`kubernetesVersion` を `v1.37.0` にする
- [x] cp-1 のインストーラーイメージを素の schematic に変える
- [x] cp-2 のノード定義を削除する（`wipe: true` パッチもここで外れる）
- [x] `talosctl reset --graceful=false --wipe-mode all` で cp-1 を消去する
- [x] 標準 v1.14 の ISO から起動し、生成した machine config を適用する
- [x] `talosctl bootstrap` でクラスターを起こす

**結果（2026年9月6日）**

| 項目 | 結果 |
| --- | --- |
| Node | `cp-1` が `Ready`、Kubernetes `v1.37.0` |
| Talos | `v1.14.0`、カーネル `6.18.48-talos` |
| EFI パーティション | 2.2GB。256GB の morty でも 128GB の jerry と同値 |
| etcd | 3.7.1、リーダー、healthy |
| VIP | cp-1 が保持。`kubectl` も VIP 経由で疎通 |

`talsecret.sops.yaml` を変えていないため、etcd のメンバー ID は再構築前と同じ `dd7677abffb26e5f` のままで、既存の talosconfig と kubeconfig がそのまま使える。

**talhelper は v1.14 の設定形式に対応している。**
3.1.17 のリリースは Talos v1.14.0 より前だが、v1.14 で独立ドキュメントに移った設定を正しく生成する。

| 設定 | v1.14 での行き先 |
| --- | --- |
| ホスト名 | `HostnameConfig` |
| ネームサーバー | `ResolverConfig` |
| `deviceSelector` | `LinkAliasConfig` |
| 静的アドレスと経路 | `LinkConfig` |
| VIP | `Layer2VIPConfig` |
| インストール先とイメージ | `machine.install`（v1alpha1 のまま） |

同じ設定を v1alpha1 と独立ドキュメントの両方に書くと、v1.14 は適用時に拒否する。
手書きでパッチを当てるときは、どちらか一方に寄せる必要がある。

**Phase 3：MS-03 を投入して2台体制**

- [x] `talos/schematics/ms03-schematic.yaml` を作成する
- [x] MS-03 を v1.14.0 で構築する（手順は [../plan.md](../plan.md) の「MS-03 のセットアップ」）
- [x] worker-1 がクラスターに参加し Ready になる
- [x] 既定の Flannel のまま、単純な Deployment と Service をデプロイして疎通を確認する

`allowSchedulingOnControlPlanes` が `false` であるため、ワーカーがなければワークロードは動かない。
この検証は、MS-03 がクラスターに参加したこと自体の確認を兼ねる。

CNI を Cilium に差し替えるのは本構築の課題として分離する。
ここで同時に入れると、Pod が動かなかったときに MS-03 側の問題か CNI 側の問題かを切り分けられなくなる。

**結果（2026年9月6日）**

| 項目 | 結果 |
| --- | --- |
| Node | `worker-1` が `Ready`、Kubernetes `v1.37.0`、Talos `v1.14.0` |
| インストール先 | `/dev/nvme0n1`（SKHynix HFS256GDE9X081N 256GB）。EFI は cp-1 と同じ 2.2GB |
| 拡張 | `intel-ucode` 20260812、`xe`、`intel-npu`、`iscsi-tools` v0.2.0、`util-linux-tools` 2.42.2 の5つがロード。schematic ID も一致 |
| カーネル引数 | `iommu=pt` が反映 |
| Pod の配置 | nginx 2レプリカが両方とも worker-1 に載った。cp-1 の control-plane taint が効いている |
| Service | ClusterIP 経由で `HTTP 200`。Endpoints に2つの Pod IP |

**MS-03 の NIC は4つとも認識された。**

| インターフェース | ドライバ | Vendor:Device | チップ |
| --- | --- | --- | --- |
| `eno2` | `igc` | 8086:125b | Intel i226-LM 2.5GbE |
| `eno3` | `r8169` | 10ec:8127 | Realtek RTL8127 10GbE RJ-45 |
| `eno4np0` | `i40e` | 8086:1572 | Intel X710 SFP+ #1 |
| `eno5np1` | `i40e` | 8086:1572 | Intel X710 SFP+ #2 |

RTL8127 が認識されなかった場合の退避先を用意しておくという懸念は、解消した。
`r8169` がデバイスを掴んでおり、リンクが down なのはケーブルが挿さっていないためである。

現在の接続は X710 の SFP+ #1（`port: DirectAttach`）で、`192.168.20.41` はこのポートに載せている。
`talconfig.yaml` の `deviceSelector` は MAC で固定した。4つとも同じ OUI の連番であり、名前の対応が起動順で入れ替わりうるためである。

**iGPU は使えるが、NPU はドライバの初期化に失敗する。**

特権 Pod から `/dev/dri` を確認すると `card0` と `renderD128` があり、`xe` 拡張が Xe3 の DRM デバイスを提供している。

一方 `/dev/accel` は存在しない。
PCI デバイスとしては `0000:00:0b.0` に Panther Lake NPU が見えており、`intel_vpu` モジュールも `live` でロードされている。
それでも probe が `-EIO` で失敗する。

```
intel_vpu 0000:00:0b.0: [drm] *ERROR* ivpu_hw_ip_host_ss_configure(): Failed qreqn check: -5
intel_vpu 0000:00:0b.0: [drm] *ERROR* ivpu_hw_power_up(): Failed to configure host SS: -5
intel_vpu 0000:00:0b.0: probe with driver intel_vpu failed with error -5
```

Linux 6.18 の `intel_vpu` が Panther Lake 世代の NPU を扱いきれていないと考えられる。
NPU を使うワークロードは初期スコープ外であり、この時点では支障にならない。
使う段になったら、カーネルの更新か BIOS 設定を確認する。

MS-03 の ISO 作成からメンテナンスモードでの NIC とディスクの確認までは、Phase 1 および Phase 2 と並行して進められる。

## v1.14 で変わった点のうち、この構成に効くもの

| 変更 | 影響 |
| --- | --- |
| `ghcr.io/siderolabs/installer` がリリースで公開されなくなった | 標準 Talos を使う場合も Image Factory 経由のインストーラーイメージが要る。`talosctl gen config` の既定値が素の schematic（`376567...`）を指す `factory.talos.dev/metal-installer/376567...:v1.14.0` になっており、`--install-disk` も `/dev/sda`、`--kubernetes-version` も `1.37.0` が既定である。`factory.talos.dev/installer/` の旧パスも 200 を返すが、生成される正規のパスは `metal-installer` である |
| etcd が 3.7.1 になり、`/metrics` などの HTTP エンドポイントが 2383 に移動 | `listen-metrics-urls` を明示している場合は移動しない。etcd 性能評価のスクリプトが使う 2381 はそのまま効く |
| Kubernetes の既定が 1.37.0 | `kubernetesVersion` を v1.36.2 から上げる |
| `LoadedKernelModule` が非推奨、`KernelModuleStatus` を追加 | モジュールのロード確認は新しいリソースを使う |
| Linux が 6.18.44 から 6.18.48 へ | どちらも 6.18 系であり、MS-03 の RTL8127 に対する見込みは変わらない |
