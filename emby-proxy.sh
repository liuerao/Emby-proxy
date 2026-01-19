#!/bin/bash

#===============================================================================
# Emby 全自动反向代理一键部署脚本 v2.0
# 支持: Nginx 反代 + SSL证书自动申请 + 自动续期
# 使用 acme.sh 申请证书（比 Certbot 更稳定）
#===============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_banner() {
    echo -e "${PURPLE}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║         Emby 全自动反向代理一键部署脚本 v2.0                  ║"
    echo "║         支持 Nginx + SSL (acme.sh) + 自动续期                 ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "请使用 root 用户运行此脚本"
        print_info "请执行: sudo -i 切换到 root 用户"
        exit 1
    fi
}

# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
    else
        print_error "不支持的操作系统"
        exit 1
    fi
    print_info "检测到系统: $OS $VERSION"
}

# 安装依赖
install_dependencies() {
    print_info "正在安装依赖..."
    
    case $OS in
        ubuntu|debian)
            apt update -y
            apt install -y nginx curl wget socat cron
            ;;
        centos|rhel|fedora|rocky|almalinux)
            if command -v dnf &> /dev/null; then
                dnf install -y epel-release
                dnf install -y nginx curl wget socat cronie
            else
                yum install -y epel-release
                yum install -y nginx curl wget socat cronie
            fi
            ;;
        *)
            print_error "不支持的操作系统: $OS"
            exit 1
            ;;
    esac
    
    print_success "依赖安装完成"
}

# 安装 acme.sh
install_acme() {
    print_info "安装 acme.sh..."
    
    if [ -f ~/.acme.sh/acme.sh ]; then
        print_info "acme.sh 已安装，更新中..."
        ~/.acme.sh/acme.sh --upgrade
    else
        curl https://get.acme.sh | sh -s email=$EMAIL
    fi
    
    # 设置默认 CA 为 Let's Encrypt
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    
    print_success "acme.sh 安装完成"
}

# 配置防火墙
configure_firewall() {
    print_info "配置防火墙..."
    
    # 检查 ufw
    if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
        ufw allow 80/tcp
        ufw allow 443/tcp
        print_success "UFW 防火墙已配置"
    fi
    
    # 检查 firewalld
    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https
        firewall-cmd --reload
        print_success "Firewalld 防火墙已配置"
    fi
    
    # iptables
    if command -v iptables &> /dev/null; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
    fi
}

