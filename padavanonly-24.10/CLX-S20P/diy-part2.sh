#!/bin/bash
# ============================================================
# DIY2 - 第三方软件源与依赖处理
#
# 软件包优先级：
# 1. package/myapp：独立第三方源码，最高优先级
# 2. DIY1 添加的第三方集合源
# 3. 官方 feeds
#
# 特殊锁定：
# - dae / daed：仅使用 feeds/small
# - rtp2httpd：仅使用 feeds/rtp2httpd
# - 特殊锁定包不允许其他 feeds 覆盖
# ============================================================

set -e

# ============================================================
# 1. 工作目录检查
# ============================================================

TOPDIR="${GITHUB_WORKSPACE:-$(pwd)}"

if [ ! -d "$TOPDIR/package" ] || [ ! -d "$TOPDIR/feeds" ]; then
    echo "错误：未找到 OpenWrt 源码目录！"
    exit 1
fi

cd "$TOPDIR"

echo "=========================================="
echo "开始执行 DIY2"
echo "源码目录：$TOPDIR"
echo "=========================================="


# ============================================================
# 2. PassWall 源码替换
# ============================================================

echo "=========================================="
echo "替换 PassWall 源码"
echo "=========================================="

rm -rf package/network/utils/redsocks2
rm -rf package/network/utils/tcping
rm -rf package/network/utils/microsocks
rm -rf feeds/luci/applications/luci-app-passwall
rm -rf package/passwall-packages
rm -rf package/passwall-luci

git clone https://github.com/Openwrt-Passwall/openwrt-passwall-packages package/passwall-packages
git clone https://github.com/Openwrt-Passwall/openwrt-passwall package/passwall-luci


# ============================================================
# 3. Rust 编译配置修复
# ============================================================

echo "=========================================="
echo "修复 Rust 编译配置"
echo "=========================================="

RUST_MAKEFILE="feeds/packages/lang/rust/Makefile"

if [ -f "$RUST_MAKEFILE" ]; then
    sed -i 's/download-ci-llvm=true/download-ci-llvm=false/g' "$RUST_MAKEFILE"
fi


# ============================================================
# 4. Golang 源码更新（kenzok8）
# ============================================================

echo "=========================================="
echo "更新 Golang 源码"
echo "=========================================="

rm -rf feeds/packages/lang/golang

git clone -b 1.27 https://github.com/kenzok8/golang feeds/packages/lang/golang


# ============================================================
# 5. 更新并安装 feeds
# ============================================================

echo "=========================================="
echo "更新并安装 feeds"
echo "=========================================="

./scripts/feeds update rtp2http2 2>/dev/null || true
./scripts/feeds update rtp2httpd

./scripts/feeds install -p packages golang || true
./scripts/feeds install -f microsocks || true
./scripts/feeds install -a


# ============================================================
# 6. rtp2httpd 特殊来源锁定
#
# 唯一来源：
# feeds/rtp2httpd
# ============================================================

echo "=========================================="
echo "锁定 rtp2httpd 来源"
echo "=========================================="

RTP2HTTPD_PACKAGES="
rtp2httpd
luci-app-rtp2httpd
"

