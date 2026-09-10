output "tunnel_id" {
  description = "Tunnel の UUID。クラスターの cluster-secrets が持つ SECRET_CLOUDFLARE_TUNNEL_ID と一致する。"
  value       = cloudflare_zero_trust_tunnel_cloudflared.blackwall.id
}

output "tunnel_cname" {
  description = "external-dns が external Gateway の HTTPRoute に向ける CNAME の宛先。"
  value       = "${cloudflare_zero_trust_tunnel_cloudflared.blackwall.id}.cfargotunnel.com"
}
