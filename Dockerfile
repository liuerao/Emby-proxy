# Emby 反向代理 Docker 镜像
FROM nginx:alpine

LABEL maintainer="BiuXin"
LABEL description="Emby Reverse Proxy with Nginx"
LABEL version="2.0"
LABEL org.opencontainers.image.source="https://github.com/liuerao/Emby-proxy"

# 安装必要工具
RUN apk add --no-cache \
    curl \
    openssl \
    bash \
    tzdata

# 设置时区
ENV TZ=Asia/Shanghai

# 环境变量默认值
ENV EMBY_HOST=emby.example.com \
    EMBY_PROTO=https \
    EMBY_PORT=443 \
    PROXY_HOST="" \
    DOMAIN=localhost

# 创建必要目录
RUN mkdir -p /etc/nginx/ssl \
    && mkdir -p /etc/nginx/conf.d \
    && mkdir -p /etc/nginx/templates \
    && mkdir -p /var/www/html/.well-known/acme-challenge \
    && mkdir -p /var/log/nginx \
    && rm -f /etc/nginx/conf.d/default.conf

# 复制配置
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/emby.conf.template /etc/nginx/templates/emby.conf.template
COPY docker-entrypoint.sh /docker-entrypoint.sh

# 设置执行权限
RUN chmod +x /docker-entrypoint.sh

# 暴露端口
EXPOSE 80 443

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

# 启动脚本
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
