# cloudflared tunnel create で手で作った Tunnel を import で回収する。
#
# config_src = "local" は ingress ルールをオリジン側に残す指定である。
# ルールはクラスターの ConfigMap が持ち、Flux が反映する。
# cloudflare_zero_trust_tunnel_cloudflared_config は作らない。
# 作ると Zero Trust ダッシュボード側にも設定が生まれ、所有者が2つになる。

resource "cloudflare_zero_trust_tunnel_cloudflared" "blackwall" {
  account_id    = var.cloudflare_account_id
  name          = "blackwall"
  config_src    = "local"
  tunnel_secret = var.tunnel_secret
}
