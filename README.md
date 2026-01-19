# Emby 全自动反向代理一键部署

支持 VPS 一键脚本部署和 Docker 部署两种方式。

## 功能特性

- ✅ 一键部署 Nginx 反向代理
- ✅ 自动申请 Let's Encrypt SSL 证书 (acme.sh)
- ✅ 自动配置证书续期
- ✅ WebSocket 支持（实时同步）
- ✅ 视频流优化配置
- ✅ 图片缓存加速
- ✅ 支持 Cloudflare CDN 源站 (SNI)
- ✅ 支持 Docker 部署
- ✅ 多架构支持 (amd64/arm64)

---

## 方式一：VPS 一键脚本部署

### 系统要求

- Linux VPS（Ubuntu 18.04+、Debian 10+、CentOS 7+）
- Root 权限
- 域名已解析到 VPS IP
- 80 和 443 端口未被占用

### 一键部署命令

```bash
bash <(curl -sL https://raw.githubusercontent.com/liuerao/Emby-proxy/main/emby-proxy.sh)
```

### 使用说明

运行脚本后，按照提示输入以下信息：

1. **域名**：你的反代域名（如 `emby.example.com`）
2. **Emby 源站地址**：Emby 服务器的域名（如 `emby.example.com`，不带 https://）
3. **Emby 源站端口**：默认 443（HTTPS）或 8096（HTTP）
4. **源站是否 HTTPS**：如果源站是 https:// 开头，选 y
5. **是否传递源站 Host 头**：反代其他域名时选 y（重要！）
6. **邮箱**：用于 SSL 证书申请
7. **是否启用 SSL**：建议 y

### 配置示例

```
域名: emby.mydomain.com
Emby 源站地址: emby.example.com
Emby 源站端口: 443
源站使用 HTTPS: y
传递源站 Host 头: y    ← 反代其他域名必选 y
邮箱: admin@mydomain.com
启用 SSL: y
```

---

## 方式二：Docker 部署

### 快速开始

```bash
docker run -d \
  --name emby-proxy \
  -p 80:80 \
  -p 443:443 \
  -e EMBY_HOST=emby.example.com \
  -e EMBY_PROTO=https \
  -e PROXY_HOST=emby.example.com \
  -e DOMAIN=your-domain.com \
  ghcr.io/liuerao/emby-proxy:latest
```

### 使用 Docker Compose

1. 创建 `docker-compose.yml`：

```yaml
version: '3.8'

services:
  emby-proxy:
    image: ghcr.io/liuerao/emby-proxy:latest
    container_name: emby-proxy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      - EMBY_HOST=emby.example.com
      - EMBY_PROTO=https
      - PROXY_HOST=emby.example.com
      - DOMAIN=your-domain.com
      - TZ=Asia/Shanghai
    volumes:
      # SSL 证书 (可选)
      - ./certs/fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
      - ./certs/privkey.pem:/etc/nginx/ssl/privkey.pem:ro
      # 日志 (可选)
      - ./logs:/var/log/nginx
```

2. 启动服务：

```bash
docker compose up -d
```

### 环境变量说明

| 变量 | 说明 | 默认值 | 必填 |
|------|------|--------|------|
| `EMBY_HOST` | Emby 源站地址（不带协议） | emby.example.com | ✅ |
| `EMBY_PROTO` | 源站协议 (http/https) | https | - |
| `PROXY_HOST` | 传递给源站的 Host 头 | 同 EMBY_HOST | ✅* |
| `DOMAIN` | 你的反代域名 | localhost | - |
| `TZ` | 时区 | Asia/Shanghai | - |

> *注：反代其他域名时 `PROXY_HOST` 必须设置为源站域名

### 挂载 SSL 证书

将证书文件挂载到容器：

```bash
docker run -d \
  --name emby-proxy \
  -p 80:80 \
  -p 443:443 \
  -e EMBY_HOST=emby.example.com \
  -e EMBY_PROTO=https \
  -e PROXY_HOST=emby.example.com \
  -e DOMAIN=emby.mydomain.com \
  -v /path/to/fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro \
  -v /path/to/privkey.pem:/etc/nginx/ssl/privkey.pem:ro \
  ghcr.io/liuerao/emby-proxy:latest
```

---

## 常用命令

### VPS 部署

```bash
# 查看 Nginx 状态
systemctl status nginx

# 重启 Nginx
systemctl restart nginx

# 查看错误日志
tail -f /var/log/nginx/emby_error.log

# 手动续期证书
~/.acme.sh/acme.sh --renew -d your-domain.com --force
```

### Docker 部署

```bash
# 查看日志
docker logs -f emby-proxy

# 重启容器
docker restart emby-proxy

# 查看状态
docker ps | grep emby-proxy

# 停止并删除
docker stop emby-proxy && docker rm emby-proxy
```

---

## 故障排除

### 1. 502 Bad Gateway

**常见原因：**
- 源站地址或端口错误
- 未正确设置 `PROXY_HOST`（反代其他域名时必须设置）
- 源站使用 Cloudflare，需要启用 SNI

**解决方法：**
- 确保 `PROXY_HOST` 设置为源站域名
- 确保 `EMBY_PROTO` 正确（http 或 https）

### 2. SSL 证书申请失败

- 确认域名已正确解析到服务器 IP
- 确认 80 端口未被占用
- 检查防火墙设置

### 3. 400 Bad Request - plain HTTP sent to HTTPS port

源站使用 HTTPS，但配置为 HTTP。将 `EMBY_PROTO` 改为 `https`。

---

## 更新日志

### v2.0
- 添加 Docker 支持
- 添加 GitHub Actions 自动构建
- 支持 Cloudflare CDN 源站 (SNI/TLS 1.2+)
- 修复 502 错误
- 多架构支持 (amd64/arm64)

### v1.0
- 初始版本
- 支持 Nginx 反向代理
- 支持 SSL 证书自动申请和续期

---

## License

MIT License