for pkg in $RTP2HTTPD_PACKAGES; do

    SRC="feeds/rtp2httpd/openwrt-support/${pkg}/Makefile"

    if [ ! -f "$SRC" ]; then
        echo "错误：rtp2httpd 源码不存在：$SRC"
        exit 1
    fi

    # 清理其他 feeds 中的同名安装入口
    for entry in package/feeds/*/"$pkg"; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue

        case "$entry" in
            package/feeds/rtp2httpd/*)
                ;;
            *)
                rm -f "$entry"
                ;;
        esac
    done

done

./scripts/feeds install -p rtp2httpd rtp2httpd luci-app-rtp2httpd

# 检查安装入口是否指向指定源码
for pkg in $RTP2HTTPD_PACKAGES; do

    LINK="package/feeds/rtp2httpd/${pkg}"
    SRC="feeds/rtp2httpd/openwrt-support/${pkg}"

    if [ ! -L "$LINK" ]; then
        echo "错误：rtp2httpd 安装入口不存在：$LINK"
        exit 1
    fi

    LINK_REAL="$(readlink -f "$LINK")"
    SRC_REAL="$(readlink -f "$SRC")"

    if [ "$LINK_REAL" != "$SRC_REAL" ]; then
        echo "错误：rtp2httpd 来源不正确：$pkg"
        exit 1
    fi

    # 检查是否存在其他 feed 的同名入口
    for entry in package/feeds/*/"$pkg"; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue

        case "$entry" in
            package/feeds/rtp2httpd/*)
                ;;
            *)
                echo "错误：发现其他 feed 的 rtp2httpd 同名入口：$entry"
                exit 1
                ;;
        esac
    done

done

echo "rtp2httpd 来源锁定完成"


# ============================================================
# 7. 第三方依赖预处理
# ============================================================

echo "=========================================="
echo "第三方依赖预处理"
echo "=========================================="

REMOVE_OFFICIAL_DEPS=""

OFFICIAL_FEEDS="
packages
luci
routing
telephony
store
third
"

THIRD_PARTY_FEEDS="
nas
nas_luci
jjm2473_apps
kenzo
small
"

# 检查软件包安装入口
package_entry_exists() {
    local pkg="$1"

    for entry in package/feeds/*/"$pkg"; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        return 0
    done

    return 1
}

# 删除指定软件包安装入口
remove_package_entry() {
    local pkg="$1"
    local feed="$2"
    local entry="package/feeds/${feed}/${pkg}"

    if [ -e "$entry" ] || [ -L "$entry" ]; then
        rm -f "$entry"
    fi
}

# 获取软件包 Makefile
package_makefile() {
    local feed="$1"
    local pkg="$2"

    if [ -f "feeds/${feed}/${pkg}/Makefile" ]; then
        echo "feeds/${feed}/${pkg}/Makefile"
        return 0
    fi

    if [ -f "feeds/${feed}/${pkg}/Makefile" ]; then
        echo "feeds/${feed}/${pkg}/Makefile"
        return 0
    fi

    return 1
}

# 检查配置是否启用
is_enabled() {
    local pkg="$1"

    grep -q "^CONFIG_PACKAGE_${pkg}=y" .config 2>/dev/null ||
    grep -q "^CONFIG_PACKAGE_${pkg}=m" .config 2>/dev/null
}

# 获取软件包版本
get_package_version() {
    local makefile="$1"

    if [ ! -f "$makefile" ]; then
        echo "未知"
        return
    fi

    local version

    version="$(grep -m1 '^PKG_VERSION:=' "$makefile" | cut -d= -f2-)"

    if [ -z "$version" ]; then
        version="$(grep -m1 '^PKG_RELEASE:=' "$makefile" | cut -d= -f2-)"
    fi

    echo "${version:-未知}"
}


# ============================================================
# 8. 清理指定官方依赖包
# ============================================================

echo "=========================================="
echo "清理官方依赖包"
echo "=========================================="

for pkg in $REMOVE_OFFICIAL_DEPS; do

    for feed in $OFFICIAL_FEEDS; do
        remove_package_entry "$pkg" "$feed"
    done

done


# ============================================================
# 9. dae / daed 特殊来源锁定
#
# 唯一来源：
# feeds/small
#
# 注意：
# luci-app-daede 不属于本段锁定范围
# ============================================================

echo "=========================================="
echo "锁定 dae / daed 来源"
echo "=========================================="

DAE_CORE_PACKAGES="
dae
daed
"

