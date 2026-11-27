"use strict";

const shotTabs = [
  ["capture", "截图"], ["annotation", "标注"], ["ocr", "OCR"], ["record", "录屏与录音"], ["translation", "翻译"], ["history", "历史与交接"],
];
let shotTab = "capture";
let shotImage = null;
let shotDocument = null;
let shotLong = null;
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
    button("添加画面", () => longCapture("append"), {cls:"primary", disabled: shotBusy}),
    button("生成长截图", () => longCapture("finish"), {disabled: shotBusy || shotLong.frames < 2}),
    button("取消", () => longCapture("cancel"), {disabled: shotBusy}),
  ] : [button("长截图", () => longCapture("start"), {disabled: shotBusy})];
  const info = "捕获前通过当前按钮选择要采集的区域、窗口或屏幕。受保护区域和安全桌面由 Windows 控制。";
  return box("shot-home", el("h2", "捕获所选内容"), note("截图后可以保存、复制或进入标注。"),
    box("row capture-actions", ...captureActions),
    box("row", button("多窗口合成", () => captureImage("windows"), {disabled: shotBusy}), ...longActions,
      button("取色", sampleColor, {disabled: shotBusy}), button("打开图像…", chooseImage, {disabled: shotBusy}), button("贴图与交接", () => changeShotTab("history"))),
    shotLong?.active && panel("长截图", note("在目标窗口手动向下滚动，每次保留一段重叠内容。点击“添加画面”后有 3 秒钟切回并滚动。"),
      note("已添加 " + shotLong.frames + " 帧 · " + shotLong.width + " × " + shotLong.height + " 像素")),
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
  const status = {start: "请选择长截图区域…", append: "3 秒内切回目标窗口并滚动…", finish: "正在拼接画面…", cancel: "正在取消…"};
  return screenshotWork(status[command], async () => {
    const result = await screenshotRequest("long", {command, confirm: true, delay: command === "append" ? 3 : 0});
    if (command === "finish" && result.id) {
      setImage(result);
      shotLong = null;
      say("长截图已生成");
    } else {
      shotLong = command === "cancel" ? null : result;
      say(command === "cancel" ? "已取消长截图" : "长截图已添加 " + result.frames + " 帧");
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
      ...exports, button("翻译结果", () => {translationDraft = bodyText; changeShotTab("translation");}, {disabled: !bodyText})));
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
function translationPage() {
  const draft = area(translationDraft, "输入或粘贴要翻译的文字");
  draft.oninput = () => { translationDraft = draft.value; };
  const capability = state.screenshot?.translation || state.screenshots?.translation;
  if (!capability?.available) return panel("本机翻译", note(capability?.reason || "当前 Windows 版没有本机翻译引擎。"), field("原文", draft));
  const source = input("auto", { placeholder: "源语言" });
  const target = input("zh-CN", {placeholder: "目标语言"});
  const output = area("", "翻译结果");
  output.readOnly = true;
  return panel("本机翻译", box("columns", field("源语言", source), field("目标语言", target)), field("原文", draft),
    box("row", button("翻译", async () => {
      const result = await screenshotRequest("translate", {text: draft.value, source: source.value, target: target.value});
      output.value = result.text || "";
    }, {cls:"primary"})), field("译文", output));
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

const recorderMimeTypes = [
  "video/webm;codecs=vp9,opus", "video/webm;codecs=vp8,opus", "video/webm",
];
const recording = {
  mode: "screen", systemAudio: false, microphone: false, fps: "30", status: "idle",
  streams: [], recorder: null, chunks: [], bytes: 0, result: null, error: "", started: null,
};
const recordingLimit = 512 * 1024 * 1024;
function recordingPage() {
  const modes = select([["screen", "屏幕 / 窗口"], ["microphone", "仅录音"]], recording.mode);
  modes.onchange = () => { recording.mode = modes.value; render(); };
  const fps = select([["15", "15 fps"], ["30", "30 fps"], ["60", "60 fps"]], recording.fps);
  fps.onchange = () => { recording.fps = fps.value; };
  const canRecord = typeof MediaRecorder === "function" &&
    (recording.mode === "microphone" ? navigator.mediaDevices?.getUserMedia : navigator.mediaDevices?.getDisplayMedia);
  const active = ["starting", "recording", "paused", "stopping"].includes(recording.status);
  modes.disabled = fps.disabled = active;
  const audio = toggle("共享音频", recording.systemAudio, value => { recording.systemAudio = value; });
  const mic = toggle("麦克风", recording.microphone, value => { recording.microphone = value; });
  audio.firstChild.disabled = mic.firstChild.disabled = active;
  const status = {idle: "未录制", starting: "等待系统授权", recording: "正在录制", paused: "已暂停", stopping: "正在生成文件", ready: "录制待保存", error: "录制已停止"};
  const controls = box("row",
    button("开始录制", beginRecording, {cls:"primary", glyph:"play", disabled: !canRecord || active || Boolean(recording.result)}),
    button(recording.status === "paused" ? "继续" : "暂停", pauseRecording, {disabled: !["recording", "paused"].includes(recording.status)}),
    button("停止并完成", () => stopRecording(false), {disabled: !["recording", "paused"].includes(recording.status)}),
    button("取消录制…", () => confirmAction("取消录制？", "当前会话的未保存内容将被丢弃。", () => stopRecording(true), "取消录制"),
      {disabled: !["recording", "paused"].includes(recording.status)}));
  const saved = recording.result && box("row", button("保存录制…", saveRecording, {cls:"primary"}),
    button("丢弃未保存录制…", () => confirmAction("丢弃录制？", "当前录制尚未写入文件。", () => {
      recording.result = null;
      recording.status = "idle";
      render();
    }, "丢弃"), {cls:"plain danger"}));
  const videoOptions = recording.mode === "screen" && box("row", field("画面帧率", fps), audio, mic);
  return box("stack", panel("录屏与录音", box("row", field("录制来源", modes)),
    videoOptions, note("点击开始后，使用系统或浏览器提示选择屏幕、窗口和麦克风。共享音频取决于所选择的来源。"),
    controls, el("strong", status[recording.status] || status.idle),
    !canRecord && note("当前应用窗口无法调用浏览器的录制接口。"),
    recording.error && el("p", recording.error, "error"),
    saved));
}
async function beginRecording() {
  if (recording.recorder || recording.result || recording.status === "starting") return;
  const voiceOnly = recording.mode === "microphone";
  const sharedAudio = recording.systemAudio;
  const wantsMic = recording.microphone || voiceOnly;
  recording.status = "starting";
  recording.error = "";
  recording.chunks = [];
  recording.bytes = 0;
  const streams = [];
  let audioContext;
  try {
    let screen;
    let microphone;
    if (!voiceOnly) {
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
    const combined = new MediaStream(screen?.getVideoTracks() || []);
    const audioInputs = [screen, microphone].filter(stream => stream?.getAudioTracks().length);
    if (audioInputs.length === 2) {
      audioContext = new AudioContext();
      await audioContext.resume();
      const mixed = audioContext.createMediaStreamDestination();
      audioInputs.forEach(stream => audioContext.createMediaStreamSource(stream).connect(mixed));
      combined.addTrack(mixed.stream.getAudioTracks()[0]);
      streams.push(mixed.stream);
    } else if (audioInputs.length) combined.addTrack(audioInputs[0].getAudioTracks()[0]);
    const mime = (voiceOnly ? ["audio/webm;codecs=opus", "audio/webm"] : recorderMimeTypes).find(type => MediaRecorder.isTypeSupported(type));
    if (!mime) throw new Error("当前浏览器无法编码 WebM。");
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
      const blob = recording.chunks.length && !recording.cancelled ? new Blob(recording.chunks, {type: mime}) : null;
      if (blob?.size) {
        recording.result = blob;
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
      if (section === "screenshots" && shotTab === "record") render();
    });
    const trackEnds = voiceOnly ? combined.getAudioTracks() : combined.getVideoTracks();
    trackEnds.forEach(track => track.addEventListener("ended", () => {
      if (recorder.state !== "inactive") stopRecording(false);
    }, {once:true}));
    recorder.start(1000);
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
  if (section === "screenshots" && shotTab === "record") render();
}
function pauseRecording() {
  const recorder = recording.recorder;
  if (recorder?.state === "recording") {
    recorder.pause(); recording.status = "paused"; say("录制已暂停");
  } else if (recorder?.state === "paused") {
    recorder.resume(); recording.status = "recording"; say("录制已继续");
  }
  if (section === "screenshots" && shotTab === "record") render();
}
function stopRecording(cancel) {
  const recorder = recording.recorder;
  if (!recorder || recorder.state === "inactive") return;
  recording.cancelled = cancel;
  recording.status = "stopping";
  recorder.stop();
}
async function saveRecording() {
  const recorded = recording.result;
  if (!recorded) return;
  const stamp = recording.started.toISOString().slice(0, 19).replaceAll(":", "-").replace("T", "_");
  const name = "搞操作-" + (recorded.type.startsWith("audio") ? "录音-" : "录屏-") + stamp + ".webm";
  if (window.showSaveFilePicker) {
    try {
      const handle = await window.showSaveFilePicker({suggestedName: name, types: [
        {description: "WebM", accept: {[recorded.type.startsWith("audio") ? "audio/webm" : "video/webm"]: [".webm"]}},
      ]});
      const writer = await handle.createWritable();
      try { await writer.write(recorded); await writer.close(); }
      catch (error) { await writer.abort(); throw error; }
      if (recording.result === recorded) {
        recording.result = null;
        recording.status = "idle";
      }
      say("录制已保存");
    } catch (error) {
      if (error.name === "AbortError") return;
      throw error;
    }
  } else {
    downloadBlob(recorded, name);
    say("已交给浏览器保存录制文件");
  }
  if (section === "screenshots" && shotTab === "record") render();
}
window.addEventListener("beforeunload", event => {
  if (!recording.recorder && !recording.result) return;
  event.preventDefault();
  event.returnValue = "";
});
