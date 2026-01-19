#!/usr/bin/env bash
#===============================================================================
# Emby 全自动反向代理一键部署脚本 v2.1（防封终极版）
# - Nginx 反代
# - acme.sh 证书（staging → production）
# - 永不 --force
# - 永不重复 issue
#===============================================================================

set -e

#==================== 全局变量 ====================
ACME="$HOME/.acme.sh/acme.sh"
SSL_BASE="/etc/nginx/ssl"
ISSUED_FLAG="/etc/nginx/ssl/.issued_production"

#==================== 颜色 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()      { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()    { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

#==================== 基础检查 ====================
check_root() {
  [[ $EUID -eq 0 ]] || fail "请使用 root 用户运行"
}

install_base() {
  apt update -y
  apt install -y nginx curl socat cron
}

install_acme() {
  if [[ ! -f "$ACME" ]]; then
    curl -fsSL https://get.acme.sh | sh
  fi
  $ACME --set-default-ca --server letsencrypt >/dev/null
}

#==================== 用户输入 ====================
input_config() {
  read -p "域名 (emby.example.com): " DOMAIN
  read -p "Emby 源站 IP / 域名: " EMBY_HOST
  read -p "Emby 端口 [8096]: " EMBY_PORT
  EMBY_PORT=${EMBY_PORT:-8096}

  read -p "源站是 HTTPS? [y/N]: " USE_SSL
  [[ "$USE_SSL" =~ ^[Yy]$ ]] && EMBY_PROTO="https" || EMBY_PROTO="http"

  read -p "证书邮箱: " EMAIL
}

#==================== Nginx ====================
nginx_http() {
cat >/etc/nginx/sites-available/emby <<EOF
server {
  listen 80;
  server_name $DOMAIN;

  location /.well-known/acme-challenge/ {
    root /var/www/html;
  }

  location / {
    proxy_pass $EMBY_PROTO://$EMBY_HOST:$EMBY_PORT;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }
}
EOF
}

nginx_https() {
cat >/etc/nginx/sites-available/emby <<EOF
server {
  listen 80;
  server_name $DOMAIN;
  location /.well-known/acme-challenge/ { root /var/www/html; }
  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl http2;
  server_name $DOMAIN;

  ssl_certificate $SSL_BASE/$DOMAIN/fullchain.pem;
  ssl_certificate_key $SSL_BASE/$DOMAIN/privkey.pem;

  location / {
    proxy_pass $EMBY_PROTO://$EMBY_HOST:$EMBY_PORT;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }
}
EOF
}

enable_nginx() {
  mkdir -p /etc/nginx/sites-enabled /var/www/html
  ln -sf /etc/nginx/sites-available/emby /etc/nginx/sites-enabled/emby
  nginx -t
  systemctl restart nginx
}

#==================== 证书核心逻辑 ====================
issue_cert_safe() {
  mkdir -p "$SSL_BASE/$DOMAIN"

  # 已有生产证书 → 只 renew
  if [[ -f "$ISSUED_FLAG" ]]; then
    info "检测到生产证书，仅续期（安全）"
    $ACME --renew -d "$DOMAIN" || true
    return
  fi

  # 第一次 → staging
  if [[ ! -d "$HOME/.acme.sh/${DOMAIN}_ecc" ]]; then
    warn "首次仅申请 staging 测试证书（不消耗额度）"
    $ACME --issue \
      --webroot /var/www/html \
      --staging \
      -d "$DOMAIN" \
      --accountemail "$EMAIL"
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn "确认一切 OK 后手动执行："
    warn "  bash $0 --prod"
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return
  fi

  warn "已存在 staging 证书，未申请生产证书（安全）"
}

issue_prod_once() {
  [[ -f "$ISSUED_FLAG" ]] && fail "生产证书已存在，禁止重复申请"

  info "⚠️ 正在申请【生产证书】（仅此一次）"
  $ACME --issue \
    --webroot /var/www/html \
    -d "$DOMAIN" \
    --accountemail "$EMAIL"

  $ACME --install-cert -d "$DOMAIN" \
    --key-file "$SSL_BASE/$DOMAIN/privkey.pem" \
    --fullchain-file "$SSL_BASE/$DOMAIN/fullchain.pem" \
    --reloadcmd "systemctl reload nginx"

  touch "$ISSUED_FLAG"
  ok "生产证书签发完成"
}

#==================== 主流程 ====================
main_install() {
  check_root
  install_base
  install_acme
  input_config

  nginx_http
  enable_nginx

  issue_cert_safe

  nginx_https
  enable_nginx

  ok "部署完成：https://$DOMAIN"
}

#==================== 入口 ====================
case "$1" in
  --prod)
    issue_prod_once
    ;;
  *)
    main_install
    ;;
esac
