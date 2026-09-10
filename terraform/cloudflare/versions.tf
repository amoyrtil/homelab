# state は Cloudflare R2 に置く。
# クラスター内には置けない。Terraform はクラスターが前提とするネットワークを作るため、
# state をクラスターに置くと循環依存になる。
#
# 資格情報とパスフレーズは .mise/tasks/terraform が環境変数として渡す。
# ここには値を書かない。

terraform {
  required_version = "~> 1.12"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.24"
    }
  }

  backend "s3" {
    bucket = "homelab-terraform-state"
    key    = "cloudflare/terraform.tfstate"

    # R2 はリージョンを持たない。S3 互換 API の必須項目を埋めるためだけの値である。
    region = "auto"

    endpoints = {
      s3 = var.state_endpoint
    }

    # R2 が持たない S3 の機構を順に切る。
    # 資格情報の検証、メタデータ API、リージョン名の検証、アカウント ID の照会、
    # チェックサム、仮想ホスト形式の URL の6つである。
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true

    # ロックは条件付き書き込みで行う。DynamoDB 相当の外部テーブルは要らない。
    use_lockfile = true
  }

  # state には Tunnel の tunnel_secret が平文で入る。
  # R2 のトークンが漏れたときの露出を潰すため、書き出す前に暗号化する。
  #
  # enforced を最初から立てる。空のバケットから始めるため、
  # 読み込むべき平文の state が存在せず、移行用の fallback が要らない。
  encryption {
    key_provider "pbkdf2" "main" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }

    state {
      method   = method.aes_gcm.main
      enforced = true
    }

    plan {
      method   = method.aes_gcm.main
      enforced = true
    }
  }
}

provider "cloudflare" {
  # API トークンは CLOUDFLARE_API_TOKEN から読む。
  # .mise/tasks/terraform が CLOUDFLARE_TERRAFORM_API_TOKEN を写して渡す。
}
