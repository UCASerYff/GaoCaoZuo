"use strict";

const iconDress = {
  items: null, roles: [], selected: new Set(), assignments: new Map(), added: [],
  search: "", source: "all", activeRole: "", loading: false, failed: false,
  skipped: 0, limited: false, preview: null, result: [], variant: "hd",
};
const iconPlaces = {desktop: "桌面", start: "开始菜单", added: "手动加入"};
const iconRequest = (action, data = {}) => api(`/api/shortcut-icons/${action}`, data);
const mascotPreview = role => iconDress.variant === "local" ? role.localPreview || role.hdPreview : role.hdPreview || role.localPreview;

async function refreshIconDress() {
  if (iconDress.loading) return;
  iconDress.loading = true;
  iconDress.failed = false;
  try {
    const result = await iconRequest("list", {added: iconDress.added});
    Object.assign(iconDress, {
      items: result.items, roles: result.roles, skipped: result.skipped, limited: result.limited,
    });
    const present = new Set(result.items.map(item => item.path));
    iconDress.selected = new Set([...iconDress.selected].filter(path => present.has(path)));
    if (iconDress.preview && !present.has(iconDress.preview.path)) iconDress.preview = null;
  } catch (error) {
    iconDress.failed = true;
    throw error;
  } finally {
    iconDress.loading = false;
    if (section === "shortcutIcons" && !dialog?.open) render();
  }
}

function iconDressPage() {
  if (iconDress.items === null && !iconDress.loading && !iconDress.failed) {
    queueMicrotask(() => refreshIconDress().catch(report));
  }
  const writable = state.status === "ready";
  const imports = box("row icon-imports",
    button("从原版程序导入…", () => importIconOriginals("original-pack"), {glyph: "inbox", disabled: !writable}),
    button("从 ICO 目录导入…", () => importIconOriginals("folder"), {cls: "plain", glyph: "folder", disabled: !writable}));
  const gallery = box("icon-grid", ...iconDress.roles.map(role => {
    const chosen = iconDress.activeRole === role.id;
    const preview = mascotPreview(role);
    const card = button("", () => assignMascot(role.id), {label: role.label, cls: "mascot-card", disabled: !preview});
    card.setAttribute("aria-pressed", String(chosen));
    card.append(iconThumbnail(preview, "mascot-image"), el("strong", role.label, "", true));
    return box("mascot-entry", card,
      button("导入 ICO…", () => importSingleMascot(role.id), {cls: "plain mascot-import", disabled: !writable}));
  }));
  const artwork = select([["hd", "优先使用高清图标"], ["local", "优先使用本地图标"]], iconDress.variant);
  artwork.setAttribute("aria-label", tr("角色图标版本"));
  artwork.addEventListener("change", () => { iconDress.variant = artwork.value; render(); });
  const galleryPanel = panel("", box("between", el("h2", "角色图标"), box("row icon-imports", artwork, imports)),
    note("选择角色后可套用到已选快捷方式。原版五款可从本机的 AI Mascot Icons v1.0.0 导入。"), gallery);

  const search = input(iconDress.search, {placeholder: "搜索快捷方式"});
  search.setAttribute("aria-label", tr("搜索快捷方式"));
  const source = select([["all", "全部位置"], ["desktop", "桌面"], ["start", "开始菜单"], ["added", "手动加入"]], iconDress.source);
  source.setAttribute("aria-label", tr("快捷方式位置"));
  const rows = box("icon-shortcuts stack");
  const actions = box("row icon-actions");
  const previewArea = box("icon-preview-container");
  function redraw() {
    const items = visibleShortcuts();
    rows.replaceChildren(...(items.length ? items.map(item => shortcutRow(item, redraw)) : [empty("image",
      iconDress.loading || (!iconDress.items && !iconDress.failed) ? "正在读取快捷方式…" : "没有匹配的快捷方式",
      iconDress.failed ? "检查后点击刷新列表重试。" : "可以从本机文件夹手动加入 .lnk 快捷方式。") ]));
    const owned = selectedShortcuts().some(item => item.managed);
    const hasAssignment = selectedShortcuts().some(item => iconDress.assignments.has(item.path));
    actions.replaceChildren(
      button("选择本页", () => {
        for (const item of items.slice(0, 100)) selectShortcut(item, true);
        redraw();
      }, {cls: "plain", disabled: !items.length}),
      button("清除选择", () => { iconDress.selected.clear(); redraw(); }, {cls: "plain", disabled: !iconDress.selected.size}),
      button("匹配常见 AI", () => matchMascots(redraw), {glyph: "sparkle", disabled: !items.length}),
      button("批量换装…", () => reviewShortcutChanges(false), {cls: "primary", disabled: !writable || !hasAssignment}),
      button("恢复原图标…", () => reviewShortcutChanges(true), {glyph: "history", disabled: !writable || !owned}));
    previewArea.replaceChildren(...(iconDress.preview ? [iconOriginalPreview()] : []));
  }
  search.addEventListener("input", () => { iconDress.search = search.value; redraw(); });
  source.addEventListener("change", () => { iconDress.source = source.value; redraw(); });
  redraw();

  const discovery = box("row", button("刷新列表", refreshIconDress, {disabled: iconDress.loading}),
    button("加入快捷方式…", addManualShortcuts, {glyph: "plus"}),
    button("输入路径…", enterShortcutPaths, {cls: "plain"}));
  const warnings = [];
  if (iconDress.skipped) warnings.push(note("已略过无法读取或不受支持的快捷方式。"));
  if (iconDress.limited) warnings.push(note("扫描结果已达上限，可手动加入所需的快捷方式。"));
  return box("stack icon-dress",
    galleryPanel,
    panel("", box("between", el("h2", "快捷方式"), discovery),
      box("row icon-filters", search, source), ...warnings, actions, rows,
      note("更换当前用户 .lnk 文件的图标。任务栏运行中图标由应用控制。")),
    previewArea, iconBatchResult());
}

