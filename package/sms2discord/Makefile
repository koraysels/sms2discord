# OpenWrt feed package. Build with the SDK:
#   echo "src-git sms2discord https://github.com/koraysels/sms2discord.git" >> feeds.conf
#   ./scripts/feeds update sms2discord && ./scripts/feeds install sms2discord
#   make package/sms2discord/compile
# Or build the .ipk without the SDK: tools/build-ipk.sh

include $(TOPDIR)/rules.mk

PKG_NAME:=sms2discord
PKG_VERSION:=0.2.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Koray Sels <koray.sels@gmail.com>

include $(INCLUDE_DIR)/package.mk

define Package/sms2discord
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Two-way SMS to Discord bridge for smstools3
  URL:=https://github.com/koraysels/sms2discord
  DEPENDS:=+smstools3 +lua +lua-cjson +curl
  PKGARCH:=all
endef

define Package/sms2discord/description
  Forwards every SMS received by smstools3 to a Discord channel via a webhook,
  and optionally sends SMS from "!sms <number> <text>" messages in that channel.
  Works on stock OpenWrt and GL.iNet firmware 4.x.
endef

define Build/Compile
endef

define Package/sms2discord/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/etc/init.d
	$(INSTALL_BIN) ./files/sms2discord.lua $(1)/usr/bin/sms2discord
	$(INSTALL_BIN) ./files/sms2discord.init $(1)/etc/init.d/sms2discord
endef

define Package/sms2discord/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/sms2discord enable
/etc/init.d/sms2discord restart
exit 0
endef

define Package/sms2discord/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/sms2discord stop
/etc/init.d/sms2discord disable
exit 0
endef

$(eval $(call BuildPackage,sms2discord))
