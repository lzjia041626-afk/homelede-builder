#!/bin/bash

# ImmortalWrt HomeProxy 面板 sing-box 一键安装脚本
# 版本: 3.1 (纯净版+本地缓存)
# 适用于 ImmortalWrt 24.10+ / OpenWrt 23.05+

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置变量
SING_BOX_VERSION="1.12.17"
HOMEPROXY_DIR="/etc/homeproxy"
RULES_DIR="/etc/homeproxy/resources"
LOG_DIR="/var/log/homeproxy"

# 打印函数
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 显示菜单
show_menu() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  ImmortalWrt HomeProxy 面板管理脚本${NC}"
    echo -e "${BLUE}    sing-box ${SING_BOX_VERSION} + HomeProxy${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "${GREEN}1.${NC} 安装 HomeProxy 面板及内核"
    echo -e "${GREEN}2.${NC} 卸载 HomeProxy 面板"
    echo -e "${GREEN}3.${NC} 升级 sing-box 内核"
    echo -e "${GREEN}4.${NC} 启动 HomeProxy"
    echo -e "${GREEN}5.${NC} 停止 HomeProxy"
    echo -e "${GREEN}6.${NC} 重启 HomeProxy"
    echo -e "${GREEN}7.${NC} 查看运行状态"
    echo -e "${GREEN}8.${NC} 查看实时日志"
    echo -e "${GREEN}9.${NC} 更新地理数据库"
    echo -e "${GREEN}10.${NC} 重置配置"
    echo -e "${GREEN}11.${NC} 系统优化"
    echo -e "${GREEN}0.${NC} 退出脚本"
    echo ""
    echo -n -e "${YELLOW}请选择操作 [0-11]: ${NC}"
}

# 检查系统
check_system() {
    print_info "检查系统环境..."
    
    if [[ ! -f /etc/openwrt_release ]]; then
        print_error "这不是 ImmortalWrt/OpenWrt 系统"
        exit 1
    fi
    
    source /etc/openwrt_release
    print_success "检测到系统: $DISTRIB_DESCRIPTION"
    
    # 检查架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)      SING_ARCH="amd64" ;;
        aarch64)     SING_ARCH="arm64" ;;
        armv7l)      SING_ARCH="armv7" ;;
        mips)        SING_ARCH="mips" ;;
        mipsel)      SING_ARCH="mipsle" ;;
        *)
            print_error "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    
    print_info "系统架构: $ARCH -> sing-box 架构: $SING_ARCH"
    
    # 检查可用空间 (tmp 用于下载)
    AVAILABLE_SPACE=$(df /tmp | awk 'NR==2 {print $4}')
    if [[ $AVAILABLE_SPACE -lt 50000 ]]; then
        print_warning "可用空间不足 50MB，可能影响安装"
    fi
}

# 安装依赖包
install_dependencies() {
    print_info "更新软件包列表..."
    opkg update
    
    print_info "安装基础依赖..."
    opkg install curl wget-ssl unzip ca-certificates ca-bundle
    opkg install jsonfilter jq luci-lib-jsonc
    
    # 网络模块
    opkg install kmod-tun kmod-inet-diag
    opkg install kmod-nft-tproxy kmod-nft-socket
    opkg install nftables ip-full
    
    # LuCI 相关
    opkg install luci-base luci-lib-ip luci-lib-nixio
    
    print_success "依赖包安装完成"
}

# 从官方源安装 HomeProxy 面板 (无本地文件缓存，直接 opkg)
install_homeproxy() {
    print_info "从 ImmortalWrt 官方源安装 HomeProxy 面板..."
    opkg update
    opkg install luci-app-homeproxy luci-i18n-homeproxy-zh-cn || {
        print_error "安装失败，请检查软件源是否包含 homeproxy"
        return 1
    }
    print_success "HomeProxy 面板安装完成"
}