function iconThumbnail(url, css) {
  if (!url) return box(css, icon("image"));
  const image = el("img", "", css);
  image.src = url;
  image.alt = "";
  return image;
}

function visibleShortcuts() {
  const search = iconDress.search.trim().toLocaleLowerCase();
  return (iconDress.items || []).filter(item =>
    (iconDress.source === "all" || item.source === iconDress.source) &&
    (!search || item.name.toLocaleLowerCase().includes(search) || item.path.toLocaleLowerCase().includes(search)));
}

function selectedShortcuts() { return (iconDress.items || []).filter(item => iconDress.selected.has(item.path)); }

function selectShortcut(item, enabled) {
  if (enabled && iconDress.selected.size < 100) {
    iconDress.selected.add(item.path);
    if (iconDress.activeRole && !iconDress.assignments.has(item.path)) {
      iconDress.assignments.set(item.path, iconDress.activeRole);
    }
  } else if (!enabled) iconDress.selected.delete(item.path);
}

function assignMascot(role) {
  iconDress.activeRole = role;
  for (const path of iconDress.selected) iconDress.assignments.set(path, role);
  render();
}

function matchMascots(redraw) {
  const enabled = new Set(iconDress.roles.filter(mascotPreview).map(role => role.id));
  const targets = iconDress.selected.size ? selectedShortcuts() : visibleShortcuts().filter(item => enabled.has(item.suggested)).slice(0, 100);
  for (const item of targets) {
    if (!enabled.has(item.suggested)) continue;
    selectShortcut(item, true);
    iconDress.assignments.set(item.path, item.suggested);
  }
  redraw();
}

function shortcutRow(item, redraw) {
  const check = el("input");
  check.type = "checkbox";
  check.checked = iconDress.selected.has(item.path);
  check.setAttribute("aria-label", item.name);
  check.addEventListener("change", () => {
    selectShortcut(item, check.checked);
    redraw();
    const current = [...document.querySelectorAll(".icon-shortcut input")].find(input => input.dataset.path === item.path);
    current?.focus({preventScroll: true});
  });
  check.dataset.path = item.path;
  const roles = [["", "选择角色"], ...iconDress.roles.filter(mascotPreview).map(role => [role.id, role.label])];
  const chosen = select(roles, iconDress.assignments.get(item.path) || "");
  chosen.setAttribute("aria-label", tr("选择角色") + " " + item.name);
  chosen.addEventListener("change", () => {
    if (chosen.value) {
      iconDress.assignments.set(item.path, chosen.value);
      selectShortcut(item, true);
    } else iconDress.assignments.delete(item.path);
    redraw();
    const current = [...document.querySelectorAll(".icon-shortcut select")].find(input => input.dataset.path === item.path);
    current?.focus({preventScroll: true});
  });
  chosen.dataset.path = item.path;
  const status = item.managed ? "已换装" : item.changed ? "发现外部修改" : iconPlaces[item.source];
  const identity = box("icon-row-name", el("strong", item.name, "", true), el("small", status, "muted"));
  identity.title = item.path;
  const preview = button("查看原图标", async () => {
    const result = await iconRequest("preview", {path: item.path});
    iconDress.preview = {path: item.path, name: item.name, image: result.preview};
    redraw();
    document.querySelector(".icon-preview")?.scrollIntoView({block: "nearest"});
  }, {cls: "plain icon-original-button"});
  return box("icon-shortcut", check, identity, chosen, preview);
}