for pkg in $DAE_CORE_PACKAGES; do

    SRC="feeds/small/${pkg}/Makefile"

    if [ ! -f "$SRC" ]; then
        echo "错误：未找到 ${pkg} 指定源码：$SRC"
        exit 1
    fi

    # 检查 package/myapp 是否存在同名核心软件包定义
    if grep -R -nE "define Package/${pkg}([[:space:]]|$)" package/myapp 2>/dev/null; then
        echo "错误：package/myapp 中发现 ${pkg} 同名定义"
        exit 1
    fi

    # 清理所有 feeds 中的同名安装入口
    for entry in package/feeds/*/"$pkg"; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        rm -f "$entry"
    done

    mkdir -p package/feeds/small

    # 建立 small 专属安装入口
    ln -s "../../../feeds/small/${pkg}" "package/feeds/small/${pkg}"

    LINK="package/feeds/small/${pkg}"

    if [ ! -L "$LINK" ]; then
        echo "错误：${pkg} 安装入口创建失败"
        exit 1
    fi

    LINK_REAL="$(readlink -f "$LINK")"
    SRC_REAL="$(readlink -f "feeds/small/${pkg}")"

    if [ "$LINK_REAL" != "$SRC_REAL" ]; then
        echo "错误：${pkg} 来源不正确"
        exit 1
    fi

    VERSION="$(get_package_version "$SRC")"

    echo "${pkg} 来源：feeds/small"
    echo "${pkg} 版本：${VERSION}"

    # 检查其他 feed 是否存在同名入口
    for entry in package/feeds/*/"$pkg"; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue

        case "$entry" in
            package/feeds/small/*)
                ;;
            *)
                echo "错误：发现 ${pkg} 其他来源：$entry"
                exit 1
                ;;
        esac
    done

done

echo "dae / daed 来源锁定完成"


# ============================================================
# 10. H68K DTS 修改
# ============================================================

: '
H68K DTS 修改内容

原始文件：
$GITHUB_WORKSPACE/test-istore/diy/H68K-DTS Linux6.1-6.6.dts

此处保留原始注释代码，不执行。
'


# ============================================================
# 11. 扫描 package/myapp 中的独立第三方软件包
# ============================================================

echo "=========================================="
echo "扫描 package/myapp 软件包"
echo "=========================================="

MYAPP_PACKAGES="$(
    find package/myapp -name Makefile -type f -print0 2>/dev/null |
    xargs -0 -r grep -hE '^define Package/' |
    sed -E 's/^define Package\/([^[:space:]\\]+).*/\1/' |
    sort -u
)"

# 排除不符合软件包名称规则的条目
MYAPP_PACKAGES="$(
    printf '%s\n' "$MYAPP_PACKAGES" |
    grep -vE '\( ('*'|*'/'*' 2>/dev/null || true
)"

echo "package/myapp 软件包列表："
printf '%s\n' "$MYAPP_PACKAGES"


# ============================================================
# 12. 读取 .config 中启用的软件包
# ============================================================

echo "=========================================="
echo "读取 .config 软件包"
echo "=========================================="

if [ ! -f .config ]; then
    echo "错误：未找到 .config"
    exit 1
fi

CONFIG_PACKAGES="$(
    sed -nE \
        's/^CONFIG_PACKAGE_([^=]+)=(y|m)$/\1/p' \
        .config |
    sort -u
)"

echo "已启用软件包数量：$(printf '%s\n' "$CONFIG_PACKAGES" | grep -c . || true)"


# ============================================================
# 13. package/myapp 独立第三方源码优先
#
# 优先级最高：
# package/myapp > 所有 feeds
# ============================================================

echo "=========================================="
echo "处理 package/myapp 独立第三方源码"
echo "=========================================="

