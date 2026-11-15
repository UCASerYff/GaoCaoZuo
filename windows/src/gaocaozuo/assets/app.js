const token = document.querySelector('meta[name="gao-token"]').content;
const version = document.querySelector('meta[name="gao-version"]').content;
const app = document.querySelector("#app");
let state = null;
let group = "daily";

async function api(path, body) {
  const response = await fetch(path, {
    method: body === undefined ? "GET" : "POST",
    headers: { "X-Gao-Token": token, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await response.json();
  if (!response.ok || data.ok === false) {
    throw new Error(data.error || "操作没有完成。");
  }
  if (data.state) state = data.state;
  return data.result === undefined ? data : data.result;
}

function el(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}

function pathsFrom(area) {
  return area.value.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
}

async function refresh() {
  state = await api("/api/state");
  render();
}

function render() {
  app.replaceChildren();
  const header = el("header");
  const titles = el("div");
  titles.append(el("h1", "搞操作"), el("div", "Windows " + version, "version"));
  header.append(titles);
  const search = document.createElement("input");
  search.placeholder = "搜索操作";
  search.addEventListener("change", () => showSearch(search.value));
  header.append(search);
  app.append(header);
  const main = el("main");
  if (state.status !== "ready") {
    const panel = el("section", "", "panel");
    panel.append(el("h2", "资料"), el("p", state.notice || "可以创建一份新的本机设置。"));
    const button = el("button", "创建设置", "primary");
    button.onclick = async () => {
      try { await api("/api/settings/create", {}); render(); }
      catch (error) { showError(panel, error); }
    };
    panel.append(button);
    main.append(panel);
  }
  const groups = el("div", "", "groups");
  for (const item of state.groups) {
    const button = el("button", item.title, item.id === group ? "active" : "");
    button.onclick = () => { group = item.id; render(); };
    groups.append(button);
  }
  main.append(groups);
  const message = el("section", "", "panel");
  message.append(el("div", state.message || "打开首页不会读取剪贴板，也不会捕获屏幕。", "notice"));
  main.append(message);
  if (group === "daily") main.append(daily());
  if (group === "desktop") main.append(desktop());
  if (group === "automation") main.append(automation());
  if (group === "activity") main.append(activity());
  app.append(main);
}

function showError(panel, error) {
  panel.append(el("p", error.message, "error"));
}

function filePanel() {
  const panel = el("section", "", "panel");
  panel.append(el("h2", "文件"));
  const area = document.createElement("textarea");
  area.placeholder = "每行一个文件或目录路径";
  const directory = document.createElement("input");
  directory.placeholder = "目标目录";
  const row = el("div", "", "row");
  for (const [id, title] of [["new.text", "新建文本"], ["new.markdown", "新建 Markdown"], ["new.folder", "新建文件夹"], ["file.new.docx", "新建 Word"], ["file.new.xlsx", "新建 Excel"], ["file.new.pptx", "新建演示"]]) {
    const button = el("button", title);
    button.onclick = () => run(panel, id, { directory: directory.value });
    row.append(button);
  }
  const copy = el("button", "复制路径");
  copy.onclick = () => run(panel, "path.copy", { paths: pathsFrom(area) });
  const names = el("button", "复制名称");
  names.onclick = () => run(panel, "name.copy", { paths: pathsFrom(area) });
  const hash = el("button", "SHA-256");
  hash.onclick = () => run(panel, "hash.sha256", { paths: pathsFrom(area) });
  const move = el("button", "移动到目录");
  move.onclick = () => run(panel, "files.move", { paths: pathsFrom(area), destination: directory.value });
  const duplicate = el("button", "复制到目录");
  duplicate.onclick = () => run(panel, "files.copy", { paths: pathsFrom(area), destination: directory.value });
  panel.append(directory, area, row, el("div", "", "row"));
  panel.lastChild.append(copy, names, hash, duplicate, move);
  const pattern = document.createElement("input");
  pattern.value = "{name}-{n:02}.{ext}";
  const preview = el("button", "预览重命名");
  preview.onclick = () => run(panel, "files.rename", { paths: pathsFrom(area), pattern: pattern.value, start: 1 });
  panel.append(pattern, preview);
  return panel;
}

function archivePanel() {
  const panel = el("section", "", "panel");
  panel.append(el("h2", "压缩"));
  const area = document.createElement("textarea");
  area.placeholder = "要压缩或解压的路径";
  const password = document.createElement("input");
  password.placeholder = "只有需要时才填写密码";
  password.type = "password";
  const row = el("div", "", "row");
  const zip = el("button", "压缩为 ZIP", "primary");
  zip.onclick = () => run(panel, "archive.create", { paths: pathsFrom(area) });
  const custom = el("button", "加密 ZIP");
  custom.onclick = () => run(panel, "archive.custom", { paths: pathsFrom(area), password: password.value, format: "zip" });
  const seven = el("button", "压缩为 7Z");
  seven.onclick = () => run(panel, "archive.7z", { paths: pathsFrom(area), password: password.value || undefined });
  const extract = el("button", "直接解压");
  extract.onclick = () => run(panel, "archive.extract", { paths: pathsFrom(area), password: password.value || undefined });
  const list = el("button", "预览");
  list.onclick = () => run(panel, "archive.list", { path: pathsFrom(area)[0], password: password.value || undefined });
  row.append(zip, custom, seven, extract, list);
  panel.append(area, password, row, el("p", state.sevenZip ? "已找到 7-Zip。" : "没有找到 7-Zip 时，7Z 会明确失败，ZIP 仍可使用。", "muted"));
  return panel;
}

function clipPanel() {
  const panel = el("section", "", "panel");
  panel.append(el("h2", "剪贴板与短语"));
  const enabled = el("button", state.clipboardEnabled ? "关闭历史" : "启用历史");
  enabled.onclick = async () => {
    try { await api("/api/settings", { clipboardEnabled: !state.clipboardEnabled }); render(); }
    catch (error) { showError(panel, error); }
  };
  const text = document.createElement("textarea");
  text.placeholder = "要记入历史或生成二维码的文字";
  const remember = el("button", "记入历史");
  remember.onclick = async () => {
    try {
      const result = await api("/api/clipboard/remember", { text: text.value, sourceApp: "gaocaozuo.manual" });
      panel.append(el("p", result.stored ? "已记入。" : "历史未启用，没有读取或写入历史。", "result"));
      await refresh();
    } catch (error) { showError(panel, error); }
  };
  const plain = el("button", "作为纯文本待核对");
  plain.onclick = () => run(panel, "clipboard.pasteplain", { text: text.value, sendEnter: false, targetMatches: true });
  const confirm = el("button", "确认已插入");
  confirm.onclick = async () => { try { panel.append(el("pre", JSON.stringify(await api("/api/paste/confirm", {}), null, 2), "result")); await refresh(); } catch (error) { showError(panel, error); } };
  const cancel = el("button", "取消并恢复");
  cancel.onclick = async () => { try { panel.append(el("pre", JSON.stringify(await api("/api/paste/cancel", {}), null, 2), "result")); } catch (error) { showError(panel, error); } };
  const qr = el("button", "生成二维码");
  qr.onclick = () => run(panel, "text.qrcode", { text: text.value });
  panel.append(enabled, text, el("div", "", "row"));
  panel.lastChild.append(remember, plain, confirm, cancel, qr);
  if (state.paste) panel.append(el("p", "粘贴阶段：" + state.paste.phase + "。事件提交不是内容已经插入。", "notice"));
  return panel;
}

function daily() {
  const wrap = el("div");
  wrap.append(filePanel(), archivePanel(), clipPanel());
  const shot = el("section", "", "panel");
  shot.append(el("h2", "截图"));
  const capture = el("button", "确认后捕获", "primary");
  capture.onclick = () => run(shot, "screenshot.capture", { confirm: true });
  const ocr = el("button", "OCR");
  ocr.onclick = () => run(shot, "screenshot.ocr.capture", {});
  const record = el("button", "录屏");
  record.onclick = () => run(shot, "screenshot.recording", {});
  shot.append(el("div", "", "row"));
  shot.lastChild.append(capture, ocr, record);
  shot.append(el("p", "不确认就不会采集。OCR、翻译和录屏会说明不可用，不会返回空成功。", "muted"));
  wrap.append(shot);
  return wrap;
}

function desktop() {
  const panel = el("section", "", "panel");
  panel.append(el("h2", "窗口布局"));
  const row = el("div", "", "row");
  for (const [id, title] of [["window.leftHalf", "左半屏"], ["window.rightHalf", "右半屏"], ["window.maximize", "铺满"], ["window.center", "居中"], ["windows.overview", "窗口列表"]]) {
    const button = el("button", title);
    button.onclick = () => run(panel, id, { apply: false });
    row.append(button);
  }
  panel.append(row, el("p", "这里只计算布局。没有可确认的窗口后端时，不会报告已经移动。", "muted"));
  const system = el("section", "", "panel");
  system.append(el("h2", "系统"));
  const lock = el("button", "提交锁屏");
  lock.onclick = () => run(system, "system.lock", {});
  const sleep = el("button", "提交睡眠");
  sleep.onclick = () => run(system, "system.sleep", {});
  const saver = el("button", "提交屏保");
  saver.onclick = () => run(system, "system.screenSaver", {});
  const awake = el("button", state.awake ? "取消保持唤醒" : "保持唤醒");
  awake.onclick = () => run(system, "system.preventSleep.toggle", {});
  system.append(el("div", "", "row"));
  system.lastChild.append(lock, sleep, saver, awake);
  system.append(el("p", "锁屏和睡眠只表示请求已提交。屏保不等于锁屏。", "muted"));
  const permissions = el("section", "", "panel");
  permissions.append(el("h2", "权限"));
  for (const [key, value] of Object.entries(state.permissions)) {
    permissions.append(el("p", key + "：" + value.detail));
  }
  const wrap = el("div");
  wrap.append(panel, system, permissions);
  return wrap;
}

function automation() {
  const panel = el("section", "", "panel");
  panel.append(el("h2", "组合操作"));
  for (const workflow of state.workflows || []) {
    const button = el("button", "运行 " + workflow.name);
    button.onclick = () => run(panel, "workflow.run." + workflow.id, { apply: false });
    panel.append(button);
  }
  panel.append(el("p", "任一步失败就停止，已经完成的步骤保留。", "muted"));
  const rules = el("section", "", "panel");
  rules.append(el("h2", "快捷键"));
  rules.append(el("p", "规则保存在本机 Input/rules.json。未注册全局钩子，冲突的快捷键不能保存。远端新规则或改变执行语义的规则必须复核后才会启用。", "muted"));
  const wrap = el("div");
  wrap.append(panel, rules);
  return wrap;
}

function activity() {
  const panel = el("section", "", "panel");
  panel.append(el("h2", "恢复记录"));
  const records = state.receipts || [];
  if (!records.length) panel.append(el("p", "还没有恢复记录。", "muted"));
  for (const record of records.slice(-12).reverse()) {
    panel.append(el("p", (record.kind || "") + " " + (record.destination || ""), "result"));
  }
  if (state.preservedKeys && state.preservedKeys.length) {
    panel.append(el("p", "设置中还有这些未改写的字段：" + state.preservedKeys.join("、"), "muted"));
  }
  return panel;
}

async function run(panel, id, payload) {
  try {
    const result = await api("/api/action", { id, payload });
    state.message = JSON.stringify(result, null, 2);
    render();
  } catch (error) {
    showError(panel, error);
  }
}

async function showSearch(query) {
  const result = await api("/api/search?q=" + encodeURIComponent(query));
  const panel = el("section", "", "panel");
  panel.append(el("h2", "搜索"));
  for (const action of result.actions.slice(0, 30)) {
    const button = el("button", action.title);
    button.onclick = () => run(panel, action.id, {});
    panel.append(button, el("span", " " + (action.unavailableReason || action.detail), "muted"));
    panel.append(el("br"));
  }
  app.querySelector("main").prepend(panel);
}

refresh().catch((error) => {
  app.append(el("p", error.message, "error"));
});
