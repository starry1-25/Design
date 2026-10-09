/* ==========================================================================
   绘职 AI — 图标集（线性 SVG，统一 currentColor）
   ========================================================================== */
(function () {
  'use strict';

  const S = (inner) =>
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" ' +
    'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + inner + '</svg>';

  const icons = {
    /* ---- 岗位图标 ---- */
    board: S('<rect x="3" y="3" width="18" height="18" rx="2.6"/><path d="M3 9.2h18M9.2 21V9.2"/>'),
    flow: S('<rect x="2.6" y="3" width="7" height="6" rx="1.8"/><rect x="14.4" y="15" width="7" height="6" rx="1.8"/>' +
            '<path d="M9.6 6h3.4a2.6 2.6 0 0 1 2.6 2.6v6.4"/><path d="m6.1 9-3.5 4.5L6.1 18"/>'),
    palette: S('<path d="M12 21a9 9 0 1 1 9-9c0 1.7-1.35 3-3 3h-1.6a1.9 1.9 0 0 0-1.35 3.25A1.9 1.9 0 0 1 12 21Z"/>' +
               '<circle cx="7.6" cy="12.2" r="1.05"/><circle cx="9.9" cy="7.9" r="1.05"/><circle cx="14.4" cy="7.9" r="1.05"/>'),
    megaphone: S('<path d="M4 10v4a1 1 0 0 0 1 1h2l5 4V5L7 9H5a1 1 0 0 0-1 1Z"/>' +
                 '<path d="M16 8.6a4.2 4.2 0 0 1 0 6.8"/><path d="M19 5.6a8 8 0 0 1 0 12.8"/>'),
    code: S('<path d="m8 8.2-4 3.8 4 3.8"/><path d="m16 8.2 4 3.8-4 3.8"/><path d="m13.6 5-3.2 14"/>'),

    /* ---- 界面图标 ---- */
    history: S('<circle cx="12" cy="12" r="9"/><path d="M12 7.2V12l3.4 2"/>'),
    menu: S('<path d="M4 7h16M4 12h16M4 17h16"/>'),
    sparkle: S('<path d="M12 3.2 13.9 9 19.7 10.9 13.9 12.8 12 18.6 10.1 12.8 4.3 10.9 10.1 9 12 3.2Z"/>'),
    wand: S('<path d="M3.8 20.2 14.9 9.1"/><path d="m13.5 7.7 2.8 2.8"/>' +
            '<path d="M18.6 3v3.4M16.9 4.7h3.4"/><path d="M8.1 3.7v2.2M7 4.8h2.2"/>' +
            '<path d="M19.4 10.4v2.2M18.3 11.5h2.2"/>'),
    plus: S('<path d="M12 5.2v13.6M5.2 12h13.6"/>'),
    arrowRight: S('<path d="M4.5 12h14"/><path d="m13 6.5 6 5.5-6 5.5"/>'),
    undo: S('<path d="M9.5 14.5 4.5 9.5l5-5"/><path d="M4.5 9.5h10a5.5 5.5 0 0 1 0 11H9"/>'),
    redo: S('<path d="m14.5 14.5 5-5-5-5"/><path d="M19.5 9.5h-10a5.5 5.5 0 0 0 0 11H15"/>'),
    copy: S('<rect x="9" y="9" width="12" height="12" rx="2.6"/>' +
           '<path d="M6 15H4.7A1.7 1.7 0 0 1 3 13.3V4.7A1.7 1.7 0 0 1 4.7 3h8.6A1.7 1.7 0 0 1 15 4.7V6"/>'),
    refresh: S('<path d="M3.5 12a8.5 8.5 0 0 1 14.6-5.9L21 8.8"/><path d="M21 3.6v5.2h-5.2"/>' +
               '<path d="M20.5 12a8.5 8.5 0 0 1-14.6 5.9L3 15.2"/><path d="M3 20.4v-5.2h5.2"/>'),
    download: S('<path d="M12 3.4v11.8"/><path d="m7.2 11 4.8 4.8L16.8 11"/><path d="M4.4 20.6h15.2"/>'),
    send: S('<path d="M21 3 3.4 10.4l6.5 2.6 2.6 6.5L21 3Z"/><path d="m9.9 13 5.4-5.4"/>'),
    chevronDown: S('<path d="m6.5 9.5 5.5 5.5 5.5-5.5"/>'),
    check: S('<path d="m4.5 12.6 5 5L19.5 6.6"/>'),
    alert: S('<circle cx="12" cy="12" r="9"/><path d="M12 7.4v5.4"/><path d="M12 16.3h.01"/>'),
    info: S('<circle cx="12" cy="12" r="9"/><path d="M12 11v5.4"/><path d="M12 7.7h.01"/>'),
    close: S('<path d="m6.4 6.4 11.2 11.2M17.6 6.4 6.4 17.6"/>'),
    image: S('<rect x="3" y="4" width="18" height="16" rx="2.6"/><circle cx="8.6" cy="9.6" r="1.6"/>' +
             '<path d="m3.6 17.4 5-4.6 4.2 3.6 3-2.6 4.6 4"/>'),
    sliders: S('<path d="M4 6.5h8M17 6.5h3M4 12h3M12 12h8M4 17.5h9M18 17.5h2"/>' +
               '<circle cx="14.5" cy="6.5" r="2.1"/><circle cx="9.5" cy="12" r="2.1"/><circle cx="15.5" cy="17.5" r="2.1"/>'),
    trash: S('<path d="M4 7h16"/><path d="M9.5 7V5.4A1.4 1.4 0 0 1 10.9 4h2.2a1.4 1.4 0 0 1 1.4 1.4V7"/>' +
             '<path d="m6.4 7 .9 12.1A1.5 1.5 0 0 0 8.8 20.5h6.4a1.5 1.5 0 0 0 1.5-1.4L17.6 7"/>'),
    shield: S('<path d="M12 3 5 5.8v5.4c0 4.2 2.9 7.7 7 9.3 4.1-1.6 7-5.1 7-9.3V5.8L12 3Z"/>' +
              '<path d="m9.2 12 2 2 3.6-3.8"/>'),
    edit: S('<path d="M4 20.4h4.2L20 8.6a2.15 2.15 0 0 0-3-3L5.2 17.4 4 20.4Z"/><path d="m14.6 6.6 3 3"/>'),
    key: S('<circle cx="7.8" cy="15.2" r="3.8"/><path d="m10.6 12.4 8.2-8.2"/>' +
           '<path d="m16.4 6.6 2.6 2.6"/><path d="m14.2 8.8 2.6 2.6"/>'),
    plug: S('<path d="M9 2.8v5.4M15 2.8v5.4"/>' +
            '<path d="M6.4 8.2h11.2v3.2a5.6 5.6 0 0 1-11.2 0V8.2Z"/><path d="M12 17v4.2"/>'),
    bolt: S('<path d="M13.4 3 5 13.4h5.6L10.6 21 19 10.6h-5.6L13.4 3Z"/>'),
    eye: S('<path d="M2.5 12S6 6 12 6s9.5 6 9.5 6-3.5 6-9.5 6-9.5-6-9.5-6Z"/><circle cx="12" cy="12" r="2.6"/>'),
    file: S('<path d="M13.5 3.4H7A1.6 1.6 0 0 0 5.4 5v14A1.6 1.6 0 0 0 7 20.6h10a1.6 1.6 0 0 0 1.6-1.6V8.4l-5-5Z"/>' +
            '<path d="M13.4 3.5v5h5"/>'),
    clock: S('<circle cx="12" cy="12" r="9"/><path d="M12 7.2V12l3.4 2"/>'),
    monitor: S('<rect x="2.6" y="4" width="18.8" height="12.4" rx="2.2"/><path d="M9 20.4h6M12 16.4v4"/>'),
    mobile: S('<rect x="6.6" y="2.6" width="10.8" height="18.8" rx="2.6"/><path d="M10.6 18.6h2.8"/>')
  };

  window.HZ = window.HZ || {};
  window.HZ.icons = icons;
  window.HZ.icon = (name) => icons[name] || icons.info;
})();
