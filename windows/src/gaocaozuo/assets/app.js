"use strict";

const token = document.querySelector('meta[name="gao-token"]').content;
const version = document.querySelector('meta[name="gao-version"]').content;
const marketingVersion = version.replace(/^(Windows\s*)?v?/i, "").split("+")[0];
document.title = "搞操作 V" + marketingVersion;
const app = document.querySelector("#app");
const sections = {
  home: ["工作台", "grid"],
  screenshots: ["截图与录制", "scan"],
  clipboard: ["剪贴板", "clip"],
  files: ["文件", "folder"],
  archives: ["压缩与解压", "archive"],
  tools: ["实用工具", "wand"],
  windows: ["窗口", "window"],
  overview: ["桌面总览", "desktops"],
  lockPolicy: ["锁屏策略", "lock"],
  input: ["快捷键与手势", "keyboard"],
  workflows: ["组合操作", "layers"],
  history: ["恢复记录", "history"],
};
const navigation = [
  ["", ["home"]],
  ["日常工具", ["screenshots", "clipboard", "files", "archives", "tools"]],
  ["桌面与窗口", ["windows", "overview", "lockPolicy"]],
  ["自动化", ["input", "workflows"]],
  ["活动", ["history"]],
];
const paths = {
  command: "M7 10H6a2 2 0 1 1 2-2v8a2 2 0 1 1-2-2h12a2 2 0 1 1-2 2V8a2 2 0 1 1 2 2z",
  grid: "M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z",
  scan: "M4 9V4h5m6 0h5v5m0 6v5h-5m-6 0H4v-5m5-3h6m-3-3v6",
  clip: "M8 6H5v15h14V6h-3M8 4h8v5H8zm1 9h6m-6 4h6",
  folder: "M3 7V5h6l2 2h10v12H3z",
  archive: "M4 8v12h16V8M3 4h18v4H3zm7 8h4",
  wand: "m4 20 12-12 3 3L7 23zM13 11l3 3m4-11v4m-2-2h4M9 3v4M7 5h4",
  window: "M3 5h18v14H3zm9 0v14m-9-9h18",
  desktops: "M3 5h12v10H3zm12 3h6v11H8v-4m-5-7h12",
  lock: "M7 10h10v10H7zm2 0V7a3 3 0 0 1 6 0v3m-3 4v2",
  keyboard: "M3 6h18v12H3zm3 4h1m3 0h1m3 0h1m3 0h1M6 14h1m3 0h6m2 0h1",
  layers: "m3 8 9-5 9 5-9 5zm0 4 9 5 9-5M3 16l9 5 9-5",
  history: "M3 11a9 9 0 1 1 1 5m-2-9 1 4 4-1m5-4v6l4 2",
  settings: "m10 3-1 3-3 1-3 3v4h3l1 3 3 3h4l1-3 3-1 3-3v-3l-3-1-1-3-3-3zm2 6a3 3 0 1 0 0 6 3 3 0 0 0 0-6z",
  search: "M15 15a6 6 0 1 1 0-8 6 6 0 0 1 0 8zm1 1 4 4",
  arrow: "M3 12h16m-6-6 6 6-6 6",
  external: "M11 5h8v8m-1-7-8 8m2 5H5V8h6",
  chevron: "m9 5 7 7-7 7",
  check: "m5 12 4 4L19 6",
  sparkle: "M12 2c0 5-3 8-8 10 5 1 8 4 8 10 1-5 4-9 8-10-4-1-8-4-8-10z",
  plus: "M12 5v14M5 12h14",
  close: "m6 6 12 12M18 6 6 18",
  star: "m12 3 2.8 5.8 6.4.9-4.6 4.5 1.1 6.3-5.7-3-5.7 3 1.1-6.3L2.8 9.7l6.4-.9z",
  inbox: "M4 6h16l2 9v5H2v-5zm-2 9h6l2 2h4l2-2h6m-10-9v6m-3-3 3 3 3-3",
  file: "M5 3h9l5 5v13H5zm9 0v6h5M8 13h8m-8 4h8",
  image: "M3 4h18v16H3zm1 13 5-5 4 4 3-3 4 4m-4-8h1",
  monitor: "M2 4h20v13H2zm10 13v4m-5 0h10",
  pin: "m9 3 10 10-4 1-3 4-2-2-6 5 4-6-2-2 4-3z",
  trash: "M4 6h16M9 6V3h6v3M6 6l1 14h10l1-14m-8 4v6m4-6v6",
  play: "m8 4 12 8-12 8z",
  warning: "m12 3 10 17H2zm0 6v4m0 3v1",
  sun: "M12 2v3m0 14v3M2 12h3m14 0h3m-17-7 2 2m10 10 2 2m0-14-2 2M7 17l-2 2m7-11a4 4 0 1 0 0 8 4 4 0 0 0 0-8z",
};
let state = {};
let catalog = [];
let section = Object.hasOwn(sections, location.hash.slice(1)) ? location.hash.slice(1) : "home";
let files = [];
let targetID = "";
let windows = [];
let listLoaded = false;
let idleStatus;
let rules = [];
let windowQuery = "";
let windowApp = "";
let clipQuery = "";
let clipGroup = "";
let lastOutputs = [];
let banner = { text: "", error: false };
let footer;
let pending = 0;
let actionRequests = 0;
let dialog = null;
let clipboardPoll = 0;
let selectionRevision = null;
let statePollInFlight = false;
let uiStrings = {};
let uiErrorTemplates = [];
let cloud = {};
const interfaceLanguages = [["system", "跟随系统"], ["zh-Hans", "简体中文"], ["zh-Hant", "繁體中文"], ["en", "English"],
  ["ja", "日本語"], ["de", "Deutsch"], ["fr", "Français"], ["es", "Español"], ["it", "Italiano"], ["ko", "한국어"], ["pt", "Português"]];

function tr(value) {
  if (typeof value !== "string") return value;
  if (Object.hasOwn(uiStrings, value)) return uiStrings[value];
  const base = value.replace(/…$/, "");
  return base !== value && Object.hasOwn(uiStrings, base) ? uiStrings[base] + "…" : value;
}
const messageVariable = /\{([a-zA-Z][a-zA-Z0-9_]*)\}/g;
const quotePattern = value => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
function formatMessage(key, values) {
  return tr(key).replace(messageVariable, (match, name) => Object.hasOwn(values, name) ? String(values[name]) : match);
}
const layoutErrorDetails = ["已确认恢复操作前的位置；原位置记录保留。", "未能确认恢复操作前的位置；原位置记录已保留，请用“恢复原位置”重试。"];
function errorTemplates(strings) {
  const templates = [];
  for (const key of Object.keys(strings)) {
    const matches = [...key.matchAll(messageVariable)];
    if (!matches.length || (key.replace(messageVariable, "").match(/[\u3400-\u9fff]/g) || []).length < 8) continue;
    const parts = [];
    let offset = 0;
    for (const capture of matches) {
      parts.push(quotePattern(key.slice(offset, capture.index)), "([\\s\\S]*?)");
      offset = capture.index + capture[0].length;
    }
    parts.push(quotePattern(key.slice(offset)));
    templates.push({key, names: matches.map(match => match[1]), pattern: new RegExp("^" + parts.join("") + "$")});
  }
  return templates.sort((left, right) => right.key.length - left.key.length);
}
function trError(value) {
  const exact = tr(value);
  if (exact !== value || typeof value !== "string" || value.length > 4096) return exact;
  for (const entry of uiErrorTemplates) {
    const match = entry.pattern.exec(value);
    if (match) return formatMessage(entry.key, Object.fromEntries(entry.names.map((name, index) => [name, match[index + 1]])));
  }
  for (const detail of layoutErrorDetails) {
    if (value.endsWith(" " + detail)) return tr(value.slice(0, -detail.length - 1)) + " " + tr(detail);
  }
  return value;
}
async function loadInterfaceLanguage() {
  let language = state.settings?.language || "system";
  if (language === "system") {
    const system = navigator.languages?.[0] || navigator.language || "en";
    language = /^(zh-Hant|zh-TW|zh-HK|zh-MO)/i.test(system) ? "zh-Hant" : /^zh/i.test(system) ? "zh-Hans" : system.split("-")[0];
  }
  if (!interfaceLanguages.some(([id]) => id === language)) language = "en";
  const result = await api("/api/localization?lang=" + encodeURIComponent(language));
  uiStrings = result.strings || {};
  uiErrorTemplates = errorTemplates(uiStrings);
  document.documentElement.lang = language;
}