# 获取用户输入
get_user_input() {
    echo ""
    print_info "请输入配置信息:"
    echo ""
    
    # 域名
    while true; do
        read -p "请输入你的域名 (例如: emby.example.com): " DOMAIN
        if [[ -n "$DOMAIN" ]]; then
            break
        fi
        print_error "域名不能为空"
    done
    
    # Emby 源站地址
    while true; do
        read -p "请输入 Emby 源站地址 (例如: 192.168.1.100 或 emby.source.com): " EMBY_HOST
        if [[ -n "$EMBY_HOST" ]]; then
            break
        fi
        print_error "源站地址不能为空"
    done
    
    # Emby 源站端口
    read -p "请输入 Emby 源站端口 [默认: 8096]: " EMBY_PORT
    EMBY_PORT=${EMBY_PORT:-8096}
    
    # 源站协议
    read -p "Emby 源站使用 HTTPS 吗? [y/N]: " EMBY_SSL
    EMBY_SSL=${EMBY_SSL:-N}
    if [[ "$EMBY_SSL" =~ ^[Yy]$ ]]; then
        EMBY_PROTO="https"
        # 如果是 HTTPS 且端口是默认的 8096，提示改为 443
        if [[ "$EMBY_PORT" == "8096" ]]; then
            read -p "源站是 HTTPS，端口是否为 443? [Y/n]: " USE_443
            USE_443=${USE_443:-Y}
            if [[ "$USE_443" =~ ^[Yy]$ ]]; then
                EMBY_PORT="443"
            fi
        fi
    else
        EMBY_PROTO="http"
    fi
    
    # 是否传递源站 Host（反代其他域名时需要）
    read -p "是否传递源站原始 Host 头? (反代其他域名时选 y) [y/N]: " PASS_HOST
    PASS_HOST=${PASS_HOST:-N}
    if [[ "$PASS_HOST" =~ ^[Yy]$ ]]; then
        PROXY_HOST="$EMBY_HOST"
    else
        PROXY_HOST="\\\$host"
    fi
    
    # 邮箱 (用于 SSL 证书)
    while true; do
        read -p "请输入邮箱 (用于 SSL 证书申请): " EMAIL
        if [[ -n "$EMAIL" && "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        fi
        print_error "请输入有效的邮箱地址"
    done
    
    # 是否启用 SSL
    read -p "是否启用 SSL (HTTPS)? [Y/n]: " ENABLE_SSL
    ENABLE_SSL=${ENABLE_SSL:-Y}
    
    # 确认信息
    echo ""
    print_info "配置信息确认:"
    echo "  域名: $DOMAIN"
    echo "  Emby 源站: $EMBY_PROTO://$EMBY_HOST:$EMBY_PORT"
    echo "  邮箱: $EMAIL"
    echo "  启用 SSL: $ENABLE_SSL"
    echo ""
    
    read -p "确认以上信息正确? [Y/n]: " CONFIRM
    CONFIRM=${CONFIRM:-Y}
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_warning "已取消，请重新运行脚本"
        exit 0
    fi
}

# 创建 Nginx HTTP 配置（用于证书申请）
create_nginx_config_http() {
    print_info "创建 Nginx HTTP 配置..."
    
    # 创建目录
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled
    mkdir -p /var/www/html/.well-known/acme-challenge
    
    # 如果源站是 HTTPS，添加 SSL/SNI 配置（支持 Cloudflare 等 CDN）
    if [[ "$EMBY_PROTO" == "https" ]]; then
        SSL_PROXY_CONFIG="
    # HTTPS 源站配置 (支持 Cloudflare/SNI)
    proxy_ssl_verify off;
    proxy_ssl_server_name on;
    proxy_ssl_protocols TLSv1.2 TLSv1.3;"
    else
        SSL_PROXY_CONFIG=""
    fi

    cat > /etc/nginx/sites-available/emby << EOF
# Emby 反向代理配置 - HTTP
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # acme.sh 验证目录
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # 日志
    access_log /var/log/nginx/emby_access.log;
    error_log /var/log/nginx/emby_error.log;

    # 客户端设置
    client_max_body_size 20G;
    client_body_buffer_size 512k;

    # 代理缓冲设置
    proxy_buffering off;
    proxy_buffer_size 8k;

    # 超时设置
    proxy_connect_timeout 600s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;
    send_timeout 600s;
$SSL_PROXY_CONFIG

    location / {
        proxy_pass $EMBY_PROTO://$EMBY_HOST;
        
        proxy_set_header Host $PROXY_HOST;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_cache_bypass \$http_upgrade;
    }

    location /embywebsocket {
        proxy_pass $EMBY_PROTO://$EMBY_HOST;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $PROXY_HOST;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location ~* ^/videos/.*\$ {
        proxy_pass $EMBY_PROTO://$EMBY_HOST;
        proxy_set_header Host $PROXY_HOST;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }

    location ~* ^/Items/.*/Images/.*\$ {
        proxy_pass $EMBY_PROTO://$EMBY_HOST;
        proxy_set_header Host $PROXY_HOST;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_cache_valid 200 30d;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
EOF

    print_success "Nginx HTTP 配置创建完成"
}

# 创建 Nginx HTTPS 配置
create_nginx_config_https() {
    print_info "创建 Nginx HTTPS 配置..."
    
    # 如果源站是 HTTPS，添加 SSL/SNI 配置（支持 Cloudflare 等 CDN）
    if [[ "$EMBY_PROTO" == "https" ]]; then
        SSL_PROXY_CONFIG="
    # HTTPS 源站配置 (支持 Cloudflare/SNI)
    proxy_ssl_verify off;
    proxy_ssl_server_name on;
    proxy_ssl_protocols TLSv1.2 TLSv1.3;"
    else
        SSL_PROXY_CONFIG=""
    fi

    cat > /etc/nginx/sites-available/emby << EOF
# Emby 反向代理配置 - HTTPS

# HTTP 重定向到 HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    
    # acme.sh 续期验证
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS 配置
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    # SSL 证书 (acme.sh)
    ssl_certificate /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/privkey.pem;
    
    # SSL 优化配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    
    # HSTS
    add_header Strict-Transport-Security "max-age=63072000" always;

    # 日志
    access_log /var/log/nginx/emby_access.log;
    error_log /var/log/nginx/emby_error.log;

    # 客户端设置
    client_max_body_size 20G;
    client_body_buffer_size 512k;

    # 代理缓冲设置
    proxy_buffering off;
    proxy_buffer_size 8k;

    # 超时设置
    proxy_connect_timeout 600s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;
    send_timeout 600s;
$SSL_PROXY_CONFIG

    location / {
        proxy_pass $EMBY_PROTO://$EMBY_HOST;
        
        proxy_set_header Host $PROXY_HOST;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_cache_bypass \$http_upgrade;
    }

    location /embywebsocket {
        proxy_pass $EMBY_PROTO://$EMBY_HOST;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $PROXY_HOST;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location ~* ^/videos/.*\$ {
        proxy_pass $EMBY_PROTO://$EMBY_HOST;
        proxy_set_header Host $PROXY_HOST;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }

    location ~* ^/Items/.*/Images/.*\$ {
        proxy_pass $EMBY_PROTO://$EMBY_HOST;
        proxy_set_header Host $PROXY_HOST;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_cache_valid 200 30d;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
EOF

    print_success "Nginx HTTPS 配置创建完成"
}

# 启用站点配置
enable_site() {
    print_info "启用站点配置..."
    
    # 检查 nginx.conf 是否包含 sites-enabled
    if ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
        # 在 http 块中添加 include
        sed -i '/http {/a\    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
    fi
    
    # 删除默认站点
    rm -f /etc/nginx/sites-enabled/default
    
    # 创建符号链接
    ln -sf /etc/nginx/sites-available/emby /etc/nginx/sites-enabled/emby
    
    # 测试配置
    nginx -t
    
    print_success "站点配置已启用"
}

# 使用 acme.sh 申请 SSL 证书
obtain_ssl_certificate() {
    print_info "申请 SSL 证书 (使用 acme.sh)..."
    
    # 创建证书目录
    mkdir -p /etc/nginx/ssl/$DOMAIN
    
    # 确保 nginx 正在运行
    systemctl restart nginx
    sleep 2
    
    # 使用 webroot 方式申请证书
    ~/.acme.sh/acme.sh --issue \
        -d $DOMAIN \
        --webroot /var/www/html \
        --keylength ec-256 \
        --force
    
    if [ $? -ne 0 ]; then
        print_warning "webroot 方式失败，尝试 standalone 方式..."
        
        # 停止 nginx，使用 standalone 方式
        systemctl stop nginx
        
        ~/.acme.sh/acme.sh --issue \
            -d $DOMAIN \
            --standalone \
            --keylength ec-256 \
            --force
        
        if [ $? -ne 0 ]; then
            print_error "SSL 证书申请失败"
            print_info "请检查:"
            print_info "  1. 域名是否正确解析到此服务器 IP"
            print_info "  2. 80 端口是否被占用或被防火墙阻止"
            print_info "  3. 可以运行: curl -I http://$DOMAIN 测试"
            systemctl start nginx
            exit 1
        fi
    fi
    
    # 安装证书到 nginx 目录
    ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
        --key-file /etc/nginx/ssl/$DOMAIN/privkey.pem \
        --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
        --reloadcmd "systemctl reload nginx"
    
    print_success "SSL 证书申请并安装成功"
}

# 启动服务
start_services() {
    print_info "启动服务..."
    
    systemctl enable nginx
    systemctl restart nginx
    
    if systemctl is-active --quiet nginx; then
        print_success "Nginx 服务已启动"
    else
        print_error "Nginx 启动失败"
        systemctl status nginx
        exit 1
    fi
}

# 显示完成信息
show_completion_info() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    部署完成！                                 ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    if [[ "$ENABLE_SSL" =~ ^[Yy]$ ]]; then
        echo -e "  ${CYAN}访问地址:${NC} https://$DOMAIN"
    else
        echo -e "  ${CYAN}访问地址:${NC} http://$DOMAIN"
    fi
    
    echo ""
    echo -e "  ${CYAN}配置文件:${NC} /etc/nginx/sites-available/emby"
    echo -e "  ${CYAN}访问日志:${NC} /var/log/nginx/emby_access.log"
    echo -e "  ${CYAN}错误日志:${NC} /var/log/nginx/emby_error.log"
    echo ""
    echo -e "  ${YELLOW}常用命令:${NC}"
    echo "    重启 Nginx:    systemctl restart nginx"
    echo "    查看状态:      systemctl status nginx"
    echo "    查看日志:      tail -f /var/log/nginx/emby_error.log"
    echo "    测试配置:      nginx -t"
    echo ""
    
    if [[ "$ENABLE_SSL" =~ ^[Yy]$ ]]; then
        echo -e "  ${YELLOW}SSL 证书 (acme.sh):${NC}"
        echo "    证书路径:      /etc/nginx/ssl/$DOMAIN/"
        echo "    查看证书:      ~/.acme.sh/acme.sh --list"
        echo "    手动续期:      ~/.acme.sh/acme.sh --renew -d $DOMAIN --force"
        echo "    自动续期:      已配置 (acme.sh 自动处理)"
        echo ""
    fi
    
    print_success "Emby 反向代理部署完成！"
}

# 卸载功能 - 仅卸载配置
uninstall_config() {
    print_warning "开始卸载 Emby 反向代理配置..."
    
    # 停止服务
    systemctl stop nginx 2>/dev/null || true
    
    # 删除配置文件
    rm -f /etc/nginx/sites-available/emby
    rm -f /etc/nginx/sites-enabled/emby
    rm -rf /etc/nginx/ssl
    
    # 恢复默认配置
    if [ -f /etc/nginx/sites-available/default ]; then
        ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
    fi
    
    # 重启 nginx
    systemctl start nginx 2>/dev/null || true
    
    print_success "Emby 反向代理配置已卸载"
    print_info "Nginx 和 acme.sh 保留，如需完全卸载请选择「完全卸载」"
}

# 完全卸载 - 包括 Nginx 和 acme.sh
uninstall_all() {
    print_warning "开始完全卸载 (Nginx + acme.sh + 所有配置)..."
    
    echo ""
    print_warning "此操作将卸载以下组件:"
    echo "  - Nginx 及其所有配置"
    echo "  - acme.sh 及其所有证书"
    echo "  - Emby 反向代理配置"
    echo ""
    
    read -p "确定要完全卸载吗? 输入 'YES' 确认: " CONFIRM
    if [[ "$CONFIRM" != "YES" ]]; then
        print_info "已取消卸载"
        return
    fi
    
    print_info "正在停止服务..."
    
    # 停止 Nginx
    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
    
    # 卸载 acme.sh
    print_info "正在卸载 acme.sh..."
    if [ -f ~/.acme.sh/acme.sh ]; then
        # 撤销所有证书的续期任务
        ~/.acme.sh/acme.sh --uninstall 2>/dev/null || true
        rm -rf ~/.acme.sh
        print_success "acme.sh 已卸载"
    else
        print_info "acme.sh 未安装，跳过"
    fi
    
    # 删除 acme.sh 的 cron 任务
    crontab -l 2>/dev/null | grep -v "acme.sh" | crontab - 2>/dev/null || true
    
    # 卸载 Nginx
    print_info "正在卸载 Nginx..."
    
    # 检测系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
    fi
    
    case $OS in
        ubuntu|debian)
            apt remove -y nginx nginx-common nginx-full 2>/dev/null || true
            apt purge -y nginx nginx-common nginx-full 2>/dev/null || true
            apt autoremove -y 2>/dev/null || true
            ;;
        centos|rhel|fedora|rocky|almalinux)
            if command -v dnf &> /dev/null; then
                dnf remove -y nginx 2>/dev/null || true
            else
                yum remove -y nginx 2>/dev/null || true
            fi
            ;;
        *)
            print_warning "无法自动卸载 Nginx，请手动卸载"
            ;;
    esac
    
    # 删除 Nginx 配置和日志目录
    print_info "正在清理配置文件..."
    rm -rf /etc/nginx
    rm -rf /var/log/nginx
    rm -rf /var/www/html/.well-known
    
    # 删除 SSL 证书目录
    rm -rf /etc/nginx/ssl
    
    echo ""
    print_success "╔═══════════════════════════════════════════════════════════════╗"
    print_success "║                    完全卸载完成！                             ║"
    print_success "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  已卸载:"
    echo "    ✓ Nginx"
    echo "    ✓ acme.sh"
    echo "    ✓ SSL 证书"
    echo "    ✓ Emby 反向代理配置"
    echo ""
}

