# SPDX-License-Identifier: MIT

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for sms2discord
LUCI_DEPENDS:=+luci-base +sms2discord
LUCI_PKGARCH:=all

PKG_VERSION:=0.5.1
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Koray Sels <koray.sels@gmail.com>

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