# 下载并安装 sing-box 官方内核 (支持本地缓存)
install_singbox() {
    local tarball="sing-box-${SING_BOX_VERSION}-linux-${SING_ARCH}.tar.gz"
    local url="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${tarball}"
    local cache_path="/tmp/${tarball}"
    
    print_info "准备 sing-box ${SING_BOX_VERSION} 内核..."
    cd /tmp || exit 1
    
    # 检查本地缓存
    if [[ -f "$cache_path" ]]; then
        print_info "发现本地缓存文件: $cache_path"
        # 可选：校验文件大小或 MD5（此处简单检查大小是否大于 1MB）
        local fsize=$(stat -c%s "$cache_path" 2>/dev/null || stat -f%z "$cache_path" 2>/dev/null || echo 0)
        if [[ $fsize -gt 1000000 ]]; then
            print_success "本地缓存有效，跳过下载"
        else
            print_warning "本地缓存文件过小，可能损坏，重新下载"
            rm -f "$cache_path"
        fi
    fi
    
    if [[ ! -f "$cache_path" ]]; then
        print_info "从官方 GitHub 下载: $url"
        wget -O "$cache_path" "$url" || {
            print_error "下载失败，请检查网络或手动下载"
            print_info "手动下载地址: $url"
            return 1
        }
        print_success "下载完成"
    fi
    
    print_info "解压安装..."
    tar -xzf "$cache_path"
    
    # 备份原有内核
    if [[ -f /usr/bin/sing-box ]]; then
        cp /usr/bin/sing-box /usr/bin/sing-box.backup
        print_info "已备份原有内核至 /usr/bin/sing-box.backup"
    fi
    
    # 安装新内核
    cp -f "sing-box-${SING_BOX_VERSION}-linux-${SING_ARCH}/sing-box" /usr/bin/sing-box
    chmod +x /usr/bin/sing-box
    
    # 验证版本
    INSTALLED_VERSION=$(/usr/bin/sing-box version 2>/dev/null | head -n1 || echo "未知")
    print_success "sing-box 安装完成: $INSTALLED_VERSION"
    
    # 清理解压目录，保留缓存文件供下次使用
    rm -rf "sing-box-${SING_BOX_VERSION}-linux-${SING_ARCH}"
    print_info "本地缓存文件保留于: $cache_path"
}

# 创建目录结构
create_directories() {
    print_info "创建目录结构..."
    
    mkdir -p "$HOMEPROXY_DIR"
    mkdir -p "$RULES_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "/etc/homeproxy/scripts"
    
    chmod 755 "$HOMEPROXY_DIR"
    chmod 755 "$RULES_DIR"
    chmod 755 "$LOG_DIR"
    
    print_success "目录创建完成"
}

# 下载地理数据库 (支持本地缓存)
download_geodata() {
    print_info "下载/更新地理数据库..."
    cd "$RULES_DIR" || exit 1
    
    # GeoIP (缓存检查)
    local geoip_cache="/tmp/geoip.db"
    if [[ -f "$geoip_cache" ]] && [[ $(find "$geoip_cache" -mtime -7 2>/dev/null) ]]; then
        print_info "使用本地缓存的 GeoIP 数据库 (7天内)"
        cp -f "$geoip_cache" geoip.db
    else
        print_info "下载 GeoIP 数据库 (官方 Release)..."
        wget -O geoip.db "https://github.com/SagerNet/sing-geoip/releases/latest/download/geoip.db" && {
            cp -f geoip.db "$geoip_cache"
            print_success "GeoIP 数据库更新完成"
        } || print_error "GeoIP 下载失败"
    fi
    
    # GeoSite (缓存检查)
    local geosite_cache="/tmp/geosite.db"
    if [[ -f "$geosite_cache" ]] && [[ $(find "$geosite_cache" -mtime -7 2>/dev/null) ]]; then
        print_info "使用本地缓存的 GeoSite 数据库 (7天内)"
        cp -f "$geosite_cache" geosite.db
    else
        print_info "下载 GeoSite 数据库 (官方 Release)..."
        wget -O geosite.db "https://github.com/SagerNet/sing-geosite/releases/latest/download/geosite.db" && {
            cp -f geosite.db "$geosite_cache"
            print_success "GeoSite 数据库更新完成"
        } || print_error "GeoSite 下载失败"
    fi
    
    # 中国大陆 IP 列表 (使用 JsDelivr CDN，带缓存)
    local chinap_cache="/tmp/china_ip4.txt"
    if [[ -f "$chinap_cache" ]] && [[ $(find "$chinap_cache" -mtime -7 2>/dev/null) ]]; then
        print_info "使用本地缓存的中国 IP 列表 (7天内)"
        cp -f "$chinap_cache" china_ip4.txt
    else
        print_info "下载中国大陆 IP 列表..."
        wget -O china_ip4.txt "https://cdn.jsdelivr.net/gh/17mon/china_ip_list@master/china_ip_list.txt" && {
            cp -f china_ip4.txt "$chinap_cache"
            print_success "中国 IP 列表更新完成"
        } || print_error "中国 IP 列表下载失败"
    fi
    
    print_success "地理数据库下载流程结束"
}

