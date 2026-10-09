/* ==========================================================================
   绘职 AI — 通用 UI 工具（图标挂载 / Toast / 剪贴板 / 下载 / 导航 / 离线守卫）
   ========================================================================== */
(function () {
  'use strict';

  const HZ = window.HZ = window.HZ || {};

  /* ---------------------------------------------------------- 图标挂载 */
  function mountIcons(root) {
    (root || document).querySelectorAll('[data-icon]').forEach((el) => {
      if (el.dataset.iconDone === '1') return;
      const svg = HZ.icon(el.dataset.icon);
      if (svg) el.insertAdjacentHTML('afterbegin', svg);
      el.dataset.iconDone = '1';
    });
  }

  function esc(str) {
    return String(str == null ? '' : str)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  /* ------------------------------------------------------------- Toast */
  let toastWrap = null;
  function toast(message, type) {
    if (!toastWrap) {
      toastWrap = document.createElement('div');
      toastWrap.className = 'toasts';
      document.body.appendChild(toastWrap);
    }
    const t = type || 'info';
    const iconName = t === 'ok' ? 'check' : (t === 'err' ? 'alert' : 'info');
    const el = document.createElement('div');
    el.className = 'toast ' + t;
    el.setAttribute('role', 'status');
    el.innerHTML = HZ.icon(iconName) + '<span>' + esc(message) + '</span>';
    toastWrap.appendChild(el);
    setTimeout(() => {
      el.classList.add('is-out');
      setTimeout(() => el.remove(), 240);
    }, t === 'err' ? 4800 : 2600);
  }

  /* --------------------------------------------------------- 剪贴板 / 下载 */
  async function copyText(text) {
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text);
        return true;
      }
    } catch (_) { /* 回退到 execCommand */ }

    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.cssText = 'position:fixed;top:0;left:0;opacity:0;pointer-events:none';
    document.body.appendChild(ta);
    ta.select();
    ta.setSelectionRange(0, ta.value.length);
    let ok = false;
    try { ok = document.execCommand('copy'); } catch (_) { ok = false; }
    ta.remove();
    return ok;
  }

  function download(url, filename) {
    const a = document.createElement('a');
    a.href = url;
    a.download = filename || '';
    a.rel = 'noopener';
    document.body.appendChild(a);
    a.click();
    a.remove();
  }

  /* ------------------------------------------------------------ 时间格式 */
  function fmtDate(value) {
    if (!value) return '';
    const d = new Date(String(value).replace(/-/g, '/'));
    if (isNaN(d.getTime())) return String(value);
    const pad = (n) => (n < 10 ? '0' + n : '' + n);
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
           ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  function debounce(fn, wait) {
    let timer = null;
    return function () {
      const args = arguments, ctx = this;
      clearTimeout(timer);
      timer = setTimeout(() => fn.apply(ctx, args), wait);
    };
  }

  /* --------------------------------------------------------------- 导航 */
  function initNav() {
    const nav = document.querySelector('.nav');
    if (nav) {
      const onScroll = () => nav.classList.toggle('is-scrolled', window.scrollY > 8);
      onScroll();
      window.addEventListener('scroll', onScroll, { passive: true });
    }

    const toggle = document.querySelector('.nav-toggle');
    const sheet = document.querySelector('.nav-sheet');
    if (toggle && sheet) {
      toggle.addEventListener('click', (e) => {
        e.stopPropagation();
        sheet.classList.toggle('is-open');
      });
      document.addEventListener('click', (e) => {
        if (!sheet.contains(e.target) && !toggle.contains(e.target)) sheet.classList.remove('is-open');
      });
      sheet.querySelectorAll('a').forEach((a) =>
        a.addEventListener('click', () => sheet.classList.remove('is-open')));
    }

    // 当前页高亮
    const here = location.pathname.replace(/\/$/, '') || '/index.html';
    document.querySelectorAll('.nav-link[href], .nav-sheet .nav-link[href]').forEach((a) => {
      const href = a.getAttribute('href');
      if (!href || href.startsWith('http')) return;
      const target = href.replace(/\/$/, '');
      if (here.endsWith(target) || (target === 'index.html' && (here === '/' || here.endsWith('/index.html')))) {
        a.classList.add('is-active');
      }
    });
  }

  /* -------------------------------------------------- 离线 / 错误来源守卫 */
  function offlineBar(html) {
    let bar = document.querySelector('.offline-bar');
    if (!bar) {
      bar = document.createElement('div');
      bar.className = 'offline-bar';
      document.body.appendChild(bar);
    }
    bar.innerHTML = html;
  }

  function clearOfflineBar() {
    const bar = document.querySelector('.offline-bar');
    if (bar) bar.remove();
  }

  /* ------------------------------------------------------------- 运行环境判定
     只有经由本地 server.ps1 打开时才有后端。部署到 GitHub Pages 等静态托管时
     没有后端，此时若仍去请求 /api/* 必然 404，还会弹出"请运行 server.ps1"这种
     在线上完全不成立的提示。因此先判定环境，再决定是探测还是如实说明。 */
  function hasLocalBackend() {
    if (location.protocol === 'file:') return false;
    const h = location.hostname;
    return h === 'localhost' || h === '127.0.0.1' || h === '::1';
  }

  const STATIC_NOTICE =
    '当前是<strong>静态预览部署</strong>：界面浏览与交互可完整体验；' +
    'AI 生成需要在本机运行后端服务。';

  // 用 file:// 打开时，所有 fetch('/api/*') 都会失败；提前给出明确指引。
  function guardOrigin() {
    if (location.protocol === 'file:') {
      const file = location.pathname.split('/').pop() || 'index.html';
      offlineBar('当前以 file:// 方式打开，云端能力不可用。请通过 ' +
        '<a href="http://localhost:8230/' + file + '">http://localhost:8230/' + file + '</a> 访问。');
      return false;
    }
    return true;
  }

  async function pingServer() {
    if (location.protocol === 'file:') return false;
    // 静态托管（GitHub Pages 等）没有后端，不必也不该发探测请求
    if (!hasLocalBackend()) return false;
    try {
      await HZ.api.health();
      clearOfflineBar();
      return true;
    } catch (_) {
      offlineBar('本地服务未响应，请先运行 <strong>server.ps1</strong> 后再刷新页面。');
      return false;
    }
  }

  HZ.ui = {
    mountIcons, esc, toast, copyText, download, fmtDate, debounce,
    initNav, guardOrigin, pingServer, offlineBar, clearOfflineBar,
    hasLocalBackend, STATIC_NOTICE
  };
})();
