# Zone-Based Firewall のゾーンとポリシー。
# 設計は docs/design.md#vlan-間ポリシー にある。
#
# **書くのは許可だけである。**
# 新規に作ったゾーンはゾーン間もゾーン内も既定で拒否になるため、拒否は
# ポリシーを書かないことで表せる。「応答を除き拒否」は逆向きの許可に
# create_allow_respond を付けることで表す。
#
# この形を保つ理由は unifi_firewall_policy の index が read-only だからである。
# 評価順を Terraform から指定できないが、同じパケットに一致する許可と拒否が
# 同居しなければ、どの順に並んでも結果は変わらない。
# 拒否のポリシーを足したくなったら、既存の許可と重ならないことを確かめる。
# 重なるなら、そのポリシーはここに置けない。
#
# **apply の途中で一時的に到達できなくなる。**
# ゾーンはポリシーより先に作られる（ポリシーがゾーンの ID を参照するため）。
# ネットワークがゾーンへ移ってからポリシーが入るまでのあいだ、VLAN 間は
# すべて拒否になる。
# コントローラー（192.168.1.1）は Gateway ゾーンにいて既定で許可されるため、
# その窓のあいだも Terraform は喋り続けられる。apply 自体は詰まらない。

# 組み込みゾーンは ID をコントローラーが持つ。名前で引く。
data "unifi_firewall_zone" "internal" {
  name = "Internal"
}

data "unifi_firewall_zone" "external" {
  name = "External"
}

# Guest（VLAN 60）はここに属している。
# unifi_network の purpose = "guest" はこのゾーンにいるあいだしか保てないため、
# ゾーンの所属は変えない。
data "unifi_firewall_zone" "hotspot" {
  name = "Hotspot"
}

locals {
  # VLAN ごとにゾーンを1つ切る。キーは networks.tf の locals.networks と揃える。
  # Guest（60）は Hotspot、Default（1）は Internal に残すため、ここには無い。
  zones = {
    management = "Management"
    server     = "Server"
    trusted    = "Trusted"
    untrusted  = "Untrusted"
    camera     = "Camera"
    service    = "Service"
  }
}

resource "unifi_firewall_zone" "this" {
  for_each = local.zones

  name = each.value

  # ネットワークの所属はゾーン側だけで管理する。
  # unifi_network も firewall_zone_id を持つが、両方から書くと state が
  # 揺れ続ける（provider のドキュメントが明示的に警告している）。
  network_ids = [unifi_network.this[each.key].id]
}