for pkg in $MYAPP_PACKAGES; do

    MYAPP_MAKEFILE="$(
        find "package/myapp" -path "*/${pkg}/Makefile" -type f -print -quit 2>/dev/null
    )"

    if [ -z "$MYAPP_MAKEFILE" ]; then
        continue
    fi

    VERSION="$(get_package_version "$MYAPP_MAKEFILE")"

    echo "独立源码：${pkg}"
    echo "源码路径：${MYAPP_MAKEFILE}"
    echo "软件版本：${VERSION}"

    # 删除第三方集合源中的同名安装入口
    for feed in $THIRD_PARTY_FEEDS; do
        remove_package_entry "$pkg" "$feed"
    done

    # 删除官方 feeds 中的同名安装入口
    for feed in $OFFICIAL_FEEDS; do
        remove_package_entry "$pkg" "$feed"
    done

done


# ============================================================
# 14. 第三方集合源优先于官方 feeds
#
# 优先级：
# package/myapp
#     >
# nas / nas_luci / jjm2473_apps / kenzo / small
#     >
# 官方 feeds
#
# dae / daed 已单独锁定，不参与本段处理
# ============================================================

echo "=========================================="
echo "处理第三方集合源优先级"
echo "=========================================="

for pkg in $CONFIG_PACKAGES; do

    # dae / daed 使用专门的来源锁定逻辑
    case "$pkg" in
        dae|daed)
            continue
            ;;
    esac

    # package/myapp 已经具有最高优先级
    if printf '%s\n' "$MYAPP_PACKAGES" | grep -Fxq "$pkg"; then
        continue
    fi

    THIRD_PARTY_SOURCE=""

    # 按照第三方集合源顺序寻找第一个有效来源
    for feed in $THIRD_PARTY_FEEDS; do

        MAKEFILE="feeds/${feed}/${pkg}/Makefile"

        if [ -f "$MAKEFILE" ]; then
            THIRD_PARTY_SOURCE="$feed"
            break
        fi

    done

    # 没有第三方来源则保留官方 feeds
    if [ -z "$THIRD_PARTY_SOURCE" ]; then
        continue
    fi

    THIRD_VERSION="$(
        get_package_version "feeds/${THIRD_PARTY_SOURCE}/${pkg}/Makefile"
    )"

    echo "第三方优先：${pkg}"
    echo "优先来源：${THIRD_PARTY_SOURCE}"
    echo "优先版本：${THIRD_VERSION}"

    # 删除所有官方 feeds 中的同名安装入口
    for feed in $OFFICIAL_FEEDS; do

        OFFICIAL_MAKEFILE="feeds/${feed}/${pkg}/Makefile"

        if [ -f "$OFFICIAL_MAKEFILE" ]; then

            OFFICIAL_VERSION="$(get_package_version "$OFFICIAL_MAKEFILE")"

            echo "清理官方来源：${feed}/${pkg}"
            echo "官方版本：${OFFICIAL_VERSION}"

            remove_package_entry "$pkg" "$feed"

        fi

    done

done


# ============================================================
# 15. SmartDNS Rust Makefile 路径修复
# ============================================================

echo "=========================================="
echo "修复 SmartDNS Rust Makefile"
echo "=========================================="

SMARTDNS_MAKEFILES="
package/myapp/smartdns/package/openwrt/Makefile
package/myapp/smartdns/Makefile
"

for file in $SMARTDNS_MAKEFILES; do

    if [ -f "$file" ]; then

        sed -i \
            's|include ../../lang/rust/rust-package.mk|include $(TOPDIR)/feeds/packages/lang/rust/rust-package.mk|g' \
            "$file"

        echo "已修复：$file"

    fi

done


# ============================================================
# 16. 自动添加 LuCI 中文语言包
# ============================================================

echo "=========================================="
echo "自动添加 LuCI 中文语言包"
echo "=========================================="

LUCI_APPS="$(
    sed -nE \
        's/^CONFIG_PACKAGE_(luci-app-[^=]+)=y$/\1/p' \
        .config |
    sort -u
)"

