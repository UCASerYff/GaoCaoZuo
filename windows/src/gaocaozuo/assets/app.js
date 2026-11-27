"use strict";

const token = document.querySelector('meta[name="gao-token"]').content;
const version = document.querySelector('meta[name="gao-version"]').content;
const marketingVersion = version.replace(/^(Windows\s*)?v?/i, "").split("+")[0];
document.title = "搞操作 V" + marketingVersion;
const app = document.querySelector("#app");
const sections = {
  home: ["工作台", "从这里开始，轻松处理日常。", "grid"],
  screenshots: ["截图与录制", "捕捉画面、识别文字，记录重要内容。", "scan"],
  clipboard: ["剪贴板", "让复制过的内容，随时回到手边。", "clip"],
  files: ["文件", "新建、整理与转换，文件处理更顺手。", "folder"],
  archives: ["压缩与解压", "快速打包、解压与预览压缩内容。", "archive"],
  tools: ["实用工具", "图片转换、校验与系统小工具。", "wand"],
  windows: ["窗口", "为眼前的工作，安排合适的位置。", "window"],
  overview: ["桌面总览", "查找应用与窗口，快速回到正在做的事。", "desktops"],
  lockPolicy: ["锁屏策略", "按自己的习惯设置本机闲置与锁屏。", "lock"],
  input: ["快捷键与手势", "让常用动作，跟着你的操作习惯走。", "keyboard"],
  workflows: ["组合操作", "把重复步骤串起来，一次完成。", "layers"],
  history: ["恢复记录", "查看文件操作，按需恢复处理结果。", "history"],
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
let dialog = null;
let clipboardPoll = 0;
let selectionRevision = null;
let statePollInFlight = false;

async function api(path, body) {
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
}
const perform = (id, payload = {}) => api("/api/action", { id, payload });

function el(tag, text, cls) {
  const node = document.createElement(tag);
  if (text !== undefined && text !== "") node.textContent = text;
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
    node.title = label;
    node.setAttribute("aria-label", label);
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
  node.placeholder = placeholder;
  if (placeholder) node.setAttribute("aria-label", placeholder);
  if (min !== undefined) node.min = min;
  if (max !== undefined) node.max = max;
  if (step !== undefined) node.step = step;
  return node;
}
function area(value = "", placeholder = "") {
  const node = el("textarea");
  node.value = value;
  node.placeholder = placeholder;
  if (placeholder) node.setAttribute("aria-label", placeholder);
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
function toggle(label, value, changed) {
  const check = el("input");
  check.type = "checkbox";
  check.checked = Boolean(value);
  if (changed) check.addEventListener("change", () => Promise.resolve(changed(check.checked)).catch(report));
  return boxLabel("option", check, el("span", label));
}
function note(value) { return el("p", value, "muted"); }
function empty(glyph, title, detail) {
  return box("empty", icon(glyph), el("strong", title), detail && note(detail));
}
function panel(title, ...content) {
  return box("panel", title && el("h2", title), ...content);
}
function go(next) {
  if (next === section) return;
  section = next;
  history.replaceState(null, "", "#" + next);
  render();
  if (["windows", "overview"].includes(section)) refreshWindows(false);
  if (section === "input") refreshRules();
}
function say(text, error = false) {
  banner = { text, error };
  drawFooter();
}
function report(error) {
  if (dialog?.open) {
    const message = dialog.querySelector(".modal-error");
    message.textContent = error.message;
    message.hidden = false;
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
  const status = el("span", text, banner.error ? "error" : "");
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
  return value && !Number.isNaN(date.getTime()) ? date.toLocaleString("zh-CN") : "";
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
  if (dialog?.open) dialog.close();
  document.documentElement.dataset.theme = state.settings?.appearance || "system";
  const side = el("aside", "", "sidebar");
  const brand = box("brand", el("span"), box("", el("strong", "搞操作"), el("small", "让操作更顺手")));
  brand.firstChild.append(icon("command"));
  const nav = el("nav", "", "nav");
  nav.setAttribute("aria-label", "主导航");
  for (const [group, entries] of navigation) {
    if (group) nav.append(el("div", group, "group-title"));
    for (const id of entries) {
      const [label, , glyph] = sections[id];
      const control = button(label, () => go(id), { glyph });
      if (section === id) control.setAttribute("aria-current", "page");
      nav.append(control);
    }
  }
  side.append(brand, nav, box("side-foot", button("设置", settingsDialog, { cls: "plain", glyph: "settings", label: "设置 Ctrl+," }), el("small", "V" + marketingVersion)));
  const main = el("main", "", "workspace");
  const [title, summary] = sections[section];
  const header = el("header", "", "workspace-header");
  header.append(box("", el("h1", title), note(summary)), button("搜索操作", openSearch, { glyph: "search" }));
  const page = box("page" + (section === "home" ? " home" : ""));
  if (state.status !== "ready") {
    const warning = box("warning", el("div", state.notice || "尚未创建本机设置。"));
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
  drawFooter();
}
function showModal(title, contents, options = {}) {
  if (dialog?.open) dialog.close();
  const current = el("dialog");
  const heading = el("h2", title);
  heading.id = "modal-heading";
  current.setAttribute("aria-labelledby", heading.id);
  const error = el("p", "", "error modal-error");
  error.hidden = true;
  const titleRow = box("between dialog-title", heading, button("", () => current.close(), { glyph: "close", cls: "plain", label: "关闭" }));
  current.append(box("dialog-content", titleRow, contents, error));
  current.addEventListener("close", () => {
    if (dialog === current) dialog = null;
    current.remove();
    options.closed?.();
  });
  app.append(current);
  dialog = current;
  current.showModal();
  return current;
}
function formDialog(title, fields, submit, submitTitle = "确定") {
  const form = el("form", "", "stack");
  const confirm = el("button", submitTitle, "primary");
  confirm.type = "submit";
  form.append(...fields, box("row dialog-actions", button("取消", () => current.close()), confirm));
  const current = showModal(title, form);
  form.addEventListener("submit", async event => {
    event.preventDefault();
    if (confirm.disabled) return;
    confirm.disabled = true;
    const error = current.querySelector(".modal-error");
    error.hidden = true;
    try {
      const keepOpen = await submit();
      if (keepOpen !== false && current.open) current.close();
    } catch (failure) { report(failure); }
    finally { confirm.disabled = false; }
  });
  return current;
}
function confirmAction(title, detail, run, accept = "确认") {
  return formDialog(title, [note(detail)], run, accept);
}
function settingsDialog() {
  const settings = state.settings || {};
  const appearance = select([["system", "跟随系统"], ["light", "浅色"], ["dark", "深色"]], settings.appearance);
  const days = input(settings.clipboardDays || 7, { type: "number", min: 1, max: 365 });
  const limit = input(settings.clipboardLimit || 200, { type: "number", min: 1, max: 1000 });
  const exclusions = area((settings.clipboardExcludedApps || []).join("\n"), "每行一个应用标识");
  const snap = toggle("窗口靠近屏幕边缘时吸附", settings.windowSnapEnabled);
  const drag = toggle("按 Alt 拖动应用窗口", settings.windowDragEnabled);
  const permissions = Object.entries(state.permissions || {}).map(([id, item]) => {
    const names = { accessibility: "窗口控制", inputMonitoring: "输入监听", finderExtension: "资源管理器", clipboardHistory: "剪贴板历史", screenCapture: "屏幕捕获", automation: "自动化" };
    return box("list-row", box("fill", el("strong", names[id] || id, "row-title"), el("small", item.detail)));
  });
  formDialog("设置", [
    field("外观", appearance), field("保留剪贴板历史（天）", days), field("历史记录上限", limit),
    field("排除的应用", exclusions),
    state.automation && panel("窗口与桌面", snap, state.automation.windowDrag && drag),
    panel("系统与权限", box("list", ...permissions)),
  ].filter(Boolean), async () => {
    await api("/api/settings", {
      appearance: appearance.value, clipboardDays: Number(days.value), clipboardLimit: Number(limit.value),
      clipboardExcludedApps: splitLines(exclusions.value),
      ...(state.automation ? {windowSnapEnabled: snap.firstChild.checked} : {}),
      ...(state.automation?.windowDrag ? {windowDragEnabled: drag.firstChild.checked} : {}),
    });
    say("设置已保存");
    render();
  }, "保存");
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
  const dots = box("hero-dots", el("i"), el("i"), el("i"));
  const artwork = box("hero-art", box("hero-shadow"), box("hero-window", dots, box("hero-layout", el("aside"), box("", icon("command"), el("b"), el("b")))), box("hero-check", icon("check")));
  artwork.setAttribute("aria-hidden", "true");
  const launch = button("打开操作面板", openSearch, {cls: "hero-launch", glyph: "command"});
  launch.append(icon("arrow"));
  const hero = box("hero", box("hero-main", box("hero-label", icon("sparkle"), el("span", "你的 Windows 操作工作台")),
    el("h2", "把常用操作，放到手边。"), el("p", "处理文件、整理窗口、记录灵感。\n从这里开始，少点几下。"), launch), artwork);
  const destinations = box("destinations");
  for (const [id, title, detail, color] of [
    ["screenshots", "截图与录制", "截图 · 标注 · 文字识别", "#1f7a6b"],
    ["clipboard", "剪贴板", "历史内容与常用短语", "#6764b3"],
    ["overview", "桌面总览", "查找窗口，快速切换", "#4877ac"],
    ["files", "文件处理", "新建 · 转换 · 压缩", "#a6703b"],
  ]) {
    const card = button("", () => go(id), { cls: "destination" });
    card.style.setProperty("--section", color);
    card.append(box("between", box("dest-icon", icon(sections[id][2])), icon("external")),
      box("", el("strong", title), el("small", detail)));
    destinations.append(card);
  }
  const favorites = (state.favorites || []).map(currentAction).filter(Boolean);
  const favoritesHeader = box("between", el("h2", "常用动作"), el("small", "在动作旁点星标，即可收藏"));
  const favoritesContent = favorites.length ? box("action-grid", ...favorites.map(actionCard)) :
    panel("", box("row", icon("star"), box("fill", el("strong", "把顺手的动作收藏在这里"), note("到文件、窗口或小工具中点亮星标，下次直接使用。")), button("浏览动作", () => go("tools"))));
  const quickFiles = panel("文件快处理", ...(files.length ? [
    note("已选择 " + files.length + " 项"),
    ...files.slice(0, 2).map(file => box("row", icon("file"), el("span", basename(file)))),
    box("row", button("压缩 ZIP", () => startAction("archive.create")), button("批量改名", () => startAction("files.rename"))),
  ] : [note("文件拖进窗口，就能接着处理。"), button("选择文件…", chooseFiles, {cls: "drop-button", glyph: "folder"})]));
  if (lastOutputs.length) quickFiles.append(el("hr"), button("在资源管理器查看上次结果", () => perform("finder.reveal", { path: lastOutputs[0], launch: true }), {cls:"plain link-row", glyph: "external"}));
  const personal = panel("我的工作方式",
    textLink("快捷键与手势", "让熟悉的操作一触即达", "keyboard", () => go("input")), el("hr"),
    textLink("组合操作", "把多个步骤串成一次动作", "layers", () => go("workflows")));
  const folder = state.settings?.folders?.[0];
  if (folder) personal.append(el("hr"), textLink(folder.name, "常用目录", "folder", () => perform("finder.reveal", {path: folder.path, launch: true})));
  return box("stack home", hero, destinations, box("stack", favoritesHeader, favoritesContent), box("columns", quickFiles, personal));
}
function textLink(title, detail, glyph, action) {
  const control = button("", action, { cls: "plain link-row icon-button" });
  control.append(icon(glyph), box("fill", el("strong", title), box("", el("small", detail))), icon("chevron"));
  return control;
}
function actionCard(action) {
  const glyph = action.id.startsWith("window.") ? "window" : sections[action.section]?.[2] || "file";
  const control = button("", () => startAction(action.id), { disabled: Boolean(action.unavailableReason) });
  control.title = action.unavailableReason || action.detail;
  control.append(box("action-icon", icon(glyph)), box("", el("strong", action.title), el("small", action.unavailableReason || action.detail)));
  const selected = (state.favorites || []).includes(action.id);
  const favorite = button("", async () => {
    await api("/api/favorites/toggle", { id: action.id });
    favorite.setAttribute("aria-pressed", String((state.favorites || []).includes(action.id)));
    if (section === "home" && !dialog?.open) render();
  }, { glyph: "star", cls: "plain star", disabled: state.status !== "ready", label: "收藏 " + action.title });
  favorite.setAttribute("aria-pressed", String(selected));
  return box("action-card", control, favorite);
}
function searchFilter(placeholder, onChange) {
  const query = input("", { type: "search", placeholder });
  const count = el("small");
  query.addEventListener("input", () => onChange(query.value, count));
  return { element: box("filter", icon("search"), query, count), query, count };
}
function actionSearch(query, rows = catalog) {
  const lower = query.trim().toLocaleLowerCase();
  return rows.filter(row => [row.title, row.detail, row.keywords, row.id].join(" ").toLocaleLowerCase().includes(lower));
}
function openSearch() {
  const result = box("action-grid dialog-result");
  const fill = (query, count) => {
    const rows = actionSearch(query);
    count.textContent = rows.length + " 个动作";
    result.replaceChildren(...rows.slice(0, 60).map(actionCard));
    if (!rows.length) result.append(empty("search", "暂无匹配动作"));
  };
  const search = searchFilter("搜索动作、关键词", fill);
  fill("", search.count);
  const current = showModal("操作面板", box("stack", search.element, result));
  search.query.focus();
  search.query.addEventListener("keydown", event => {
    if (event.key === "Enter") {
      const first = actionSearch(search.query.value).find(row => !row.unavailableReason);
      if (first) { event.preventDefault(); current.close(); startAction(first.id).catch(report); }
    }
  });
}

function actionPage(kind) {
  const items = catalog.filter(action => action.section === kind);
  const grid = box("action-grid");
  const update = (query, count) => {
    const rows = actionSearch(query, items);
    count.textContent = rows.length + " 个动作";
    grid.replaceChildren(...rows.map(actionCard));
    if (!rows.length) grid.append(empty("search", "暂无匹配动作", "试试其他关键词。"));
  };
  const filter = searchFilter("搜索动作或关键词", update);
  update("", filter.count);
  const wrap = box("stack", kind !== "windows" && selectionBar(), filter.element, kind === "windows" && targetPanel(), grid);
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
    confirmAction(currentAction(id)?.title || "提交系统请求", "请先保存工作。系统请求可能立即结束当前交互。", () => executeAction(id));
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
    const result = await progress("正在读取压缩包…", () => perform("archive.list", {path, password}));
    const members = result.members || [];
    const controls = members.map(item => toggle(item.name || item.path, false));
    const list = box("list dialog-result", ...controls.map((control, index) => box("list-row", box("fill", control), el("small", members[index].size === undefined ? "" : members[index].size + " 字节"))));
    showModal("预览 " + basename(path), box("stack", list, box("row",
      button("选择全部", () => controls.forEach(control => { control.firstChild.checked = true; })),
      button("提取所选…", () => {
        const chosen = members.filter((_, index) => controls[index].firstChild.checked).map(item => item.name || item.path);
        if (!chosen.length) throw new Error("请勾选要提取的文件。");
        chooseDestination("提取所选文件", "解压位置", destination => extractArchives({paths: [path], destination, members: chosen, password, batchID: crypto.randomUUID()}));
      }, {cls: "primary"}))));
    say("已读取压缩包目录 " + members.length + " 项");
  } catch (error) {
    if (!["password", "password-required"].includes(error.code)) throw error;
    const next = input("", {type: "password", placeholder: "压缩包密码"});
    next.required = true;
    formDialog("输入预览密码", [note(error.message), next], () => archivePreview(path, next.value), "查看");
  }
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
    confirmAction("关闭所选窗口？", windowName(item || {id: selected}) + "。若存在未保存内容，请在目标应用处理保存提示。", async () => {
      await run();
      if (section === "overview") refreshWindows(false, false);
    }, "关闭窗口");
  } else await run();
}
function targetPanel() {
  const selector = windowSelectField();
  return panel("", box("between", el("h3", "窗口控制"), button("刷新窗口", () => refreshWindows(), {glyph: "history"})),
    note(state.permissions?.accessibility?.detail || "选择一个正在运行的应用窗口。"), selector);
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
      confirmAction("关闭当前虚拟桌面？", "Windows 将把打开的窗口移到相邻桌面。", () => executeAction("system." + id), "关闭当前桌面") :
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
  const enabledRow = box("row", el("h2", "剪贴板"), enabled);
  const output = box("list");
  const groups = [...new Set(rows.map(item => item.group).filter(Boolean))].sort();
  const groupFilter = select([["", "全部"], ...groups], clipGroup);
  groupFilter.onchange = () => { clipGroup = groupFilter.value; redraw(); };
  const search = searchFilter("搜索历史", value => { clipQuery = value; redraw(); });
  search.query.value = clipQuery;
  const redraw = () => {
    const q = clipQuery.toLocaleLowerCase();
    const visible = rows.filter(item => (!clipGroup || item.group === clipGroup) &&
      [item.title, item.text, item.group, ...(item.tags || [])].join(" ").toLocaleLowerCase().includes(q));
    search.count.textContent = visible.length + " 条";
    output.replaceChildren();
    if (!visible.length) {
      output.append(empty("clip", state.clipboardEnabled ? "等待新的复制内容" : "历史记录尚未启用", "也可以直接使用下方常用短语。"));
      return;
    }
    for (const item of visible) output.append(clipboardRow(item));
  };
  redraw();
  const workspace = panel("", box("between", enabledRow, button("刷新", () => refreshClipboard(true), { glyph: "history" })),
    search.element, note("历史保存在本机。可在设置中设置期限和排除应用。"),
    state.clipboardNotice && el("p", state.clipboardNotice, "error"),
    box("between", el("small", rows.length + " 条 · 保留 " + (state.settings?.clipboardDays || 7) + " 天"),
      button("清除未固定历史…", () => confirmAction("清除未固定的历史？", "这是永久操作，已固定的条目会保留。", async () => {
        await api("/api/clipboard/clear", {});
        say("未固定的历史已清除");
        render();
      }, "清除"), {disabled: !rows.some(item => !item.pinned)})),
    box("row", boxLabel("option", el("span", "分组"), groupFilter),
      button("查看堆栈", async () => {
        const result = await api("/api/paste/stack/current", {});
        const parts = result.parts || [];
        showModal("粘贴堆栈", box("stack",
          parts.length ? box("list", ...parts.map(item => box("list-row", icon("clip"), el("span", item.text || item.path || item.kind, "wrap-text")))) : note("堆栈为空。"),
          parts.length && box("row", button("清空堆栈…", () => confirmAction("清空粘贴堆栈？", "当前堆栈中的待粘贴项将被移除。", async () => {
            await api("/api/paste/stack/clear", {});
            say("已清空粘贴堆栈");
          }, "清空")))));
      }), button("粘贴堆栈", () => choosePasteTarget(id => api("/api/paste/stack/paste", {targetID: id})))),
    state.paste && box("panel compact", el("strong", "粘贴等待核对"),
      note("请在目标窗口确认内容已插入，再结束本次事务。"),
      box("row", button("确认已插入", () => finishPaste("/api/paste/confirm"), {cls: "primary"}), button("取消并恢复", () => finishPaste("/api/paste/cancel")))),
    output);
  return box("stack", workspace, snippetPanel());
}
let clipboardRevision = "";
async function refreshClipboard(force = false) {
  if (pending || dialog?.open || statePollInFlight) return;
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
    if (force || key !== clipboardRevision && (clipboardRevision || JSON.stringify(result.clipboard) !== JSON.stringify(state.clipboard))) {
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
  return box("list-row", icon(item.kind === "image" ? "image" : "file"), box("fill", el("strong", title, "row-title"), el("small", details)),
    box("row", pin, button("复制", () => operate("copy")), item.kind === "text" && button("纯文本", () => operate("plain")),
      button("粘贴", () => choosePasteTarget(id => operate("paste", {targetID: id}))),
      button("更多…", () => showModal("剪贴板条目", box("row", button("分组与标签…", metadata), button("加入粘贴堆栈", () => operate("stack"))))),
      button("", () => confirmAction("删除此条历史？", title, () => operate("delete"), "删除"), { glyph: "trash", cls: "plain danger", label: "删除" })));
}
function snippetPanel() {
  const name = input("", {placeholder: "名称"});
  const value = input("", {placeholder: "文本内容", cls: "fill"});
  const records = state.snippets || [];
  const save = async (item = {}) => {
    if (!name.value.trim() || !value.value) throw new Error("请填写名称和文本内容。");
    await api("/api/snippets/save", { ...item, name: name.value.trim(), text: value.value });
    say("短语已保存");
    render();
  };
  const saveButton = button("保存", () => save());
  const snippets = box("row", ...records.map(item => button(item.name, () => snippetDialog(item))));
  return panel("", box("between", el("h3", "常用短语"), button("导出 CSV…", async () => {
    const response = await fetch("/api/export/snippets.csv", {headers: {"X-Gao-Token": token}});
    if (!response.ok) throw new Error("无法导出短语。");
    downloadBlob(await response.blob(), "搞操作短语.csv");
  }, {disabled: !records.length})), box("row", name, value, saveButton), records.length ? snippets : note("暂无常用短语。"));
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
    const result = await api("/api/rules/list", {});
    rules = result.rules || [];
    if (section === "input" && !dialog?.open) render();
  } catch (error) { report(error); }
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
    return box("list-row", toggle("启用", rule.enabled, value => saveRules(rules.map(item => item.id === rule.id ? {...item, enabled: value} : item))),
      box("fill", el("strong", currentAction(rule.actionID)?.title || rule.actionID, "row-title"),
        el("small", [rule.shortcut || rule.trigger || "未指定快捷键", rule.application || (rule.include || []).join("、") || "所有应用", labels[status?.status] || status?.status].filter(Boolean).join(" · ")),
        status?.detail && el("small", status.detail)),
      button("编辑", () => ruleDialog(rule)), button("", () => confirmAction("移除输入规则？", rule.shortcut || rule.actionID,
        () => saveRules(rules.filter(item => item.id !== rule.id)), "移除"), {glyph: "trash", cls: "plain danger", label: "移除规则"}));
  });
  return box("stack", panel("", box("between", box("stack", el("h2", "快捷键与手势"), note("按应用设置的规则可限定到指定的 Windows 程序。")),
    button("添加规则", () => ruleDialog(), {glyph: "plus", disabled: state.status !== "ready"})),
    box("between", box("row", icon(runtime.running ? "check" : "keyboard"), el("strong", !state.settings?.windowsAutomationEnabled ? "全局输入规则尚未启用" : runtime.paused ? "输入监听已暂停" : runtime.running ? "输入监听正在运行" : "输入监听尚未运行")),
      toggle("启用 Windows 全局输入规则", state.settings?.windowsAutomationEnabled, async enabled => {
        await api("/api/settings", {windowsAutomationEnabled: enabled});
        say(enabled ? "全局输入规则已启用" : "全局输入规则已关闭");
        render();
      }),
      button(runtime.paused ? "继续监听" : "暂停监听", async () => {
        await api("/api/settings", {inputPaused: !runtime.paused});
        render();
      }, {disabled: !state.settings?.windowsAutomationEnabled || (!runtime.running && !runtime.paused)})),
    runtime.lastAction?.detail && note(runtime.lastAction.detail),
    rules.length ? box("list", ...rows) : empty("keyboard", "还没有输入规则", "添加快捷键来运行常用操作。")),
    panel("系统与权限", note(state.permissions?.inputMonitoring?.detail || ""), button("打开设置", settingsDialog, {glyph: "settings"})));
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
  const record = button("录制快捷键", () => {
    shortcut.focus();
    const listen = event => {
      if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); shortcut.removeEventListener("keydown", listen); return; }
      if (["Control", "Alt", "Shift", "Meta"].includes(event.key)) return;
      event.preventDefault();
      event.stopPropagation();
      if (!event.ctrlKey && !event.altKey && !event.metaKey) return;
      const key = names[event.key] || (event.key.length === 1 ? event.key.toUpperCase() : event.key);
      shortcut.value = [event.ctrlKey && "Ctrl", event.altKey && "Alt", event.shiftKey && "Shift", event.metaKey && "Win", key].filter(Boolean).join("+");
      shortcut.removeEventListener("keydown", listen);
    };
    shortcut.addEventListener("keydown", listen);
  }, {glyph: "keyboard"});
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
  const hotkey = box("row", field("快捷键", shortcut), record);
  const update = () => {
    gesture.hidden = trigger.value !== "gesture";
    mouse.hidden = trigger.value !== "mouseButton";
    modifiers.hidden = trigger.value !== "mouseButton";
    hotkey.hidden = trigger.value !== "hotkey";
    shortcut.required = trigger.value === "hotkey";
  };
  trigger.onchange = update;
  update();
  formDialog("编辑输入规则", [field("执行动作", action), field("触发方式", trigger), hotkey, gesture, mouse, modifiers, field("限定应用（可选）", application), enabled], () => {
    const next = {
      ...original, id: original.id || crypto.randomUUID(), actionID: action.value, shortcut: trigger.value === "hotkey" ? shortcut.value.trim() : "",
      trigger: trigger.value, direction: direction.value, application: application.value.trim(), enabled: enabled.firstChild.checked,
      ...(trigger.value === "mouseButton" ? {mouseButton: Number(mouseButton.value), mouseModifiers: modifierControl.value.trim()} :
        trigger.value === "gesture" ? {mouseModifiers: "Alt"} : {}),
    };
    return saveRules(original.id ? rules.map(item => item.id === original.id ? next : item) : [...rules, next]);
  }, "保存");
}
const actionTitle = id => currentAction(id)?.title || ({delay: "等待", "open.path": "打开路径", "open.url": "打开网址"}[id] || id);
function workflowPage() {
  const workflows = state.workflows || [];
  const list = workflows.map(workflow => box("list-row", icon("layers"),
    box("fill", el("strong", workflow.name, "row-title"), el("small", (workflow.steps || []).map(step => actionTitle(step.actionID)).join(" → "))),
    button("运行", () => runWorkflow(workflow), {glyph: "play"}), button("编辑", () => workflowDialog(workflow)),
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
async function initialize() {
  [state] = await Promise.all([api("/api/state"), refreshCatalog()]);
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
document.addEventListener("DOMContentLoaded", () => initialize().catch(error => {
  app.append(el("p", error.message, "error"));
}));
