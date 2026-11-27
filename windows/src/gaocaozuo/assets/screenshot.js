"use strict";

const shotTabs = [
  ["capture", "截图"], ["annotation", "标注"], ["ocr", "OCR"], ["record", "录屏与录音"], ["translation", "翻译"], ["history", "历史与交接"],
];
let shotTab = "capture";
let shotImage = null;
let shotDocument = null;
let shotLong = null;
let shotLongOverlap = "";
let shotHistory = null;
let providerJobs = [];
let translationDraft = "";
let captureDelay = 0;
let annot = { commands: [], redo: [], rendered: null, tool: "rectangle", color: "#e34037", width: 3, text: "" };
let shotBusy = false;
let previewURL = "";

function changeShotTab(id, repaint = true) {
  shotTab = id;
  if (section !== "screenshots") go("screenshots");
  else if (repaint) render();
  if (id === "history" && !shotHistory) getShotHistory().catch(report);
  if (id === "ocr" && ocrLanguages === null) {
    screenshotRequest("ocr/languages", {}).then(result => {
      ocrLanguages = result.languages || [];
      if (!shotBusy && section === "screenshots" && shotTab === "ocr" && !dialog?.open) render();
    }).catch(() => { ocrLanguages = []; });
  }
}
function screenshotPage() {
  const nav = box("segmented");
  nav.setAttribute("role", "tablist");
  nav.setAttribute("aria-label", "截图工作台");
  const current = shotTabs.find(([id]) => id === shotTab);
  for (const [id, title] of shotTabs) {
    const control = button(title, () => changeShotTab(id));
    control.id = "shot-tab-" + id;
    control.setAttribute("role", "tab");
    control.setAttribute("aria-selected", String(id === shotTab));
    control.setAttribute("aria-controls", "shot-workspace");
    control.tabIndex = id === shotTab ? 0 : -1;
    control.addEventListener("keydown", event => {
      const index = shotTabs.findIndex(([value]) => value === id);
      const target = {ArrowLeft: (index + shotTabs.length - 1) % shotTabs.length, ArrowRight: (index + 1) % shotTabs.length,
        Home: 0, End: shotTabs.length - 1}[event.key];
      if (target === undefined) return;
      event.preventDefault();
      const next = shotTabs[target][0];
      changeShotTab(next);
      document.getElementById("shot-tab-" + next)?.focus();
    });
    nav.append(control);
  }
  const views = { capture: capturePage, annotation: annotationPage, ocr: ocrPage, record: recordingPage, translation: translationPage, history: screenshotHistoryPage };
  const body = views[shotTab]();
  body.id = "shot-workspace";
  body.setAttribute("role", "tabpanel");
  body.setAttribute("aria-labelledby", "shot-tab-" + current[0]);
  return box("stack", nav, body);
}
function screenshotAction(id) {
  const destination = {
    "screenshot.workspace": "capture", "screenshot.capture": "capture", "screenshot.long": "capture",
    "screenshot.annotate": "annotation", "screenshot.recording": "record", "screenshot.pins.restore": "history",
    "screenshot.ocr.capture": "ocr", "screenshot.ocr.clipboard": "ocr", "screenshot.ocr.files": "ocr",
    "screenshot.translate.clipboard": "translation", "screenshot.translate.capture": "translation",
  };
  changeShotTab(destination[id] || "capture");
  if (id === "screenshot.ocr.capture") captureImage("region", true).catch(report);
  if (id === "screenshot.ocr.clipboard") runOCR({clipboard: true}).catch(report);
  if (id === "screenshot.ocr.files") chooseOCRFiles().catch(report);
  if (id === "screenshot.translate.clipboard") inputTranslationClipboard().catch(report);
  if (id === "screenshot.translate.capture") inputTranslationCapture().catch(report);
}
function screenshotRequest(path, payload) { return api("/api/screenshot/" + path, payload); }
async function screenshotWork(message, handler) {
  if (shotBusy) throw new Error("请等待当前截图任务完成。");
  shotBusy = true;
  try { return await progress(message, handler); }
  finally {
    shotBusy = false;
    if (section === "screenshots" && !dialog?.open) render();
  }
}
function setImage(image) {
  shotImage = image;
  annot.commands = [];
  annot.redo = [];
  annot.rendered = null;
  shotHistory = null;
  shotTab = "annotation";
}
function capturePage() {
  const delay = input(captureDelay, { type: "range", min: 0, max: 60 });
  delay.setAttribute("aria-label", "延时（秒）");
  const delayLabel = el("span", captureDelay + " 秒");
  delay.oninput = () => { captureDelay = +delay.value; delayLabel.textContent = captureDelay + " 秒"; };
  const capture = [
    ["区域截图", "region", "scan"], ["窗口截图", "window", "window"], ["屏幕截图", "display", "monitor"],
  ];
  const captureActions = capture.map(([title, mode, glyph]) => button(title, () => captureImage(mode), { cls: "primary", glyph, disabled: shotBusy }));
  const longActions = shotLong?.active ? [
    button("自动滚动拼接", () => longCapture("auto"), {cls:"primary", disabled: shotBusy}),
    button("手动添加画面", () => longCapture("append"), {disabled: shotBusy}),
    button("生成长截图", () => longCapture("finish"), {disabled: shotBusy || shotLong.frames < 2}),
    button("取消", () => longCapture("cancel"), {disabled: shotBusy}),
  ] : [button("长截图", () => longCapture("start"), {disabled: shotBusy})];
  const manualOverlap = input(shotLongOverlap, {type:"number", min:0, step:1, placeholder:tr("自动检测")});
  manualOverlap.oninput = () => { shotLongOverlap = manualOverlap.value; };
  const info = "捕获前通过当前按钮选择要采集的区域、窗口或屏幕。受保护区域和安全桌面由 Windows 控制。";
  return box("shot-home", el("h2", "捕获所选内容"), note("截图后可以保存、复制或进入标注。"),
    box("row capture-actions", ...captureActions),
    box("row", button("多窗口合成", () => captureImage("windows"), {disabled: shotBusy}), ...longActions,
      button("取色", sampleColor, {disabled: shotBusy}), button("打开图像…", chooseImage, {disabled: shotBusy}), button("贴图与交接", () => changeShotTab("history"))),
    shotLong?.active && panel("长截图",
      note("开始自动滚动后，3 秒内切回原窗口，把鼠标停在选区内。移动鼠标或按 Esc 可停止。"),
      note("手动添加时，在 3 秒内切回并向下滚动，保留一段重叠内容。"),
      field("手动续拍重叠像素", manualOverlap),
      shotLong.automatic && note(shotLong.automatic.reason),
      note(mediaText("已添加 {count} 帧 · {width} × {height} 像素", {count:shotLong.frames, width:shotLong.width, height:shotLong.height}))),
    panel("捕获选项", box("row", el("span", "延时"), delay, delayLabel)), panel("权限与范围", note(info)));
}
async function sampleColor() {
  return screenshotWork("等待选择颜色…", async () => {
    const {hex, rgb, colorSpace} = await perform("screenshot.capture", {confirm: true, mode: "color", delay: captureDelay});
    if (!hex) throw new Error("没有取得颜色。");
    const sample = box("color-sample", el("span", hex));
    sample.style.borderColor = hex;
    showModal("取色", box("stack", sample, el("p", colorSpace + " · RGB " + rgb.join(", ")),
      button("复制 " + hex, async () => {
        await perform("clipboard.copyplain", {text: hex});
        say("已复制 " + hex);
      }, {glyph:"clip"})));
    say("已取得 " + hex);
  });
}
async function captureImage(mode, recognize = false) {
  return screenshotWork("等待选择捕获内容…", async () => {
    const result = await perform("screenshot.capture", {confirm: true, mode, delay: captureDelay});
    if (!result.id) throw new Error("未取得画面。");
    setImage(result);
    say("已捕获 " + result.width + " × " + result.height);
    if (recognize) {
      shotTab = "ocr";
      await runOCRInternal({id: result.id});
    }
  });
}
async function chooseImage() {
  const selectedImage = files.length === 1 && /\.(png|jpe?g|tiff?|webp|bmp|gif|heic|heif|gaowinannotation)$/i.test(files[0]) ? files[0] : null;
  const path = selectedImage || (await pick("files", false))[0];
  if (!path) return;
  return screenshotWork("正在打开图像…", async () => {
    const result = await screenshotRequest("open", {path});
    setImage(result);
    say("已打开 " + basename(path));
  });
}
async function longCapture(command) {
  const status = {start: "请选择长截图区域…", append: "3 秒内切回目标窗口并滚动…", auto: "3 秒内切回原窗口，把鼠标停在选区内…", finish: "正在拼接画面…", cancel: "正在取消…"};
  return screenshotWork(status[command], async () => {
    const overlap = command === "append" && shotLongOverlap !== "" ? Number(shotLongOverlap) : undefined;
    if (overlap !== undefined && (!Number.isInteger(overlap) || overlap < 0)) throw new Error("重叠像素须为非负整数。");
    const result = await screenshotRequest("long", {command, confirm: true, delay: ["append", "auto"].includes(command) ? 3 : 0, overlap});
    if (["start", "finish", "cancel"].includes(command)) shotLongOverlap = "";
    if (command === "finish" && result.id) {
      setImage(result);
      shotLong = null;
      say("长截图已生成");
    } else {
      shotLong = command === "cancel" ? null : result;
      const message = result.automatic ? mediaText("自动滚动新增 {count} 帧。", {count:result.automatic.added}) + " " + tr(result.automatic.reason) :
        mediaText("长截图已添加 {count} 帧", {count:result.frames});
      say(command === "cancel" ? "已取消长截图" : message);
    }
  });
}
function preview(id) {
  return fetch("/api/screenshot/preview?id=" + encodeURIComponent(id), {headers: {"X-Gao-Token": token}})
    .then(response => {
      if (!response.ok || !response.headers.get("Content-Type")?.startsWith("image/")) throw new Error("无法读取当前图像的预览。");
      return response.blob();
    });
}
function showPreview(result) {
  const img = el("img", "", "shot-preview");
  img.alt = "预览图片";
  let objectURL;
  const current = showModal("最终预览", img, {closed: () => { if (objectURL) URL.revokeObjectURL(objectURL); }});
  preview(result.id).then(blob => {
    if (!current.open) return;
    objectURL = URL.createObjectURL(blob);
    img.src = objectURL;
  }).catch(report);
}
function annotationPage() {
  if (!shotImage) return panel("", empty("image", "没有待标注图像", "截图或打开已有图片后，即可编辑。"), box("row",
    button("区域截图", () => captureImage("region"), {cls:"primary", glyph:"scan", disabled: shotBusy}), button("打开图像…", chooseImage, {disabled: shotBusy})));
  const tools = [["rectangle", "矩形"], ["ellipse", "椭圆"], ["arrow", "箭头"], ["line", "直线"], ["pen", "画笔"],
    ["text", "文字"], ["number", "编号"], ["mosaic", "马赛克"], ["blur", "模糊"], ["redact", "遮盖"], ["highlight", "高亮"], ["crop", "裁剪"]];
  const tool = select(tools, annot.tool);
  tool.setAttribute("aria-label", "标注工具");
  tool.onchange = () => { annot.tool = tool.value; };
  const color = input(annot.color, {type:"color"});
  color.setAttribute("aria-label", "标注颜色");
  color.oninput = () => { annot.color = color.value; };
  const width = input(annot.width, {type:"range", min:1, max:24});
  width.setAttribute("aria-label", "线宽");
  width.oninput = () => { annot.width = +width.value; };
  const content = input(annot.text, {placeholder: "文字 / 编号"});
  content.oninput = () => { annot.text = content.value; };
  const canvas = el("canvas");
  const context = canvas.getContext("2d");
  canvas.setAttribute("aria-label", "标注画布");
  canvas.tabIndex = 0;
  let image = null;
  let draft = null;
  const draw = () => {
    if (!image) return;
    context.clearRect(0, 0, canvas.width, canvas.height);
    context.drawImage(image, 0, 0);
    for (const command of annot.commands) drawAnnotation(context, command);
    if (draft) drawAnnotation(context, draft);
  };
  const undo = button("撤销", () => {
    if (annot.commands.length) annot.redo.push(annot.commands.pop());
    annot.rendered = null; update();
  }, {disabled: !annot.commands.length});
  const redo = button("重做", () => {
    if (annot.redo.length) annot.commands.push(annot.redo.pop());
    annot.rendered = null; update();
  }, {disabled: !annot.redo.length});
  const update = () => { undo.disabled = !annot.commands.length; redo.disabled = !annot.redo.length; draw(); };
  const point = event => {
    const b = canvas.getBoundingClientRect();
    return {
      x: Math.round(Math.max(0, Math.min(canvas.width - 1, (event.clientX - b.left) / b.width * canvas.width))),
      y: Math.round(Math.max(0, Math.min(canvas.height - 1, (event.clientY - b.top) / b.height * canvas.height))),
    };
  };
  canvas.addEventListener("pointerdown", event => {
    if (!image || event.button !== 0) return;
    const {x, y} = point(event);
    const number = annot.commands.filter(command => command.type === "number").length + 1;
    const typed = content.value || (tool.value === "number" ? String(number) : "");
    if (tool.value === "text" && !typed) { say("请在工具栏输入标注文字。", true); return; }
    draft = { type: tool.value, x, y, x1: x, y1: y, x2: x, y2: y, width: +width.value, color: color.value, text: typed, points: [{x, y}] };
    canvas.setPointerCapture(event.pointerId);
    draw();
  });
  canvas.addEventListener("pointermove", event => {
    if (!draft) return;
    const {x, y} = point(event);
    draft.x2 = x;
    draft.y2 = y;
    if (draft.type === "pen" && draft.points.length < 2999) draft.points.push({x, y});
    draw();
  });
  canvas.addEventListener("pointerup", event => {
    if (!draft) return;
    const {x, y} = point(event);
    draft.x2 = x;
    draft.y2 = y;
    if (draft.type === "pen") draft.points.push({x, y});
    if (draft.type === "crop") {
      const command = {type: "crop", x: draft.x1, y: draft.y1, x2: x, y2: y};
      draft = null;
      draw();
      if (Math.abs(command.x - x) < 2 || Math.abs(command.y - y) < 2) {
        say("请选择至少 2 × 2 像素的裁剪区域。", true);
      } else {
        confirmAction("裁剪图像？", "应用后，编辑画布将使用裁剪结果。", () => transformImage(command), "裁剪");
      }
      return;
    }
    if (annot.commands.length >= 500) { draft = null; say("一张图片最多包含 500 个标注。", true); return; }
    annot.commands.push(draft);
    draft = null;
    annot.redo.length = 0;
    annot.rendered = null;
    update();
  });
  canvas.addEventListener("pointercancel", () => { draft = null; draw(); });
  const initialID = shotImage.id;
  preview(initialID).then(blob => {
    if (!canvas.isConnected || shotImage?.id !== initialID) return;
    if (previewURL) URL.revokeObjectURL(previewURL);
    previewURL = URL.createObjectURL(blob);
    const source = new Image();
    source.onload = () => { image = source; canvas.width = source.naturalWidth; canvas.height = source.naturalHeight; draw(); };
    source.onerror = () => report(new Error("无法显示图像。"));
    source.src = previewURL;
  }).catch(report);
  const withOutput = handler => async () => {
    if (shotBusy) return;
    const result = await annotationResult();
    return handler(result);
  };
  const toolbar = box("row", tool, color, width, content, undo, redo, button("向右旋转", () => transformImage({type: "rotate", degrees: 90})),
    button("最终预览", withOutput(showPreview)));
  const exportImage = withOutput(result => saveImageDialog(result, false));
  const actions = box("row",
    button("复制", withOutput(async result => {
      await screenshotRequest("copy", {id: result.id});
      say("图像已复制");
    })), button("贴图", withOutput(async result => {
      const pinned = await screenshotRequest("pin", {id: result.id, persistent: false});
      say(pinned.message || "贴图已打开");
    })), button("OCR", withOutput(result => runOCR({id: result.id}))),
    button("另存图像…", exportImage, {cls:"primary"}), button("保存编辑稿…", withOutput(result => saveImageDialog(result, true))),
    button("保存为持久贴图", withOutput(async result => {
      const pinned = await screenshotRequest("pin", {id: result.id, persistent: true});
      shotHistory = null;
      say(pinned.message || "持久贴图已保存");
    })));
  return panel("", toolbar, box("canvas-wrap", canvas), actions, el("small", shotImage.width + " × " + shotImage.height + " 像素"));
}
function drawAnnotation(ctx, command) {
  const {type, x1, y1, x2, y2, color, width, text, points} = command;
  ctx.strokeStyle = color;
  ctx.fillStyle = color;
  ctx.lineWidth = width;
  ctx.lineJoin = "round";
  ctx.lineCap = "round";
  ctx.beginPath();
  if (type === "rectangle") { ctx.strokeRect(x1, y1, x2 - x1, y2 - y1); return; }
  if (type === "ellipse") {
    ctx.ellipse((x1 + x2) / 2, (y1 + y2) / 2, Math.abs(x1 - x2) / 2, Math.abs(y1 - y2) / 2, 0, 0, 2 * Math.PI);
    ctx.stroke(); return;
  }
  if (type === "highlight" || type === "redact") {
    ctx.globalAlpha = type === "highlight" ? 0.35 : 1;
    ctx.fillRect(x1, y1, x2 - x1, y2 - y1);
    ctx.globalAlpha = 1;
    return;
  }
  if (type === "mosaic" || type === "blur") {
    const x = Math.min(x1, x2), y = Math.min(y1, y2);
    const w = Math.min(Math.abs(x1 - x2), ctx.canvas.width - x), h = Math.min(Math.abs(y1 - y2), ctx.canvas.height - y);
    if (!w || !h) return;
    const miniature = el("canvas");
    miniature.width = type === "blur" ? w : Math.max(1, Math.floor(w / 14));
    miniature.height = type === "blur" ? h : Math.max(1, Math.floor(h / 14));
    const temp = miniature.getContext("2d");
    if (type === "blur") temp.filter = "blur(" + width + "px)";
    temp.drawImage(ctx.canvas, x, y, w, h, 0, 0, miniature.width, miniature.height);
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(miniature, x, y, w, h);
    ctx.imageSmoothingEnabled = true;
    return;
  }
  if (type === "crop") {
    ctx.setLineDash([6, 4]);
    ctx.strokeRect(x1, y1, x2 - x1, y2 - y1);
    ctx.setLineDash([]);
    return;
  }
  if (type === "text" || type === "number") {
    const size = Math.max(14, width * 5);
    ctx.font = "600 " + size + "px Segoe UI, Microsoft YaHei UI, sans-serif";
    ctx.textBaseline = "top";
    ctx.fillText(text, x1, y1);
    return;
  }
  if (type === "pen") {
    ctx.moveTo(points[0].x, points[0].y);
    for (const p of points.slice(1)) ctx.lineTo(p.x, p.y);
    ctx.stroke(); return;
  }
  ctx.moveTo(x1, y1);
  ctx.lineTo(x2, y2);
  if (type === "arrow") {
    const angle = Math.atan2(y2 - y1, x2 - x1);
    const size = Math.max(9, width * 4);
    for (const direction of [-1, 1]) {
      ctx.moveTo(x2, y2);
      ctx.lineTo(x2 - size * Math.cos(angle + direction * Math.PI / 6), y2 - size * Math.sin(angle + direction * Math.PI / 6));
    }
  }
  ctx.stroke();
}
async function transformImage(command) {
  const result = await annotationResult();
  const transformed = await screenshotRequest("annotate", {id: result.id, commands: [command]});
  setImage(transformed);
  if (command.type === "crop") annot.tool = "rectangle";
  say(command.type === "crop" ? "图像已裁剪" : "图像已旋转");
  render();
}
async function annotationResult() {
  if (!annot.commands.length) return shotImage;
  if (!annot.rendered) {
    const commands = annot.commands.map(command => ({
      type: command.type === "number" ? "text" : command.type,
      x: command.x1, y: command.y1, x2: command.x2, y2: command.y2,
      stroke: command.width, fontSize: Math.max(14, command.width * 5), color: command.color, text: command.text,
      points: command.points.map(({x, y}) => [x, y]),
    }));
    annot.rendered = await screenshotRequest("annotate", {id: shotImage.id, commands});
    shotHistory = null;
  }
  return annot.rendered;
}
function saveImageDialog(result, editable) {
  const directory = directoryField("输出目录");
  const name = input("", {placeholder: editable ? "文件名" : "留空使用默认名称"});
  name.required = editable;
  const format = select([["png", "PNG"], ["jpg", "JPEG"], ["tiff", "TIFF"], ["webp", "WebP"]], "png");
  formDialog(editable ? "保存编辑稿" : "另存图像", [directory.wrapper, field("文件名", name), !editable && field("格式", format)].filter(Boolean), async () => {
    const extension = editable ? "gaowinannotation" : format.value;
    const base = name.value.trim();
    const filename = base ? (base.toLowerCase().endsWith("." + extension) ? base : base + "." + extension) :
      format.value === "png" ? undefined : "截图-" + result.id.slice(0, 8) + "." + extension;
    const saved = await screenshotRequest("save", {id: result.id, directory: directory.control.value.trim(), filename});
    rememberOutputs(saved);
    say("已保存 " + basename(saved.path));
  }, "保存");
}