for pkg in $LUCI_APPS; do

    trans="luci-i18n-${pkg#luci-app-}-zh-cn"

    if grep -R -qE "Package.*${trans}" package feeds 2>/dev/null; then

        if ! grep -q "^CONFIG_PACKAGE_${trans}=y" .config; then

            echo "CONFIG_PACKAGE_${trans}=y" >> .config

            echo "添加中文语言包：${trans}"

        fi

    fi

done


# ============================================================
# 17. Conntrack 连接数配置
# ============================================================

echo "=========================================="
echo "设置 Conntrack 连接数"
echo "=========================================="

SYSCTL_FILE="package/base-files/files/etc/sysctl.conf"

mkdir -p "$(dirname "$SYSCTL_FILE")"

touch "$SYSCTL_FILE"

sed -i '/net\.netfilter\.nf_conntrack_max/d' "$SYSCTL_FILE"

echo "net.netfilter.nf_conntrack_max=655550" >> "$SYSCTL_FILE"


# ============================================================
# 18. Wi-Fi 首次启动自动启用
# ============================================================

echo "=========================================="
echo "配置 Wi-Fi 首次启动脚本"
echo "=========================================="

WIFI_SCRIPT="files/etc/uci-defaults/zz-enable-wifi"

mkdir -p "$(dirname "$WIFI_SCRIPT")"

cat > "$WIFI_SCRIPT" <<'EOF'
#!/bin/sh

# 等待无线配置文件生成
i=0

while [ ! -f /etc/config/wireless ] && [ "$i" -lt 30 ]; do
    sleep 1
    i=$((i + 1))
done

# 如果无线配置不存在，尝试生成
if [ ! -f /etc/config/wireless ]; then
    wifi config
fi

[ -f /etc/config/wireless ] || exit 0

. /lib/functions.sh

# 启用无线设备
enable_all() {
    local section="$1"
    uci set wireless."$section".disabled='0'
}

config_load wireless

config_foreach enable_all wifi-device
config_foreach enable_all wifi-iface

uci commit wireless

wifi up || wifi

exit 0
EOF

chmod +x "$WIFI_SCRIPT"


# ============================================================
# 19. 最终软件包来源检查
# ============================================================

echo "=========================================="
echo "最终软件包来源检查"
echo "=========================================="

# package/myapp 独立第三方软件包
for pkg in $MYAPP_PACKAGES; do

    MYAPP_MAKEFILE="$(
        find "package/myapp" -path "*/${pkg}/Makefile" -type f -print -quit 2>/dev/null
    )"

    [ -n "$MYAPP_MAKEFILE" ] || continue

    VERSION="$(get_package_version "$MYAPP_MAKEFILE")"

    echo "[MYAPP] ${pkg}"
    echo "  路径：${MYAPP_MAKEFILE}"
    echo "  版本：${VERSION}"

done


