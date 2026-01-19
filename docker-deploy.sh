#!/bin/bash

#===============================================================================
# Emby 反向代理 Docker 一键部署脚本
# 使用 Docker + Nginx + Certbot 自动部署
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

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

print_banner() {
    echo -e "${PURPLE}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║      Emby 反向代理 Docker 一键部署脚本 v1.0                   ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# 检查 root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "请使用 root 用户运行"
        exit 1
    fi
}

# 安装 Docker
install_docker() {
    if command -v docker &> /dev/null; then
        print_info "Docker 已安装"
        return
    fi

    print_info "正在安装 Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    print_success "Docker 安装完成"
}

# 安装 Docker Compose
install_docker_compose() {
    if command -v docker-compose &> /dev/null || docker compose version &> /dev/null; then
        print_info "Docker Compose 已安装"
        return
    fi

    print_info "正在安装 Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    print_success "Docker Compose 安装完成"
}

# 获取用户输入
get_user_input() {
    echo ""
    print_info "请输入配置信息:"
    echo ""

    read -p "请输入你的域名: " DOMAIN
    read -p "请输入 Emby 源站地址: " EMBY_HOST
    read -p "请输入 Emby 源站端口 [8096]: " EMBY_PORT
    EMBY_PORT=${EMBY_PORT:-8096}
    read -p "请输入邮箱 (SSL证书): " EMAIL

    echo ""
    print_info "配置确认:"
    echo "  域名: $DOMAIN"
    echo "  源站: $EMBY_HOST:$EMBY_PORT"
    echo "  邮箱: $EMAIL"
    echo ""

    read -p "确认? [Y/n]: " CONFIRM
    if [[ ! "${CONFIRM:-Y}" =~ ^[Yy]$ ]]; then
        exit 0
    fi
}

# 创建目录结构
create_directories() {
    DEPLOY_DIR="/opt/emby-proxy"
    mkdir -p $DEPLOY_DIR/{certs,logs,certbot-webroot}
    cd $DEPLOY_DIR
    print_success "目录创建完成: $DEPLOY_DIR"
}

# 生成 Nginx 配置
generate_nginx_config() {
    print_info "生成 Nginx 配置..."

    cat > $DEPLOY_DIR/nginx.conf << EOF
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript;

    upstream emby_backend {
        server $EMBY_HOST:$EMBY_PORT;
        keepalive 32;
    }

    server {
        listen 80;
        listen [::]:80;
        server_name $DOMAIN;

        location /.well-known/acme-challenge/ {
            root /var/www/certbot;
        }

        location / {
            return 301 https://\$host\$request_uri;
        }
    }

    server {
        listen 443 ssl http2;
        listen [::]:443 ssl http2;
        server_name $DOMAIN;

        ssl_certificate /etc/nginx/certs/live/$DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/nginx/certs/live/$DOMAIN/privkey.pem;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;

        add_header Strict-Transport-Security "max-age=63072000" always;

        client_max_body_size 20G;
        proxy_buffering off;
        proxy_buffer_size 8k;

        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;

        location / {
            proxy_pass http://emby_backend;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
        }

        location /embywebsocket {
            proxy_pass http://emby_backend;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_read_timeout 86400s;
        }

        location ~* ^/videos/.*\$ {
            proxy_pass http://emby_backend;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
        }

        location ~* ^/Items/.*/Images/.*\$ {
            proxy_pass http://emby_backend;
            proxy_set_header Host \$host;
            expires 30d;
            add_header Cache-Control "public, immutable";
        }
    }
}
EOF

    print_success "Nginx 配置生成完成"
}

# 生成临时 HTTP 配置（用于证书申请）
generate_temp_nginx_config() {
    cat > $DEPLOY_DIR/nginx-temp.conf << EOF
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    server {
        listen 80;
        listen [::]:80;
        server_name $DOMAIN;

        location /.well-known/acme-challenge/ {
            root /var/www/certbot;
        }

        location / {
            return 200 'Emby Proxy - Waiting for SSL certificate...';
            add_header Content-Type text/plain;
        }
    }
}
EOF
}

