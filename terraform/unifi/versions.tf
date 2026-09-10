# state は Cloudflare R2 に置く。cloudflare の root モジュールと同じバケットで、
# キーだけを分ける。
#
# root モジュールを provider ごとに分けているのは、UniFi provider が
# controller への到達を要求するためである。単一の root に両方を置くと、
# Cloudflare だけを変えるときにも宅内にいる必要が出る。
#
# 資格情報とパスフレーズは .mise/tasks/terraform が環境変数として渡す。
# ここには値を書かない。

terraform {
  required_version = "~> 1.12"

  required_providers {
    unifi = {
      source  = "ubiquiti-community/unifi"
      version = "~> 0.55"
    }
  }

  backend "s3" {
    bucket = "homelab-terraform-state"
    key    = "unifi/terraform.tfstate"

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

  # cloudflare 側と同じ理由で暗号化する。
  # この state に秘密は入らないが、揃えておけば後から機微な属性を持つ
  # リソースを足したときに設定を見直さずに済む。
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

provider "unifi" {
  api_url = var.unifi_api_url

  # API キーは UNIFI_API_KEY から読む。
  # .mise/tasks/terraform が UNIFI_TERRAFORM_API_KEY を写して渡す。
  # api_key を与えると username と password は無視される。

  # UCG-Fiber は CN=unifi.local の自己署名証明書を出す。
  # 発行者も自分自身であり、ホスト名で繋いでも検証は通らない。
  # provider は ca_cert に相当する属性を持たないため、これ以外の手がない。
  #
  # 検証を切ると API キーが未検証の TLS に載るが、宅内 LAN 内の1本に閉じるため
  # 許容する。外すにはコントローラーに正式な証明書を載せることになる。
  allow_insecure = true
}
