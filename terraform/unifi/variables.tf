variable "state_endpoint" {
  description = <<-EOT
    state を置く S3 互換ストレージのエンドポイント URL。
    URL にアカウント ID が入り、リポジトリが public であるため Git には置かない。
    値は .mise/tasks/terraform が組み立てて渡す。
  EOT
  type        = string
}

variable "state_passphrase" {
  description = "state と plan の暗号化に使うパスフレーズ。16 文字以上。"
  type        = string
  sensitive   = true
}

variable "backup_dns_address" {
  description = <<-EOT
    Backup DNS のアドレス。VLAN 20 の `192.168.20.10` を予定している。
    フェーズ1で建つまでは null にしておく。null のあいだ、この宛先への
    53 を許可するポリシーは作られない。
  EOT
  type        = string
  default     = null
}

variable "pihole_address" {
  description = <<-EOT
    クラスター上の Pi-hole の LoadBalancer IP。VLAN 120 から払い出される。
    クラスターが払い出すまで確定しないため、それまでは null にしておく。
  EOT
  type        = string
  default     = null
}

variable "keep_default_vlan_access" {
  description = <<-EOT
    VLAN 1（Default）から Server / Service / Management への暫定の許可を
    置くかどうか。
    作業端末が VLAN 1 にいるあいだは true にしておく。VLAN 30 へ移し、
    UCG-Fiber の管理アドレスを VLAN 10 へ移したら false にする。
  EOT
  type        = bool
  default     = true
}

variable "unifi_api_url" {
  description = <<-EOT
    UniFi controller の URL。パス（/api）は付けない。
    UCG-Fiber が controller を兼ねており、いまは VLAN 1 のアドレスで応答する。
    VLAN 10（Management）へ管理アドレスを移したあとは 192.168.10.1 になる。
  EOT
  type        = string
  default     = "https://192.168.1.1"
}
