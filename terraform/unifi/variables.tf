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

variable "unifi_api_url" {
  description = <<-EOT
    UniFi controller の URL。パス（/api）は付けない。
    UCG-Fiber が controller を兼ねており、いまは VLAN 1 のアドレスで応答する。
    VLAN 10（Management）へ管理アドレスを移したあとは 192.168.10.1 になる。
  EOT
  type        = string
  default     = "https://192.168.1.1"
}
