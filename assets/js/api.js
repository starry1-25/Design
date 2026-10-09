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
    client_timeout:      '等待超时了，模型可能正忙，请再试一次。',
    upstream_timeout:    '模型接口响应超时，请重试一次。',
    upstream_rate_limited: '请求过于频繁，稍等几秒再试。',
    upstream_auth_failed:  '鉴权失败：API 密钥无效，或该密钥没有访问此模型的权限。',
    upstream_error:      '模型接口暂时不可用，已自动重试仍未成功，请稍后再试。',
    upstream_unreachable:'无法连接到该 API 地址：请检查地址是否写错、网络是否可达。',
    upstream_tls:        'HTTPS 证书校验失败：请确认该地址证书有效，或改用 http 地址。',
    no_provider:         '还没有启用可用的大模型。请到「设置 → 大模型接入配置」中添加并启用后再试。',
    no_api_key:          '请填写 API 密钥。',
    no_model:            '请至少填写一个模型标识（文本或图像）。',
    model_not_found:     '模型标识不存在，或当前密钥无权访问该模型，请核对模型名称。',
    models_unsupported:  '该服务未提供 /models 接口，请在「文本模型」一栏手动填写模型标识。',
    model_not_listed:    '该模型未出现在服务商的模型列表中，请确认模型标识是否拼写正确。',
    cannot_verify:       '该服务未提供模型列表，无法自动校验图像模型，请自行确认模型标识。',
    not_provided:        '未填写，已跳过校验。',
    url_empty:           'API 地址不能为空。',
    url_scheme:          'API 地址必须以 http:// 或 https:// 开头。',
    url_malformed:       'API 地址格式不正确。',
    plan_parse_failed:   '模型这次返回的内容无法解析，请点「重新生成」。',
    refine_parse_failed: '微调结果无法解析，换个说法再试一次。',
    not_found:           '这条记录已不存在，请刷新页面。',
    empty_requirement:   '请先描述你的需求。',
    empty_instruction:   '请输入你想调整的内容。',
    offline:             '无法连接本地服务，请确认 server.ps1 正在运行。'
  };

  // 这些错误意味着「用户还没配好模型」，界面应引导到设置页而不是报故障
  const SETUP_CODES = ['no_provider', 'no_api_key', 'no_model'];

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
    clear:      ()                  => request('/history/clear', {}, 15000),

    /* 用户自定义大模型接入 */
    providers: {
      list:     ()         => get('/providers', 20000),
      save:     (payload)  => request('/providers', payload, 30000),
      remove:   (id)       => del('/providers?id=' + encodeURIComponent(id), 20000),
      activate: (payload)  => request('/providers/activate', payload, 20000),
      // 服务端会先探测 /models（≤20s），再跑一次极小的对话（≤30s）
      test:     (payload)  => request('/providers/test', payload, 90000)
    }
  };
})();