let ocrLanguage = "";
let ocrLanguages = null;
function ocrPage() {
  const language = select([["", "跟随 Windows 识别语言"], ...(ocrLanguages || [])], ocrLanguage);
  language.onchange = () => { ocrLanguage = language.value; };
  const status = shotDocument ? ocrResult(shotDocument) :
    empty("scan", "选择文件开始识别", "OCR 在本机运行。请核对复杂表格、手写内容和阅读顺序。");
  return panel("本机 OCR", box("row", field("识别语言", language),
    button("选择图像 / PDF 批次…", chooseOCRFiles, {cls:"primary", disabled: shotBusy}),
    button("主动读取剪贴板图片", () => runOCR({clipboard: true}), {disabled: shotBusy}),
    button("从当前图像识别", async () => runOCR({id: (await annotationResult()).id}), {disabled: !shotImage || shotBusy}),
    button("从区域截图识别", () => captureImage("region", true), {disabled: shotBusy})),
    status);
}
async function chooseOCRFiles() {
  const paths = files.length && files.every(path => /\.(png|jpe?g|tiff?|webp|bmp|gif|heic|heif|pdf)$/i.test(path)) ? files : await pick("files", true);
  if (paths.length) await runOCR({paths});
}
async function runOCR(payload) {
  shotTab = "ocr";
  return screenshotWork("正在本机识别，请稍候…", () => runOCRInternal(payload));
}
async function runOCRInternal(payload) {
  const languages = ocrLanguage.trim().split(/[,，\s]+/).filter(Boolean);
  shotDocument = null;
  shotDocument = payload.clipboard ? await perform("screenshot.ocr.clipboard", {languages, confirm: true}) :
    await screenshotRequest("ocr", { ...payload, languages, confirm: true });
  const pages = (shotDocument.sources || []).flatMap(source => source.pages || []);
  say("识别完成 " + pages.filter(page => !page.error).length + " / " + pages.length + " 页");
}
function ocrResult(documentResult) {
  const sources = documentResult.sources || [];
  const pages = sources.flatMap(source => source.pages || []);
  const successful = pages.filter(page => !page.error);
  const bodyText = documentResult.text ?? successful.map(page => page.text || "").filter(Boolean).join("\n\n");
  const preview = area(bodyText, "未识别出文字");
  preview.readOnly = true;
  preview.rows = 8;
  const failed = pages.filter(page => page.error).map(page => el("p", "第 " + (page.page || page.pageNumber) + " 页 · " + page.error, "error"));
  const formats = [["text", "纯文本"], ["markdown", "Markdown"], ["json", "结构化 JSON"], ["searchablePDF", "可搜索 PDF"]];
  const exports = formats.map(([format, title]) => button("导出" + title + "…", () =>
    chooseDestination("导出" + title, "输出目录", async directory => {
      const saved = await screenshotRequest("ocr/export", {id: documentResult.id, directory, format});
      const paths = rememberOutputs(saved);
      say(paths.length ? "已导出 " + paths.map(basename).join("、") : "导出完成");
    }), {disabled: !successful.length}));
  return box("stack", el("p", "成功 " + successful.length + " / " + pages.length + " 页"), ...failed, preview,
    box("row", button("复制文字", async () => { await perform("clipboard.copyplain", {text: bodyText}); say("已复制识别文字"); }, {disabled: !bodyText}),
      button("逐行校正…", () => correctOCR(documentResult), {disabled: !successful.some(page => page.lines?.length)}),
      ...exports, button("翻译结果", () => {setTranslationDraft(bodyText); changeShotTab("translation");}, {disabled: !bodyText || !!localTranslation.active})));
}
function correctOCR(result) {
  const content = box("stack dialog-result");
  const redraw = () => {
    const sources = result.sources || [];
    content.replaceChildren(...sources.flatMap((source, sourceIndex) =>
      (source.pages || []).filter(page => page.lines?.length).map(page => panel(source.name + " · 第 " + page.page + " 页",
        ...page.lines.map((row, lineIndex) => {
          const value = input(row.text || "", { cls: "fill", placeholder: "识别文字" });
          const originalText = el("small", row.originalText ? "原识别：" + row.originalText : "");
          return box("stack", box("row", value, button("应用", async () => {
            shotDocument = await screenshotRequest("ocr/edit", {id: result.id, sourceIndex, pageNumber: page.page, lineIndex, text: value.value});
            result = shotDocument;
            say("识别行已校正");
            originalText.textContent = "原识别：" + (row.originalText || row.text);
          })), originalText);
        })))));
  };
  redraw();
  showModal("校正识别文字", box("stack", note("逐行点击“应用”后，导出将使用校正后的文字。"), content),
    {closed: () => {
      if (section === "screenshots" && shotTab === "ocr" && !dialog?.open) render();
    }});
}
const localTranslation = {catalog: null, loading: false, source:"auto", target:"en", output:null, active:null, status:"", error:""};
function repaintTranslation() {
  if (section === "screenshots" && shotTab === "translation" && !dialog?.open) render();
}
function setTranslationDraft(text) {
  if (localTranslation.active) throw new Error("请先完成或取消本机翻译任务。");
  translationDraft = text;
  localTranslation.output = null;
  localTranslation.status = "";
  localTranslation.error = "";
}
async function loadTranslationCatalog() {
  if (localTranslation.loading) return;
  localTranslation.loading = true;
  try { localTranslation.catalog = await screenshotRequest("translate/catalog", {}); }
  catch (error) { localTranslation.catalog = {available:false, reason:error.message}; }
  finally { localTranslation.loading = false; repaintTranslation(); }
}
function translationLanguage(code) {
  const language = localTranslation.catalog?.languages?.find(item => item.code === code);
  if (language && typeof Intl.DisplayNames === "function") {
    try {
      const tag = {zt:"zh-Hant", zh:"zh-Hans"}[code] || code;
      return new Intl.DisplayNames([document.documentElement.lang || "zh-CN"], {type:"language"}).of(tag) || language.name;
    } catch { return language.name; }
  }
  return language?.name || code;
}
function translationPage() {
  if (!localTranslation.catalog && !localTranslation.loading) void loadTranslationCatalog();
  const capability = localTranslation.catalog;
  const active = !!localTranslation.active;
  const draft = area(translationDraft, "输入或粘贴要翻译的文字");
  draft.maxLength = 100000;
  draft.disabled = active;
  const result = localTranslation.output;
  const output = area(result?.text || "", "翻译结果");
  output.readOnly = true;
  const run = button("翻译", prepareTranslation, {cls:"primary", disabled: active || !capability?.available || !translationDraft.trim()});
  const clear = () => { output.value = ""; localTranslation.output = null; localTranslation.status = ""; localTranslation.error = ""; };
  const message = el("p", localTranslation.error || localTranslation.status, localTranslation.error ? "error" : "muted");
  const copy = button("复制译文", async () => {
    await perform("clipboard.copyplain", {text: localTranslation.output.text});
    say("已复制译文");
  }, {disabled: !result});
  draft.oninput = () => {
    translationDraft = draft.value;
    clear();
    message.textContent = "";
    copy.disabled = true;
    run.disabled = !capability?.available || !translationDraft.trim();
  };
  const languages = (capability?.languages || []).map(language => [language.code, translationLanguage(language.code)]);
  const source = select([["auto", "自动检测"], ...languages], localTranslation.source);
  const target = select(languages, localTranslation.target);
  source.disabled = target.disabled = active || !capability?.available;
  source.onchange = () => {localTranslation.source = source.value; clear(); repaintTranslation();};
  target.onchange = () => {localTranslation.target = target.value; clear(); repaintTranslation();};
  const notice = capability?.available
    ? "原文和译文只在本机处理。缺少语言包时，可查看大小并主动确认下载。"
    : capability?.reason || "正在检查本机翻译组件…";
  return panel("本机翻译", note(notice), box("columns", field("源语言", source), field("目标语言", target)), field("原文", draft),
    box("row", button("使用剪贴板文字", inputTranslationClipboard, {disabled: active}),
      button("截图识别文字", inputTranslationCapture, {disabled: active || shotBusy}), run,
      active && button("取消", cancelLocalTranslation)), message,
    result?.detected && note(tr("识别的原文语言") + " · " + translationLanguage(result.source)), field("译文", output), copy);
}
async function inputTranslationClipboard() {
  if (localTranslation.active) throw new Error("请先完成或取消本机翻译任务。");
  const result = await screenshotRequest("translate/input", {mode:"clipboard", confirm:true});
  if (!result.text) throw new Error("剪贴板没有可翻译的文字。");
  setTranslationDraft(result.text);
  changeShotTab("translation");
}
async function inputTranslationCapture() {
  if (localTranslation.active) throw new Error("请先完成或取消本机翻译任务。");
  return screenshotWork("等待截图与离线识别…", async () => {
    const capture = await perform("screenshot.capture", {confirm:true, mode:"region", delay:captureDelay});
    if (!capture.id) throw new Error("未取得画面。");
    shotDocument = await screenshotRequest("ocr", {id:capture.id, confirm:true});
    if (!shotDocument.text) throw new Error("截图没有可翻译的识别文字。");
    setTranslationDraft(shotDocument.text);
    shotTab = "translation";
  });
}
async function prepareTranslation() {
  if (localTranslation.active) return;
  const request = {text:translationDraft, source:localTranslation.source, target:localTranslation.target};
  const operation = {cancelled:false, id:null};
  localTranslation.active = operation;
  localTranslation.output = null;
  localTranslation.error = "";
  localTranslation.status = "正在检查语言组合…";
  repaintTranslation();
  try {
    const plan = await screenshotRequest("translate/plan", request);
    if (operation.cancelled) return;
    const damaged = plan.packs.find(pack => pack.status === "damaged");
    if (damaged) throw new Error("本机语言包文件不完整，请检查 TranslationModels 目录后重试。");
    const packs = plan.packs.filter(pack => pack.status !== "installed");
    if (!packs.length) return await runLocalTranslation(operation, request, []);
    localTranslation.active = null;
    localTranslation.status = "待下载语言包。";
    const packageNames = packs.map(pack => el("li", translationLanguage(pack.source) + " → " + translationLanguage(pack.target) +
      " · " + (pack.size / (1024 * 1024)).toFixed(1) + " MiB"));
    const packageList = el("ul", "", "result-list");
    packageList.append(...packageNames);
    showModal("下载本机翻译语言包", box("stack", note("将从 Argos Open Tech 下载固定版本的语言包。此次下载只请求语言包文件。"),
      packageList,
      plan.pivot && note("该组合通过英语中转。"),
      box("row", button("取消", () => dialog.close()), button("确认下载并翻译", () => {
        dialog.close();
        return runLocalTranslation(operation, request, packs);
      }, {cls:"primary"}))), {closed: repaintTranslation});
  } catch (error) {
    if (!operation.cancelled) localTranslation.error = error.message;
  } finally {
    if (localTranslation.active === operation) localTranslation.active = null;
    if (operation.cancelled) localTranslation.status = "已取消。";
    repaintTranslation();
  }
}
async function runLocalTranslation(operation, request, packs) {
  localTranslation.active = operation;
  try {
    for (const pack of packs) {
      if (operation.cancelled) return;
      localTranslation.status = "正在下载语言包…";
      repaintTranslation();
      const download = await screenshotRequest("translate/download", {packId:pack.id, confirm:true});
      await pollTranslationJob(operation, download);
    }
    if (operation.cancelled) return;
    localTranslation.status = "正在本机翻译…";
    repaintTranslation();
    const job = await screenshotRequest("translate", request);
    const result = await pollTranslationJob(operation, job);
    if (result && !operation.cancelled) {
      localTranslation.output = result;
      localTranslation.status = "本机翻译已完成。";
    }
  } catch (error) {
    if (!operation.cancelled) { localTranslation.error = error.message; localTranslation.status = ""; }
  } finally {
    if (operation.cancelled) localTranslation.status = "已取消。";
    if (localTranslation.active === operation) localTranslation.active = null;
    repaintTranslation();
  }
}
async function pollTranslationJob(operation, job) {
  operation.id = job.jobId;
  if (operation.cancelled) await screenshotRequest("translate/cancel", {jobId:operation.id});
  try {
    while (["running", "cancelling"].includes(job.status)) {
      if (job.kind === "download" && !operation.cancelled) {
        localTranslation.status = tr("正在下载语言包…") + " " + Math.floor(job.completedBytes / job.totalBytes * 100) + "%";
        repaintTranslation();
      }
      await new Promise(resolve => setTimeout(resolve, 400));
      job = await screenshotRequest("translate/job", {jobId:operation.id});
    }
    if (job.status === "error") throw new Error(job.error || "本机翻译任务失败。");
    return job.result;
  } finally {
    operation.id = null;
  }
}
async function cancelLocalTranslation() {
  const operation = localTranslation.active;
  if (!operation) return;
  operation.cancelled = true;
  localTranslation.status = "正在取消…";
  repaintTranslation();
  if (operation.id) await screenshotRequest("translate/cancel", {jobId:operation.id});
}
async function getShotHistory(enabled) {
  const [history, jobs] = await Promise.all([
    screenshotRequest("history", enabled === undefined ? {} : {enabled}),
    api("/api/ocr-provider/jobs", {}),
  ]);
  shotHistory = history;
  providerJobs = jobs.jobs || [];
  if (section === "screenshots" && shotTab === "history" && !dialog?.open) render();
}
function openIncomingOCR(job) {
  changeShotTab("history");
  reviewProviderJob(job);
}
function screenshotHistoryPage() {
  const items = shotHistory?.items || [];
  const pins = shotHistory?.pins || [];
  const open = (name, pin) => screenshotWork("正在读取图像…", async () => {
    const image = await screenshotRequest("history/open", {name, pin});
    setImage(image);
    say("已打开 " + basename(name));
  });
  const history = panel("", box("between", el("h2", "截图历史"), toggle("保存截图历史", shotHistory?.enabled, async enabled => {
    await getShotHistory(enabled);
    say(enabled ? "截图历史已启用" : "截图历史已关闭");
  }), button("刷新", () => getShotHistory(), {glyph:"history"})),
    items.length ? box("list", ...items.map(item => box("list-row", icon("image"), box("fill", el("strong", item.name || basename(item.path), "row-title"),
      item.width && el("small", item.width + " × " + item.height + " 像素")), button("打开", () => open(item.name || basename(item.path), false))))) :
      empty("history", shotHistory ? "暂无截图历史" : "正在读取截图历史"));
  const restore = async names => {
    const result = await perform("screenshot.pins.restore", {confirm: true, names});
    const opened = Array.isArray(result.opened) ? result.opened.length : result.opened;
    if (result.failures?.length) {
      showModal("贴图恢复结果", box("stack", ...result.failures.map(item => el("p", item.error || item.message || item.name, "error"))));
    }
    say("已恢复 " + (opened || 0) + " 张贴图", Boolean(result.failures?.length));
  };
  const pinPanel = panel("", box("between", el("h2", "持久贴图"), pins.length && button("恢复全部贴图", () => restore())),
    pins.length ? box("list", ...pins.map(item => {
    const name = typeof item === "string" ? basename(item) : item.name || basename(item.path);
    return box("list-row", icon("pin"), el("span", name, "fill"), button("恢复贴图", () => restore([name])), button("打开图像", () => open(name, true)));
  })) : note("还没有保存持久贴图。"));
  const handoff = providerPanel();
  return box("stack", history, pinPanel, handoff);
}
const providerLabels = {
  pending: "待复核", completed: "已完成", partial: "部分完成", failed: "失败", interrupted: "已中断", expired: "已过期",
};
function providerPanel() {
  const rows = providerJobs.map(job => box("list-row", icon("file"),
    box("fill", el("strong", job.sourceBundleID, "row-title"),
      el("small", providerLabels[job.status] || job.status),
      el("small", (job.items || []).map(item => item.name).slice(0, 4).join("、"))),
    button(job.status === "pending" ? "复核并识别…" : "查看…", () => reviewProviderJob(job)),
    job.resultCount > 0 && button("导出结果…", () => exportProviderJob(job))));
  return panel("", box("between", el("h2", "跨应用交接"), button("打开 OCR 交接包…", async () => {
    const [path] = await pick("directory", false);
    if (!path) return;
    const job = await api("/api/ocr-provider/review", {path});
    const index = providerJobs.findIndex(item => item.requestID === job.requestID);
    if (index < 0) providerJobs.unshift(job);
    else providerJobs[index] = job;
    render();
    reviewProviderJob(job);
  }, {glyph:"folder"})),
    note("打开 .gaoaction 文件夹后，复核来源与附件并确认本机识别。"),
    rows.length ? box("list", ...rows) : empty("file", "暂无 OCR 交接"));
}
function reviewProviderJob(job) {
  const details = [
    box("stack", el("strong", job.sourceBundleID),
      el("small", (providerLabels[job.status] || job.status) + " · " + job.action), el("small", dateLabel(job.createdAt))),
    box("list dialog-result", ...(job.items || []).map(item => box("list-row", el("span", item.name, "fill"), el("small", item.byteCount + " 字节")))),
    ...(job.errors || []).map(item => el("p", typeof item === "string" ? item : item.message || item.errorCode || "有输出未完成。", "error")),
  ];
  if (job.status === "pending") {
    formDialog("复核 OCR 交接", details, async () => {
      const completed = await progress("正在本机处理交接…", () => api("/api/ocr-provider/approve", {requestID: job.requestID, confirm: true}));
      await getShotHistory();
      say(providerLabels[completed.status] || completed.status, completed.status === "failed");
      render();
      reviewProviderJob(completed);
    }, "确认识别");
  } else {
    showModal("OCR 交接状态", box("stack", ...details, job.resultCount > 0 && button("导出结果…", () => exportProviderJob(job))));
  }
}
function exportProviderJob(job) {
  chooseDestination("导出 OCR 交接结果", "输出目录", async directory => {
    const result = await api("/api/ocr-provider/result", {requestID: job.requestID, directory, confirm: true});
    rememberOutputs(result);
    say("已导出 " + basename(result.path));
  });
}

