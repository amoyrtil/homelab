variable "cloudflare_account_id" {
  description = "Cloudflare のアカウント ID。R2 のエンドポイントと Tunnel の所属先に使う。"
  type        = string
}

variable "state_passphrase" {
  description = "state と plan の暗号化に使うパスフレーズ。16 文字以上。"
  type        = string
  sensitive   = true
}

variable "tunnel_secret" {
  description = <<-EOT
    既存の Tunnel の資格情報。~/.cloudflared/<UUID>.json の TunnelSecret である。
    API から読み出せないため、import しても state に入らない。値はこちらから与える。
  EOT
  type        = string
  sensitive   = true
}