function iconOriginalPreview() {
  const view = iconDress.preview;
  return panel("", box("between icon-preview", box("row", iconThumbnail(view.image, "original-icon"),
    box("stack", el("h3", view.name, "", true), note(view.image ? "原始图标" : "无法预览此快捷方式的原始图标。"))),
    button("关闭", () => { iconDress.preview = null; render(); }, {cls: "plain"})));
}

async function addManualShortcuts() {
  const {paths} = await iconRequest("pick", {kind: "shortcuts"});
  if (!paths.length) return;
  await addShortcutPaths(paths);
}

function enterShortcutPaths() {
  const inputPaths = area("", "每行一个快捷方式路径");
  formDialog("加入快捷方式", [field("快捷方式路径", inputPaths)], async () => {
    const paths = splitLines(inputPaths.value);
    await addShortcutPaths(paths);
    if (dialog?.open) dialog.close();
    render();
  }, "添加");
}

async function addShortcutPaths(paths) {
  paths = paths.filter(path => path.toLowerCase().endsWith(".lnk"));
  if (!paths.length) throw new Error("请选择 .lnk 快捷方式。");
  const all = [...new Set([...iconDress.added, ...paths])];
  if (all.length > 100) throw new Error("最多可手动加入 100 个快捷方式。");
  iconDress.added = all;
  await refreshIconDress();
}

async function importSingleMascot(role) {
  const {paths} = await iconRequest("pick", {kind: "ico"});
  if (!paths.length) return;
  const result = await iconRequest("import", {role, path: paths[0]});
  iconDress.roles = result.roles;
  iconDress.variant = "local";
  render();
}

async function importIconOriginals(kind) {
  const {paths} = await iconRequest("pick", {kind});
  if (!paths.length) return;
  const result = await iconRequest("originals", {path: paths[0]});
  iconDress.roles = result.roles;
  iconDress.variant = "local";
  render();
}

function reviewShortcutChanges(restore) {
  const roles = new Map(iconDress.roles.map(role => [role.id, role.label]));
  const items = selectedShortcuts().filter(item => restore ? item.managed : roles.has(iconDress.assignments.get(item.path)));
  const variant = iconDress.variant;
  const title = restore ? "恢复原图标" : "应用角色图标";
  const entries = el("ul", "", "icon-review");
  for (const item of items) {
    const entry = el("li", "", "stack");
    entry.append(el("strong", restore ? item.name : `${item.name}  →  ${roles.get(iconDress.assignments.get(item.path))}`, "", true),
      el("small", item.path, "muted", true));
    entries.append(entry);
  }
  const current = formDialog(title, [entries], async () => {
    const result = await iconRequest(restore ? "restore" : "apply", {confirm: true,
      items: items.map(item => ({path: item.path, ...(!restore && {role: iconDress.assignments.get(item.path), variant})}))});
    iconDress.result = result.items;
    iconDress.preview = null;
    for (const item of result.items) if (item.ok) iconDress.selected.delete(item.path);
    current.close();
    await refreshIconDress();
  }, title, {size: "wide"});
}

function iconBatchResult() {
  if (!iconDress.result.length) return null;
  return panel("换装结果", box("stack", ...iconDress.result.map(item => box("row icon-result",
    icon(item.ok ? "check" : "warning"), el("strong", basename(item.path), "", true),
    el("small", item.ok ? "已完成" : trError(item.error), item.ok ? "muted" : "error", !item.ok)))));
}