const recordingOutputFormats = {
  mov: "QuickTime MOV", m4a: "MPEG-4 Audio", gif: "GIF",
};
const recording = {
  mode: "screen", systemAudio: true, microphone: false, fps: "30", status: "idle",
  streams: [], recorder: null, chunks: [], bytes: 0, result: null, saved: false, error: "", started: null,
  exportTask: null, elapsed: 0, resumedAt: null, clock: null,
};
const recordingLimit = 512 * 1024 * 1024;
const mediaTools = {
  source: null, start: 0, end: 5, fps: 10, size: 640, crop: false,
  x: 0, y: 0, width: 1, height: 1, saturation: 1, contrast: 1, brightness: 0, prepared: null, writing: false,
};

function recordingVisible() { return section === "screenshots" && shotTab === "record"; }
function renderRecording() { if (recordingVisible()) render(); }
function mediaText(key, values) {
  return tr(key).replace(/\{([a-z]+)\}/g, (placeholder, name) => values[name] ?? placeholder);
}

function recorderMimeType(video, audio) {
  const candidates = video ?
    [audio ? "video/mp4;codecs=avc1,mp4a.40.2" : "video/mp4;codecs=avc1",
      audio ? "video/mp4;codecs=avc1.640034,mp4a.40.2" : "video/mp4;codecs=avc1.640034",
      audio ? "video/webm;codecs=vp9,opus" : "video/webm;codecs=vp9",
      audio ? "video/webm;codecs=vp8,opus" : "video/webm;codecs=vp8", "video/webm"] :
    ["audio/mp4;codecs=mp4a.40.2", "audio/webm;codecs=opus", "audio/webm"];
  return candidates.find(mime => MediaRecorder.isTypeSupported(mime));
}