# 创建 UCI 配置 (无订阅部分)
create_uci_config() {
    print_info "创建 HomeProxy UCI 配置..."
    
    # 删除现有配置
    uci -q delete homeproxy 2>/dev/null || true
    
    # 创建基础配置
    uci set homeproxy=homeproxy
    uci set homeproxy.config=homeproxy
    uci set homeproxy.config.main_node='nil'
    uci set homeproxy.config.main_udp_node='nil'
    uci set homeproxy.config.dns_server='wan'
    uci set homeproxy.config.dns_port='5333'
    uci set homeproxy.config.routing_mode='bypass_mainland_china'
    uci set homeproxy.config.proxy_mode='redirect_tproxy'
    uci set homeproxy.config.ipv6_support='0'
    uci set homeproxy.config.auto_firewall='1'
    uci set homeproxy.config.wan_proxy_ipv4_ips='149.154.160.0/20 91.108.4.0/22 91.108.56.0/24 109.239.140.0/24'
    uci set homeproxy.config.wan_proxy_ipv6_ips=''
    uci set homeproxy.config.self_mark='100'
    
    # 提交配置
    uci commit homeproxy
    
    print_success "UCI 配置创建完成"
}

# 创建分流规则更新脚本
create_routing_script() {
    print_info "创建分流规则更新脚本..."
    
    cat > "/etc/homeproxy/scripts/update_rules.sh" << 'EOF'
#!/bin/bash

# HomeProxy 分流规则更新脚本

RULES_DIR="/etc/homeproxy/resources"
LOG_FILE="/var/log/homeproxy/update_rules.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

update_geoip() {
    log "更新 GeoIP 数据库..."
    cd "$RULES_DIR"
    wget -O geoip.db "https://github.com/SagerNet/sing-geoip/releases/latest/download/geoip.db" && log "GeoIP 更新成功" || log "GeoIP 更新失败"
}

update_geosite() {
    log "更新 GeoSite 数据库..."
    cd "$RULES_DIR"
    wget -O geosite.db "https://github.com/SagerNet/sing-geosite/releases/latest/download/geosite.db" && log "GeoSite 更新成功" || log "GeoSite 更新失败"
}

update_china_ip() {
    log "更新中国大陆 IP 列表..."
    cd "$RULES_DIR"
    wget -O china_ip4.txt "https://cdn.jsdelivr.net/gh/17mon/china_ip_list@master/china_ip_list.txt" && log "中国 IP 列表更新成功" || log "中国 IP 列表更新失败"
}

mkdir -p "$(dirname "$LOG_FILE")"
log "开始更新分流规则..."

update_geoip
update_geosite
update_china_ip

log "分流规则更新完成"

# 重启 HomeProxy 服务
/etc/init.d/homeproxy restart
log "HomeProxy 服务已重启"
EOF
    
    chmod +x "/etc/homeproxy/scripts/update_rules.sh"
    print_success "分流规则脚本创建完成"
}