# 卸载菜单
uninstall_menu() {
    echo ""
    print_warning "请选择卸载方式:"
    echo ""
    echo "  1) 仅卸载 Emby 配置 (保留 Nginx 和 acme.sh)"
    echo "  2) 完全卸载 (Nginx + acme.sh + 所有配置)"
    echo "  0) 返回主菜单"
    echo ""
    
    read -p "请输入选项 [0-2]: " UNINSTALL_OPTION
    
    case $UNINSTALL_OPTION in
        1)
            read -p "确定要卸载 Emby 配置吗? [y/N]: " CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                uninstall_config
            else
                print_info "已取消"
            fi
            ;;
        2)
            uninstall_all
            ;;
        0)
            main_menu
            ;;
        *)
            print_error "无效选项"
            uninstall_menu
            ;;
    esac
}

# 主菜单
main_menu() {
    echo "请选择操作:"
    echo ""
    echo "  1) 安装 Emby 反向代理"
    echo "  2) 卸载"
    echo "  3) 重新配置"
    echo "  4) 查看状态"
    echo "  5) 仅申请/续期 SSL 证书"
    echo "  6) 查看当前配置"
    echo "  0) 退出"
    echo ""
    
    read -p "请输入选项 [0-6]: " OPTION
    
    case $OPTION in
        1)
            install_proxy
            ;;
        2)
            uninstall_menu
            ;;
        3)
            install_proxy
            ;;
        4)
            show_status
            ;;
        5)
            renew_ssl_only
            ;;
        6)
            show_current_config
            ;;
        0)
            exit 0
            ;;
        *)
            print_error "无效选项"
            main_menu
            ;;
    esac
}

