variable "cloudflare_account_id" {
  description = "Cloudflare のアカウント ID。R2 のエンドポイントと Tunnel の所属先に使う。"
  type        = string
}

variable "state_passphrase" {
  description = "state と plan の暗号化に使うパスフレーズ。16 文字以上。"
  type        = string
  sensitive   = true
}

variable "tunnel_id" {
  description = <<-EOT
    既存の Tunnel の UUID。import の対象を指すために使う。
    クラスターの cluster-secrets が持つ SECRET_CLOUDFLARE_TUNNEL_ID と同じ値であり、
    リポジトリが public であるため Git には置かない。
  EOT
  type        = string
}