function recordingSeconds() {
  return ((recording.elapsed + (recording.resumedAt === null ? 0 : performance.now() - recording.resumedAt)) / 1000).toFixed(1);
}

function recordingPage() {
  const modes = select([["screen", "屏幕 / 窗口"], ["audio", "仅录音"]], recording.mode);
  modes.onchange = () => {
    recording.mode = modes.value;
    if (recording.mode === "audio" && !recording.systemAudio) recording.microphone = true;
    render();
  };
  const fps = select([["15", "15 fps"], ["30", "30 fps"], ["60", "60 fps"]], recording.fps);
  fps.onchange = () => { recording.fps = fps.value; };
  const screenNeeded = recording.mode === "screen" || recording.systemAudio;
  const canRecord = typeof MediaRecorder === "function" &&
    (!screenNeeded || Boolean(navigator.mediaDevices?.getDisplayMedia)) &&
    (!recording.microphone || Boolean(navigator.mediaDevices?.getUserMedia));
  const hasSource = recording.mode === "screen" || recording.systemAudio || recording.microphone;
  const active = ["starting", "recording", "paused", "stopping"].includes(recording.status);
  const exporting = Boolean(recording.exportTask) || mediaTools.writing;
  modes.disabled = fps.disabled = active || exporting;
  const audio = toggle("共享音频", recording.systemAudio, value => { recording.systemAudio = value; render(); });
  const mic = toggle("麦克风", recording.microphone, value => { recording.microphone = value; render(); });
  audio.firstChild.disabled = mic.firstChild.disabled = active || exporting;
  const status = {idle: "未录制", starting: "等待系统授权", recording: "正在录制", paused: "已暂停", stopping: "正在生成文件", ready: "录制待保存", saved: "录制已保存", error: "录制已停止"};
  const result = recording.result;
  const target = result?.format?.toUpperCase();
  const controls = box("row",
    button("开始录制", beginRecording, {cls:"primary", glyph:"play", disabled: !hasSource || !canRecord || active || exporting || (Boolean(result) && !recording.saved)}),
    button(recording.status === "paused" ? "继续" : "暂停", pauseRecording, {disabled: !["recording", "paused"].includes(recording.status)}),
    button("停止并完成", () => stopRecording(false), {disabled: !["recording", "paused"].includes(recording.status)}),
    button("取消录制…", () => confirmAction("取消录制？", "当前会话的未保存内容将被丢弃。", () => stopRecording(true), "取消录制"),
      {disabled: !["recording", "paused"].includes(recording.status)}));
  const saved = result && box("row",
    button(mediaText("生成 {format}", {format: target}), () => saveRecording(result.format, true), {cls:"primary", disabled: exporting}),
    result.audio && result.format !== "m4a" && button("导出 M4A…", () => saveRecording("m4a"), {disabled: exporting}),
    button("保存原始录制…", saveRawRecording, {disabled: exporting}),
    button(recording.saved ? "关闭录制副本…" : "丢弃未保存录制…", () => confirmAction("关闭当前录制？",
      recording.saved ? "已保存的文件会保留，工作台将关闭当前录制副本。" : "当前录制尚未写入文件。", () => {
      recording.result = null;
      recording.saved = false;
      recording.status = "idle";
      render();
    }, "关闭"), {cls:"plain danger", disabled: exporting}));
  const elapsed = el("span", mediaText("{seconds} 秒", {seconds: recordingSeconds()}), "muted");
  elapsed.dataset.recordingElapsed = "true";
  const exportStatus = el("span", recording.exportTask?.status || "", "muted");
  exportStatus.dataset.mediaExportStatus = "true";
  return box("stack", panel("录屏与独立录音", box("row", field("录制来源", modes)),
    box("row", recording.mode === "screen" && field("画面帧率", fps), audio, mic),
    note("系统提示会让你选择画面和音源。仅录音时，为提供系统声音而选择的画面不会进入输出。两种音源同时使用时会混为一轨。"),
    controls, box("row", el("strong", status[recording.status] || status.idle), elapsed),
    !canRecord && note("当前应用窗口无法调用浏览器的录制接口。"),
    !hasSource && note("请选择共享音频或麦克风。"),
    recording.error && el("p", recording.error, "error"),
    saved), mediaToolsPanel(active || exporting), recording.exportTask && box("row",
      exportStatus, button("取消导出", () => recording.exportTask?.controller.abort())), mediaSavePanel(active || exporting));
}
async function beginRecording() {
  if (recording.recorder || (recording.result && !recording.saved) || recording.exportTask || mediaTools.writing || recording.status === "starting") return;
  const voiceOnly = recording.mode === "audio";
  const sharedAudio = recording.systemAudio;
  const wantsMic = recording.microphone;
  if (voiceOnly && !sharedAudio && !wantsMic) return;
  recording.result = null;
  recording.saved = false;
  recording.status = "starting";
  recording.error = "";
  recording.chunks = [];
  recording.bytes = 0;
  recording.elapsed = 0;
  recording.resumedAt = null;
  const streams = [];
  let audioContext;
  try {
    let screen;
    let microphone;
    if (!voiceOnly || sharedAudio) {
      screen = await navigator.mediaDevices.getDisplayMedia({
        video: { frameRate: {ideal: Number(recording.fps), max: Number(recording.fps)} }, audio: sharedAudio,
      });
      streams.push(screen);
    }
    if (wantsMic) {
      microphone = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
      streams.push(microphone);
    }
    if (screen?.getVideoTracks().every(track => track.readyState === "ended")) throw new Error("共享画面已经结束。");
    const displayAudio = Boolean(screen?.getAudioTracks().length);
    const combined = new MediaStream(voiceOnly ? [] : screen?.getVideoTracks() || []);
    const audioInputs = [screen, microphone].filter(stream => stream?.getAudioTracks().length);
    if (audioInputs.length === 2) {
      audioContext = new AudioContext();
      await audioContext.resume();
      const mixed = audioContext.createMediaStreamDestination();
      audioInputs.forEach(stream => audioContext.createMediaStreamSource(stream).connect(mixed));
      combined.addTrack(mixed.stream.getAudioTracks()[0]);
      streams.push(mixed.stream);
    } else if (audioInputs.length) combined.addTrack(audioInputs[0].getAudioTracks()[0]);
    const hasAudio = Boolean(combined.getAudioTracks().length);
    if (voiceOnly && !hasAudio) throw new Error("所选来源未提供音频。请选择可共享声音的来源，或开启麦克风。");
    const mime = recorderMimeType(!voiceOnly, hasAudio);
    if (!mime) throw new Error("当前浏览器没有可用的录制编码器。");
    const recorder = new MediaRecorder(combined, {mimeType: mime});
    recording.recorder = recorder;
    recording.streams = streams;
    recording.started = new Date();
    recording.cancelled = false;
    recording.status = "recording";
    recorder.addEventListener("dataavailable", event => {
      if (!event.data.size || recording.cancelled) return;
      if (recording.bytes + event.data.size > recordingLimit) {
        recording.error = "录制达到 512 MiB 上限。可保存上限前已录制的内容。";
        if (recorder.state !== "inactive") stopRecording(false);
        return;
      }
      recording.bytes += event.data.size;
      recording.chunks.push(event.data);
    });
    recorder.addEventListener("error", () => { recording.error = "浏览器编码失败。"; });
    recorder.addEventListener("stop", () => {
      finishRecordingClock();
      const blob = recording.chunks.length && !recording.cancelled ? new Blob(recording.chunks, {type: recorder.mimeType || mime}) : null;
      if (blob?.size) {
        recording.result = {blob, audio: hasAudio, video: !voiceOnly, format: voiceOnly && !displayAudio ? "m4a" : "mov"};
        recording.status = "ready";
        say(recording.error || "录制已完成，可保存文件", Boolean(recording.error));
      } else {
        recording.status = recording.cancelled ? "idle" : "error";
        say(recording.cancelled ? "已取消录制" : (recording.error || "录制结束时没有可保存的内容"), !recording.cancelled);
      }
      streams.flatMap(stream => stream.getTracks()).forEach(track => track.stop());
      audioContext?.close().catch(() => {});
      recording.recorder = null;
      recording.chunks = [];
      recording.streams = [];
      recording.bytes = 0;
      renderRecording();
    });
    const trackEnds = [screen, microphone].filter(Boolean).flatMap(stream => stream.getTracks());
    trackEnds.forEach(track => track.addEventListener("ended", () => {
      if (recorder.state !== "inactive") stopRecording(false);
    }, {once:true}));
    recorder.start(1000);
    recording.resumedAt = performance.now();
    recording.clock = setInterval(() => {
      const label = document.querySelector("[data-recording-elapsed]");
      if (label) label.textContent = mediaText("{seconds} 秒", {seconds: recordingSeconds()});
    }, 250);
    say(sharedAudio && screen && !screen.getAudioTracks().length ? "正在录制。当前共享来源没有提供音频。" : "正在录制");
  } catch (error) {
    streams.flatMap(stream => stream.getTracks()).forEach(track => track.stop());
    audioContext?.close().catch(() => {});
    recording.status = "error";
    recording.recorder = null;
    recording.streams = [];
    recording.error = error.name === "NotAllowedError" ? "录制授权已取消或被 Windows 拒绝。" : error.message;
    say(recording.error, true);
  }
  renderRecording();
}
function pauseRecordingClock() {
  if (recording.resumedAt !== null) recording.elapsed += performance.now() - recording.resumedAt;
  recording.resumedAt = null;
}
function finishRecordingClock() {
  pauseRecordingClock();
  clearInterval(recording.clock);
  recording.clock = null;
}
function pauseRecording() {
  const recorder = recording.recorder;
  if (recorder?.state === "recording") {
    recorder.pause(); pauseRecordingClock(); recording.status = "paused"; say("录制已暂停");
  } else if (recorder?.state === "paused") {
    recorder.resume(); recording.resumedAt = performance.now(); recording.status = "recording"; say("录制已继续");
  }
  renderRecording();
}
function stopRecording(cancel) {
  const recorder = recording.recorder;
  if (!recorder || recorder.state === "inactive") return;
  recording.cancelled = cancel;
  recording.status = "stopping";
  recorder.stop();
  renderRecording();
}

