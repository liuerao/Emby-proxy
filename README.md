# Emby 全自动反向代理一键部署脚本

## 功能特性

- ✅ 一键部署 Nginx 反向代理
- ✅ 自动申请 Let's Encrypt SSL 证书
- ✅ 自动配置证书续期
- ✅ WebSocket 支持（实时同步）
- ✅ 视频流优化配置
- ✅ 图片缓存加速
- ✅ 支持 Ubuntu/Debian/CentOS/RHEL 等主流系统
- ✅ 自动配置防火墙

## 系统要求

- Linux VPS（Ubuntu 18.04+、Debian 10+、CentOS 7+）
- Root 权限
- 域名已解析到 VPS IP
- 80 和 443 端口未被占用

## 一键部署命令

### 方法一：直接运行（推荐）

```bash
# 下载并运行脚本
bash <(curl -sL https://github.com/liuerao/Emby-proxy/blob/main/emby-proxy.sh)
```

### 方法二：手动下载运行

```bash
# 下载脚本
wget -O emby-proxy.sh https://github.com/liuerao/Emby-proxy/blob/main/emby-proxy.sh

# 添加执行权限
chmod +x emby-proxy.sh

# 运行脚本
./emby-proxy.sh
```

### 方法三：直接复制脚本内容

将 `emby-proxy.sh` 的内容复制到 VPS 上，保存为文件后运行：

```bash
# 创建脚本文件
nano emby-proxy.sh

# 粘贴脚本内容后保存，然后运行
chmod +x emby-proxy.sh
./emby-proxy.sh
```

## 使用说明

运行脚本后，按照提示输入以下信息：

1. **域名**：你的反代域名（如 `emby.example.com`）
2. **Emby 源站地址**：Emby 服务器的 IP 或域名
3. **Emby 源站端口**：默认 8096
4. **反代监听端口**：默认 443
5. **邮箱**：用于 SSL 证书申请
6. **是否启用 SSL**：建议启用

## 配置示例

```
域名: emby.mydomain.com
Emby 源站: 192.168.1.100
Emby 端口: 8096
反代端口: 443
邮箱: admin@mydomain.com
启用 SSL: Y
```

## 常用命令

```bash
# 查看 Nginx 状态
systemctl status nginx

# 重启 Nginx
systemctl restart nginx

# 测试配置文件
nginx -t

# 查看访问日志
tail -f /var/log/nginx/emby_access.log

# 查看错误日志
tail -f /var/log/nginx/emby_error.log

# 手动续期证书
certbot renew

# 查看证书信息
certbot certificates
```

## 文件位置

| 文件 | 路径 |
|------|------|
| Nginx 配置 | `/etc/nginx/sites-available/emby` |
| SSL 证书 | `/etc/letsencrypt/live/你的域名/` |
| 访问日志 | `/var/log/nginx/emby_access.log` |
| 错误日志 | `/var/log/nginx/emby_error.log` |

## 卸载

```bash
./emby-proxy.sh --uninstall
```

或运行脚本后选择 "卸载" 选项。

## 高级配置

### 修改配置

```bash
# 编辑配置文件
nano /etc/nginx/sites-available/emby

# 测试配置
nginx -t

# 重载配置
systemctl reload nginx
```

### 多域名支持

如需添加多个域名，修改配置文件中的 `server_name`：

```nginx
server_name emby.example.com emby2.example.com;
```

### 自定义缓存

修改图片缓存时间：

```nginx
location ~* ^/Items/.*/Images/.*$ {
    # 修改缓存时间（默认 30 天）
    proxy_cache_valid 200 7d;
    expires 7d;
}
```

## 故障排除

### 1. 证书申请失败

- 确认域名已正确解析到 VPS IP
- 确认 80 端口未被占用
- 检查防火墙设置

```bash
# 检查域名解析
dig +short your-domain.com

# 检查端口占用
netstat -tlnp | grep :80
```

### 2. 502 Bad Gateway

- 确认 Emby 服务器正在运行
- 确认源站地址和端口正确
- 检查 VPS 能否访问源站

```bash
# 测试连接
curl -I http://源站IP:8096
```

### 3. WebSocket 连接失败

检查 Nginx 配置中的 WebSocket 设置是否正确。

## 更新日志

### v1.0
- 初始版本
- 支持 Nginx 反向代理
- 支持 SSL 证书自动申请和续期
- 支持 WebSocket
- 视频流和图片缓存优化

## License

MIT License