locals {
  zone_ids = merge(
    { for key, zone in unifi_firewall_zone.this : key => zone.id },
    {
      internal = data.unifi_firewall_zone.internal.id
      external = data.unifi_firewall_zone.external.id
      hotspot  = data.unifi_firewall_zone.hotspot.id
    }
  )

  # 名前解決の許可。宛先が決まるまで作らない。
  # Backup DNS はフェーズ1の成果物であり、Pi-hole の LB IP はクラスターが
  # 払い出すまで確定しない。どちらも null のあいだ、この group は空になる。
  dns_targets = merge(
    var.backup_dns_address == null ? {} : {
      backup = { zone = "server", ip = var.backup_dns_address }
    },
    var.pihole_address == null ? {} : {
      pihole = { zone = "service", ip = var.pihole_address }
    },
  )

  # 自前の DNS を引かせる送信元。
  # Trusted と Server は宛先ゾーンへの全許可を別に持つため、ここには要らない。
  dns_sources = {
    untrusted  = "untrusted"
    camera     = "camera"
    guest      = "hotspot"
    management = "management"
  }

  dns_policies = {
    for pair in setproduct(keys(local.dns_sources), keys(local.dns_targets)) :
    "${pair[0]}-dns-${pair[1]}" => {
      name     = "Allow ${title(pair[0])} to DNS (${pair[1]})"
      src      = local.dns_sources[pair[0]]
      dst      = local.dns_targets[pair[1]].zone
      dst_ips  = [local.dns_targets[pair[1]].ip]
      port     = "53"
      protocol = "tcp_udp"
      respond  = true
    }
  }

  # 宛先ゾーンへの全許可。
  # External 宛に respond を付けないのは、External への established が
  # 既定で許可されているためである。
  zone_policies = {
    trusted-management = { name = "Allow Trusted to Management", src = "trusted", dst = "management", dst_ips = null, port = null, protocol = "all", respond = true }
    trusted-server     = { name = "Allow Trusted to Server", src = "trusted", dst = "server", dst_ips = null, port = null, protocol = "all", respond = true }
    trusted-service    = { name = "Allow Trusted to Service", src = "trusted", dst = "service", dst_ips = null, port = null, protocol = "all", respond = true }
    trusted-untrusted  = { name = "Allow Trusted to Untrusted", src = "trusted", dst = "untrusted", dst_ips = null, port = null, protocol = "all", respond = true }
    server-service     = { name = "Allow Server to Service", src = "server", dst = "service", dst_ips = null, port = null, protocol = "all", respond = true }

    trusted-external    = { name = "Allow Trusted to Internet", src = "trusted", dst = "external", dst_ips = null, port = null, protocol = "all", respond = false }
    server-external     = { name = "Allow Server to Internet", src = "server", dst = "external", dst_ips = null, port = null, protocol = "all", respond = false }
    untrusted-external  = { name = "Allow Untrusted to Internet", src = "untrusted", dst = "external", dst_ips = null, port = null, protocol = "all", respond = false }
    management-external = { name = "Allow Management to Internet", src = "management", dst = "external", dst_ips = null, port = null, protocol = "all", respond = false }
  }

  # 暫定。作業端末が VLAN 1 にいるあいだだけ要る。
  # 他の VLAN がカスタムゾーンへ移ると Internal には VLAN 1 しか残らず、
  # Internal から新規ゾーンへの組にはポリシーが無いため既定拒否になる。
  # これが無いと作業端末から kubectl も talosctl も LB IP も届かない。
  #
  # 作業端末を VLAN 30 へ、UCG-Fiber の管理アドレスを VLAN 10 へ移したら
  # var.keep_default_vlan_access を false にして消す。
  transitional_policies = var.keep_default_vlan_access ? {
    internal-server     = { name = "TEMP Allow Default VLAN to Server", src = "internal", dst = "server", dst_ips = null, port = null, protocol = "all", respond = true }
    internal-service    = { name = "TEMP Allow Default VLAN to Service", src = "internal", dst = "service", dst_ips = null, port = null, protocol = "all", respond = true }
    internal-management = { name = "TEMP Allow Default VLAN to Management", src = "internal", dst = "management", dst_ips = null, port = null, protocol = "all", respond = true }
  } : {}

  policies = merge(local.zone_policies, local.dns_policies, local.transitional_policies)
}

# Camera から NVR への許可はここに無い。
# 録画先が UNVR か DS923+ か クラスター上の NVR かが決まっていないため、
# 宛先ゾーンが定まらない（docs/plan.md の「UniFi Protect の録画先」）。
# Camera から外への通信は、ポリシーを書かないことで拒否したままにする。

resource "unifi_firewall_policy" "allow" {
  for_each = local.policies

  name       = each.value.name
  action     = "ALLOW"
  protocol   = each.value.protocol
  ip_version = "IPV4"

  # 逆向きのポリシーを書く代わりに、応答を自動で通す。
  create_allow_respond = each.value.respond

  source = {
    zone_id         = local.zone_ids[each.value.src]
    matching_target = "ANY"
  }

  destination = {
    zone_id            = local.zone_ids[each.value.dst]
    matching_target    = each.value.dst_ips == null ? "ANY" : "IP"
    ips                = each.value.dst_ips
    port               = each.value.port
    port_matching_type = each.value.port == null ? "ANY" : "SPECIFIC"
  }
}
