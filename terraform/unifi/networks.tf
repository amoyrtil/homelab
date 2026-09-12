# VLAN は UI で手作業で作ってある。R8 はそれをコード化する作業であり、
# 設定の変更ではない。値はすべて 2026年9月10日にコントローラーの API から読んだ
# 現在値をそのまま書いている。推測で書くと、import した時点で稼働中の
# ネットワークに書き込みが走る。
#
# ここに挙げていない属性は provider が Optional かつ Computed として扱い、
# コントローラーの現在値を読む。書いていないものは「管理外」ではなく
# 「コントローラーに従う」である。
#
# Terraform に載せるのは VLAN を持つ7つだけである。
# Default（VLAN 1）は機器を収容せず、WAN は unifi_wan という別のリソースを持つ。
# どちらも UI の管理のまま残す。

locals {
  # アドレスは 192.168.<VLAN ID>.0/24、ゲートウェイは .1 で揃えてある。
  # 属性はネストさせず平らに持つ。map の要素は型が揃っている必要があり、
  # 該当しない項目を null で埋めるほうが読みやすい。
  networks = {
    management = {
      name               = "Management"
      vlan               = 10
      subnet             = "192.168.10.1/24"
      purpose            = "corporate"
      setting_preference = "auto"
      dhcp_start         = "192.168.10.6"
      dhcp_stop          = "192.168.10.254"
      dhcp_guard_servers = null
    }
    server = {
      name    = "Server"
      vlan    = 20
      subnet  = "192.168.20.1/24"
      purpose = "corporate"
      # .1-.149 を静的割り当てと DHCP 予約に空け、プールを .150 から始める。
      # 設計どおりの値を UI で入れてあるため、UniFi の既定から外れている。
      setting_preference = "manual"
      dhcp_start         = "192.168.20.150"
      dhcp_stop          = "192.168.20.250"
      dhcp_guard_servers = ["192.168.20.1"]
    }
    trusted = {
      name               = "Trusted"
      vlan               = 30
      subnet             = "192.168.30.1/24"
      purpose            = "corporate"
      setting_preference = "auto"
      dhcp_start         = "192.168.30.6"
      dhcp_stop          = "192.168.30.254"
      # 持ち込まれた機器やルーターが DHCP を配り始める事故を止める。
      dhcp_guard_servers = ["192.168.30.1"]
    }
    untrusted = {
      name               = "Untrusted"
      vlan               = 40
      subnet             = "192.168.40.1/24"
      purpose            = "corporate"
      setting_preference = "auto"
      dhcp_start         = "192.168.40.6"
      dhcp_stop          = "192.168.40.254"
      dhcp_guard_servers = null
    }
    camera = {
      name               = "Camera"
      vlan               = 50
      subnet             = "192.168.50.1/24"
      purpose            = "corporate"
      setting_preference = "auto"
      dhcp_start         = "192.168.50.6"
      dhcp_stop          = "192.168.50.254"
      dhcp_guard_servers = null
    }
    guest = {
      name   = "Guest"
      vlan   = 60
      subnet = "192.168.60.1/24"
      # purpose が guest でいられるのは、このネットワークが guest ゾーンに
      # 属しているあいだだけである。ゾーンを外すとコントローラーが corporate に
      # 書き戻し、apply が inconsistent result で落ちる。
      # ゾーンは unifi_firewall_zone を入れるまで UI の管理のまま置く。
      purpose            = "guest"
      setting_preference = "auto"
      dhcp_start         = "192.168.60.6"
      dhcp_stop          = "192.168.60.254"
      # ゲストの機器は素性が分からない。偽の DHCP サーバーを止める。
      dhcp_guard_servers = ["192.168.60.1"]
    }
    service = {
      name    = "Service"
      vlan    = 120
      subnet  = "192.168.120.1/24"
      purpose = "corporate"
      # DHCP は動かさない。実体は Cilium が BGP で広告する /32 の集合である。
      setting_preference = "manual"
      dhcp_start         = null
      dhcp_stop          = null
      dhcp_guard_servers = null
    }
  }
}

resource "unifi_network" "this" {
  for_each = local.networks

  name               = each.value.name
  vlan               = each.value.vlan
  subnet             = each.value.subnet
  purpose            = each.value.purpose
  setting_preference = each.value.setting_preference

  # provider は省略すると true を既定値として当てる。Computed であっても
  # 現在値を読まない。7つとも false であり、書かないと import が
  # 「取り込んで即座に更新する」plan になる。
  # サブネットのサイズは設計で /24 に固定してあるため、自動拡張は要らない。
  auto_scale = false

  dhcp_server = each.value.dhcp_start == null ? null : {
    enabled = true
    start   = each.value.dhcp_start
    stop    = each.value.dhcp_stop
  }

  dhcp_guarding = each.value.dhcp_guard_servers == null ? null : {
    enabled = true
    servers = each.value.dhcp_guard_servers
  }
}

# import ブロックで回収する。plan に「何を取り込むか」が出てから apply できる。
# ID には name= 形式を使う。ObjectId でも指せるが、名前のほうが読める。
import {
  for_each = local.networks

  to = unifi_network.this[each.key]
  id = "name=${each.value.name}"
}
