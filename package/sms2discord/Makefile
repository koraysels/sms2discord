# OpenWrt feed package. Build with the SDK:
#   echo "src-git sms2discord https://github.com/koraysels/sms2discord.git" >> feeds.conf
#   ./scripts/feeds update sms2discord && ./scripts/feeds install sms2discord
#   make package/sms2discord/compile
# Or build the .ipk without the SDK: tools/build-ipk.sh

include $(TOPDIR)/rules.mk

PKG_NAME:=sms2discord
PKG_VERSION:=0.5.1
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
  DEPENDS:=+smstools3 +lua +lua-cjson +libuci-lua +curl
  PKGARCH:=all
endef

define Package/sms2discord/description
  Forwards every SMS received by smstools3 to a Discord channel via a webhook,
  and optionally sends SMS from "!sms <number> <text>" messages in that channel.
  Works on stock OpenWrt and GL.iNet firmware 4.x.
  Configure with luci-app-sms2discord or "sms2discord setup".
endef

define Package/sms2discord/conffiles
/etc/config/sms2discord
endef

define Build/Compile
endef

define Package/sms2discord/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/etc/init.d $(1)/etc/config $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/sms2discord.lua $(1)/usr/bin/sms2discord
	$(INSTALL_BIN) ./files/sms2discord.init $(1)/etc/init.d/sms2discord
	$(INSTALL_CONF) ./files/sms2discord.config $(1)/etc/config/sms2discord
	$(INSTALL_BIN) ./files/sms2discord.uci-defaults $(1)/etc/uci-defaults/90-sms2discord
endef

$(eval $(call BuildPackage,sms2discord))
