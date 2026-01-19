#!/bin/bash
set -e

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}[Emby Proxy] 启动配置...${NC}"

# 检查必要的环境变量
if [ -z "$EMBY_HOST" ]; then
    echo -e "${YELLOW}[WARNING] EMBY_HOST 未设置，使用默认值: emby.example.com${NC}"
    EMBY_HOST="emby.example.com"
fi

# 设置默认值
EMBY_PROTO=${EMBY_PROTO:-https}
EMBY_PORT=${EMBY_PORT:-443}
PROXY_HOST=${PROXY_HOST:-$EMBY_HOST}
DOMAIN=${DOMAIN:-localhost}

echo "[Emby Proxy] 配置信息:"
echo "  - 域名: $DOMAIN"
echo "  - 源站: $EMBY_PROTO://$EMBY_HOST:$EMBY_PORT"
echo "  - Host 头: $PROXY_HOST"

# 根据协议设置 SSL 代理配置
if [ "$EMBY_PROTO" = "https" ]; then
    SSL_PROXY_CONFIG="    proxy_ssl_verify off;
    proxy_ssl_server_name on;
    proxy_ssl_protocols TLSv1.2 TLSv1.3;"
else
    SSL_PROXY_CONFIG=""
fi

# 检查是否有 SSL 证书
if [ -f "/etc/nginx/ssl/fullchain.pem" ] && [ -f "/etc/nginx/ssl/privkey.pem" ]; then
    echo "[Emby Proxy] 检测到 SSL 证书，启用 HTTPS..."
    ENABLE_SSL="true"
else
    echo "[Emby Proxy] 未检测到 SSL 证书，仅启用 HTTP..."
    ENABLE_SSL="false"
fi

# 生成 Nginx 配置
if [ "$ENABLE_SSL" = "true" ]; then
    cat > /etc/nginx/conf.d/emby.conf << EOFCONFIG
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location /health {
        return 200 'OK';
        add_header Content-Type text/plain;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    access_log /var/log/nginx/emby_access.log;
    error_log /var/log/nginx/emby_error.log;

    client_max_body_size 20G;
    proxy_buffering off;
    proxy_connect_timeout 600s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;
${SSL_PROXY_CONFIG}

    location /health {
        return 200 'OK';
        add_header Content-Type text/plain;
    }

    location / {
        proxy_pass ${EMBY_PROTO}://${EMBY_HOST};
        proxy_set_header Host ${PROXY_HOST};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location /embywebsocket {
        proxy_pass ${EMBY_PROTO}://${EMBY_HOST};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host ${PROXY_HOST};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location ~* ^/videos/ {
        proxy_pass ${EMBY_PROTO}://${EMBY_HOST};
        proxy_set_header Host ${PROXY_HOST};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }

    location ~* ^/Items/.*/Images/ {
        proxy_pass ${EMBY_PROTO}://${EMBY_HOST};
        proxy_set_header Host ${PROXY_HOST};
        proxy_set_header X-Real-IP \$remote_addr;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
EOFCONFIG
else
    cat > /etc/nginx/conf.d/emby.conf << EOFCONFIG
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    access_log /var/log/nginx/emby_access.log;
    error_log /var/log/nginx/emby_error.log;

    client_max_body_size 20G;
    proxy_buffering off;
    proxy_connect_timeout 600s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;
${SSL_PROXY_CONFIG}

    location /health {
        return 200 'OK';
        add_header Content-Type text/plain;
    }

    location / {
        proxy_pass ${EMBY_PROTO}://${EMBY_HOST};
        proxy_set_header Host ${PROXY_HOST};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location /embywebsocket {
        proxy_pass ${EMBY_PROTO}://${EMBY_HOST};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host ${PROXY_HOST};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location ~* ^/videos/ {
        proxy_pass ${EMBY_PROTO}://${EMBY_HOST};
        proxy_set_header Host ${PROXY_HOST};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }

    location ~* ^/Items/.*/Images/ {
        proxy_pass ${EMBY_PROTO}://${EMBY_HOST};
        proxy_set_header Host ${PROXY_HOST};
        proxy_set_header X-Real-IP \$remote_addr;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
EOFCONFIG
fi

echo -e "${GREEN}[Emby Proxy] 配置生成完成，启动 Nginx...${NC}"

# 测试配置
nginx -t

# 执行传入的命令
exec "$@"
