/**
 * Emby 反向代理 Cloudflare Worker
 * 
 * 功能：
 * - 将你的域名反代到 Emby 源站
 * - 支持 WebSocket（实时同步）
 * - 支持视频流媒体
 * - 自动处理 CORS
 * 
 * 使用方法：
 * 1. 在 Cloudflare Dashboard 创建 Worker
 * 2. 复制此代码粘贴
 * 3. 修改下方 EMBY_HOST 为你的源站地址
 * 4. 绑定自定义域名
 */

// ============== 配置区域 ==============
const CONFIG = {
  // Emby 源站地址（不带 https://）
  EMBY_HOST: 'emos.best',
  
  // 源站协议
  EMBY_PROTOCOL: 'https',
  
  // 是否启用缓存（图片等静态资源）
  ENABLE_CACHE: true,
  
  // 图片缓存时间（秒）
  IMAGE_CACHE_TTL: 86400 * 7,  // 7 天
  
  // 是否允许所有 CORS 请求
  ENABLE_CORS: true,
};
// =====================================

export default {
  async fetch(request, env, ctx) {
    return handleRequest(request, ctx);
  }
};

async function handleRequest(request, ctx) {
  const url = new URL(request.url);
  const originalHost = url.hostname;
  
  // 修改目标地址
  url.hostname = CONFIG.EMBY_HOST;
  url.protocol = CONFIG.EMBY_PROTOCOL + ':';
  
  // 处理 WebSocket 升级请求
  if (request.headers.get('Upgrade') === 'websocket') {
    return handleWebSocket(request, url);
  }
  
  // 检查是否是可缓存的资源
  const isImage = /\/Items\/.*\/Images\//.test(url.pathname);
  const isStaticResource = /\.(js|css|woff|woff2|ttf|ico|png|jpg|jpeg|gif|webp|svg)$/i.test(url.pathname);
  
  // 尝试从缓存获取
  if (CONFIG.ENABLE_CACHE && (isImage || isStaticResource)) {
    const cache = caches.default;
    const cacheKey = new Request(url.toString(), request);
    let response = await cache.match(cacheKey);
    
    if (response) {
      return addCorsHeaders(response, originalHost);
    }
    
    // 缓存未命中，请求源站
    response = await fetchFromOrigin(request, url);
    
    if (response.ok) {
      // 克隆响应用于缓存
      const responseToCache = response.clone();
      const headers = new Headers(responseToCache.headers);
      headers.set('Cache-Control', `public, max-age=${CONFIG.IMAGE_CACHE_TTL}`);
      
      const cachedResponse = new Response(responseToCache.body, {
        status: responseToCache.status,
        statusText: responseToCache.statusText,
        headers: headers
      });
      
      ctx.waitUntil(cache.put(cacheKey, cachedResponse.clone()));
      return addCorsHeaders(cachedResponse, originalHost);
    }
    
    return addCorsHeaders(response, originalHost);
  }
  
  // 普通请求
  const response = await fetchFromOrigin(request, url);
  return addCorsHeaders(response, originalHost);
}

async function fetchFromOrigin(request, url) {
  // 构建新的请求头
  const headers = new Headers(request.headers);
  
  // 设置正确的 Host 头（关键！）
  headers.set('Host', CONFIG.EMBY_HOST);
  
  // 移除可能导致问题的头
  headers.delete('cf-connecting-ip');
  headers.delete('cf-ipcountry');
  headers.delete('cf-ray');
  headers.delete('cf-visitor');
  
  // 保留原始 IP（如果源站需要）
  const clientIP = request.headers.get('cf-connecting-ip');
  if (clientIP) {
    headers.set('X-Real-IP', clientIP);
    headers.set('X-Forwarded-For', clientIP);
  }
  
  // 创建新请求
  const newRequest = new Request(url.toString(), {
    method: request.method,
    headers: headers,
    body: request.body,
    redirect: 'follow',
  });
  
  try {
    return await fetch(newRequest);
  } catch (error) {
    return new Response(`Proxy Error: ${error.message}`, { 
      status: 502,
      headers: { 'Content-Type': 'text/plain' }
    });
  }
}

async function handleWebSocket(request, url) {
  // WebSocket 代理
  const headers = new Headers(request.headers);
  headers.set('Host', CONFIG.EMBY_HOST);
  
  // 构建 WebSocket URL
  const wsUrl = new URL(url);
  wsUrl.protocol = CONFIG.EMBY_PROTOCOL === 'https' ? 'wss:' : 'ws:';
  
  try {
    // 创建到源站的 WebSocket 连接
    const originResponse = await fetch(wsUrl.toString(), {
      headers: headers,
      // @ts-ignore
      upgrade: 'websocket',
    });
    
    return originResponse;
  } catch (error) {
    return new Response(`WebSocket Error: ${error.message}`, { 
      status: 502,
      headers: { 'Content-Type': 'text/plain' }
    });
  }
}

function addCorsHeaders(response, originalHost) {
  if (!CONFIG.ENABLE_CORS) {
    return response;
  }
  
  const headers = new Headers(response.headers);
  headers.set('Access-Control-Allow-Origin', '*');
  headers.set('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS, HEAD');
  headers.set('Access-Control-Allow-Headers', '*');
  headers.set('Access-Control-Expose-Headers', '*');
  
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: headers
  });
}

// 处理 OPTIONS 预检请求
export async function onRequestOptions() {
  return new Response(null, {
    status: 204,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS, HEAD',
      'Access-Control-Allow-Headers': '*',
      'Access-Control-Max-Age': '86400',
    }
  });
}
