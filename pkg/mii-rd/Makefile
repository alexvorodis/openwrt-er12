# mii_rd — minimal MDIO register reader (SIOCGMIIREG)
#
# This is free software, licensed under the GNU General Public License v2.

include $(TOPDIR)/rules.mk

PKG_NAME:=mii-rd
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/mii-rd
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=MDIO register reader for ER-12 linksync
  DEPENDS:=@(TARGET_octeon||TARGET_ath79) +kmod-libphy
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/mii_rd.c $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) -o $(PKG_BUILD_DIR)/mii_rd $(PKG_BUILD_DIR)/mii_rd.c
endef

define Package/mii-rd/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/mii_rd $(1)/usr/sbin/mii_rd
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/etc/config $(1)/usr/lib/er12
	$(INSTALL_BIN) ./files/er12-linksync.init $(1)/etc/init.d/er12-linksync
	$(INSTALL_BIN) ./files/er12-linksync.sh $(1)/usr/lib/er12/er12-linksync.sh
	$(INSTALL_CONF) ./files/linksync $(1)/etc/config/linksync
endef

$(eval $(call BuildPackage,mii-rd))
