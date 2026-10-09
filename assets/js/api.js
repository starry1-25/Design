/* ==========================================================================
   绘职 AI — API 客户端
   前后端同源（server.ps1 同时托管静态站与 /api），因此统一使用相对路径。
   超时预算 = 服务端「单次超时 × 重试次数 + 退避」，避免客户端先于服务端放弃。
   ========================================================================== */
(function () {
  'use strict';

  /* 超时必须覆盖服务端的完整重试预算，否则前端会先于后端放弃：
     用户看到"超时"，而服务端其实还在正常重试。
     服务端预算 —— 文本：60s × 3 次 + (5s + 10s) 退避 ≈ 195s
                   图像：75s × 2 次 + 5s 退避 + 75s（兜底模型）= 230s */
  const TIMEOUT = {
    plan:       250000,
    render:     290000,
    rerender:   290000,
    refine:     250000,
    regenerate: 490000,
    short:       20000
  };

  const FRIENDLY = {
    client_timeout:      '等待超时了，模型服务可能正忙，请再试一次。',
    upstream_timeout:    'Agnes AI 响应超时，请重试一次。',
    upstream_rate_limited: '请求过于频繁，稍等几秒再试。',
    upstream_auth_failed:  'Agnes AI 鉴权失败：API 密钥无效或已失效。',
    upstream_unreachable:'无法连接到 Agnes AI 服务，请检查网络后重试。',
    upstream_tls:        'HTTPS 证书校验失败，请确认当前网络环境是否安全可信。',
    upstream_error:      'Agnes AI 服务暂时不可用，已自动重试仍未成功，请稍后再试。',
    no_api_key:          '服务端尚未配置 Agnes AI 密钥，请联系服务提供方。',
    plan_parse_failed:   '模型这次返回的内容无法解析，请点「重新生成」。',
    refine_parse_failed: '微调结果无法解析，换个说法再试一次。',
    not_found:           '这条记录已不存在，请刷新页面。',
    empty_requirement:   '请先描述你的需求。',
    empty_instruction:   '请输入你想调整的内容。',
    offline:             '无法连接本地服务，请确认服务正在运行。'
  };

  // 「服务端未配密钥」属于部署侧问题，并非用户可自行解决，界面只做说明
  const SETUP_CODES = ['no_api_key'];

  function isSetupError(err) {
    return !!(err && SETUP_CODES.indexOf(err.code) >= 0);
  }

  function friendly(err) {
    if (!err) return '发生未知错误。';
    if (err.code && FRIENDLY[err.code]) return FRIENDLY[err.code];
    if (err.name === 'TypeError' || /Failed to fetch|NetworkError|Load failed/i.test(err.message || '')) {
      return FRIENDLY.offline;
    }
    return err.message || '发生未知错误。';
  }

  async function request(path, body, timeoutMs) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs || TIMEOUT.short);
    try {
      const res = await fetch('/api' + path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body || {}),
        signal: ctrl.signal
      });
      const data = await res.json().catch(() => null);
      if (!res.ok || !data || data.ok === false) {
        const e = new Error((data && data.message) || ('HTTP ' + res.status));
        e.code = (data && data.error) || ('http_' + res.status);
        e.status = res.status;
        throw e;
      }
      return data;
    } catch (err) {
      if (err && err.name === 'AbortError') {
        const e = new Error('client timeout');
        e.code = 'client_timeout';
        throw e;
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }
  }

  async function get(path, timeoutMs) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs || TIMEOUT.short);
    try {
      const res = await fetch('/api' + path, { signal: ctrl.signal });
      const data = await res.json().catch(() => null);
      if (!res.ok || !data) {
        const e = new Error('HTTP ' + res.status);
        e.code = 'http_' + res.status;
        throw e;
      }
      return data;
    } catch (err) {
      if (err && err.name === 'AbortError') {
        const e = new Error('client timeout');
        e.code = 'client_timeout';
        throw e;
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }
  }

  async function del(path, timeoutMs) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs || TIMEOUT.short);
    try {
      const res = await fetch('/api' + path, { method: 'DELETE', signal: ctrl.signal });
      const data = await res.json().catch(() => null);
      if (!res.ok || !data || data.ok === false) {
        const e = new Error((data && data.message) || ('HTTP ' + res.status));
        e.code = (data && data.error) || ('http_' + res.status);
        e.status = res.status;
        throw e;
      }
      return data;
    } catch (err) {
      if (err && err.name === 'AbortError') {
        const e = new Error('client timeout');
        e.code = 'client_timeout';
        throw e;
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }
  }

  window.HZ = window.HZ || {};
  window.HZ.api = {
    friendly,
    isSetupError,

    health:     ()                  => get('/health', 8000),
    roles:      ()                  => get('/roles', 20000),
    history:    ()                  => get('/history', 30000),
    plan:       (payload)           => request('/plan', payload, TIMEOUT.plan),
    render:     (payload)           => request('/render', payload, TIMEOUT.render),
    refine:     (payload)           => request('/refine', payload, TIMEOUT.refine),
    rerender:   (payload)           => request('/rerender', payload, TIMEOUT.rerender),
    regenerate: (payload)           => request('/regenerate', payload, TIMEOUT.regenerate),
    remove:     (id)                => del('/history?id=' + encodeURIComponent(id), 20000),
    clear:      ()                  => request('/history/clear', {}, 15000)
  };
})();