# 仅申请/续期 SSL
renew_ssl_only() {
    check_root
    
    read -p "请输入域名: " DOMAIN
    read -p "请输入邮箱: " EMAIL
    
    install_acme
    
    mkdir -p /etc/nginx/ssl/$DOMAIN
    
    ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --keylength ec-256 --force
    
    ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
        --key-file /etc/nginx/ssl/$DOMAIN/privkey.pem \
        --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
        --reloadcmd "systemctl reload nginx"
    
    print_success "证书已更新"
}

# 查看状态
show_status() {
    echo ""
    print_info "========== 服务状态 =========="
    echo ""
    
    # Nginx 状态
    echo -e "${CYAN}Nginx 状态:${NC}"
    if systemctl is-active --quiet nginx; then
        echo -e "  状态: ${GREEN}运行中${NC}"
    else
        echo -e "  状态: ${RED}未运行${NC}"
    fi
    
    if systemctl is-enabled --quiet nginx 2>/dev/null; then
        echo -e "  开机启动: ${GREEN}已启用${NC}"
    else
        echo -e "  开机启动: ${YELLOW}未启用${NC}"
    fi
    echo ""
    
    # acme.sh 状态
    echo -e "${CYAN}acme.sh 状态:${NC}"
    if [ -f ~/.acme.sh/acme.sh ]; then
        echo -e "  状态: ${GREEN}已安装${NC}"
        echo "  证书列表:"
        ~/.acme.sh/acme.sh --list 2>/dev/null | head -20 || echo "    无证书"
    else
        echo -e "  状态: ${YELLOW}未安装${NC}"
    fi
    echo ""
    
    # 端口监听
    echo -e "${CYAN}端口监听:${NC}"
    if command -v ss &> /dev/null; then
        ss -tlnp | grep -E ':80|:443' | head -5 || echo "  未检测到 80/443 端口监听"
    elif command -v netstat &> /dev/null; then
        netstat -tlnp | grep -E ':80|:443' | head -5 || echo "  未检测到 80/443 端口监听"
    fi
    echo ""
    
    # 配置文件
    echo -e "${CYAN}配置文件:${NC}"
    if [ -f /etc/nginx/sites-available/emby ]; then
        echo -e "  Emby 配置: ${GREEN}存在${NC}"
    else
        echo -e "  Emby 配置: ${YELLOW}不存在${NC}"
    fi
    
    if [ -d /etc/nginx/ssl ] && [ "$(ls -A /etc/nginx/ssl 2>/dev/null)" ]; then
        echo -e "  SSL 证书: ${GREEN}已配置${NC}"
        ls /etc/nginx/ssl/ 2>/dev/null | while read dir; do
            echo "    - $dir"
        done
    else
        echo -e "  SSL 证书: ${YELLOW}未配置${NC}"
    fi
    echo ""
}

