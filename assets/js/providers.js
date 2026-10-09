/* ==========================================================================
   绘职 AI — 大模型接入配置
   新增 / 测试 / 保存 / 切换 / 删除，全部通过本地服务端完成。
   密钥由服务端用 DPAPI 加密落盘，前端只会拿到掩码后的值。
   ========================================================================== */
(function () {
  'use strict';

  const { api, ui } = window.HZ;
  const $ = (sel, root) => (root || document).querySelector(sel);

  const STEP_LABEL = {
    url:   'API 地址',
    auth:  '连通与鉴权',
    chat:  '文本模型',
    image: '图像模型'
  };

  const MODEL_CHIP_LIMIT = 24;

  const state = {
    providers: [],
    activeChatId: '',
    activeImageId: '',
    editingId: '',
    busy: false,
    lastModels: [],
    fillTarget: 'chat'   // 模型 chip 点击后填到哪个输入框
  };

  const els = {};

  function find(id) {
    return state.providers.filter((p) => p.id === id)[0] || null;
  }

  function notifyChanged() {
    try {
      document.dispatchEvent(new CustomEvent('hz:providers-changed'));
    } catch (_) {}
  }

  /* ------------------------------------------------------------ 列表渲染 */
  function renderList() {
    // 空态用真实 DOM 而不是 CSS 伪元素：伪元素读屏软件读不到，也无法被检索
    if (!state.providers.length) {
      els.list.innerHTML =
        '<div class="prov-empty">' +
          '<span class="prov-empty-ico" data-icon="plug" aria-hidden="true"></span>' +
          '<div>' +
            '<strong>还没有接入任何模型</strong>' +
            '<span>点击右上角「添加模型接入」，填入 API 地址、密钥与模型标识即可开始使用。</span>' +
          '</div>' +
        '</div>';
      ui.mountIcons(els.list);
      return;
    }

    els.list.innerHTML = state.providers.map((p) => {
      const isChat = state.activeChatId === p.id;
      const isImage = state.activeImageId === p.id;

      const badges = [];
      badges.push(p.chatModel
        ? '<span class="prov-badge ' + (isChat ? 'chat' : 'off') + '">文本 · ' + ui.esc(p.chatModel) + (isChat ? ' · 已启用' : '') + '</span>'
        : '<span class="prov-badge off">未设文本模型</span>');
      badges.push(p.imageModel
        ? '<span class="prov-badge ' + (isImage ? 'image' : 'off') + '">图像 · ' + ui.esc(p.imageModel) + (isImage ? ' · 已启用' : '') + '</span>'
        : '<span class="prov-badge off">未设图像模型</span>');

      return '<div class="prov-item' + ((isChat || isImage) ? ' is-on' : '') + '" data-id="' + ui.esc(p.id) + '">' +
        '<div class="prov-main">' +
          '<div class="prov-name">' + ui.esc(p.name || '未命名接入') + '</div>' +
          '<div class="prov-url">' + ui.esc(p.baseUrl) + '　密钥 ' + ui.esc(p.keyMasked || '未设置') + '</div>' +
          '<div class="prov-models">' + badges.join('') + '</div>' +
        '</div>' +
        '<div class="prov-actions">' +
          (p.chatModel
            ? '<button class="btn" type="button" data-act="use-chat"' + (isChat ? ' disabled' : '') + '>' +
              '<span data-icon="plug"></span><span>' + (isChat ? '文本已启用' : '设为文本') + '</span></button>'
            : '') +
          (p.imageModel
            ? '<button class="btn" type="button" data-act="use-image"' + (isImage ? ' disabled' : '') + '>' +
              '<span data-icon="plug"></span><span>' + (isImage ? '图像已启用' : '设为图像') + '</span></button>'
            : '') +
          '<button class="btn" type="button" data-act="test">' +
            '<span data-icon="shield"></span><span>测试</span></button>' +
          '<button class="btn" type="button" data-act="edit">' +
            '<span data-icon="edit"></span><span>编辑</span></button>' +
          '<button class="btn is-danger" type="button" data-act="del">' +
            '<span data-icon="trash"></span><span>删除</span></button>' +
        '</div>' +
      '</div>';
    }).join('');

    ui.mountIcons(els.list);
  }

  /* ------------------------------------------------------------ 测试结果 */
  function stepText(s) {
    if (s.status === 'pass') return '通过';
    if (s.status === 'fail') return '失败';
    if (s.status === 'warn') return '需要注意';
    return '已跳过';
  }

  function renderResult(res, heading) {
    const steps = (res.steps || []).map((s) => {
      const iconName =
        s.status === 'pass' ? 'check' :
        s.status === 'fail' ? 'alert' :
        s.status === 'warn' ? 'alert' : 'info';

      let lines = '<em>' + ui.esc(stepText(s)) + (s.detail ? '　' + ui.esc(s.detail) : '') + '</em>';
      if (s.status !== 'pass' && s.code) {
        const hint = api.friendly({ code: s.code });
        if (hint) lines += '<em>' + ui.esc(hint) + '</em>';
      }

      return '<div class="pf-step ' + ui.esc(s.status) + '">' +
        '<span class="pf-step-ico">' + HZ.icon(iconName) + '</span>' +
        '<span class="pf-step-label">' + ui.esc(STEP_LABEL[s.key] || s.key) + '</span>' +
        '<span class="pf-step-text">' + lines + '</span>' +
      '</div>';
    }).join('');

    let picker = '';
    if (res.models && res.models.length) {
      state.lastModels = res.models;
      const shown = res.models.slice(0, MODEL_CHIP_LIMIT);
      picker = '<div class="model-picker">' +
        '<h5>探测到 ' + res.models.length + ' 个模型' +
          (res.models.length > shown.length ? '（仅显示前 ' + shown.length + ' 个）' : '') +
          ' · 点击即可填入选中的模型输入框</h5>' +
        '<div class="chips">' +
          shown.map((m) => '<button class="chip" type="button" data-model="' + ui.esc(m) + '">' + ui.esc(m) + '</button>').join('') +
        '</div>' +
      '</div>';
    } else {
      state.lastModels = [];
    }

    els.result.className = 'pf-result ' + (res.passed ? 'pass' : 'fail');
    els.result.innerHTML =
      '<div class="pf-steps"><div class="pf-step ' + (res.passed ? 'pass' : 'fail') + '">' +
        '<span class="pf-step-ico">' + HZ.icon(res.passed ? 'check' : 'alert') + '</span>' +
        '<span class="pf-step-label">' + ui.esc(heading || (res.passed ? '连接正常' : '连接失败')) + '</span>' +
        '<span class="pf-step-text"><em>' + (res.latencyMs ? '总耗时 ' + res.latencyMs + ' ms' : '') + '</em></span>' +
      '</div></div>' +
      '<div class="pf-steps" style="margin-top:11px">' + steps + '</div>' +
      picker;

    els.result.classList.remove('is-hidden');
    ui.mountIcons(els.result);

    els.result.querySelectorAll('[data-model]').forEach((b) =>
      b.addEventListener('click', () => {
        const target = state.fillTarget === 'image' ? els.imageModel : els.chatModel;
        target.value = b.dataset.model;
        ui.toast('已填入' + (state.fillTarget === 'image' ? '图像' : '文本') + '模型：' + b.dataset.model, 'ok');
      }));
  }

  function setStatus(text, kind) {
    els.status.textContent = text || '';
    els.status.style.color = kind === 'err' ? 'var(--danger)' : (kind === 'ok' ? 'var(--mint)' : '');
  }

  /* ---------------------------------------------------------------- 表单 */
  function openForm(id) {
    state.editingId = id || '';
    const p = id ? find(id) : null;

    els.title.textContent = p ? ('编辑接入 · ' + (p.name || '未命名')) : '添加模型接入';
    els.name.value = p ? p.name : '';
    els.baseUrl.value = p ? p.baseUrl : '';
    els.chatModel.value = p ? p.chatModel : '';
    els.imageModel.value = p ? p.imageModel : '';
    els.apiKey.value = '';
    els.keyHint.textContent = p
      ? '留空表示不修改已保存的密钥（当前 ' + (p.keyMasked || '未设置') + '）'
      : '仅加密保存在本机';

    els.form.classList.remove('is-hidden');
    els.result.classList.add('is-hidden');
    els.result.innerHTML = '';
    setStatus('');
    els.name.focus();
    els.form.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  }

  function closeForm() {
    state.editingId = '';
    els.form.classList.add('is-hidden');
    els.result.classList.add('is-hidden');
    setStatus('');
  }

  function gather() {
    return {
      id: state.editingId || undefined,
      name: els.name.value.trim(),
      baseUrl: els.baseUrl.value.trim(),
      apiKey: els.apiKey.value.trim(),
      chatModel: els.chatModel.value.trim(),
      imageModel: els.imageModel.value.trim()
    };
  }

  function validate(payload) {
    if (!payload.baseUrl) return api.friendly({ code: 'url_empty' });
    if (!/^https?:\/\//i.test(payload.baseUrl)) return api.friendly({ code: 'url_scheme' });
    if (!payload.chatModel && !payload.imageModel) return api.friendly({ code: 'no_model' });
    if (!payload.id && !payload.apiKey) return api.friendly({ code: 'no_api_key' });
    return '';
  }

  /* -------------------------------------------------------------- 动作 */
  async function runTest(payload, heading) {
    if (state.busy) return null;
    const problem = validate(payload);
    if (problem) { setStatus(problem, 'err'); ui.toast(problem, 'err'); return null; }

    state.busy = true;
    els.test.disabled = true;
    els.save.disabled = true;
    setStatus('正在测试连接，请稍候…');
    els.result.classList.add('is-hidden');

    try {
      const res = await api.providers.test(payload);
      renderResult(res, heading);
      setStatus(res.passed ? '连接测试通过' : '连接测试未通过', res.passed ? 'ok' : 'err');
      return res;
    } catch (err) {
      const msg = api.friendly(err);
      setStatus(msg, 'err');
      ui.toast(msg, 'err');
      return null;
    } finally {
      state.busy = false;
      els.test.disabled = false;
      els.save.disabled = false;
    }
  }

  async function doTest() {
    if (!ui.hasLocalBackend()) {
      ui.toast('静态预览部署无法测试连接，请在本机运行后端服务', 'info');
      return;
    }
    const payload = gather();
    // 编辑已有接入且未重填密钥时，让服务端用已保存的密钥来测
    if (state.editingId && !payload.apiKey) {
      await runTest({
        id: state.editingId,
        baseUrl: payload.baseUrl,
        chatModel: payload.chatModel,
        imageModel: payload.imageModel
      }, '测试结果');
    } else {
      await runTest(payload, '测试结果');
    }
  }

  async function doSave() {
    if (state.busy) return;
    if (!ui.hasLocalBackend()) {
      ui.toast('静态预览部署无法保存接入配置，请在本机运行后端服务', 'info');
      return;
    }
    const payload = gather();
    const problem = validate(payload);
    if (problem) { setStatus(problem, 'err'); ui.toast(problem, 'err'); return; }

    if (!payload.name) {
      payload.name = payload.chatModel || payload.imageModel || '未命名接入';
    }

    state.busy = true;
    els.save.disabled = true;
    els.test.disabled = true;
    setStatus('正在保存…');

    try {
      const res = await api.providers.save(payload);
      applyList(res);
      renderList();
      closeForm();
      ui.toast(state.providers.length > 1 ? '接入已保存' : '接入已保存，并已自动启用', 'ok');
      notifyChanged();
    } catch (err) {
      const msg = api.friendly(err);
      setStatus(msg, 'err');
      ui.toast(msg, 'err');
    } finally {
      state.busy = false;
      els.save.disabled = false;
      els.test.disabled = false;
    }
  }

  function applyList(res) {
    if (!res) return;
    state.providers = res.providers || [];
    state.activeChatId = res.activeChatId || '';
    state.activeImageId = res.activeImageId || '';
  }

  async function doActivate(id, capability) {
    if (state.busy) return;
    state.busy = true;
    try {
      const res = await api.providers.activate({ id: id, capability: capability });
      applyList(res);
      renderList();
      ui.toast(capability === 'image' ? '已切换图像模型' : '已切换文本模型', 'ok');
      notifyChanged();
    } catch (err) {
      ui.toast(api.friendly(err), 'err');
    } finally {
      state.busy = false;
    }
  }

  async function doDelete(id) {
    if (state.busy) return;
    const p = find(id);
    if (!p) return;
    if (!window.confirm('确定删除接入「' + (p.name || '未命名') + '」吗？该操作不可撤销。')) return;

    state.busy = true;
    try {
      const res = await api.providers.remove(id);
      applyList(res);
      renderList();
      if (state.editingId === id) closeForm();
      ui.toast('已删除该接入', 'ok');
      notifyChanged();
    } catch (err) {
      ui.toast(api.friendly(err), 'err');
    } finally {
      state.busy = false;
    }
  }

  async function testSaved(id) {
    state.fillTarget = 'chat';
    await runTest({ id: id }, '测试结果 · ' + ((find(id) || {}).name || ''));
    if (!els.form.classList.contains('is-hidden') && state.editingId !== id) closeForm();
    els.result.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  }

  /* -------------------------------------------------------------- 事件 */
  function bind() {
    els.list.addEventListener('click', (e) => {
      const btn = e.target.closest('[data-act]');
      if (!btn) return;
      const item = btn.closest('.prov-item');
      if (!item) return;
      const id = item.dataset.id;
      const act = btn.dataset.act;
      if (act === 'use-chat')  return doActivate(id, 'chat');
      if (act === 'use-image') return doActivate(id, 'image');
      if (act === 'edit')      return openForm(id);
      if (act === 'del')       return doDelete(id);
      if (act === 'test')      return testSaved(id);
    });

    if (els.add) els.add.addEventListener('click', () => openForm(''));
    els.cancel.addEventListener('click', closeForm);
    els.test.addEventListener('click', doTest);
    els.save.addEventListener('click', doSave);

    // 记住用户最后聚焦的是哪个模型输入框，模型 chip 就填到那里
    els.chatModel.addEventListener('focus', () => { state.fillTarget = 'chat'; });
    els.imageModel.addEventListener('focus', () => { state.fillTarget = 'image'; });

    els.baseUrl.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); doTest(); }
    });
  }

  /* -------------------------------------------------------------- 初始化 */
  function renderListLoading() {
    els.list.innerHTML =
      '<div class="skeleton" style="height:78px"></div>' +
      '<div class="skeleton" style="height:78px"></div>';
  }

  function renderListError(err) {
    // 读取失败时绝不能落到"还没有接入任何模型"的空态上去 —— 那会误导用户
    els.list.innerHTML =
      '<div class="empty" style="padding:24px 18px">' +
        '<div class="empty-ico" data-icon="alert"></div>' +
        '<h3>读取接入配置失败</h3>' +
        '<p>' + ui.esc(api.friendly(err)) + '</p>' +
        '<button class="btn is-primary" type="button" id="provRetry">' +
          '<span data-icon="refresh"></span><span>重新读取</span></button>' +
      '</div>';
    ui.mountIcons(els.list);
    const btn = $('#provRetry');
    if (btn) btn.addEventListener('click', load);
  }

  async function load() {
    // 静态托管没有后端：接入配置无法读写，直接说明而不是报错
    if (!ui.hasLocalBackend()) {
      els.list.innerHTML =
        '<div class="prov-empty">' +
          '<span class="prov-empty-ico" data-icon="monitor" aria-hidden="true"></span>' +
          '<div>' +
            '<strong>静态预览部署</strong>' +
            '<span>本站没有后端服务，无法保存接入配置。请在本机运行 start.ps1，' +
              '再通过 http://localhost:8230/settings.html 进行配置。</span>' +
          '</div>' +
        '</div>';
      ui.mountIcons(els.list);
      return;
    }

    renderListLoading();
    try {
      applyList(await api.providers.list());
      renderList();
      notifyChanged();
    } catch (err) {
      renderListError(err);
    }
  }

  function init() {
    els.list      = $('#provList');
    els.form      = $('#provForm');
    els.title     = $('#pfTitle');
    els.name      = $('#pfName');
    els.baseUrl   = $('#pfBaseUrl');
    els.apiKey    = $('#pfApiKey');
    els.keyHint   = $('#pfKeyHint');
    els.chatModel = $('#pfChatModel');
    els.imageModel= $('#pfImageModel');
    els.test      = $('#pfTest');
    els.save      = $('#pfSave');
    els.cancel    = $('#pfCancel');
    els.status    = $('#pfStatus');
    els.result    = $('#pfResult');
    els.add       = $('#addProvider');

    if (!els.list) return;
    bind();
    load();
  }

  window.HZ = window.HZ || {};
  window.HZ.providersUI = {
    reload: load,
    count: () => state.providers.length
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();