async function api(path, body) {
  const tracksWork = body !== undefined && path !== "/api/shutdown" && !path.startsWith("/api/lifecycle");
  if (tracksWork) actionRequests += 1;
  try {
    const response = await fetch(path, {
      method: body === undefined ? "GET" : "POST",
      headers: { "X-Gao-Token": token, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const data = await response.json();
    if (!response.ok || data.ok === false) {
      const error = new Error(data.error || "操作没有完成。");
      error.code = data.code;
      throw error;
    }
    if (data.state) state = data.state;
    return data.result === undefined ? data : data.result;
  } finally {
    if (tracksWork) actionRequests -= 1;
  }
}
const perform = (id, payload = {}) => api("/api/action", { id, payload });

function el(tag, text, cls, userContent = false) {
  const node = document.createElement(tag);
  if (text !== undefined && text !== "") node.textContent = userContent ? text : tr(text);
  if (cls) node.className = cls;
  return node;
}
function box(cls, ...children) {
  const node = el("div", "", cls);
  node.append(...children.filter(Boolean));
  return node;
}
function icon(key) {
  const ns = "http://www.w3.org/2000/svg";
  const node = document.createElementNS(ns, "svg");
  for (const [k, v] of Object.entries({ viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", "stroke-width": "1.55", "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true" })) {
    node.setAttribute(k, v);
  }
  const path = document.createElementNS(ns, "path");
  path.setAttribute("d", paths[key] || paths.file);
  node.append(path);
  return node;
}
function button(title, handler, { cls = "", glyph, disabled = false, label } = {}) {
  const node = el("button", "", (cls + (glyph ? " icon-button" : "")).trim());
  node.type = "button";
  if (glyph) node.append(icon(glyph));
  if (title) node.append(el("span", title));
  if (label) {
    node.title = tr(label);
    node.setAttribute("aria-label", tr(label));
  }
  node.disabled = disabled;
  node.addEventListener("click", event => {
    try { Promise.resolve(handler(event)).catch(report); }
    catch (error) { report(error); }
  });
  return node;
}
function input(value = "", { type = "text", placeholder = "", min, max, step, cls } = {}) {
  const node = el("input", "", cls);
  node.type = type;
  node.value = value;
  node.placeholder = tr(placeholder);
  if (placeholder) node.setAttribute("aria-label", tr(placeholder));
  if (min !== undefined) node.min = min;
  if (max !== undefined) node.max = max;
  if (step !== undefined) node.step = step;
  return node;
}
function area(value = "", placeholder = "") {
  const node = el("textarea");
  node.value = value;
  node.placeholder = tr(placeholder);
  if (placeholder) node.setAttribute("aria-label", tr(placeholder));
  return node;
}
function select(items, current = "") {
  const node = el("select");
  for (const item of items) {
    const [value, title] = Array.isArray(item) ? item : [item, item];
    const option = el("option", title);
    option.value = value;
    node.append(option);
  }
  if (items.some(item => (Array.isArray(item) ? item[0] : item) === current)) node.value = current;
  return node;
}
function field(label, control) {
  return boxLabel("field", el("span", label), control);
}
function boxLabel(cls, ...children) {
  const node = el("label", "", cls);
  node.append(...children);
  return node;
}
function toggle(label, value, changed, userContent = false) {
  const check = el("input");
  check.type = "checkbox";
  check.checked = Boolean(value);
  if (changed) check.addEventListener("change", () => Promise.resolve(changed(check.checked)).catch(report));
  return boxLabel("option", check, el("span", label, undefined, userContent));
}
function note(value) { return el("p", value, "muted"); }
function empty(glyph, title, detail) {
  return box("empty", icon(glyph), el("strong", title), detail && note(detail));
}
function panel(title, ...content) {
  return box("panel", title && el("h2", title), ...content);
}
function go(next, focus = false) {
  if (next !== section) {
    section = next;
    history.replaceState(null, "", "#" + next);
    render();
    if (["windows", "overview"].includes(section)) refreshWindows(false);
    if (section === "input") refreshRules();
  }
  if (focus) document.querySelector(".workspace-header h1")?.focus({preventScroll: true});
}
function say(text, error = false) {
  banner = { text, error };
  drawFooter();
}
function report(error, current = dialog) {
  if (current?.open) {
    const message = current.querySelector(".modal-error");
    message.textContent = trError(error.message);
    message.hidden = false;
    return;
  }
  say(error.message, true);
}
async function progress(message, operation) {
  pending += 1;
  say(message);
  try { return await operation(); }
  finally {
    pending -= 1;
    drawFooter();
  }
}
function drawFooter() {
  if (!footer) return;
  const text = banner.text || state.message || "就绪";
  const status = box("workspace-status", banner.error ? icon("warning") : el("i", "", pending ? "status-working" : "status-dot"),
    el("span", banner.error ? trError(text) : text, banner.error ? "error" : "", banner.error));
  status.setAttribute("role", "status");
  status.setAttribute("aria-live", "polite");
  const actions = box("row");
  if (lastOutputs.length) actions.append(button("上次结果", () => perform("finder.reveal", { path: lastOutputs[0], launch: true }), { glyph: "folder" }));
  if (state.awake) {
    const sun = icon("sun");
    sun.setAttribute("aria-label", "保持唤醒已开启");
    sun.setAttribute("role", "img");
    actions.append(sun);
  }
  if (pending) footer.setAttribute("aria-busy", "true");
  else footer.removeAttribute("aria-busy");
  footer.replaceChildren(status, actions);
}
function basename(path) { return String(path || "").split(/[\\/]/).filter(Boolean).at(-1) || String(path || ""); }
function dateLabel(value) {
  const date = new Date(value);
  return value && !Number.isNaN(date.getTime()) ? date.toLocaleString(document.documentElement.lang) : "";
}
function currentAction(id) { return catalog.find(item => item.id === id); }
function rememberOutputs(result) {
  if (!result) return [];
  const candidates = [result.path, ...(result.paths || []), ...(result.parts || []),
    ...(result.receipts || []).map(item => item.destination), ...(result.items || []).map(item => item.destination)];
  const outputs = candidates.filter(value => typeof value === "string" && value);
  if (outputs.length) lastOutputs = [...new Set(outputs)];
  return outputs;
}

function render() {
  const refocusTitle = document.activeElement?.matches(".workspace-header h1");
  if (dialog?.open) dialog.close();
  document.documentElement.dataset.theme = state.settings?.appearance || "system";
  const side = el("aside", "", "sidebar");
  const logo = el("img", "", "brand-logo");
  logo.src = "/operation-icon.png";
  logo.alt = "";
  const brand = box("brand", logo, el("strong", "搞操作"));
  const nav = el("nav", "", "nav");
  nav.id = "workspace-navigation";
  nav.setAttribute("aria-label", tr("主导航"));
  const navToggle = button("导航", () => setNavigation(navToggle.getAttribute("aria-expanded") === "false"), {cls: "nav-reveal", glyph: "grid"});
  const setNavigation = open => {
    side.classList.toggle("navigation-open", open);
    navToggle.setAttribute("aria-expanded", String(open));
  };
  navToggle.setAttribute("aria-controls", nav.id);
  setNavigation(false);
  side.addEventListener("keydown", event => {
    if (event.key === "Escape" && navToggle.getAttribute("aria-expanded") === "true") {
      event.preventDefault();
      setNavigation(false);
      navToggle.focus();
    }
  });
  side.addEventListener("focusout", event => {
    if (event.relatedTarget && !side.contains(event.relatedTarget)) setNavigation(false);
  });
  for (const [group, entries] of navigation) {
    const block = box("nav-group", group && el("div", group, "group-title"));
    for (const id of entries) {
      const [label, glyph] = sections[id];
      const control = button(label, () => { setNavigation(false); go(id, true); }, { glyph });
      if (section === id) control.setAttribute("aria-current", "page");
      block.append(control);
    }
    nav.append(block);
  }
  const settings = button("设置", settingsDialog, {cls: "plain", glyph: "settings", label: "设置"});
  settings.setAttribute("aria-keyshortcuts", "Control+,");
  side.append(brand, navToggle, nav, box("side-foot", settings, el("small", "V" + version)));
  const main = el("main", "", "workspace");
  main.addEventListener("pointerdown", () => setNavigation(false));
  const header = el("header", "", "workspace-header");
  const title = el("h1", sections[section][0]);
  title.tabIndex = -1;
  header.append(title);
  const headerActions = box("row workbench-header-actions", section !== "home" && searchLauncher(false),
    box("row workbench-desktop-actions"));
  header.append(headerActions);
  const page = box("page" + (section === "home" ? " home" : ""));
  if (state.status !== "ready") {
    const warning = box("warning workspace-warning", icon("warning"), el("div", state.notice || "尚未创建本机设置。", "fill"));
    warning.setAttribute("role", "status");
    if (state.status === "missing" || state.status === "new" || state.status === "empty") {
      warning.append(button("创建设置", async () => {
        await api("/api/settings/create", {});
        say("已创建本机设置");
        render();
      }, {cls: "primary"}));
    }
    page.append(warning);
  }
  const views = {
    home: homePage, screenshots: screenshotPage, clipboard: clipboardPage,
    files: () => actionPage("files"), archives: () => actionPage("archives"),
    tools: () => actionPage("tools"), windows: () => actionPage("windows"),
    overview: overviewPage, lockPolicy: lockPage, input: inputPage,
    workflows: workflowPage, history: historyPage,
  };
  page.append(views[section]());
  const body = box("body", page);
  footer = el("footer", "", "footer");
  main.append(header, body, footer);
  app.replaceChildren(box("shell", side, main));
  renderDesktopActions();
  if (refocusTitle) title.focus({preventScroll: true});
  drawFooter();
}
let dialogSequence = 0;
function showModal(title, contents, options = {}) {
  if (!options.overlay && dialog?.open) dialog.close();
  const current = el("dialog", "", "workflow-dialog");
  if (options.size) current.dataset.size = options.size;
  if (options.protectExit) current.dataset.protectExit = "true";
  const heading = el("h2", title);
  heading.id = "modal-heading-" + ++dialogSequence;
  current.setAttribute("aria-labelledby", heading.id);
  const error = el("p", "", "error modal-error");
  error.setAttribute("role", "alert");
  error.hidden = true;
  const close = button("", () => options.dismiss ? options.dismiss() : current.close(), {glyph: "close", cls: "plain", label: "关闭"});
  const titleRow = el("header", "", "dialog-title");
  titleRow.append(...[options.danger && icon("warning"), heading, close].filter(Boolean));
  if (options.danger) titleRow.classList.add("danger-title");
  if (options.actions) options.actions.classList.add("dialog-actions");
  current.append(box("dialog-content", titleRow, box("dialog-body", contents), error, options.actions));
  current.addEventListener("close", () => {
    if (dialog === current) dialog = null;
    current.remove();
    options.closed?.();
  });
  if (options.overlay) document.body.append(current);
  else {
    app.append(current);
    dialog = current;
  }
  if (options.dismiss) current.addEventListener("cancel", event => {
    event.preventDefault();
    close.click();
  });
  current.showModal();
  return current;
}
function formDialog(title, fields, submit, submitTitle = "确定", options = {}) {
  const form = el("form", "", "stack");
  form.id = "modal-form-" + (dialogSequence + 1);
  form.append(...fields.filter(Boolean));
  const confirm = el("button", submitTitle, options.danger ? "primary danger" : "primary");
  confirm.type = "submit";
  confirm.setAttribute("form", form.id);
  const cancel = button("取消", () => current.close());
  const focus = [...form.querySelectorAll("input:not([type=hidden]), select, textarea")]
    .find(control => !control.disabled && !control.closest("[hidden]"));
  (focus || cancel).autofocus = true;
  const current = showModal(title, form, {...options, protectExit: true, actions: box("row", cancel, confirm)});
  form.addEventListener("submit", async event => {
    event.preventDefault();
    if (confirm.disabled) return;
    confirm.disabled = true;
    confirm.classList.add("is-pending");
    form.setAttribute("aria-busy", "true");
    const error = current.querySelector(".modal-error");
    error.hidden = true;
    try {
      const keepOpen = await submit();
      if (keepOpen !== false && current.open) current.close();
    } catch (failure) { report(failure, current); }
    finally {
      form.removeAttribute("aria-busy");
      confirm.classList.remove("is-pending");
      confirm.disabled = false;
    }
  });
  return current;
}
function confirmAction(title, detail, run, accept = "确认", options = {}) {
  return formDialog(title, [note(detail)], run, accept, {size: "compact", ...options});
}
function settingsDialog() {
  const settings = state.settings || {};
  const appearance = select([["system", "跟随系统"], ["light", "浅色"], ["dark", "深色"]], settings.appearance);
  const language = select(interfaceLanguages, settings.language || "system");
  const days = input(settings.clipboardDays || 7, { type: "number", min: 1, max: 365 });
  const limit = input(settings.clipboardLimit || 200, { type: "number", min: 1, max: 1000 });
  const exclusions = area((settings.clipboardExcludedApps || []).join("\n"), "每行一个应用标识");
  const snap = toggle("窗口靠近屏幕边缘时吸附", settings.windowSnapEnabled);
  const drag = toggle("按 Alt 拖动应用窗口", settings.windowDragEnabled);
  const permissions = Object.entries(state.permissions || {}).map(([id, item]) => {
    const names = { accessibility: "窗口控制", inputMonitoring: "输入监听", finderExtension: "资源管理器", clipboardHistory: "剪贴板历史", screenCapture: "屏幕捕获", automation: "自动化" };
    return box("settings-permission", el("strong", names[id] || id), note(item.detail));
  });
  const system = el("details", "", "settings-system");
  system.append(el("summary", "系统与权限"), box("settings-permissions", ...permissions));
  formDialog("设置", [
    box("settings-section", el("h3", "界面"), box("settings-fields", field("外观", appearance), field("界面语言", language))),
    box("settings-section", el("h3", "剪贴板历史"),
      box("settings-fields", field("保留剪贴板历史（天）", days), field("历史记录上限", limit)), field("排除的应用", exclusions)),
    state.automation && box("settings-section", el("h3", "窗口与桌面"), snap, state.automation.windowDrag && drag),
    permissions.length && system,
  ].filter(Boolean), async () => {
    await api("/api/settings", {
      appearance: appearance.value, language: language.value, clipboardDays: Number(days.value), clipboardLimit: Number(limit.value),
      clipboardExcludedApps: splitLines(exclusions.value),
      ...(state.automation ? {windowSnapEnabled: snap.firstChild.checked} : {}),
      ...(state.automation?.windowDrag ? {windowDragEnabled: drag.firstChild.checked} : {}),
    });
    await loadInterfaceLanguage();
    say("设置已保存");
    render();
  }, "保存", {size: "wide"});
}
const splitLines = value => value.split(/\r?\n/).map(line => line.trim()).filter(Boolean);

async function pick(kind = "files", multiple = true) {
  const result = await api("/api/files/pick", { kind, multiple });
  return result.paths || [];
}
async function chooseFiles() {
  const chosen = await pick();
  if (chosen.length) {
    files = chosen;
    render();
  }
}
function directoryField(label = "目标目录", value = "") {
  const control = input(value, {placeholder: "输入或选择目录"});
  control.required = true;
  control.classList.add("fill");
  const wrapper = box("stack", boxLabel("field", el("span", label), box("row", control, button("选择…", async () => {
    const [chosen] = await pick("directory", false);
    if (chosen) control.value = chosen;
  }))));
  return { control, wrapper };
}
function manuallySelect() {
  const areaControl = area(files.join("\n"), "每行一个绝对路径");
  formDialog("输入文件或文件夹路径", [field("路径", areaControl)], () => {
    files = splitLines(areaControl.value);
    render();
  }, "选择");
}
function selectionBar() {
  const summary = box("file-summary fill", el("strong", files.length ? "已选择 " + files.length + " 项" : "拖入文件，开始处理"),
    el("small", files.length ? files.map(basename).slice(0, 3).join("、") + (files.length > 3 ? "…" : "") : "支持多选文件与文件夹"));
  summary.title = files.join("\n");
  return box("selection-bar", box("selection-icon", icon(files.length ? "file" : "inbox")), summary,
    button("选择文件…", chooseFiles), button("输入路径…", manuallySelect, {cls: "plain"}),
    files.length && button("", () => { files = []; render(); }, {cls: "plain", glyph: "close", label: "清除选择"}));
}
function homePage() {
  const destinations = box("destinations");
  for (const [id, title, detail] of [
    ["screenshots", "截图与录制", "截图 · 标注 · 文字识别"],
    ["clipboard", "剪贴板", "历史内容与常用短语"],
    ["windows", "窗口控制", "布局、大小与位置"],
    ["files", "文件处理", "新建、重命名与移动"],
    ["archives", "压缩与解压", "压缩、解压与档案编辑"],
    ["input", "快捷键与手势", "快捷键、鼠标手势与规则"],
  ]) {
    const card = button("", () => go(id, true), {cls: "destination", label: title});
    card.append(box("dest-icon", icon(sections[id][1])), box("fill", el("strong", title), el("small", detail)), icon("chevron"));
    destinations.append(card);
  }
  const favorites = (state.favorites || []).map(currentAction).filter(Boolean);
  const favoriteList = favorites.length ? box("action-grid favorites-grid", ...favorites.map(actionCard)) :
    empty("star", "暂无收藏", "在动作旁点星标，即可收藏");
  const favoritePanel = panel("", box("between", el("h2", "常用动作"), button("浏览动作", openSearch, {cls: "plain", glyph: "arrow"})), favoriteList);
  favoritePanel.classList.add("favorite-workbench");
  const quickFiles = panel("文件快处理",
    files.length ? box("stack queue-list", el("strong", formatMessage("已选择 {count} 项", {count: files.length}), "", true),
      ...files.slice(0, 3).map(file => box("row", icon("file"), el("span", basename(file), "wrap-text", true)))) :
      box("file-drop-hint", box("dest-icon", icon("inbox")), note("拖入文件，开始处理")),
    box("row", button("选择文件…", chooseFiles, {glyph: "folder"}), button("输入路径…", manuallySelect, {cls: "plain"})),
    files.length && box("row", button("压缩 ZIP", () => startAction("archive.create")), button("批量改名", () => startAction("files.rename")),
      button("", () => { files = []; render(); }, {cls: "plain", glyph: "close", label: "清除选择"})));
  quickFiles.classList.add("file-queue");
  return box("workbench-overview", searchLauncher(true), box("stack", el("h2", "常用入口"), destinations),
    box("workbench-columns", favoritePanel, quickFiles));
}
function searchLauncher(large) {
  const label = large ? "搜索动作、关键词" : "搜索操作";
  const control = button(label, openSearch, {cls: large ? "command-launch" : "header-search", glyph: "search", label});
  const shortcut = el("kbd", "Ctrl+K", "shortcut-key");
  shortcut.setAttribute("aria-hidden", "true");
  control.setAttribute("aria-keyshortcuts", "Control+K");
  control.append(shortcut);
  return control;
}
function actionCard(action) {
  const glyph = action.id.startsWith("window.") ? "window" : sections[action.section]?.[1] || "file";
  const control = button("", () => startAction(action.id), { disabled: Boolean(action.unavailableReason) });
  control.title = action.unavailableReason || action.detail;
  control.append(box("action-icon", icon(glyph)), box("", el("strong", action.title), el("small", action.unavailableReason || action.detail)));
  const selected = (state.favorites || []).includes(action.id);
  const favorite = button("", async () => {
    await api("/api/favorites/toggle", { id: action.id });
    favorite.setAttribute("aria-pressed", String((state.favorites || []).includes(action.id)));
    if (section === "home" && !dialog?.open) {
      const refocus = document.activeElement === favorite;
      render();
      if (refocus) document.querySelector(".favorite-workbench .between button").focus({preventScroll: true});
    }
  }, { glyph: "star", cls: "plain star", disabled: state.status !== "ready", label: "收藏 " + action.title });
  favorite.setAttribute("aria-pressed", String(selected));
  return box("action-card", control, favorite);
}
function searchFilter(placeholder, onChange) {
  const query = input("", { type: "search", placeholder });
  const count = el("small");
  query.setAttribute("aria-label", tr(placeholder));
  count.setAttribute("aria-live", "polite");
  query.addEventListener("input", () => onChange(query.value, count));
  return { element: box("filter", icon("search"), query, count), query, count };
}
function actionSearch(query, rows = catalog) {
  const lower = query.trim().toLocaleLowerCase();
  return rows.filter(row => [row.title, row.detail, row.keywords, row.id].join(" ").toLocaleLowerCase().includes(lower));
}
function openSearch() {
  let category = "";
  const result = box("action-grid dialog-result");
  const categories = box("action-categories");
  categories.setAttribute("role", "group");
  categories.setAttribute("aria-label", tr("动作分类"));
  const scope = () => category ? catalog.filter(row => row.section === category) : catalog;
  const fill = (query, count) => {
    const favorites = new Set(state.favorites || []);
    const rows = actionSearch(query, scope());
    if (!query.trim()) rows.sort((first, second) => Number(favorites.has(second.id)) - Number(favorites.has(first.id)));
    count.textContent = formatMessage("{count} 个动作", {count: rows.length});
    result.replaceChildren(...rows.slice(0, 60).map(actionCard));
    if (!rows.length) result.append(empty("search", "暂无匹配动作"));
    return rows;
  };
  const search = searchFilter("搜索动作、关键词", fill);
  for (const id of ["", "screenshots", "clipboard", "files", "archives", "tools", "windows"]) {
    if (id && !catalog.some(row => row.section === id)) continue;
    const tab = button(id ? sections[id][0] : "全部", () => {
      category = id;
      Array.from(categories.children).forEach(control => control.setAttribute("aria-pressed", String(control === tab)));
      fill(search.query.value, search.count);
    });
    tab.setAttribute("aria-pressed", String(id === category));
    categories.append(tab);
  }
  fill("", search.count);
  const current = showModal("操作面板", box("stack command-library", search.element, categories, result), {size: "wide"});
  search.query.focus();
  search.query.addEventListener("keydown", event => {
    if (event.key === "Enter") {
      const first = fill(search.query.value, search.count).find(row => !row.unavailableReason);
      if (first) { event.preventDefault(); current.close(); startAction(first.id).catch(report); }
    }
  });
}

function actionPage(kind) {
  const items = catalog.filter(action => action.section === kind);
  const grid = box("action-grid");
  const update = (query, count) => {
    const rows = actionSearch(query, items);
    count.textContent = formatMessage("{count} 个动作", {count: rows.length});
    grid.replaceChildren(...rows.map(actionCard));
    if (!rows.length) grid.append(empty("search", "暂无匹配动作", "试试其他关键词。"));
  };
  const filter = searchFilter("搜索动作或关键词", update);
  update("", filter.count);
  const wrap = box("stack action-page", kind === "windows" ? targetPanel() : selectionBar(), filter.element, grid);
  if (kind === "files") {
    const settings = state.settings || {};
    const folders = panel("", box("between", el("h3", "常用目录"), button("添加目录…", () => startAction("folder.favorite.add"))));
    if (!settings.folders?.length) folders.append(note("收藏常用目录，快速打开或用于复制、移动。"));
    for (const folder of settings.folders || []) {
      folders.append(box("list-row", box("fill", el("strong", folder.name, "row-title"), el("small", folder.path)),
        button("打开", () => perform("finder.reveal", {path: folder.path, launch: true})),
        files.length && button("复制到这里", () => executeAction("files.copy", {paths: files, destination: folder.path})),
        files.length && button("移动到这里", () => executeAction("files.move", {paths: files, destination: folder.path})),
        button("", () => confirmAction("移除常用目录？", folder.path, async () => {
          await api("/api/settings", { folders: settings.folders.filter(item => item.id !== folder.id) });
          say("已移除目录收藏");
          render();
        }, "移除"), { glyph: "trash", cls: "plain danger", label: "移除 " + folder.name })));
    }
    const templates = panel("", box("between", el("h3", "文件模板"), button("管理模板…", manageTemplates)));
    if (!settings.templates?.length) templates.append(note("暂无文件模板。"));
    else templates.append(box("row", ...settings.templates.map(item => button(item.name, () => chooseDestination("从模板新建", "保存位置", directory => executeAction("new.template", {directory, templateID: item.id}))))));
    wrap.append(folders, templates);
  }
  return wrap;
}
function manageTemplates() {
  const elements = box("list");
  const draw = () => {
    const templates = state.settings?.templates || [];
    elements.replaceChildren(...templates.map(item => box("list-row", box("fill", el("strong", item.name, "row-title"), el("small", item.filename)),
      button("编辑", () => edit(item)),
      button("", () => confirmAction("移除模板？", item.name, async () => {
        await api("/api/settings", { templates: templates.filter(row => row.id !== item.id) });
        say("已移除模板");
        manageTemplates();
      }, "移除"), { glyph: "trash", cls: "plain danger", label: "移除 " + item.name }))));
  };
  const edit = (item = {}) => {
    const name = input(item.name || "", {placeholder: "模板名称"});
    const filename = input(item.filename || "", {placeholder: "包含扩展名"});
    const content = area(item.content || "", "初始内容");
    name.required = filename.required = true;
    formDialog("编辑文件模板", [field("名称", name), field("文件名", filename), field("内容", content)], async () => {
      const templates = state.settings?.templates || [];
      const next = { ...item, id: item.id || crypto.randomUUID(), name: name.value.trim(), filename: filename.value.trim(), content: content.value };
      await api("/api/settings", { templates: item.id ? templates.map(row => row.id === item.id ? next : row) : [...templates, next] });
      say("模板已保存");
      manageTemplates();
    }, "保存");
  };
  showModal("文件模板", box("stack", elements, box("row", button("添加模板", () => edit(), {glyph: "plus"}))));
  draw();
}
function chooseDestination(title, label, onChoose) {
  const dest = directoryField(label);
  return formDialog(title, [dest.wrapper], () => onChoose(dest.control.value.trim()), "继续");
}
async function ensureFiles() {
  if (files.length) return files;
  const chosen = await pick();
  if (!chosen.length) return null;
  files = chosen;
  render();
  return chosen;
}
async function executeAction(id, payload = {}, success) {
  const title = currentAction(id)?.title || "操作";
  const result = await progress("正在" + title + "…", () => perform(id, payload));
  const outputs = rememberOutputs(result);
  if (success) { await success(result); return result; }
  describeResult(result, title, outputs);
  if (!dialog?.open && ["system.preventSleep.toggle", "folder.favorite.add"].includes(id)) render();
  return result;
}
function describeResult(result, title, outputs = []) {
  if (result.pngBase64) {
    const image = el("img", "", "shot-preview");
    image.alt = "生成的二维码";
    image.src = "data:image/png;base64," + result.pngBase64;
    showModal(title, box("stack", image, result.path && el("small", result.path, "wrap-text")));
  } else if (result.text && !result.copiedToSystemClipboard) {
    showModal(title, box("stack", el("pre", result.text), box("row", button("复制", async () => {
      await perform("clipboard.copyplain", {text: result.text});
      say("已复制");
    }, {glyph: "clip"}))));
  } else if (outputs.length) {
    say(outputs.length === 1 ? "已生成 " + basename(outputs[0]) : "已处理 " + outputs.length + " 项");
  } else if (result.applied === false) {
    say("已计算目标位置。");
  } else {
    const detail = result.message || result.detail || (result.copiedToSystemClipboard ? "已复制" : undefined);
    say(detail || title + "已提交");
  }
}
async function startAction(id) {
  if (dialog?.open) dialog.close();
  if (["panel.show"].includes(id)) { openSearch(); return; }
  if (id === "clipboard.show") { go("clipboard"); return; }
  if (id === "finder.popup") { go("files"); openSearch(); return; }
  if (id === "workflow.show") { go("workflows"); return; }
  if (id === "windows.overview") {
    if (section === "overview") await refreshWindows(false);
    else go("overview");
    return;
  }
  if (id === "desktop.openSettings") { go("windows"); settingsDialog(); return; }
  if (id === "lock.settings") { go("lockPolicy"); return; }
  if (id === "system.applicationWindows") {
    if (section !== "overview") {
      section = "overview";
      history.replaceState(null, "", "#overview");
    }
    await refreshWindows(true, false);
    render();
    return;
  }
  if (id.startsWith("screenshot.")) { screenshotAction(id); return; }
  if (id === "ocr.files") { screenshotAction("screenshot.ocr.files"); return; }
  if (id.startsWith("workflow.run.")) {
    const workflow = state.workflows?.find(item => item.id === id.slice("workflow.run.".length));
    return runWorkflow(workflow);
  }
  if (id.startsWith("window.")) {
    if (!targetID) {
      await refreshWindows(false, false);
      if (!windows.length) throw new Error("找不到可以操作的窗口。");
      formDialog("选择目标窗口", [windowSelectField()], async () => applyWindow(id), "运行");
      return;
    }
    return applyWindow(id);
  }
  if (["system.lock", "system.sleep", "system.screenSaver"].includes(id)) {
    confirmAction(currentAction(id)?.title || "提交系统请求", "请先保存工作。系统请求可能立即结束当前交互。", () => executeAction(id), "确认", {danger: true});
    return;
  }
  if (id.startsWith("new.") || id.startsWith("file.new.")) {
    if (id === "new.custom") {
      const directory = directoryField("保存位置");
      const name = input("", {placeholder: "文件名（包含扩展名）"});
      name.required = true;
      const content = area("", "初始内容");
      formDialog("自定义新建", [directory.wrapper, field("文件名", name), field("内容", content)], () =>
        executeAction(id, { directory: directory.control.value.trim(), name: name.value.trim(), content: content.value }));
      return;
    }
    if (id === "new.template") { manageTemplates(); return; }
    const [directory] = await pick("directory", false);
    if (directory) await executeAction(id, { directory });
    return;
  }
  if (id === "folder.favorite.add") {
    const [path] = await pick("directory", false);
    if (path) await executeAction(id, { path });
    return;
  }
  if (id === "terminal.open") {
    const [path] = await pick("directory", false);
    if (path) await executeAction(id, { path, launch: true });
    return;
  }
  if (id === "text.qrcode") {
    const value = area("", "输入要生成二维码的文字");
    value.required = true;
    const directory = directoryField("保存位置（可选）");
    directory.control.required = false;
    formDialog("自定义二维码", [field("文字", value), directory.wrapper], () =>
      executeAction(id, {text: value.value, directory: directory.control.value.trim() || undefined}), "生成");
    return;
  }
  if (id === "clipboard.copyplain" || id === "clipboard.pasteplain") {
    const value = area("", "输入文字，留空则读取本次剪贴板");
    formDialog(currentAction(id).title, [value], async () => {
      const payload = value.value ? {text: value.value} : {};
      if (id.endsWith("pasteplain")) {
        payload.targetID = targetID || undefined;
        await nativePaste(payload);
      } else await executeAction(id, payload);
    }, "继续");
    return;
  }
  const action = currentAction(id);
  const selected = action?.files ? await ensureFiles() : files;
  if (action?.files && !selected) return;
  const payload = { paths: selected || [] };
  switch (id) {
    case "files.copy":
    case "files.move": {
      const [destination] = await pick("directory", false);
      if (destination) await executeAction(id, { ...payload, destination });
      return;
    }
    case "files.rename": return renameDialog(selected);
    case "archive.custom": return customArchiveDialog(selected);
    case "archive.extract":
      return extractArchives({ paths: selected, batchID: crypto.randomUUID() });
    case "archive.extract.custom":
      return chooseDestination("解压到其他目录", "解压位置", destination => extractArchives({paths: selected, destination, batchID: crypto.randomUUID()}));
    case "archive.list": return archivePreview(selected[0]);
    case "images.convert": return convertDialog(selected);
    case "finder.reveal": return executeAction(id, { path: selected[0], launch: true });
    default: return executeAction(id, payload);
  }
}
function renameDialog(selected) {
  const pattern = input("{name}-{n:02}.{ext}", {placeholder: "命名模板"});
  const start = input(1, {type: "number", min: 0});
  pattern.required = true;
  formDialog("批量重命名", [field("名称模板", pattern), field("起始序号", start), note("可使用 {name} 原文件名、{ext} 扩展名和 {n:02} 两位序号。")], async () => {
    const { plans } = await perform("files.rename", { paths: selected, pattern: pattern.value, start: Number(start.value) });
    const list = el("ul", "", "result-list dialog-result");
    for (const plan of plans) list.append(el("li", basename(plan.source) + " → " + basename(plan.destination)));
    formDialog("预览重命名", [list], () => executeAction("files.rename", { plans }), "应用重命名");
  }, "预览");
}
function customArchiveDialog(selected) {
  const format = select([["zip", "ZIP"], ["7z", "7Z"]], "zip");
  const password = input("", { type: "password", placeholder: "留空则不加密" });
  password.autocomplete = "new-password";
  const split = input("", { type: "number", min: 1, placeholder: "留空则不分卷" });
  const solid = toggle("固实压缩", true);
  const savePassword = toggle("用 Windows 凭据管理器记住这份压缩包的密码", false);
  solid.hidden = true;
  savePassword.hidden = true;
  password.oninput = () => { savePassword.hidden = !password.value; };
  format.addEventListener("change", () => { solid.hidden = format.value !== "7z"; });
  formDialog("自定义压缩", [field("格式", format), field("密码", password), field("分卷大小（MiB）", split), solid, savePassword], () =>
    executeAction("archive.custom", { paths: selected, format: format.value, password: password.value || undefined,
      splitMB: split.value ? Number(split.value) : undefined, solid: solid.firstChild.checked,
      savePassword: Boolean(password.value && savePassword.firstChild.checked) }), "压缩");
}
async function extractArchives(payload) {
  try {
    return await executeAction(payload.destination || payload.members ? "archive.extract.custom" : "archive.extract", payload, result => {
      const output = rememberOutputs(result);
      const rows = (result.items || []).map(item => box("list-row", box("fill", el("strong", basename(item.archive), "row-title"), el("small", item.destination)), item.skipped && el("small", "已完成")));
      say("已解压 " + output.length + " 项");
      showModal("解压结果", box("stack dialog-result", ...rows));
    });
  } catch (error) {
    if (!["password", "password-required", "cancelled"].includes(error.code)) throw error;
    const password = input("", {type: "password", placeholder: "压缩包密码"});
    password.autocomplete = "off";
    const saved = toggle("使用 Windows 凭据管理器中保存的密码", false);
    password.required = true;
    saved.firstChild.onchange = () => { password.required = !saved.firstChild.checked; password.disabled = saved.firstChild.checked; };
    formDialog("输入解压密码", [note(error.message), password, saved], () => extractArchives({
      ...payload, password: saved.firstChild.checked ? undefined : password.value, useSaved: saved.firstChild.checked,
    }), "继续解压");
  }
}
async function archivePreview(path, password) {
  try {
    const editable = /\.(zip|7z)$/i.test(path);
    const result = await progress("正在读取压缩包…", () => editable ? api("/api/archive/edit/preview", {path, password}) : perform("archive.list", {path, password}));
    const members = result.members || [];
    const formatSize = new Intl.NumberFormat(document.documentElement.lang, {style: "unit", unit: "byte", unitDisplay: "short"});
    const controls = members.map(item => toggle(item.name || item.path, false, updateSelection, true));
    const items = el("ul", "", "archive-members");
    for (const [index, item] of members.entries()) {
      const row = el("li", "", "archive-member");
      const size = !item.directory && item.size !== undefined ? formatSize.format(item.size) : "";
      row.append(controls[index], el("small", size, "archive-size", true));
      items.append(row);
    }
    const count = el("small");
    count.setAttribute("role", "status");
    const extract = button("提取所选…", () => chooseDestination("提取所选文件", "解压位置", destination =>
      extractArchives({paths: [path], destination, members: selected(), password, batchID: crypto.randomUUID()})), {cls: "primary"});
    const edit = result.previewID && button("编辑压缩包…", () => editArchive(path, password, result, selected()));
    const selectAll = button("选择全部", () => setSelection(true), {disabled: !members.length});
    const clear = button("清除选择", () => setSelection(false));
    function selected() {
      return members.filter((_, index) => controls[index].firstChild.checked).map(item => item.name || item.path);
    }
    function updateSelection() {
      const active = selected().length;
      count.textContent = formatMessage("已选择 {selected} 项，共 {total} 项", {selected: active, total: members.length});
      extract.disabled = clear.disabled = !active;
      selectAll.disabled = active === members.length;
    }
    function setSelection(value) {
      for (const control of controls) control.firstChild.checked = value;
      updateSelection();
    }
    updateSelection();
    const membersPanel = members.length ? box("archive-member-panel",
      box("between archive-tools", count, box("row", selectAll, clear)), items) : empty("archive", "压缩包为空");
    showModal("压缩包预览", box("stack", archiveIdentity(path), membersPanel),
      {size: "wide", actions: box("row", edit, extract)});
    say("已读取压缩包目录 " + members.length + " 项");
  } catch (error) {
    if (!["password", "password-required"].includes(error.code)) throw error;
    const next = input("", {type: "password", placeholder: "压缩包密码"});
    next.required = true;
    formDialog("输入预览密码", [note(error.message), next], () => archivePreview(path, next.value), "查看");
  }
}
function archiveIdentity(path) {
  return box("archive-identity", icon("archive"),
    box("fill", el("strong", basename(path), "wrap-text", true), el("small", path, "wrap-text", true)));
}
function editArchive(path, password, preview, removals) {
  const additions = [];
  const selected = el("p", "尚未选择新增文件", "muted");
  selected.setAttribute("role", "status");
  const hidden = toggle("清理隐藏成员", false);
  const passwordBox = input(password || "", {type: "password", placeholder: "压缩包密码"});
  passwordBox.autocomplete = "off";
  const finish = async (mode, destination) => {
    const result = await progress("正在校验并保存压缩包…", () => api("/api/archive/edit/save", {
      previewID: preview.previewID, password: passwordBox.value, add: additions, remove: removals,
      removeHidden: hidden.firstChild.checked, mode, destination, confirm: true,
    }));
    say("已保存 " + result.path);
    render();
  };
  const clearAdditions = button("清除选择", () => updateAdditions([]), {disabled: true});
  function updateAdditions(paths) {
    additions.splice(0, additions.length, ...paths);
    selected.textContent = additions.map(basename).join("、") || tr("尚未选择新增文件");
    clearAdditions.disabled = !additions.length;
  }
  const removeList = el("ul", "", "archive-removals");
  for (const name of removals) removeList.append(el("li", name, "wrap-text", true));
  const edits = box("archive-edit-fields", removals.length && box("archive-remove-plan", el("h3", "移除勾选项"), removeList),
    box("archive-add-plan", box("row", button("选择新增文件…", async () => {
      const paths = await pick();
      if (paths.length) updateAdditions(paths);
    }, {glyph: "plus"}), clearAdditions), selected), hidden,
    preview.encrypted && field("密码", passwordBox));
  const saveOriginal = button("保存到原包…", () => confirmAction("保存到原包？", path, () => finish("replace"), "保存", {danger: true}), {cls: "danger"});
  const saveCopy = button("另存新副本…", () => {
      const suffix = path.match(/\.(zip|7z)$/i)?.[0] || "";
      const filename = input(basename(path).slice(0, -suffix.length) + "-edited" + suffix);
      chooseDestination("另存新副本", "保存位置", folder => formDialog("新压缩包名称", [field("名称", filename)], () => {
        if (!filename.value.trim() || /[\\/:]/.test(filename.value)) throw new Error("请输入有效文件名称。");
        return finish("copy", folder.replace(/[\\/]$/, "") + "\\" + filename.value.trim());
      }, "保存"));
  }, {cls: "primary"});
  showModal("编辑压缩包", box("stack", archiveIdentity(path), preview.encrypted && note("保存后仍需密码才能打开成员。"), edits),
    {size: "wide", protectExit: true, actions: box("row", saveOriginal, saveCopy)});
}
function convertDialog(selected) {
  const options = [["png", "PNG"], ["bmp", "BMP"]];
  for (const [id, title] of [["jpeg", "JPEG"], ["heic", "HEIC"], ["tiff", "TIFF"], ["webp", "WebP"], ["icns", "ICNS"]]) {
    if (currentAction("images." + id)?.available) options.push([id, title]);
  }
  const format = select(options, "png");
  const maxEdge = input("", {type: "number", min: 1, placeholder: "留空则保持尺寸"});
  formDialog("自定义图片转换", [field("格式", format), field("最长边（像素）", maxEdge)], () => executeAction("images.convert", {
    paths: selected, format: format.value, maxEdge: maxEdge.value ? Number(maxEdge.value) : undefined,
  }), "转换");
}

async function refreshWindows(sameApplication = false, repaint = true) {
  try {
    const result = await perform(sameApplication ? "system.applicationWindows" : "windows.overview");
    windows = (result.windows || []).map(item => ({...item, id: String(item.id)}));
    listLoaded = true;
    if (!windows.some(row => row.id === targetID)) targetID = "";
    if (repaint && ["windows", "overview"].includes(section) && !dialog?.open) render();
  } catch (error) { report(error); }
}
function windowSelectField() {
  const picker = select([["", "请选择窗口"], ...windows.map(row => [row.id, windowName(row)])], targetID);
  picker.required = true;
  picker.addEventListener("change", () => { targetID = picker.value; });
  return field("目标窗口", picker);
}
function windowName(row) { return [row.application, row.title].filter(Boolean).join(" · ") || row.id; }
async function applyWindow(id, selected = targetID) {
  if (!selected) throw new Error("请先选择要操作的窗口。");
  const run = async () => {
    await executeAction(id, { targetID: selected, apply: true, confirm: true });
    if (id !== "window.focus" && id !== "window.close") await refreshWindows(false, !dialog?.open);
  };
  if (id === "window.close") {
    const item = windows.find(row => row.id === selected);
    confirmAction("关闭所选窗口？", windowName(item || {id: selected}) + tr("。若存在未保存内容，请在目标应用处理保存提示。"), async () => {
      await run();
      if (section === "overview") refreshWindows(false, false);
    }, "关闭窗口", {danger: true});
  } else await run();
}
function targetPanel() {
  const selector = windowSelectField();
  return box("panel window-target", box("dest-icon", icon("window")), selector,
    button("刷新窗口", () => refreshWindows(), {glyph: "history"}));
}
function overviewPage() {
  const list = box("list");
  const apps = [...new Set(windows.map(row => row.application).filter(Boolean))].sort();
  const appFilter = select([["", "全部应用"], ...apps], windowApp);
  appFilter.setAttribute("aria-label", "应用");
  const search = searchFilter("搜索窗口或应用", (query) => { windowQuery = query; draw(); });
  search.query.value = windowQuery;
  appFilter.onchange = () => { windowApp = appFilter.value; draw(); };
  const draw = () => {
    const term = windowQuery.trim().toLocaleLowerCase();
    const shown = windows.filter(row => (!windowApp || row.application === windowApp) && windowName(row).toLocaleLowerCase().includes(term));
    search.count.textContent = shown.length + " 项";
    list.replaceChildren();
    if (!shown.length) {
      list.append(empty("desktops", listLoaded ? "没有匹配的窗口或应用" : "正在读取窗口列表", listLoaded ? "尝试清除搜索或刷新目录。" : ""));
      return;
    }
    for (const row of shown) {
      const check = button(row.id === targetID ? "已选目标" : "选择", () => {
        targetID = row.id;
        draw();
      });
      check.setAttribute("aria-pressed", String(row.id === targetID));
      list.append(box("list-row", icon("window"), box("fill", el("strong", row.title || windowName(row), "row-title"),
        el("small", [row.application, row.minimized ? "已最小化" : "", row.maximized ? "已最大化" : ""].filter(Boolean).join(" · "))),
        check, button("聚焦", () => applyWindow("window.focus", row.id)), button("关闭…", () => applyWindow("window.close", row.id), { cls: "plain danger" })));
    }
  };
  draw();
  search.query.addEventListener("keydown", event => {
    if (event.key !== "Enter") return;
    const shown = windows.find(row => (!windowApp || row.application === windowApp) && windowName(row).toLocaleLowerCase().includes(windowQuery.toLocaleLowerCase()));
    if (shown) applyWindow("window.focus", shown.id).catch(report);
  });
  const tools = [
    ["missionControl", "任务视图"],
    ["showDesktop", "显示桌面"],
    ["spaceLeft", "左侧桌面"],
    ["spaceRight", "右侧桌面"],
    ["createDesktop", "新建桌面"],
    ["closeDesktop", "关闭当前桌面"],
  ];
  const desktopActions = box("row", ...tools
    .filter(([id]) => currentAction("system." + id)?.available)
    .map(([id, title]) => button(title, () => id === "closeDesktop" ?
      confirmAction("关闭当前虚拟桌面？", "Windows 将把打开的窗口移到相邻桌面。", () => executeAction("system." + id), "关闭当前桌面", {danger: true}) :
      executeAction("system." + id))));
  return box("stack", panel("", box("between", el("h3", "窗口列表"), box("row", appFilter, button("刷新", () => refreshWindows(), { glyph: "history" }))),
    search.element, list), desktopActions.children.length && panel("虚拟桌面", desktopActions));
}
function lockPage() {
  const settings = state.settings?.localLock || {};
  const supported = Boolean(state.automation);
  const enabled = toggle("启用闲置策略", settings.enabled);
  const idleSeconds = input(settings.idleSeconds || 300, {type: "number", min: 30, max: 86400, step: 5});
  const warningSeconds = input(settings.warningSeconds || 15, {type: "number", min: 5, max: 120});
  const action = select([["lockScreen", "锁定电脑"], ["screenSaver", "启动屏幕保护程序"]], settings.action);
  const form = box("stack", enabled, box("columns", field("闲置时间（秒）", idleSeconds), field("预告时间（秒）", warningSeconds)),
    field("闲置动作", action),
    box("row", button("保存策略", async () => {
      if (!idleSeconds.reportValidity() || !warningSeconds.reportValidity()) return;
      await api("/api/settings", {localLock: { ...settings, enabled: enabled.firstChild.checked, idleSeconds: +idleSeconds.value, warningSeconds: +warningSeconds.value, action: action.value }});
      say("闲置策略已保存");
      render();
    }, { cls: "primary" })));
  idleStatus = box("stack");
  updateIdleStatus();
  return box("stack", panel("本机锁屏与闲置策略", note("锁屏由 Windows 执行。屏幕保护程序的密码要求由系统设置决定。"),
    box("row", button("手动锁屏…", () => startAction("system.lock"), {glyph: "lock"}), button("启动屏保…", () => startAction("system.screenSaver")),
      button(state.awake ? "取消保持唤醒" : "保持唤醒", () => executeAction("system.preventSleep.toggle"), {glyph: "sun"})), el("hr"),
    supported ? form : note("本会话没有运行自动闲置观察。"),
    idleStatus));
}
function updateIdleStatus() {
  if (!idleStatus) return;
  const idle = state.idle || {};
  const descriptions = {disabled: "已关闭", observing: "等待闲置", countdown: "闲置倒计时", paused: "任务期间暂停", waitingForActivity: "等待重新活动"};
  const parts = [el("strong", descriptions[idle.state] || "已关闭")];
  if (idle.detail) parts.push(note(idle.detail));
  if (idle.state === "countdown") parts.push(box("row", el("span", idle.remaining + " 秒"),
    button("取消本次倒计时", async () => {
      state.idle = await api("/api/lock/cancel", {});
      say("已取消本次倒计时");
      updateIdleStatus();
    })));
  idleStatus.replaceChildren(...parts);
}
function historyPage() {
  const records = (state.receipts || []).slice().reverse();
  const kinds = {create: "新建", copy: "复制", move: "移动", rename: "重命名", convert: "转换", extract: "解压"};
  const rows = records.map(record => box("list-row", box("fill", el("strong", basename(record.destination), "row-title"),
    el("small", record.destination), el("small", dateLabel(record.date))), el("small", kinds[record.kind] || record.kind),
    button("恢复…", () => confirmAction("恢复这次操作？", record.destination, async () => {
      await api("/api/undo", { ids: [record.id] });
      say("已恢复 " + basename(record.destination));
      render();
    }, "恢复"), {disabled: state.status !== "ready"})));
  return panel("恢复记录", note("恢复前会核验目标内容。原位置冲突、文件变化或文件缺失时停止。"),
    records.length ? box("list", ...rows) : empty("history", "暂无恢复记录"));
}

async function nativePaste(payload) {
  if (!payload.targetID) {
    await refreshWindows(false, false);
    if (!windows.length) throw new Error("找不到可接收粘贴的窗口。");
    formDialog("选择粘贴目标", [windowSelectField()], () => nativePaste({ ...payload, targetID }), "提交粘贴");
    return;
  }
  const result = await perform("clipboard.pasteplain", { ...payload, sendEnter: false });
  say(result.message || "请在目标窗口核对插入内容");
  render();
}
function clipboardPage() {
  const rows = state.clipboard || [];
  const enabled = toggle("记录新复制的内容", state.clipboardEnabled, async value => {
    await api("/api/settings", {clipboardEnabled: value});
    say(value ? "剪贴板历史已启用" : "剪贴板历史已关闭");
    render();
  });
  const output = box("list clipboard-list");
  const groups = [...new Set(rows.map(item => item.group).filter(Boolean))].sort();
  if (clipGroup && !groups.includes(clipGroup)) clipGroup = "";
  const groupFilter = select([["", "全部"]]);
  for (const group of groups) {
    const option = el("option", group, "", true);
    option.value = group;
    groupFilter.append(option);
  }
  groupFilter.value = clipGroup;
  groupFilter.onchange = () => { clipGroup = groupFilter.value; redraw(); };
  const search = searchFilter("搜索历史", value => { clipQuery = value; redraw(); });
  search.query.value = clipQuery;
  const redraw = () => {
    const q = clipQuery.toLocaleLowerCase();
    const visible = rows.filter(item => (!clipGroup || item.group === clipGroup) &&
      [item.title, item.text, item.group, ...(item.tags || [])].join(" ").toLocaleLowerCase().includes(q));
    search.count.textContent = formatMessage("共 {count} 条", {count: visible.length});
    output.replaceChildren();
    if (!visible.length) {
      output.append(rows.length ? empty("search", "没有匹配项") :
        empty("clip", state.clipboardEnabled ? "等待新的复制内容" : "历史记录尚未启用"));
      return;
    }
    for (const item of visible) output.append(clipboardRow(item));
  };
  redraw();
  const viewStack = button("查看堆栈", async () => {
    const result = await api("/api/paste/stack/current", {});
    const parts = result.parts || [];
    const clear = parts.length && button("清空堆栈…", () => confirmAction("清空粘贴堆栈？", "当前堆栈中的待粘贴项将被移除。", async () => {
      await api("/api/paste/stack/clear", {});
      say("已清空粘贴堆栈");
    }, "清空", {danger: true}), {cls: "danger"});
    const contents = parts.length ? box("list", ...parts.map(item => box("list-row", icon("clip"), el("span", item.text || item.path || item.kind, "wrap-text", true)))) :
      empty("layers", "堆栈为空。");
    showModal("粘贴堆栈", contents, clear ? {actions: box("row", clear)} : {});
  }, {glyph: "layers"});
  const clearHistory = button("清除未固定历史…", () => confirmAction("清除未固定的历史？", "这是永久操作，已固定的条目会保留。", async () => {
    await api("/api/clipboard/clear", {});
    say("未固定的历史已清除");
    render();
  }, "清除", {danger: true}), {cls: "plain danger", disabled: !rows.some(item => !item.pinned)});
  const issue = state.clipboardNotice && el("p", trError(state.clipboardNotice), "workflow-feedback error", true);
  if (issue) issue.setAttribute("role", "alert");
  const pasteReview = state.paste && box("workflow-callout", icon("clip"), box("fill", el("strong", "粘贴等待核对"),
    note("请在目标窗口确认内容已插入，再结束本次事务。")), box("row", button("取消并恢复", () => finishPaste("/api/paste/cancel")),
    button("确认已插入", () => finishPaste("/api/paste/confirm"), {cls: "primary"})));
  const workspace = box("panel clipboard-history", box("between workflow-head", el("h2", "历史记录"),
    box("row", enabled, button("刷新", () => refreshClipboard(true), {glyph: "history"}))),
    issue, pasteReview,
    box("clipboard-filters", search.element, groups.length && boxLabel("option clipboard-group", el("span", "分组"), groupFilter)),
    box("between clipboard-tools", box("row", viewStack,
      button("粘贴堆栈", () => choosePasteTarget(id => api("/api/paste/stack/paste", {targetID: id})))),
    clearHistory), output,
    el("small", formatMessage("保留 {days} 天", {days: state.settings?.clipboardDays || 7}), "clipboard-retention", true));
  return box("stack clipboard-workspace", workspace, snippetPanel());
}
let clipboardRevision = "";
async function refreshClipboard(force = false) {
  if (document.hidden && !force) return;
  if (pending || dialog?.open || lifecycle.dialog?.open || statePollInFlight) return;
  statePollInFlight = true;
  try {
    const result = await api("/api/state");
    if (result.selectionRevision !== selectionRevision) {
      selectionRevision = result.selectionRevision;
      files = result.selection || [];
      state = result;
      if (result.incomingOCRRequest) openIncomingOCR(result.incomingOCRRequest);
      else if (files.length && section !== "files") go("files");
      else render();
      return;
    }
    if (section === "lockPolicy" && JSON.stringify(result.idle) !== JSON.stringify(state.idle)) {
      state.idle = result.idle;
      updateIdleStatus();
    }
    if (section === "input" && JSON.stringify(result.automation) !== JSON.stringify(state.automation)) {
      state.automation = result.automation;
      render();
    }
    if (section !== "clipboard" && !force) return;
    const key = JSON.stringify([result.clipboard?.map(item => [item.id, item.pinned, item.group]), result.paste, result.clipboardEnabled]);
    if (force || key !== clipboardRevision && (clipboardRevision || JSON.stringify(result.clipboard) !== JSON.stringify(state.clipboard) ||
        JSON.stringify(result.paste) !== JSON.stringify(state.paste) || result.clipboardEnabled !== state.clipboardEnabled)) {
      const focused = document.activeElement;
      const isEditing = focused instanceof HTMLInputElement || focused instanceof HTMLTextAreaElement || focused instanceof HTMLSelectElement;
      if (force || !isEditing) {
        state = result;
        render();
      } else return;
    }
    clipboardRevision = key;
  } catch (error) { if (force) report(error); }
  finally { statePollInFlight = false; }
}
function choosePasteTarget(run) {
  return (async () => {
    const paste = async id => {
      const result = await run(id);
      say(result.message || "请在目标窗口核对插入内容");
      render();
    };
    if (targetID) return paste(targetID);
    await refreshWindows(false, false);
    if (!windows.length) throw new Error("找不到可接收粘贴的窗口。");
    formDialog("选择粘贴目标", [windowSelectField()], () => paste(targetID), "提交粘贴");
  })();
}
async function finishPaste(path) {
  const result = await api(path, {});
  say(result.message || (path.endsWith("confirm") ? "粘贴已确认" : "粘贴已取消"));
  render();
}
function clipboardRow(item) {
  const operate = async (operation, extra = {}) => {
    const result = await api("/api/clipboard/item", {id: item.id, operation, ...extra});
    const messages = { copy: "已复制", plain: "已复制纯文本", pin: item.pinned ? "已取消固定" : "已固定", delete: "已删除历史", metadata: "已保存标签与分组", stack: "已加入堆栈" };
    say(result.message || messages[operation] || "请在目标窗口核对插入内容");
    render();
    return result;
  };
  const metadata = () => {
    const group = input(item.group || "", {placeholder: "分组"});
    const tags = input((item.tags || []).join("，"), {placeholder: "用逗号分隔标签"});
    formDialog("分组与标签", [field("分组", group), field("标签", tags)], () => operate("metadata", {
      group: group.value.trim(), tags: tags.value.split(/[,，]/).map(tag => tag.trim()).filter(Boolean),
    }), "保存");
  };
  const title = item.title || item.text || item.kind;
  const details = [dateLabel(item.date), item.sourceApp, item.group, (item.tags || []).join("、")].filter(Boolean).join(" · ");
  const pin = button("", () => operate("pin"), {glyph: "pin", cls: "plain", label: item.pinned ? "取消固定" : "固定"});
  pin.setAttribute("aria-pressed", String(Boolean(item.pinned)));
  return box("list-row clipboard-row", box("workflow-icon", icon(item.kind === "image" ? "image" : "file")),
    box("fill clipboard-item", el("strong", title, "row-title clipboard-preview", true), details && el("small", details, "", true)),
    box("row clipboard-row-actions", pin, button("复制", () => operate("copy")), item.kind === "text" && button("纯文本", () => operate("plain")),
      button("粘贴", () => choosePasteTarget(id => operate("paste", {targetID: id}))),
      button("更多…", () => showModal("剪贴板条目", box("stack", el("pre", item.text || title, "clipboard-item-full", true),
        details && el("small", details, "wrap-text", true)),
      {actions: box("row", button("分组与标签…", metadata), button("加入粘贴堆栈", () => operate("stack")))})),
      button("", () => confirmAction("删除此条历史？", title, () => operate("delete"), "删除", {danger: true}), {glyph: "trash", cls: "plain danger", label: "删除"})));
}
function snippetPanel() {
  const name = input();
  const value = input();
  name.required = value.required = true;
  const records = state.snippets || [];
  const save = async (item = {}) => {
    if (!name.value.trim() || !value.value) throw new Error("请填写名称和文本内容。");
    await api("/api/snippets/save", { ...item, name: name.value.trim(), text: value.value });
    say("短语已保存");
    render();
  };
  const saveButton = el("button", "保存", "primary");
  saveButton.type = "submit";
  const form = el("form", "", "snippet-form");
  form.append(field("名称", name), field("文本内容", value), saveButton);
  form.addEventListener("submit", async event => {
    event.preventDefault();
    saveButton.disabled = true;
    try { await save(); }
    catch (error) { report(error); }
    finally { saveButton.disabled = false; }
  });
  const snippets = box("row", ...records.map(item => button(item.name, () => snippetDialog(item))));
  return panel("", box("between workflow-head", el("h2", "常用短语"), button("导出 CSV…", async () => {
    const response = await fetch("/api/export/snippets.csv", {headers: {"X-Gao-Token": token}});
    if (!response.ok) throw new Error("无法导出短语。");
    downloadBlob(await response.blob(), "搞操作短语.csv");
  }, {disabled: !records.length})), form, records.length ? snippets : note("暂无常用短语。"));
}
function snippetDialog(item) {
  const name = input(item.name || "", {placeholder: "名称"});
  const value = area(item.text || "", "文本内容");
  name.required = value.required = true;
  const group = input(item.group || "", {placeholder: "分组"});
  const mode = select([["copyOnly", "仅复制"], ["pasteOnly", "仅粘贴"]], item.mode);
  const shortcut = input(item.shortcut || "", {placeholder: "短语快捷码"});
  const resolve = () => api("/api/snippets/resolve", {id: item.id});
  const current = formDialog("编辑短语", [field("名称", name), field("内容", value), field("分组", group), field("快捷码", shortcut), field("执行方式", mode),
    box("row", button("仅复制", async () => {
      const result = await resolve();
      await perform("clipboard.copyplain", {text: result.text});
      say("已复制短语");
      current.close();
    }), button("仅粘贴", async () => {
      const result = await resolve();
      current.close();
      await nativePaste({text: result.text, targetID: targetID || undefined});
    }))], async () => {
    await api("/api/snippets/save", {...item, name: name.value.trim(), text: value.value, group: group.value.trim(), shortcut: shortcut.value.trim(), mode: mode.value});
    say("短语已保存");
    render();
  }, "保存");
}
function downloadBlob(blob, name) {
  const url = URL.createObjectURL(blob);
  const link = el("a");
  link.href = url;
  link.download = name;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 15_000);
}

async function refreshRules() {
  try {
    const [result, status] = await Promise.all([api("/api/rules/list", {}), api("/api/rules/cloud/status", {})]);
    cloud = status;
    rules = result.rules || [];
    if (section === "input" && !dialog?.open) render();
  } catch (error) { report(error); }
}
async function cloudAction(action, payload = {}) {
  cloud = await api("/api/rules/cloud/" + action, payload);
  if (cloud.message) say(cloud.message, cloud.status !== "localSynced");
  await refreshRules();
  render();
}
function rulesCloudPanel() {
  const status = cloud.status || "off";
  const labels = {off: "同步已关闭", localSynced: "本机修订已同步到 iCloud Drive 文件夹", conflict: "发现规则冲突", cloudPending: "正在等待 iCloud 文件"};
  const resolve = (choice, title) => confirmAction(title, (cloud.conflicts || []).join("、"),
    () => cloudAction("resolve", {choice, token: cloud.token, confirm: true}), "确认");
  return panel("iCloud Drive 规则同步", el("p", labels[status] || cloud.message || status,
    status === "conflict" ? "workflow-feedback error" : "muted"), cloud.folder && el("code", cloud.folder, "wrap-text", true),
    box("row", button("选择 iCloud Drive 目录…", () => chooseDestination("iCloud Drive 规则同步", "同步目录", folder =>
      confirmAction("启用规则同步？", folder, () => cloudAction("configure", {folder, confirm: true})))),
    status !== "off" && button("立即同步", () => cloudAction("status", {force: true})),
    status !== "off" && button("停止同步", () => confirmAction("停止规则同步？", "本机规则和云端修订会保留。", () => cloudAction("configure", {confirm: true})))),
    status === "conflict" && box("stack", el("strong", "选择冲突规则要采用的版本"),
      button("保留本机改动", () => resolve("local", "保留本机改动")),
      ...(cloud.choices || []).map(branch => button(formatMessage("采用远端分支 {id}", {id: branch.id.slice(0, 10)}), () => resolve(branch.id, "采用这个远端分支？")))));
}
async function saveRules(next) {
  const result = await api("/api/rules/save", {rules: next});
  rules = result.rules || next;
  say("输入规则已保存");
  render();
}
function inputPage() {
  const runtime = state.automation || {};
  const statuses = new Map((runtime.rules || []).map(item => [item.id, item]));
  const labels = { registered: "已注册", active: "已启用", disabled: "已停用", paused: "已暂停", conflict: "快捷键冲突", unsupported: "当前不支持", error: "注册失败", pending: "等待启用" };
  const rows = rules.map(rule => {
    const status = statuses.get(rule.id);
    const name = currentAction(rule.actionID)?.title || rule.actionID;
    const application = rule.application || (rule.include || []).join("、");
    const trigger = rule.shortcut ? box("rule-key-combination", ...rule.shortcut.split("+").map(key => el("kbd", key, "", true))) :
      el("small", ({gesture: "鼠标手势", mouseButton: "鼠标按钮"})[rule.trigger] || "未指定快捷键");
    const approval = rule.needsReview && button("在本机复核…", () => showModal("在本机复核规则", box("stack",
      el("strong", rule.name || name, "wrap-text", Boolean(rule.name)),
      el("code", [rule.actionID, rule.shortcut, application].filter(Boolean).join(" · "), "wrap-text", true)),
    {protectExit: true, actions: box("row", button("保持停用", () => cloudAction("approve", {id: rule.id, accept: false, confirm: true})),
      rule.cloudWantsEnabled && button("启用", () => cloudAction("approve", {id: rule.id, accept: true, confirm: true}), {cls: "primary"}))}));
    const active = !rule.needsReview && toggle("启用", rule.enabled,
      value => saveRules(rules.map(item => item.id === rule.id ? {...item, enabled: value} : item)));
    const stateLabel = rule.needsReview ? "等待本机复核" : labels[status?.status] || status?.status;
    const stateClass = rule.needsReview || ["conflict", "error", "unsupported"].includes(status?.status) ? "rule-issue" :
      ["active", "registered"].includes(status?.status) ? "rule-ready" : "";
    return box("list-row rule-row", box("workflow-icon", icon("keyboard")), box("fill rule-content",
      box("row", el("strong", name, "row-title"), trigger),
      box("row rule-meta", el("small", application || "所有应用", "", Boolean(application)),
        stateLabel && el("small", stateLabel, "rule-status " + stateClass)),
      status?.detail && el("small", trError(status.detail), "wrap-text", true)),
    box("row rule-actions", active, approval, button("试跑…", () => rulePreviewDialog("rule", rule)), button("编辑", () => ruleDialog(rule)),
      button("", () => confirmAction("移除输入规则？", rule.shortcut || rule.actionID,
        () => saveRules(rules.filter(item => item.id !== rule.id)), "移除", {danger: true}), {glyph: "trash", cls: "plain danger", label: "移除规则"})));
  });
  const enabled = Boolean(state.settings?.windowsAutomationEnabled);
  const status = !enabled ? "全局输入规则尚未启用" : runtime.paused ? "输入监听已暂停" : runtime.running ? "输入监听正在运行" : "输入监听尚未运行";
  const connectivity = box("workflow-callout", icon(runtime.running ? "check" : "keyboard"),
    box("fill", el("strong", status), runtime.lastAction?.detail && note(runtime.lastAction.detail)),
    box("row", toggle("启用 Windows 全局输入规则", enabled, async value => {
      await api("/api/settings", {windowsAutomationEnabled: value});
      say(value ? "全局输入规则已启用" : "全局输入规则已关闭");
      render();
    }), button(runtime.paused ? "继续监听" : "暂停监听", async () => {
      await api("/api/settings", {inputPaused: !runtime.paused});
      render();
    }, {disabled: !enabled || (!runtime.running && !runtime.paused)})));
  const rulesPanel = box("panel rules-panel", box("between workflow-head", el("h2", "输入规则"),
    button("添加规则", () => ruleDialog(), {glyph: "plus", cls: "primary", disabled: state.status !== "ready"})),
    connectivity, note("按应用设置的规则可限定到指定的 Windows 程序。"),
    rules.length ? box("list rule-list", ...rows) : empty("keyboard", "还没有输入规则", "添加快捷键来运行常用操作。"));
  return box("stack rules-workspace", rulesPanel, box("rule-support", rulesCloudPanel(),
    panel("系统与权限", note(state.permissions?.inputMonitoring?.detail || ""), button("打开设置", settingsDialog, {glyph: "settings"}))));
}
function ruleDialog(original = {}) {
  const runtime = state.automation || {};
  const choices = catalog.filter(item => !item.unavailableReason && !item.files && (runtime.actionIDs ? runtime.actionIDs.includes(item.id) :
    /^(window\.|system\.(volume|mute|play|nextTrack|previousTrack|lock|showDesktop|missionControl|space|preventSleep))/.test(item.id)));
  if (original.actionID && !choices.some(item => item.id === original.actionID)) choices.unshift({id: original.actionID, title: original.actionID});
  const action = select(choices.map(row => [row.id, row.title]), original.actionID || "window.leftHalf");
  const shortcut = input(original.shortcut || "", {placeholder: "Ctrl+Alt+W"});
  shortcut.required = true;
  const names = {Escape: "Escape", " ": "Space", ArrowLeft: "Left", ArrowRight: "Right", ArrowUp: "Up", ArrowDown: "Down"};
  let recording = false;
  const record = button("录制快捷键", () => { setRecording(true); shortcut.focus(); }, {glyph: "keyboard"});
  function setRecording(value) {
    recording = value;
    record.setAttribute("aria-pressed", String(value));
    record.querySelector("span").textContent = tr(value ? "按下快捷键" : "录制快捷键");
  }
  setRecording(false);
  shortcut.addEventListener("blur", () => setRecording(false));
  shortcut.addEventListener("keydown", event => {
    if (!recording || ["Control", "Alt", "Shift", "Meta"].includes(event.key)) return;
    if (event.key === "Tab" && !event.ctrlKey && !event.altKey && !event.metaKey) return;
    event.preventDefault();
    event.stopPropagation();
    if (event.key === "Escape") { setRecording(false); return; }
    if (!event.ctrlKey && !event.altKey && !event.metaKey) return;
    const key = names[event.key] || (event.key.length === 1 ? event.key.toUpperCase() : event.key);
    shortcut.value = [event.ctrlKey && "Ctrl", event.altKey && "Alt", event.shiftKey && "Shift", event.metaKey && "Win", key].filter(Boolean).join("+");
    setRecording(false);
  });
  const application = input(original.application || "", {placeholder: "例如 notepad.exe"});
  const enabled = toggle("启用此规则", original.enabled ?? true);
  const triggerOptions = [["hotkey", "快捷键"]];
  if (runtime.gestures || original.trigger === "gesture") triggerOptions.push(["gesture", "鼠标手势"]);
  if (runtime.mouseButtons || original.trigger === "mouseButton") triggerOptions.push(["mouseButton", "鼠标按钮"]);
  const trigger = select(triggerOptions, original.trigger);
  const direction = select([["left", "向左"], ["right", "向右"], ["up", "向上"], ["down", "向下"]], original.direction);
  const gesture = box("stack", field("拖动方向", direction), note("按 Alt＋鼠标右键拖动至少 70 像素，再松开右键。"));
  const mouseButton = select([["2", "中键"], ["3", "侧键 X1"], ["4", "侧键 X2"]], String(original.mouseButton || 2));
  const mouse = field("鼠标按钮", mouseButton);
  const modifierControl = input(original.mouseModifiers || "", {placeholder: "例如 Ctrl+Alt"});
  const modifiers = field("鼠标修饰键（可选）", modifierControl);
  const hotkey = box("rule-hotkey", field("快捷键", shortcut), record);
  const mouseFields = box("rule-fields", mouse, modifiers);
  const update = () => {
    gesture.hidden = trigger.value !== "gesture";
    mouseFields.hidden = trigger.value !== "mouseButton";
    hotkey.hidden = trigger.value !== "hotkey";
    shortcut.required = trigger.value === "hotkey";
  };
  trigger.onchange = update;
  update();
  const draftID = original.id || crypto.randomUUID();
  const draft = () => ({
    ...original, id: draftID, actionID: action.value, shortcut: trigger.value === "hotkey" ? shortcut.value.trim() : "",
    trigger: trigger.value, direction: direction.value, application: application.value.trim(), enabled: enabled.firstChild.checked,
    ...(trigger.value === "mouseButton" ? {mouseButton: Number(mouseButton.value), mouseModifiers: modifierControl.value.trim()} :
      trigger.value === "gesture" ? {mouseModifiers: "Alt"} : {}),
  });
  formDialog("编辑输入规则", [box("rule-fields", field("执行动作", action), field("触发方式", trigger)),
    box("rule-trigger-fields", hotkey, gesture, mouseFields),
    box("rule-fields rule-scope", field("限定应用（可选）", application), enabled),
    box("row", button("试跑草稿…", () => rulePreviewDialog("rule", draft(), true)))], () => {
    const next = draft();
    return saveRules(original.id ? rules.map(item => item.id === original.id ? next : item) : [...rules, next]);
  }, "保存");
}
function rulePreviewDialog(kind, item, draft = false) {
  const preview = box("stack rule-preview-result");
  let revision = 0;
  let fields;
  let sample;
  if (kind === "rule") {
    const application = input(item.application || item.appBundleID || item.include?.[0] || "notepad.exe");
    const trigger = select([["hotkey", "快捷键"], ["gesture", "鼠标手势"], ["mouseButton", "鼠标按钮"]], item.trigger || "hotkey");
    const shortcut = input(item.shortcut || "Ctrl+Alt+W");
    const direction = select([["left", "向左"], ["right", "向右"], ["up", "向上"], ["down", "向下"]], item.direction || "left");
    const mouseButton = select([["2", "中键"], ["3", "侧键 X1"], ["4", "侧键 X2"]], String(item.mouseButton || 2));
    const modifiers = input(item.mouseModifiers || "", {placeholder: "留空沿用规则设置"});
    const hotkeyField = field("模拟快捷键", shortcut);
    const gestureField = field("拖动方向", direction);
    const mouseField = field("鼠标按钮", mouseButton);
    const modifierField = field("鼠标修饰键（可选）", modifiers);
    const mouseFields = box("rule-fields", gestureField, mouseField, modifierField);
    const update = () => {
      hotkeyField.hidden = trigger.value !== "hotkey";
      gestureField.hidden = trigger.value !== "gesture";
      mouseField.hidden = trigger.value !== "mouseButton";
      mouseFields.hidden = trigger.value === "hotkey";
    };
    trigger.addEventListener("change", update);
    update();
    fields = box("stack", box("rule-fields", field("模拟应用", application), field("模拟触发方式", trigger)), hotkeyField, mouseFields);
    sample = () => ({application: application.value.trim(), trigger: trigger.value,
      ...(trigger.value === "hotkey" ? {shortcut: shortcut.value.trim()} : {
        ...(trigger.value === "gesture" ? {direction: direction.value} : {mouseButton: Number(mouseButton.value)}),
        ...(modifiers.value.trim() && {mouseModifiers: modifiers.value.trim()}),
      })});
  } else {
    const pathInput = area("C:\\GaoPreview\\Inbox\\sample.png\nC:\\GaoPreview\\Inbox\\notes.txt");
    const existing = area("");
    fields = box("stack", field("合成输入路径（每行一个）", pathInput), field("模拟已存在路径（可选）", existing));
    sample = () => ({paths: splitLines(pathInput.value), existingPaths: splitLines(existing.value)});
  }
  fields.addEventListener("input", () => { revision += 1; preview.replaceChildren(); });
  fields.addEventListener("change", () => { revision += 1; preview.replaceChildren(); });
  const selection = kind === "rule" ? draft ? {rule: item} : {ruleID: item.id} : {workflowID: item.id};
  const name = item.name || actionTitle(item.actionID);
  const current = formDialog(kind === "rule" ? "规则试跑" : "组合操作试跑", [el("strong", name, "wrap-text", Boolean(item.name)),
    note("仅根据下面的合成输入生成只读计划。"), fields, preview], async () => {
    const submittedRevision = revision;
    const result = await api("/api/rules/preview", {kind, ...selection, sample: sample()});
    if (current.open && submittedRevision === revision) {
      preview.replaceChildren(rulePreviewResult(result));
      const heading = preview.querySelector("h3");
      heading.focus({preventScroll: true});
      heading.scrollIntoView({block: "start"});
    }
    return false;
  }, "生成试跑计划", {size: "wide", overlay: draft});
}
function rulePreviewResult(plan) {
  const outcomes = {planned: "已生成试跑计划", blocked: "试跑已阻断", notMatched: "试跑条件未命中"};
  const conditionLabels = {match: "命中", mismatch: "不匹配", blocked: "已阻断", unknown: "不确定"};
  const stepLabels = {planned: "预计", blocked: "已阻断", skipped: "已跳过"};
  const title = el("h3", outcomes[plan.outcome] || "试跑结果");
  title.tabIndex = -1;
  const conditions = el("ul", "", "rule-preview-list");
  for (const condition of plan.conditions) {
    const item = el("li", "", "rule-preview-item");
    item.append(box("between", el("strong", condition.label), el("small", conditionLabels[condition.status], `rule-preview-status ${condition.status}`)));
    if (condition.detail) item.append(el("p", trError(condition.detail), "wrap-text", true));
    conditions.append(item);
  }
  const steps = el("ol", "", "rule-preview-list");
  for (const step of plan.steps) {
    const item = el("li", "", "rule-preview-item");
    item.append(box("between", el("strong", formatMessage("步骤 {index} · {title}", {index: step.index, title: tr(step.title || step.actionID)}), "wrap-text", true),
      el("small", stepLabels[step.status], `rule-preview-status ${step.status}`)));
    if (step.reason) item.append(el("p", trError(step.reason), "wrap-text", true));
    if (step.uncertainty) item.append(el("p", formatMessage("不确定：{detail}", {detail: trError(step.uncertainty)}), "rule-preview-uncertainty wrap-text", true));
    if (step.effects.length) {
      const effects = el("ul", "", "rule-preview-effects");
      for (const effect of step.effects) {
        const row = el("li");
        row.append(el("span", effect.operation));
        if (effect.source) row.append(box("row", el("small", "来源"), el("code", effect.source, "wrap-text fill", true)));
        if (effect.path) row.append(box("row", el("small", "目标路径"), el("code", effect.path, "wrap-text fill", true)));
        effects.append(row);
      }
      item.append(effects);
    }
    steps.append(item);
  }
  return box("stack", title, conditions.children.length && box("stack", el("h3", "命中条件"), conditions),
    steps.children.length && box("stack", el("h3", "预计动作与文件"), steps));
}
const actionTitle = id => currentAction(id)?.title || ({delay: "等待", "open.path": "打开路径", "open.url": "打开网址"}[id] || id);
function workflowPage() {
  const workflows = state.workflows || [];
  const list = workflows.map(workflow => box("list-row", icon("layers"),
    box("fill", el("strong", workflow.name, "row-title"), el("small", (workflow.steps || []).map(step => actionTitle(step.actionID)).join(" → "))),
    button("运行", () => runWorkflow(workflow), {glyph: "play"}), button("试跑…", () => rulePreviewDialog("workflow", workflow)),
    button("编辑", () => workflowDialog(workflow)),
    button("", () => confirmAction("删除此组合操作？", workflow.name, async () => {
      await api("/api/settings", {workflows: state.workflows.filter(item => item.id !== workflow.id)});
      await refreshCatalog();
      say("组合操作已删除");
      render();
    }, "删除"), {glyph: "trash", cls: "plain danger", label: "删除 " + workflow.name})));
  return panel("", box("between", el("h2", "组合操作"), button("新建组合操作", () => workflowDialog(), {glyph: "plus", disabled: state.status !== "ready"})),
    note("组合操作按步骤运行，出现错误时停止。已经完成的操作会保留。"),
    list.length ? box("list", ...list) : empty("layers", "还没有组合操作", "例如，依次调整窗口和打开文件夹。"));
}
async function runWorkflow(workflow) {
  if (!workflow) return;
  let selected = files;
  if (workflow.steps?.some(step => currentAction(step.actionID)?.files) && !files.length) {
    selected = await ensureFiles();
    if (!selected) return;
  }
  const hasWindow = workflow.steps?.some(step => step.actionID.startsWith("window."));
  const invoke = () => perform("workflow.run." + workflow.id, {paths: selected, targetID: targetID || undefined, apply: true, confirm: true});
  const verify = async () => {
    const result = await progress("正在运行 " + workflow.name + "…", invoke);
    const done = result.completed || [];
    for (const {result: stepResult} of done) rememberOutputs(stepResult);
    const detail = result.stopped ? result.error : "完成 " + done.length + " 个步骤";
    say(detail, result.stopped);
    const list = box("list", ...done.map(step => box("list-row", icon("check"), el("span", actionTitle(step.actionID)))));
    showModal(workflow.name, box("stack", el("p", detail, result.stopped ? "error" : "muted"), list));
  };
  const details = "将按顺序运行 " + workflow.steps.length + " 个步骤。";
  if (hasWindow && !targetID) {
    await refreshWindows(false, false);
    if (!windows.length) throw new Error("找不到可用于运行组合操作的窗口。");
    formDialog("运行 " + workflow.name, [note(details), windowSelectField()], verify, "运行");
  } else confirmAction("运行 " + workflow.name + "？", details, verify, "运行");
}
function workflowDialog(original = {}) {
  const name = input(original.name || "", {placeholder: "组合操作名称"});
  name.required = true;
  const steps = (original.steps || []).map(step => ({ ...step }));
  const rendered = box("stack");
  const options = catalog.filter(action => !action.unavailableReason && !action.id.startsWith("workflow.") &&
    (/^(window\.|system\.(volume|mute|play|nextTrack|previousTrack|showDesktop|missionControl|space|preventSleep)|archive\.(create|7z|extract)$|images\.(bmp|png)$)/.test(action.id)));
  if (state.workflowActions) options.splice(0, options.length, ...state.workflowActions.map(id => currentAction(id) || {id, title: actionTitle(id)}));
  const draw = () => {
    rendered.replaceChildren(...steps.map((step, index) => {
      const choices = options.some(item => item.id === step.actionID) ? options : [...options, {id: step.actionID, title: actionTitle(step.actionID)}];
      const action = select(choices.map(item => [item.id, item.title]), step.actionID);
      action.onchange = () => { step.actionID = action.value; draw(); };
      const argument = input(step.argument || "", {placeholder: "参数（可选）", cls: "fill"});
      argument.oninput = () => { step.argument = argument.value; };
      const move = direction => {
        [steps[index], steps[index + direction]] = [steps[index + direction], steps[index]];
        draw();
      };
      return panel("", box("row", el("strong", String(index + 1)), action,
        ["delay", "open.path", "open.url"].includes(step.actionID) && argument,
        button("↑", () => move(-1), {disabled: index === 0, label: "上移步骤"}),
        button("↓", () => move(1), {disabled: index === steps.length - 1, label: "下移步骤"}),
        button("", () => {steps.splice(index, 1); draw();}, {glyph: "trash", cls: "plain danger", label: "移除步骤"})));
    }));
  };
  const add = button("添加步骤", () => {
    if (steps.length >= 50) throw new Error("最多 50 个步骤。");
    if (!options.length) throw new Error("当前没有可选动作。");
    steps.push({id: crypto.randomUUID(), actionID: options[0].id, argument: ""});
    draw();
  }, {glyph: "plus"});
  draw();
  formDialog("编辑组合操作", [field("名称", name), rendered, add], async () => {
    if (!name.value.trim() || !steps.length) throw new Error("请填写名称并至少添加一个步骤。");
    await api("/api/workflows/save", {...original, name: name.value.trim(), steps});
    await refreshCatalog();
    say("组合操作已保存");
    render();
  }, "保存");
}

async function refreshCatalog() {
  catalog = (await api("/api/search?q=")).actions || [];
}
const lifecycle = {
  clientID: crypto.randomUUID(), desktop: null, timer: null, polling: false, deciding: false, committed: false,
  requestID: null, dialog: null, reviewKey: "", reviewed: false, pastePending: false, error: "",
};

function renderDesktopActions() {
  const container = document.querySelector(".workbench-desktop-actions");
  if (!container) return;
  if (!lifecycle.desktop) {
    container.replaceChildren();
    return;
  }
  const hide = "收起到通知区域";
  const quit = "退出搞操作";
  container.replaceChildren(
    button(hide, () => api("/api/lifecycle/hide", {}), {cls: "plain", glyph: "monitor", label: hide}),
    button(quit, async () => {
      await api("/api/shutdown", {});
      await pollLifecycle();
    }, {cls: "plain", glyph: "external", label: quit}));
}

function workbenchExitStatus() {
  const status = captureExitStatus();
  return {...status, working: Boolean(status.working || pending || actionRequests),
    pendingDialog: Boolean(dialog?.open && dialog.dataset.protectExit)};
}

async function decideWorkbenchExit(decision, resume) {
  if (!lifecycle.requestID || lifecycle.deciding) return;
  const status = workbenchExitStatus();
  if (decision === "confirm" && (status.working || status.recording)) {
    showExitReview(status);
    return;
  }
  lifecycle.deciding = true;
  try {
    const result = await api("/api/lifecycle/exit", {clientID: lifecycle.clientID, requestID: lifecycle.requestID, decision});
    if (!result.accepted) return;
    lifecycle.committed = decision === "confirm";
    lifecycle.requestID = null;
    lifecycle.dialog?.close();
    if (lifecycle.committed) {
      app.inert = true;
      say("正在退出搞操作…");
    }
    if (resume) resume();
  } catch (failure) {
    lifecycle.error = failure.message;
    showExitReview(workbenchExitStatus());
  } finally {
    lifecycle.deciding = false;
  }
}

function showExitReview(status) {
  const key = JSON.stringify([lifecycle.requestID, status, lifecycle.pastePending, lifecycle.error]);
  if (lifecycle.dialog?.open && lifecycle.reviewKey === key) return;
  lifecycle.reviewed = true;
  lifecycle.reviewKey = key;
  lifecycle.dialog?.close();
  const cancel = () => decideWorkbenchExit("cancel");
  const cancelButton = button("取消退出", cancel);
  cancelButton.autofocus = true;
  const actions = [cancelButton];
  const details = [
    status.working && note("操作仍在进行，请先完成或取消任务。"),
    status.recording && note("正在录制。请停止录制并保存，或取消退出。"),
    status.unsavedMedia && note("有未保存的录制或导出。"),
    status.unsavedImage && note("有未保存的截图或标注。"),
    status.pendingDialog && note("有待确认的操作。退出将关闭此对话框。"),
    lifecycle.pastePending && note("粘贴正在等待核对。退出会取消本次粘贴并尝试恢复剪贴板。"),
  ];
  if (lifecycle.error) {
    const message = el("p", trError(lifecycle.error), "error", true);
    message.setAttribute("role", "alert");
    details.push(message);
  }
  if (!status.working && !status.pendingDialog) {
    if (status.recording) actions.push(button("停止录制并转到保存", () => decideWorkbenchExit("cancel", () => {
      stopRecording(false);
      changeShotTab("record");
    }), {cls: "primary"}));
    else if (status.unsavedMedia) actions.push(button("返回保存", () => decideWorkbenchExit("cancel", () => changeShotTab("record")), {cls: "primary"}));
    else if (status.unsavedImage) actions.push(button("返回截图", () => decideWorkbenchExit("cancel", () => changeShotTab(shotLong?.active ? "capture" : "annotation")), {cls: "primary"}));
    else if (lifecycle.pastePending) actions.push(button("返回粘贴核对", () => decideWorkbenchExit("cancel", () => {
      go("clipboard");
      void refreshClipboard(true);
    }), {cls: "primary"}));
  }
  if (!status.working && !status.recording) {
    const unsaved = status.unsavedMedia || status.unsavedImage;
    const confirm = unsaved ? "放弃未保存内容并退出" : status.pendingDialog ? "放弃本次操作并退出" :
      lifecycle.pastePending ? "取消粘贴并退出" : "退出搞操作";
    actions.push(button(confirm, () => decideWorkbenchExit("confirm"), {
      cls: unsaved || status.pendingDialog || lifecycle.pastePending ? "primary danger" : "primary",
    }));
  }
  lifecycle.dialog = showModal("退出搞操作？", box("stack", ...details),
    {overlay: true, size: "compact", dismiss: cancel, actions: box("row", ...actions)});
}

async function pollLifecycle() {
  if (lifecycle.polling || lifecycle.deciding) return;
  lifecycle.polling = true;
  try {
    const updated = await api("/api/lifecycle", {clientID: lifecycle.clientID, busy: Object.values(workbenchExitStatus()).some(Boolean)});
    if (lifecycle.desktop !== updated.desktop) {
      lifecycle.desktop = updated.desktop;
      renderDesktopActions();
    }
    if (updated.desktop && lifecycle.timer === null) lifecycle.timer = setInterval(pollLifecycle, 750);
    if (lifecycle.committed && !updated.exitError) return;
    if (lifecycle.committed) app.inert = false;
    lifecycle.committed = false;
    if (lifecycle.requestID !== updated.exitRequest) {
      lifecycle.requestID = updated.exitRequest;
      lifecycle.reviewed = false;
      lifecycle.error = "";
    }
    if (!lifecycle.requestID) {
      lifecycle.dialog?.close();
      if (updated.exitError && updated.exitError !== lifecycle.error) {
        lifecycle.error = updated.exitError;
        say(updated.exitError, true);
      }
      return;
    }
    lifecycle.pastePending = updated.pastePending;
    lifecycle.error = updated.exitError || lifecycle.error;
    const status = workbenchExitStatus();
    if (lifecycle.reviewed || lifecycle.pastePending || lifecycle.error || Object.values(status).some(Boolean)) showExitReview(status);
    else await decideWorkbenchExit("confirm");
  } catch {
    // A disconnected or closing workbench has no lifecycle updates to present.
  } finally {
    lifecycle.polling = false;
  }
}

window.addEventListener("focus", () => { if (lifecycle.desktop) void pollLifecycle(); });
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && state) void refreshClipboard();
});
window.addEventListener("beforeunload", event => {
  if (lifecycle.committed || !Object.values(workbenchExitStatus()).some(Boolean)) return;
  event.preventDefault();
  event.returnValue = "";
});

async function initialize() {
  [state] = await Promise.all([api("/api/state"), refreshCatalog()]);
  await loadInterfaceLanguage();
  files = state.selection || [];
  selectionRevision = state.selectionRevision;
  if (files.length && !location.hash) section = "files";
  render();
  if (state.incomingOCRRequest) openIncomingOCR(state.incomingOCRRequest);
  if (["windows", "overview"].includes(section)) refreshWindows(false);
  if (section === "input") refreshRules();
  if (!clipboardPoll) clipboardPoll = setInterval(() => refreshClipboard(), 3000);
}
document.addEventListener("keydown", event => {
  if (lifecycle.committed) return;
  if ((event.ctrlKey || event.metaKey) && !event.altKey && event.key === ",") {
    event.preventDefault();
    settingsDialog();
  }
  if ((event.ctrlKey || event.metaKey) && !event.altKey && event.key.toLowerCase() === "k") {
    event.preventDefault();
    openSearch();
  }
});
let dragCount = 0;
app.addEventListener("dragenter", event => {
  if (!event.dataTransfer.types.includes("Files") && !event.dataTransfer.types.includes("text/uri-list")) return;
  event.preventDefault();
  dragCount++;
  app.classList.add("dropping");
});
app.addEventListener("dragleave", () => {
  dragCount = Math.max(0, dragCount - 1);
  if (!dragCount) app.classList.remove("dropping");
});
app.addEventListener("dragover", event => {
  if (dragCount) event.preventDefault();
});
app.addEventListener("drop", event => {
  if (!dragCount) return;
  event.preventDefault();
  dragCount = 0;
  app.classList.remove("dropping");
  const uriList = splitLines(event.dataTransfer.getData("text/uri-list"));
  const paths = uriList.filter(value => value.startsWith("file://")).map(value => {
    const uri = new URL(value);
    return (uri.hostname ? "//" + uri.hostname : "") + decodeURIComponent(uri.pathname).replace(/^\/(?=[A-Za-z]:)/, "");
  });
  if (!paths.length) {
    say("当前窗口无法从拖放取得完整文件路径，请使用“选择文件…”或“输入路径…”。", true);
    return;
  }
  files = [...new Set(paths)];
  if (section === "home") go("files");
  else render();
});
async function startWorkbench() {
  void pollLifecycle();
  const loading = box("startup-state", el("i", "", "status-working"), el("p", "正在加载工作台…"));
  loading.setAttribute("role", "status");
  app.replaceChildren(loading);
  try {
    await initialize();
  } catch (error) {
    const message = box("startup-state", icon("warning"), el("h1", "无法打开工作台"),
      el("p", trError(error.message), "error", true), button("重试", startWorkbench, {cls: "primary"}));
    message.setAttribute("role", "alert");
    app.replaceChildren(message);
  }
}
document.addEventListener("DOMContentLoaded", startWorkbench);