function recordingName(clip, extension, audioExport = false) {
  const stamp = recording.started.toISOString().slice(0, 19).replaceAll(":", "-").replace("T", "_");
  return `搞操作-${clip.video && !audioExport ? "录屏" : "录音"}-${stamp}.${extension}`;
}

function setMediaExportProgress(task, status) {
  task.status = status;
  const label = document.querySelector("[data-media-export-status]");
  if (label) label.textContent = status;
}

async function prepareMediaOutput(build) {
  if (recording.exportTask || mediaTools.writing) return;
  const task = {controller: new AbortController(), status: "正在准备导出…"};
  recording.exportTask = task;
  renderRecording();
  try {
    mediaTools.prepared = await build(task);
    say("导出已生成，请选择保存位置。");
  } catch (error) {
    if (task.controller.signal.aborted || error.name === "AbortError") say("已取消导出。");
    else say(error.message || "媒体导出失败。", true);
  } finally {
    recording.exportTask = null;
    renderRecording();
  }
}

function saveRecording(format, primary = false) {
  const clip = recording.result;
  if (!clip) return;
  return prepareMediaOutput(async task => {
    const {convertRecording} = await import("./media_export.js");
    const blob = await convertRecording(clip.blob, format, {
      signal: task.controller.signal,
      progress: rate => setMediaExportProgress(task, mediaText("正在导出 {format} · {percent}%", {format: format.toUpperCase(), percent: Math.round(rate * 100)})),
    });
    return {blob, format, name: recordingName(clip, format, format === "m4a"), primary: primary ? clip : null};
  });
}