# 系统优化 (防止重复写入)
optimize_system() {
    print_info "进行系统优化..."
    
    local sysctl_conf="/etc/sysctl.conf"
    local params=(
        "net.core.default_qdisc = fq"
        "net.ipv4.tcp_congestion_control = bbr"
        "net.core.rmem_max = 134217728"
        "net.core.wmem_max = 134217728"
        "net.ipv4.tcp_rmem = 4096 65536 134217728"
        "net.ipv4.tcp_wmem = 4096 65536 134217728"
        "net.ipv4.tcp_fastopen = 3"
        "net.ipv4.tcp_mtu_probing = 1"
        "net.ipv4.ip_forward = 1"
        "net.ipv6.conf.all.forwarding = 1"
    )
    
    for param in "${params[@]}"; do
        if ! grep -qF "$param" "$sysctl_conf" 2>/dev/null; then
            echo "$param" >> "$sysctl_conf"
        fi
    done
    
    sysctl -p 2>/dev/null
    print_success "内核参数优化完成"
    
    # 创建定时任务 (仅分流规则更新，无订阅)
    local cron_file="/etc/crontabs/root"
    local cron_job="0 4 * * 0 /etc/homeproxy/scripts/update_rules.sh"
    
    if ! grep -qF "/etc/homeproxy/scripts/update_rules.sh" "$cron_file" 2>/dev/null; then
        echo "$cron_job" >> "$cron_file"
        print_success "已添加定时任务 (每周日凌晨4点更新规则)"
        /etc/init.d/cron restart
    else
        print_info "定时任务已存在，跳过添加"
    fi
}

# 完整安装
full_install() {
    print_info "开始完整安装 HomeProxy 及 sing-box 内核..."
    
    check_system
    install_dependencies
    install_homeproxy
    install_singbox
    create_directories
    download_geodata
    create_uci_config
    create_routing_script
    optimize_system
    
    # 启动服务
    print_info "启动 HomeProxy 服务..."
    /etc/init.d/homeproxy enable
    /etc/init.d/homeproxy start
    
    print_success "HomeProxy 安装完成！"
    print_info ""
    print_info "访问地址: http://路由器IP/cgi-bin/luci/admin/services/homeproxy"
    print_info "默认用户名: root"
    print_info "默认密码: 路由器管理密码"
    print_info ""
    print_info "请手动添加节点或导入订阅链接"
    print_info ""
    print_info "日志文件: /var/log/homeproxy/"
    print_info "配置文件: /etc/config/homeproxy"
}

# 卸载 HomeProxy
uninstall_homeproxy() {
    print_warning "确定要完全卸载 HomeProxy 吗？(y/N)"
    read -r confirm
    if [[ $confirm != [yY] ]]; then
        print_info "取消卸载"
        return
    fi
    
    print_info "停止 HomeProxy 服务..."
    /etc/init.d/homeproxy stop 2>/dev/null || true
    /etc/init.d/homeproxy disable 2>/dev/null || true
    
    print_info "卸载 HomeProxy 包..."
    opkg remove luci-app-homeproxy --force-depends 2>/dev/null || true
    
    print_info "删除相关文件..."
    rm -rf "$HOMEPROXY_DIR"
    rm -rf "$LOG_DIR"
    rm -f /usr/bin/sing-box /usr/bin/sing-box.backup
    rm -f /tmp/geoip.db /tmp/geosite.db /tmp/china_ip4.txt
    rm -f /tmp/sing-box-*.tar.gz
    
    # 清理 UCI 配置
    uci -q delete homeproxy 2>/dev/null || true
    uci commit
    
    # 清理定时任务
    sed -i '/homeproxy/d' /etc/crontabs/root 2>/dev/null || true
    /etc/init.d/cron restart
    
    print_success "HomeProxy 卸载完成"
}

