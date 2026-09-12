# どちらも Tunnel の UUID を含む。
# variables.tf は同じ値を「Git には置かない」ものとして変数で受け取っており、
# output だけ素で出るのは筋が通らない。sensitive を立てて揃える。
#
# 値を取り出すときは -raw を使う。
#   mise run terraform cloudflare output -raw tunnel_id

output "tunnel_id" {
  description = "Tunnel の UUID。クラスターの cluster-secrets が持つ SECRET_CLOUDFLARE_TUNNEL_ID と一致する。"
  value       = cloudflare_zero_trust_tunnel_cloudflared.blackwall.id
  sensitive   = true
}

output "tunnel_cname" {
  description = "external-dns が external Gateway の HTTPRoute に向ける CNAME の宛先。"
  value       = "${cloudflare_zero_trust_tunnel_cloudflared.blackwall.id}.cfargotunnel.com"
  sensitive   = true
}
