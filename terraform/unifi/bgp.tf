# UCG-Fiber の BGP は、UI の Settings -> Routing -> BGP から FRR の設定ファイルを
# アップロードして入れてあった。これを import で回収する。
#
# BGP の設定はサイトごとの singleton であり、import ID はサイト名である。
#
# **raw の config で持つ。**
# provider は asn、router_id、peers から config を組み立てる構造化モードも持つ。
# ただし API はレンダリング済みの config しか保持せず、provider もそれを
# 構造化の属性に読み戻さない。import した設定を構造化モードで表すと、
# 読み戻せない属性が state に残り続けて差分が消えない。

resource "unifi_bgp" "blackwall" {
  description = "Blackwall-BGP"
  enabled     = true

  # UI にアップロードしたときのファイル名である。コントローラーが保持しており、
  # 書かないと差分になる。
  upload_file_name = "ucg-fiber-bgp.conf"

  # コントローラーが保持している内容と、このファイルはバイト単位で一致している。
  # クラスター側の Cilium の設定は bootstrap/cilium-bgp.yaml にある。
  config = file("${path.module}/ucg-fiber-bgp.conf")
}

import {
  to = unifi_bgp.blackwall
  id = "default"
}
