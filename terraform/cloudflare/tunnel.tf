# cloudflared tunnel create で手で作った Tunnel を import で回収する。
#
# tunnel_secret は渡さない。
# 渡すと plan が in-place の更新を1件出し、稼働中の Tunnel へ書き込みが走る。
# 渡さなければ差分ゼロの純粋な import になり、state にも秘密が入らない（実測）。
# 値はクラスターの cloudflared-credentials にあり、失われてはいない。
#
# config_src = "local" は ingress ルールをオリジン側に残す指定である。
# ルールはクラスターの ConfigMap が持ち、Flux が反映する。
# cloudflare_zero_trust_tunnel_cloudflared_config は作らない。
# 作ると Zero Trust ダッシュボード側にも設定が生まれ、所有者が2つになる。

resource "cloudflare_zero_trust_tunnel_cloudflared" "blackwall" {
  account_id = var.cloudflare_account_id
  name       = "blackwall"
  config_src = "local"
}

# import ブロックで回収する。plan に「何を取り込むか」が出てから apply できる。
import {
  to = cloudflare_zero_trust_tunnel_cloudflared.blackwall
  id = "${var.cloudflare_account_id}/${var.tunnel_id}"
}
