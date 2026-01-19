#!/bin/bash

#===============================================================================
# Emby 全自动反向代理一键部署脚本
# 支持: Nginx 反代 + SSL证书自动申请 + 自动续期
# 作者: Auto Generated
# 使用: bash <(curl -sL https://your-domain.com/emby-proxy.sh)
#===============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 打印带颜色的信息
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
    echo "║         Emby 全自动反向代理一键部署脚本 v1.0                  ║"
    echo "║         支持 Nginx + SSL + 自动续期                          ║"
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
            apt install -y nginx certbot python3-certbot-nginx curl wget
            ;;
        centos|rhel|fedora|rocky|almalinux)
            if [ "$OS" = "centos" ] && [ "${VERSION%%.*}" -ge 8 ]; then
                dnf install -y epel-release
                dnf install -y nginx certbot python3-certbot-nginx curl wget
            else
                yum install -y epel-release
                yum install -y nginx certbot python3-certbot-nginx curl wget
            fi
            ;;
        *)
            print_error "不支持的操作系统: $OS"
            exit 1
            ;;
    esac
    
    print_success "依赖安装完成"
}

# 配置防火墙
configure_firewall() {
    print_info "配置防火墙..."
    
    # 检查 ufw
    if command -v ufw &> /dev/null; then
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw allow $PROXY_PORT/tcp 2>/dev/null || true
        print_success "UFW 防火墙已配置"
    fi
    
    # 检查 firewalld
    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https
        firewall-cmd --permanent --add-port=$PROXY_PORT/tcp 2>/dev/null || true
        firewall-cmd --reload
        print_success "Firewalld 防火墙已配置"
    fi
    
    # 检查 iptables
    if command -v iptables &> /dev/null; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport $PROXY_PORT -j ACCEPT 2>/dev/null || true
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
    
    # 反代端口
    read -p "请输入反代监听端口 [默认: 443]: " PROXY_PORT
    PROXY_PORT=${PROXY_PORT:-443}
    
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
    echo "  Emby 源站: $EMBY_HOST:$EMBY_PORT"
    echo "  反代端口: $PROXY_PORT"
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

# 创建 Nginx 配置 (HTTP)
create_nginx_config_http() {
    print_info "创建 Nginx HTTP 配置..."
    
    cat > /etc/nginx/sites-available/emby << 'NGINX_EOF'
# Emby 反向代理配置 - HTTP
upstream emby_backend {
    server EMBY_HOST_PLACEHOLDER:EMBY_PORT_PLACEHOLDER;
    keepalive 32;
}

server {
    listen 80;
    listen [::]:80;
    server_name DOMAIN_PLACEHOLDER;

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

    location / {
        proxy_pass http://emby_backend;
        
        # 代理头设置
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 缓存设置
        proxy_cache_bypass $http_upgrade;
    }

    # WebSocket 专用路径
    location /embywebsocket {
        proxy_pass http://emby_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # 视频流优化
    location ~* ^/videos/.*$ {
        proxy_pass http://emby_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }

    # 图片缓存
    location ~* ^/Items/.*/Images/.*$ {
        proxy_pass http://emby_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_cache_valid 200 30d;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
NGINX_EOF

    # 替换占位符
    sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" /etc/nginx/sites-available/emby
    sed -i "s/EMBY_HOST_PLACEHOLDER/$EMBY_HOST/g" /etc/nginx/sites-available/emby
    sed -i "s/EMBY_PORT_PLACEHOLDER/$EMBY_PORT/g" /etc/nginx/sites-available/emby
    
    print_success "Nginx HTTP 配置创建完成"
}

# 创建 Nginx 配置 (HTTPS)
create_nginx_config_https() {
    print_info "创建 Nginx HTTPS 配置..."
    
    cat > /etc/nginx/sites-available/emby << 'NGINX_EOF'
# Emby 反向代理配置 - HTTPS
upstream emby_backend {
    server EMBY_HOST_PLACEHOLDER:EMBY_PORT_PLACEHOLDER;
    keepalive 32;
}

# HTTP 重定向到 HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name DOMAIN_PLACEHOLDER;
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS 配置
server {
    listen PROXY_PORT_PLACEHOLDER ssl http2;
    listen [::]:PROXY_PORT_PLACEHOLDER ssl http2;
    server_name DOMAIN_PLACEHOLDER;

    # SSL 证书
    ssl_certificate /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/privkey.pem;
    
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

    location / {
        proxy_pass http://emby_backend;
        
        # 代理头设置
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 缓存设置
        proxy_cache_bypass $http_upgrade;
    }

    # WebSocket 专用路径
    location /embywebsocket {
        proxy_pass http://emby_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # 视频流优化
    location ~* ^/videos/.*$ {
        proxy_pass http://emby_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }

    # 图片缓存
    location ~* ^/Items/.*/Images/.*$ {
        proxy_pass http://emby_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_cache_valid 200 30d;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
NGINX_EOF

    # 替换占位符
    sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" /etc/nginx/sites-available/emby
    sed -i "s/EMBY_HOST_PLACEHOLDER/$EMBY_HOST/g" /etc/nginx/sites-available/emby
    sed -i "s/EMBY_PORT_PLACEHOLDER/$EMBY_PORT/g" /etc/nginx/sites-available/emby
    sed -i "s/PROXY_PORT_PLACEHOLDER/$PROXY_PORT/g" /etc/nginx/sites-available/emby
    
    print_success "Nginx HTTPS 配置创建完成"
}

# 启用站点配置
enable_site() {
    print_info "启用站点配置..."
    
    # 创建 sites-enabled 目录（如果不存在）
    mkdir -p /etc/nginx/sites-enabled
    
    # 检查 nginx.conf 是否包含 sites-enabled
    if ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
        # 在 http 块中添加 include
        sed -i '/http {/a\    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
    fi
    
    # 删除默认站点（如果存在）
    rm -f /etc/nginx/sites-enabled/default
    
    # 创建符号链接
    ln -sf /etc/nginx/sites-available/emby /etc/nginx/sites-enabled/emby
    
    # 测试配置
    nginx -t
    
    print_success "站点配置已启用"
}

# 申请 SSL 证书
obtain_ssl_certificate() {
    print_info "申请 SSL 证书..."
    
    # 先启动 nginx 用于验证
    systemctl start nginx || true
    
    # 申请证书
    certbot certonly --nginx -d $DOMAIN --email $EMAIL --agree-tos --non-interactive --redirect
    
    if [ $? -eq 0 ]; then
        print_success "SSL 证书申请成功"
    else
        print_error "SSL 证书申请失败，请检查域名解析是否正确"
        exit 1
    fi
}

# 配置证书自动续期
setup_auto_renewal() {
    print_info "配置证书自动续期..."
    
    # 创建续期脚本
    cat > /etc/cron.d/certbot-renew << 'CRON_EOF'
# 每天凌晨 3 点检查并续期证书
0 3 * * * root certbot renew --quiet --post-hook "systemctl reload nginx"
CRON_EOF
    
    # 测试续期
    certbot renew --dry-run
    
    print_success "证书自动续期已配置"
}

# 启动服务
start_services() {
    print_info "启动服务..."
    
    # 启用并启动 nginx
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
        echo -e "  ${YELLOW}SSL 证书:${NC}"
        echo "    证书路径:      /etc/letsencrypt/live/$DOMAIN/"
        echo "    手动续期:      certbot renew"
        echo "    自动续期:      已配置 (每天凌晨 3 点检查)"
        echo ""
    fi
    
    print_success "Emby 反向代理部署完成！"
}

# 卸载功能
uninstall() {
    print_warning "开始卸载 Emby 反向代理..."
    
    read -p "确定要卸载吗? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_info "已取消卸载"
        exit 0
    fi
    
    # 停止服务
    systemctl stop nginx 2>/dev/null || true
    
    # 删除配置文件
    rm -f /etc/nginx/sites-available/emby
    rm -f /etc/nginx/sites-enabled/emby
    
    # 删除证书续期任务
    rm -f /etc/cron.d/certbot-renew
    
    print_success "卸载完成"
    print_info "注意: Nginx 和 Certbot 未被卸载，如需卸载请手动执行"
}

# 主菜单
main_menu() {
    print_banner
    
    echo "请选择操作:"
    echo ""
    echo "  1) 安装 Emby 反向代理"
    echo "  2) 卸载 Emby 反向代理"
    echo "  3) 重新配置"
    echo "  4) 查看状态"
    echo "  0) 退出"
    echo ""
    
    read -p "请输入选项 [0-4]: " OPTION
    
    case $OPTION in
        1)
            install_proxy
            ;;
        2)
            uninstall
            ;;
        3)
            install_proxy
            ;;
        4)
            systemctl status nginx
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
        obtain_ssl_certificate
        # 更新为 HTTPS 配置
        create_nginx_config_https
        setup_auto_renewal
    else
        create_nginx_config_http
        enable_site
    fi
    
    start_services
    show_completion_info
}

# 脚本入口
main() {
    print_banner
    
    # 检查是否有参数
    if [ "$1" = "--uninstall" ] || [ "$1" = "-u" ]; then
        check_root
        uninstall
        exit 0
    fi
    
    if [ "$1" = "--install" ] || [ "$1" = "-i" ]; then
        install_proxy
        exit 0
    fi
    
    # 显示主菜单
    main_menu
}

# 运行主函数
main "$@"
