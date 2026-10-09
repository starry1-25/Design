/* ==========================================================================
   绘职 AI — 设置 / 个人中心
   ========================================================================== */
(function () {
  'use strict';

  const { api, ui } = window.HZ;
  const $ = (sel) => document.querySelector(sel);

  const FALLBACK_ROLES = [
    { id: 'pm', name: '产品经理', defaultRatio: '16:9' },
    { id: 'ixd', name: '交互设计', defaultRatio: '16:9' },
    { id: 'ui', name: 'UI 设计', defaultRatio: '9:16' },
    { id: 'ops', name: '运营设计', defaultRatio: '9:16' },
    { id: 'fe', name: '前端开发', defaultRatio: '16:9' }
  ];

  let roles = FALLBACK_ROLES.slice();
  let ratios = ['1:1', '16:9', '9:16', '4:3'];
  let prefs = {};

  /* ------------------------------------------------------------------ 偏好 */
  function loadPrefs() {
    try { prefs = JSON.parse(localStorage.getItem('hz.prefs') || '{}') || {}; }
    catch (_) { prefs = {}; }
  }

  function savePrefs() {
    try { localStorage.setItem('hz.prefs', JSON.stringify(prefs)); } catch (_) {}
  }

  function roleName(id) {
    const r = roles.filter((x) => x.id === id)[0];
    return r ? r.name : id;
  }

  function renderPrefs() {
    if (!prefs.roleId) prefs.roleId = (roles[0] || FALLBACK_ROLES[0]).id;
    if (!prefs.ratio) prefs.ratio = '16:9';

    $('#prefRoles').innerHTML = roles.map((r) =>
      '<button class="chip chip-text' + (r.id === prefs.roleId ? ' is-on' : '') + '" type="button" ' +
      'data-role="' + ui.esc(r.id) + '">' + ui.esc(r.name) + '</button>').join('');

    $('#prefRatios').innerHTML = ratios.map((r) =>
      '<button class="chip' + (r === prefs.ratio ? ' is-on' : '') + '" type="button" ' +
      'data-ratio="' + ui.esc(r) + '">' + ui.esc(r) + '</button>').join('');

    $('#prefSummary').textContent = roleName(prefs.roleId) + ' · ' + prefs.ratio;
  }

  function bindPrefs() {
    $('#prefRoles').addEventListener('click', (e) => {
      const b = e.target.closest('[data-role]');
      if (!b) return;
      prefs.roleId = b.dataset.role;
      savePrefs(); renderPrefs();
      ui.toast('默认岗位已设为「' + roleName(prefs.roleId) + '」', 'ok');
    });

    $('#prefRatios').addEventListener('click', (e) => {
      const b = e.target.closest('[data-ratio]');
      if (!b) return;
      prefs.ratio = b.dataset.ratio;
      savePrefs(); renderPrefs();
      ui.toast('默认比例已设为 ' + prefs.ratio, 'ok');
    });
  }

  /* -------------------------------------------------------------- 运行状态 */
  function describe(side) {
    if (!side || !side.configured) return '未启用';
    const name = side.name ? '（' + side.name + '）' : '';
    return side.model + name;
  }

  async function loadHealth() {
    const live = $('#svcLive');

    // 静态托管没有后端：不探测，直接呈现"静态预览"
    if (!ui.hasLocalBackend()) {
      live.classList.remove('is-off');
      live.classList.add('is-warn');
      live.innerHTML = '<i aria-hidden="true"></i> 静态预览';
      $('#svcVersion').textContent = '静态部署';
      $('#svcCount').textContent = '—';
      $('#svcChat').textContent = '静态部署不可用';
      $('#svcImage').textContent = '静态部署不可用';
      $('#svcReady').textContent = '需在本机运行后端服务';
      ui.offlineBar(ui.STATIC_NOTICE);
      return;
    }

    try {
      const h = await api.health();
      live.classList.remove('is-off');
      live.innerHTML = '<i aria-hidden="true"></i> 正常';
      $('#svcVersion').textContent = 'v' + (h.version || '—');
      $('#svcCount').textContent = (h.providerCount || 0) + ' 个';
      $('#svcChat').textContent = describe(h.chat);
      $('#svcImage').textContent = describe(h.image);
      $('#svcReady').textContent = h.configured ? '就绪，可以生成' : '待配置，请先接入模型';
    } catch (_) {
      live.classList.add('is-off');
      live.innerHTML = '<i aria-hidden="true"></i> 未连接';
      ['#svcVersion', '#svcCount', '#svcChat', '#svcImage', '#svcReady'].forEach((s) => {
        const el = $(s);
        if (el) el.textContent = '—';
      });
      ui.offlineBar('本地服务未响应，请先运行 <strong>server.ps1</strong> 后再刷新页面。');
    }
  }

  /* -------------------------------------------------------------- 数据统计 */
  async function loadData() {
    if (!ui.hasLocalBackend()) { $('#dataCount').textContent = '—'; return; }
    try {
      const d = await api.history();
      const n = (d.records || []).length;
      $('#dataCount').textContent = n + ' 条';
    } catch (_) {
      $('#dataCount').textContent = '—';
    }
  }

  /* ------------------------------------------------------------------ 启动 */
  function init() {
    ui.initNav();
    ui.mountIcons(document);
    ui.guardOrigin();

    loadPrefs();

    // 岗位列表优先取服务端
    api.roles().then((d) => {
      if (d && d.roles && d.roles.length) {
        roles = d.roles;
        if (d.ratios && d.ratios.length) ratios = d.ratios;
      }
      renderPrefs();
    }).catch(() => { renderPrefs(); });

    renderPrefs();
    bindPrefs();

    $('#resetPrefs').addEventListener('click', () => {
      prefs = {};
      try { localStorage.removeItem('hz.prefs'); } catch (_) {}
      renderPrefs();
      ui.toast('已重置本机偏好', 'ok');
    });

    // 接入配置发生增删改或切换后，运行状态卡片需要同步刷新
    document.addEventListener('hz:providers-changed', loadHealth);

    loadHealth();
    loadData();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else { init(); }
})();