# 查看当前配置
show_current_config() {
    echo ""
    print_info "========== 当前配置 =========="
    echo ""
    
    if [ -f /etc/nginx/sites-available/emby ]; then
        echo -e "${CYAN}Nginx 配置文件: /etc/nginx/sites-available/emby${NC}"
        echo "----------------------------------------"
        cat /etc/nginx/sites-available/emby
        echo "----------------------------------------"
    else
        print_warning "未找到 Emby 配置文件"
    fi
    echo ""
}

# 安装主流程
install_proxy() {
    check_root
    detect_os
    get_user_input
    install_dependencies
    configure_firewall
    
    if [[ "$ENABLE_SSL" =~ ^[Yy]$ ]]; then
        # 先创建 HTTP 配置用于证书验证
        create_nginx_config_http
        enable_site
        start_services
        
        # 安装 acme.sh 并申请证书
        install_acme
        obtain_ssl_certificate
        
        # 更新为 HTTPS 配置
        create_nginx_config_https
        start_services
    else
        create_nginx_config_http
        enable_site
        start_services
    fi
    
    show_completion_info
}

# 显示帮助
show_help() {
    echo "Emby 反向代理一键部署脚本 v2.0"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -i, --install       直接安装 (跳过菜单)"
    echo "  -u, --uninstall     卸载 Emby 配置 (保留 Nginx)"
    echo "  --uninstall-all     完全卸载 (Nginx + acme.sh + 配置)"
    echo "  -s, --status        查看状态"
    echo "  -h, --help          显示此帮助"
    echo ""
    echo "示例:"
    echo "  $0                  显示交互式菜单"
    echo "  $0 -i               直接开始安装"
    echo "  $0 --uninstall-all  完全卸载所有组件"
    echo ""
}

# 脚本入口
main() {
    print_banner
    
    # 检查参数
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -i|--install)
            install_proxy
            exit 0
            ;;
        -u|--uninstall)
            check_root
            read -p "确定要卸载 Emby 配置吗? [y/N]: " CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                uninstall_config
            fi
            exit 0
            ;;
        --uninstall-all)
            check_root
            uninstall_all
            exit 0
            ;;
        -s|--status)
            show_status
            exit 0
            ;;
        "")
            # 无参数，显示主菜单
            main_menu
            ;;
        *)
            print_error "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