function saveRawRecording() {
  const clip = recording.result;
  if (!clip) return;
  const format = clip.blob.type.includes("mp4") ? (clip.video ? "mp4" : "m4a") : "webm";
  return writeMediaOutput({blob: clip.blob, format, name: recordingName(clip, format), primary: clip});
}

async function writeMediaOutput(item) {
  if (!item || recording.exportTask || mediaTools.writing) return;
  const {blob, format, name, primary} = item;
  const description = recordingOutputFormats[format] || format.toUpperCase();
  try {
    if (!window.showSaveFilePicker) {
      downloadBlob(blob, name);
      say("已请求浏览器下载。请核对下载结果。");
      return;
    }
    mediaTools.writing = true;
    const picking = window.showSaveFilePicker({suggestedName: name, types: [
      {description, accept: {[blob.type.split(";")[0]]: [`.${format}`]}},
    ]});
    renderRecording();
    const handle = await picking;
    const writer = await handle.createWritable();
    try { await writer.write(blob); await writer.close(); }
    catch (error) { await writer.abort().catch(() => {}); throw error; }
    if (primary && recording.result === primary) {
      recording.saved = true;
      recording.status = "saved";
    }
    if (mediaTools.prepared === item) mediaTools.prepared = null;
    say(mediaText("已保存 {name}", {name: handle.name || name}));
  } catch (error) {
    if (error.name !== "AbortError") say(error.message || "无法保存导出文件。", true);
  } finally {
    mediaTools.writing = false;
    renderRecording();
  }
}

