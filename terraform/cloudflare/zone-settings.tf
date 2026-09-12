# ゾーン設定のうち、この構成の正しさに関わるものだけを持つ。
# cloudflare_zone_setting は設定1つで1リソースであり、挙げなかったものは
# UI の管理のまま残る。
#
# 値は 2026年9月10日に API で読んだ現在値から始めた。
# 推測で書くと、ssl を取り違えた時点で公開中のサイトが壊れる。
#
# ssl と min_tls_version は R9 の監査（2026年9月11日）で引き上げた。
# 経緯は docs/knowledge/gateway-and-tunnel.md#ゾーン設定を引き上げる にある。

locals {
  zone_settings = {
    always_use_https         = "on"
    automatic_https_rewrites = "on"
    security_level           = "medium"
    tls_1_3                  = "on"
    websockets               = "on"

    # TLS 1.0 と 1.1 は非推奨である。
    # このゾーンが serve するのは Tunnel 経由の自分のサービスだけで、
    # 古い機器がここを引くことはない。互換性を気にする相手が居ない。
    min_tls_version = "1.2"

    # Cloudflare は Full 系を強く推奨しており、flexible を選ぶ理由がこの構成に無い。
    # Tunnel を使う限り edge から cloudflared までは常に暗号化されるため、
    # この設定は実質バイパスされる。ingress が http:// を向いていても壊れない。
    #
    # それでも flexible のままにしないのは、ゾーン全体に効く設定だからである。
    #   - Tunnel を通さない proxied レコードを1本足した瞬間、平文で origin に届く
    #   - flexible では Authenticated Origin Pull が使えない
    #   - flexible は 443 以外の HTTPS で full にフォールバックし、挙動がポートで変わる
    ssl = "strict"
  }
}

resource "cloudflare_zone_setting" "this" {
  for_each = local.zone_settings

  zone_id    = var.cloudflare_zone_id
  setting_id = each.key
  value      = each.value
}

import {
  for_each = local.zone_settings

  to = cloudflare_zone_setting.this[each.key]
  id = "${var.cloudflare_zone_id}/${each.key}"
}
