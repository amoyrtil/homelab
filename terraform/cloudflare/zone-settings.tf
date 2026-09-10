# ゾーン設定のうち、この構成の正しさに関わるものだけを持つ。
# cloudflare_zone_setting は設定1つで1リソースであり、挙げなかったものは
# UI の管理のまま残る。
#
# 値はすべて 2026年9月10日に API で読んだ現在値である。
# 推測で書くと、ssl を取り違えた時点で公開中のサイトが壊れる。
#
# ssl の flexible と min_tls_version の 1.0 は、いずれも見直す価値がある。
# ただし R8 はコード化であって設定の変更ではないため、ここでは現在値のまま
# 取り込む。判断は R9 の監査（公開とセキュリティ）で行う。

locals {
  zone_settings = {
    always_use_https         = "on"
    automatic_https_rewrites = "on"
    min_tls_version          = "1.0"
    security_level           = "medium"
    ssl                      = "flexible"
    tls_1_3                  = "on"
    websockets               = "on"
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