# 生成 Docker Compose 文件
generate_docker_compose() {
    print_info "生成 Docker Compose 配置..."

    cat > $DEPLOY_DIR/docker-compose.yml << EOF
version: '3.8'

services:
  nginx:
    image: nginx:alpine
    container_name: emby-proxy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/etc/nginx/certs:ro
      - ./logs:/var/log/nginx
      - ./certbot-webroot:/var/www/certbot:ro
    environment:
      - TZ=Asia/Shanghai
    networks:
      - emby-network

networks:
  emby-network:
    driver: bridge
EOF

    print_success "Docker Compose 配置生成完成"
}

# 申请 SSL 证书
obtain_ssl_certificate() {
    print_info "申请 SSL 证书..."

    # 先用临时配置启动 nginx
    generate_temp_nginx_config
    cp $DEPLOY_DIR/nginx-temp.conf $DEPLOY_DIR/nginx.conf

    docker run -d --name emby-proxy-temp \
        -p 80:80 \
        -v $DEPLOY_DIR/nginx.conf:/etc/nginx/nginx.conf:ro \
        -v $DEPLOY_DIR/certbot-webroot:/var/www/certbot \
        nginx:alpine

    sleep 3

    # 申请证书
    docker run --rm \
        -v $DEPLOY_DIR/certs:/etc/letsencrypt \
        -v $DEPLOY_DIR/certbot-webroot:/var/www/certbot \
        certbot/certbot certonly \
        --webroot \
        --webroot-path=/var/www/certbot \
        -d $DOMAIN \
        --email $EMAIL \
        --agree-tos \
        --non-interactive

    # 停止临时容器
    docker stop emby-proxy-temp
    docker rm emby-proxy-temp

    if [ -f "$DEPLOY_DIR/certs/live/$DOMAIN/fullchain.pem" ]; then
        print_success "SSL 证书申请成功"
    else
        print_error "SSL 证书申请失败"
        exit 1
    fi
}

# 配置证书自动续期
setup_auto_renewal() {
    print_info "配置证书自动续期..."

    cat > /etc/cron.d/emby-certbot << EOF
0 3 * * * root docker run --rm -v $DEPLOY_DIR/certs:/etc/letsencrypt -v $DEPLOY_DIR/certbot-webroot:/var/www/certbot certbot/certbot renew --quiet && docker exec emby-proxy nginx -s reload
EOF

    print_success "证书自动续期已配置"
}

# 启动服务
start_services() {
    print_info "启动服务..."

    # 恢复正式配置
    generate_nginx_config

    cd $DEPLOY_DIR
    docker-compose up -d

    sleep 3

    if docker ps | grep -q emby-proxy; then
        print_success "服务启动成功"
    else
        print_error "服务启动失败"
        docker-compose logs
        exit 1
    fi
}

# 显示完成信息
show_completion() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                      部署完成！                               ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}访问地址:${NC} https://$DOMAIN"
    echo -e "  ${CYAN}部署目录:${NC} $DEPLOY_DIR"
    echo ""
    echo -e "  ${YELLOW}常用命令:${NC}"
    echo "    查看状态:  docker-compose -f $DEPLOY_DIR/docker-compose.yml ps"
    echo "    查看日志:  docker-compose -f $DEPLOY_DIR/docker-compose.yml logs -f"
    echo "    重启服务:  docker-compose -f $DEPLOY_DIR/docker-compose.yml restart"
    echo "    停止服务:  docker-compose -f $DEPLOY_DIR/docker-compose.yml down"
    echo ""
    print_success "Emby 反向代理部署完成！"
}

# 主函数
main() {
    print_banner
    check_root
    get_user_input
    install_docker
    install_docker_compose
    create_directories
    obtain_ssl_certificate
    generate_docker_compose
    start_services
    setup_auto_renewal
    show_completion
}

main "$@"