function mediaSavePanel(disabled) {
  const prepared = mediaTools.prepared;
  if (!prepared) return null;
  return box("row", el("strong", prepared.name),
    button("选择位置保存…", () => writeMediaOutput(prepared), {cls:"primary", disabled}),
    button("关闭导出", () => { mediaTools.prepared = null; renderRecording(); }, {disabled}));
}

function mediaToolsPanel(disabled) {
  const recordingVideo = recording.result?.video ? recording.result.blob : null;
  const video = mediaTools.source || recordingVideo;
  const source = document.createElement("input");
  source.type = "file";
  source.accept = "video/*,audio/*,.mov,.mp4,.m4a,.mkv,.webm";
  source.disabled = disabled;
  source.onchange = () => {
    if (source.files.length) mediaTools.source = source.files[0];
    renderRecording();
  };
  const number = (label, key, min, max, step = 1) => {
    const control = input(mediaTools[key], {type:"number", min, max, step});
    control.disabled = disabled;
    control.oninput = () => { mediaTools[key] = control.valueAsNumber; };
    return field(label, control);
  };
  const crop = toggle("按归一化坐标裁剪", mediaTools.crop, value => { mediaTools.crop = value; renderRecording(); });
  crop.firstChild.disabled = disabled;
  return panel("视频转 GIF 与音频导出", field("本机媒体文件", source),
    mediaTools.source && box("row", el("span", mediaTools.source.name), button("清除所选文件", () => {
      mediaTools.source = null;
      renderRecording();
    }, {disabled})),
    !mediaTools.source && recordingVideo && note("当前录屏可直接用作来源。"),
    box("row", number("开始秒", "start", 0, undefined, 0.1), number("结束秒", "end", 0.1, undefined, 0.1),
      number("帧率", "fps", 1, 30), number("最长边（像素）", "size", 16, 1920)),
    box("row", number("饱和度", "saturation", 0, 2, 0.1), number("对比度", "contrast", 0.5, 2, 0.1),
      number("亮度", "brightness", -0.5, 0.5, 0.1), crop),
    mediaTools.crop && box("row", number("X", "x", 0, 1, 0.01), number("Y", "y", 0, 1, 0.01),
      number("宽", "width", 0.01, 1, 0.01), number("高", "height", 0.01, 1, 0.01)),
    note("GIF 最多 256 色，不含音频。转换在本机完成。"),
    box("row", button("生成 GIF", () => prepareMediaOutput(async task => {
      const {makeGif} = await import("./media_export.js");
      const {start, end, fps, size, saturation, contrast, brightness} = mediaTools;
      const {blob, frames} = await makeGif(video, {start, end, fps, size, saturation, contrast, brightness,
        crop: mediaTools.crop ? [mediaTools.x, mediaTools.y, mediaTools.width, mediaTools.height] : null}, {
        signal: task.controller.signal,
        progress: (done, total) => setMediaExportProgress(task, mediaText("正在转换 GIF · {done}/{total} 帧", {done, total})),
      });
      say(mediaText("已生成 {frames} 帧 GIF", {frames}));
      return {blob, format: "gif", name: "搞操作-动图.gif"};
    }), {disabled: disabled || !video}),
    button("从本机文件导出 M4A", () => prepareMediaOutput(async task => {
      const {convertRecording} = await import("./media_export.js");
      const blob = await convertRecording(mediaTools.source, "m4a", {signal: task.controller.signal,
        progress: rate => setMediaExportProgress(task, mediaText("正在导出 {format} · {percent}%", {format: "M4A", percent: Math.round(rate * 100)}))});
      return {blob, format: "m4a", name: "搞操作-音频.m4a"};
    }), {disabled: disabled || !mediaTools.source})));
}

window.addEventListener("beforeunload", event => {
  if (!recording.recorder && (!recording.result || recording.saved) && !recording.exportTask && !mediaTools.prepared) return;
  event.preventDefault();
  event.returnValue = "";
});