# dae / daed 最终来源检查
for pkg in $DAE_CORE_PACKAGES; do

    LINK="package/feeds/small/${pkg}"
    SRC="feeds/small/${pkg}"

    if [ ! -L "$LINK" ]; then
        echo "错误：${pkg} 安装入口不存在"
        exit 1
    fi

    if [ "$(readlink -f "$LINK")" != "$(readlink -f "$SRC")" ]; then
        echo "错误：${pkg} 最终来源不是 feeds/small"
        exit 1
    fi

    VERSION="$(get_package_version "${SRC}/Makefile")"

    echo "[DAE] ${pkg}"
    echo "  来源：feeds/small"
    echo "  版本：${VERSION}"

    for entry in package/feeds/*/"$pkg"; do

        [ -e "$entry" ] || [ -L "$entry" ] || continue

        case "$entry" in
            package/feeds/small/*)
                ;;
            *)
                echo "错误：${pkg} 存在其他来源：${entry}"
                exit 1
                ;;
        esac

    done

done


# rtp2httpd 最终来源检查
for pkg in $RTP2HTTPD_PACKAGES; do

    LINK="package/feeds/rtp2httpd/${pkg}"
    SRC="feeds/rtp2httpd/openwrt-support/${pkg}"

    if [ ! -L "$LINK" ]; then
        echo "错误：${pkg} 安装入口不存在"
        exit 1
    fi

    if [ "$(readlink -f "$LINK")" != "$(readlink -f "$SRC")" ]; then
        echo "错误：${pkg} 最终来源不是 feeds/rtp2httpd"
        exit 1
    fi

    echo "[RTP2HTTPD] ${pkg}"
    echo "  来源：feeds/rtp2httpd"

    for entry in package/feeds/*/"$pkg"; do

        [ -e "$entry" ] || [ -L "$entry" ] || continue

        case "$entry" in
            package/feeds/rtp2httpd/*)
                ;;
            *)
                echo "错误：${pkg} 存在其他来源：${entry}"
                exit 1
                ;;
        esac

    done

done

echo "所有特殊软件包来源检查通过"


# ============================================================
# 20. IPQ60xx 内核大小修改
# ============================================================

echo "=========================================="
echo "修改 IPQ60xx 内核大小"
echo "=========================================="

set_kernel_size() {

    local file="$1"
    local old="$2"
    local new="$3"

    if [ -f "$file" ]; then

        sed -i "s/${old}/${new}/g" "$file"

        echo "已修改：${file}"

    fi

}

IPQ60XX_FILE="target/linux/qualcommax/image/ipq60xx.mk"

if [ -f "$IPQ60XX_FILE" ]; then

    # emmc-common
    set_kernel_size "$IPQ60XX_FILE" \
        "KERNEL_SIZE := 6144k" \
        "KERNEL_SIZE := 12288k"

    # nand-common
    sed -i '/define Device\/nand-common/,/endef/ {
        /endef/i\
	KERNEL_SIZE := 8192k
    }' "$IPQ60XX_FILE"

    # JDCloud 设备
    set_kernel_size "$IPQ60XX_FILE" \
        "KERNEL_SIZE := 6144k" \
        "KERNEL_SIZE := 12288k"

    # Linksys MR
    set_kernel_size "$IPQ60XX_FILE" \
        "KERNEL_SIZE := 8192k" \
        "KERNEL_SIZE := 12288k"

    # Linksys MR7350
    sed -i '/define Device\/linksys_mr7350/,/endef/ {
        /endef/i\
	IMAGE_SIZE := 12288k
    }' "$IPQ60XX_FILE"

fi


# ============================================================
# 21. 启用 SKB Recycler
# ============================================================

echo "=========================================="
echo "启用 SKB Recycler"
echo "=========================================="

if [ -f .config ]; then

    sed -i \
        '/^CONFIG_KERNEL_SKB_RECYCLER=/d' \
        .config

    sed -i \
        '/^# CONFIG_KERNEL_SKB_RECYCLER is not set$/d' \
        .config

    cat >> .config <<'EOF'

CONFIG_KERNEL_SKB_RECYCLER=y
CONFIG_KERNEL_SKB_RECYCLER_MULTI_CPU=y
EOF

fi


# ============================================================
# 22. OpenAppFilter
# ============================================================

echo "=========================================="
echo "添加 OpenAppFilter"
echo "=========================================="

rm -rf feeds/packages/net/open-app-filter

git clone https://github.com/destan19/OpenAppFilter package/OpenAppFilter


# ============================================================
# 23. Golang 源码更新（sbwml）
#
# 保留原脚本后续覆盖行为
# ============================================================

echo "=========================================="
echo "更新 Golang 源码（sbwml）"
echo "=========================================="

rm -rf feeds/packages/lang/golang

git clone -b 26.x https://github.com/sbwml/packages_lang_golang feeds/packages/lang/golang


# ============================================================
# 24. OpenList
# ============================================================

echo "=========================================="
echo "添加 OpenList"
echo "=========================================="

git clone https://github.com/sbwml/luci-app-openlist2 package/openlist


# ============================================================
# 25. EasyTier
# ============================================================

echo "=========================================="
echo "添加 EasyTier"
echo "=========================================="

git clone https://github.com/EasyTier/luci-app-easytier package/luci-app-easytier


# ============================================================
# 26. Lucky
# ============================================================

echo "=========================================="
echo "添加 Lucky"
echo "=========================================="

git clone https://github.com/gdy666/luci-app-lucky package/lucky


# ============================================================
# 27. Nginx 配置
# ============================================================

echo "=========================================="
echo "配置 Nginx"
echo "=========================================="

NGINX_CONFIG="package/network/services/nginx-util/files/nginx.config"

mkdir -p "$(dirname "$NGINX_CONFIG")"

cat > "$NGINX_CONFIG" <<'EOF'
config main global
    option uci_enable 'true'

config server '_lan'
    option server_name '_lan'
    list listen '80 default_server'
    list listen '[::]:80 default_server'
    list include 'conf.d/*.locations'
    option access_log 'off; # logd openwrt'
EOF


# ============================================================
# 28. QuickFile
# ============================================================

echo "=========================================="
echo "添加 QuickFile"
echo "=========================================="

git clone https://github.com/sbwml/luci-app-quickfile package/quickfile


# ============================================================
# 29. LuCI Fluent 主题
# ============================================================

echo "=========================================="
echo "添加 LuCI Fluent 主题"
echo "=========================================="

git clone https://github.com/LazuliKao/luci-theme-fluent /tmp/luci-theme-fluent

cp -a /tmp/luci-theme-fluent/package/* package/


# ============================================================
# 30. LuCI Shadcn 主题
# ============================================================

echo "=========================================="
echo "添加 LuCI Shadcn 主题"
echo "=========================================="

git clone https://github.com/eamonxg/luci-theme-shadcn package/luci-theme-shadcn


# ============================================================
# 31. LuCI Argon 主题
# ============================================================

echo "=========================================="
echo "添加 LuCI Argon 主题"
echo "=========================================="

rm -rf feeds/luci/themes/luci-theme-argon

git clone https://github.com/jerrykuku/luci-theme-argon package/luci-theme-argon


# ============================================================
# 32. OpenClash Meta 核心
# ============================================================

echo "=========================================="
echo "下载 OpenClash Meta 核心"
echo "=========================================="

curl -L \
    https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz \
    -o /tmp/clash.tar.gz

tar -zxf /tmp/clash.tar.gz -C /tmp/

chmod +x /tmp/clash

mkdir -p feeds/luci/applications/luci-app-openclash/root/etc/openclash/core

mv /tmp/clash \
    feeds/luci/applications/luci-app-openclash/root/etc/openclash/core/clash_meta

rm -f /tmp/clash.tar.gz


# ============================================================
# 33. 删除 DDNS 示例配置
# ============================================================

echo "=========================================="
echo "清理 DDNS 示例配置"
echo "=========================================="

DDNS_CONFIG="feeds/packages/net/ddns-scripts/files/etc/config/ddns"

if [ -f "$DDNS_CONFIG" ]; then
    sed -i '/myddns_ipv4/,$d' "$DDNS_CONFIG"
fi


# ============================================================
# 34. MT7986A CPU 频率显示
# ============================================================

echo "=========================================="
echo "设置 MT7986A CPU 频率显示"
echo "=========================================="

CPUINFO_FILE="package/emortal/autocore/files/generic/cpuinfo"

if [ -f "$CPUINFO_FILE" ]; then

    sed -i '/"mediatek"\/\*|"mvebu"\/\*)/i "mediatek/filogic")\n\tcpu_freq="2.0GHz" ;;' \
        "$CPUINFO_FILE"

fi


# ============================================================
# 35. DIY2 执行完成
# ============================================================

echo "=========================================="
echo "DIY2 所有操作执行完成"
echo "=========================================="

exit 0