# 升级 sing-box 内核
upgrade_singbox() {
    print_info "升级 sing-box 内核到 ${SING_BOX_VERSION}..."
    /etc/init.d/homeproxy stop
    install_singbox
    /etc/init.d/homeproxy start
    print_success "sing-box 内核升级完成"
}

# 启动服务
start_homeproxy() {
    print_info "启动 HomeProxy 服务..."
    /etc/init.d/homeproxy start
    sleep 2
    check_status
}

# 停止服务
stop_homeproxy() {
    print_info "停止 HomeProxy 服务..."
    /etc/init.d/homeproxy stop
    print_success "HomeProxy 服务已停止"
}

# 重启服务
restart_homeproxy() {
    print_info "重启 HomeProxy 服务..."
    /etc/init.d/homeproxy restart
    sleep 2
    check_status
}

# 检查状态
check_status() {
    print_info "HomeProxy 服务状态:"
    
    if pgrep -f sing-box > /dev/null; then
        print_success "sing-box 进程运行中"
        ps | grep sing-box | grep -v grep
        
        print_info "监听端口:"
        if command -v ss &>/dev/null; then
            ss -tlnp | grep sing-box
        elif command -v netstat &>/dev/null; then
            netstat -tlnp | grep sing-box
        else
            print_warning "未找到 ss 或 netstat 命令，无法显示端口"
        fi
        
        print_info "内存使用:"
        ps aux | grep sing-box | grep -v grep | awk '{print "PID: "$2", CPU: "$3"%, MEM: "$4"%, CMD: "$11}'
    else
        print_error "sing-box 进程未运行"
    fi
    
    if [[ -f /var/etc/homeproxy/sing-box.json ]]; then
        print_info "配置文件: /var/etc/homeproxy/sing-box.json"
        print_info "配置文件大小: $(du -h /var/etc/homeproxy/sing-box.json | cut -f1)"
    else
        print_warning "配置文件不存在"
    fi
}

# 查看实时日志
view_logs() {
    print_info "查看 HomeProxy 实时日志 (按 Ctrl+C 退出):"
    echo ""
    
    if [[ -f /var/log/homeproxy/sing-box.log ]]; then
        tail -f /var/log/homeproxy/sing-box.log
    elif [[ -f /tmp/log/homeproxy.log ]]; then
        tail -f /tmp/log/homeproxy.log
    else
        print_warning "未找到日志文件，显示系统日志:"
        logread -f | grep homeproxy
    fi
}

# 更新地理数据库
update_geodata() {
    print_info "更新地理数据库..."
    /etc/homeproxy/scripts/update_rules.sh
    print_success "地理数据库更新完成"
}

# 重置配置
reset_config() {
    print_warning "确定要重置所有配置吗？这将删除所有节点和规则设置！(y/N)"
    read -r confirm
    if [[ $confirm != [yY] ]]; then
        print_info "取消重置"
        return
    fi
    
    print_info "停止服务..."
    /etc/init.d/homeproxy stop
    
    print_info "重置配置..."
    uci -q delete homeproxy 2>/dev/null || true
    rm -rf /var/etc/homeproxy/
    
    create_uci_config
    
    print_info "重启服务..."
    /etc/init.d/homeproxy start
    
    print_success "配置重置完成"
}

# 主菜单循环
main() {
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1) full_install ;;
            2) uninstall_homeproxy ;;
            3) upgrade_singbox ;;
            4) start_homeproxy ;;
            5) stop_homeproxy ;;
            6) restart_homeproxy ;;
            7) check_status ;;
            8) view_logs ;;
            9) update_geodata ;;
            10) reset_config ;;
            11) optimize_system ;;
            0) print_info "退出脚本"; exit 0 ;;
            *) print_error "无效选择，请重新输入" ;;
        esac
        
        echo ""
        echo -n "按回车键继续..."
        read -r
    done
}

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
    print_error "请使用 root 权限运行此脚本"
    exit 1
fi

# 启动主程序
main
