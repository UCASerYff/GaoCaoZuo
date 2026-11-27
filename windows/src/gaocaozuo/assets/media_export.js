import {
  ADTS, BlobSource, BufferTarget, CanvasSink, Conversion, FLAC, Input, MATROSKA,
  MovOutputFormat, MP3, MP4, Mp4OutputFormat, OGG, Output, QTFF, WAVE, WEBM,
} from "./vendor/mediabunny.js";

const formats = [MP4, QTFF, WEBM, MATROSKA, WAVE, OGG, FLAC, MP3, ADTS];
const mediaLimit = 512 * 1024 * 1024;
const gifPixelLimit = 240_000_000;

function openMedia(blob) {
  if (!(blob instanceof Blob) || !blob.size || blob.size > mediaLimit) {
    throw new Error("请选择 512 MiB 以内的媒体文件。");
  }
  return new Input({ source: new BlobSource(blob), formats });
}

export async function convertRecording(blob, format, { signal, progress } = {}) {
  if (format !== "mov" && format !== "m4a") throw new Error("录制导出格式无效。");
  const input = openMedia(blob);
  let conversion;
  const onAbort = () => { if (conversion) void conversion.cancel().catch(() => {}); };
  try {
    signal?.throwIfAborted();
    const audioOnly = format === "m4a";
    const [audioTracks, videoTracks] = await Promise.all([input.getAudioTracks(), input.getVideoTracks()]);
    if (audioOnly && !audioTracks.length) throw new Error("这个文件没有音频轨。");
    if (audioTracks.length + videoTracks.length > 8) throw new Error("媒体超过 8 条轨道，请先选择需要导出的轨道。");
    const target = new BufferTarget();
    const muxer = audioOnly ? new Mp4OutputFormat() : new MovOutputFormat();
    conversion = await Conversion.init({
      input,
      output: new Output({ format: muxer, target }),
      audio: { codec: "aac" },
      video: audioOnly ? { discard: true } : { codec: "avc" },
      tags: {},
      showWarnings: false,
    });
    signal?.throwIfAborted();
    if (!conversion.isValid || conversion.discardedTracks.some(item =>
      (item.track.isAudioTrack() || (!audioOnly && item.track.isVideoTrack())) && item.reason !== "discarded_by_user")) {
      throw new Error("当前浏览器无法用 H.264/AAC 导出全部所需轨道。请保留原始录制，或更新浏览器及 Windows 媒体功能。");
    }
    if (progress) conversion.onProgress = progress;
    signal?.addEventListener("abort", onAbort, { once: true });
    await conversion.execute();
    signal?.throwIfAborted();
    if (!target.buffer?.byteLength || target.buffer.byteLength > mediaLimit) throw new Error("录制导出结果为空或超过 512 MiB。");
    return new Blob([target.buffer], { type: audioOnly ? "audio/mp4" : "video/quicktime" });
  } finally {
    signal?.removeEventListener("abort", onAbort);
    input.dispose();
  }
}

function boundedGif(options) {
  const { start, end, fps, size, crop, saturation = 1, contrast = 1, brightness = 0 } = options;
  if (![start, end, fps, size, saturation, contrast, brightness].every(Number.isFinite) ||
      start < 0 || end <= start || end - start > 120 || !Number.isInteger(fps) || fps < 1 || fps > 30 ||
      !Number.isInteger(size) || size < 16 || size > 1920 || saturation < 0 || saturation > 2 ||
      contrast < 0.5 || contrast > 2 || brightness < -0.5 || brightness > 0.5) {
    throw new Error("GIF 须选择 0–120 秒的片段、1–30 fps、16–1920 像素，并使用范围内的调色参数。");
  }
  const frames = Math.ceil((end - start) * fps);
  if (frames > 3000 || size * size * frames > gifPixelLimit) {
    throw new Error("GIF 超出 2.4 亿帧像素预算。请缩短片段或降低尺寸、帧率。");
  }
  if (crop && (!Array.isArray(crop) || crop.length !== 4 || !crop.every(value => Number.isFinite(value) && value >= 0 && value <= 1) ||
    crop[2] <= 0 || crop[3] <= 0 || crop[0] + crop[2] > 1 || crop[1] + crop[3] > 1)) {
    throw new Error("GIF 裁剪范围须位于 0–1，且宽高须大于 0。");
  }
  return { start, end, fps, size, crop, saturation, contrast, brightness, frames };
}

export async function makeGif(blob, settings, { signal, progress } = {}) {
  const options = boundedGif(settings);
  const { GIFEncoder, quantize, applyPalette } = await import("./vendor/gifenc.js");
  const input = openMedia(blob);
  try {
    signal?.throwIfAborted();
    const track = await input.getPrimaryVideoTrack();
    if (!track || !await track.canDecode()) throw new Error("当前浏览器没有此视频的解码器。");
    const [start, end, sourceWidth, sourceHeight] = await Promise.all([
      track.getFirstTimestamp(), track.computeDuration(), track.getDisplayWidth(), track.getDisplayHeight(),
    ]);
    if (options.end > end - start + 0.005) throw new Error("GIF 片段的结束时间超过视频长度。");
    const [x, y, w, h] = options.crop || [0, 0, 1, 1];
    const crop = {
      left: Math.min(sourceWidth - 1, Math.floor(x * sourceWidth)),
      top: Math.min(sourceHeight - 1, Math.floor(y * sourceHeight)),
      width: Math.max(1, Math.floor(w * sourceWidth)),
      height: Math.max(1, Math.floor(h * sourceHeight)),
    };
    const scale = Math.min(1, options.size / Math.max(crop.width, crop.height));
    const width = Math.max(1, Math.round(crop.width * scale));
    const height = Math.max(1, Math.round(crop.height * scale));
    const sink = new CanvasSink(track, { width, height, fit: "fill", crop, poolSize: 1 });
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext("2d", { willReadFrequently: true });
    context.filter = `saturate(${options.saturation}) contrast(${options.contrast}) brightness(${1 + options.brightness})`;
    const gif = GIFEncoder();
    const timestamps = Array.from({ length: options.frames }, (_, index) => start + options.start + index / options.fps);
    let added = 0;
    for await (const source of sink.canvasesAtTimestamps(timestamps)) {
      signal?.throwIfAborted();
      if (!source) throw new Error("无法解码所选片段的一帧，未生成 GIF。");
      context.drawImage(source.canvas, 0, 0, width, height);
      const pixels = context.getImageData(0, 0, width, height).data;
      const palette = quantize(pixels, 256);
      const endMs = Math.min((options.end - options.start) * 1000, (added + 1) * 1000 / options.fps);
      const startMs = added * 1000 / options.fps;
      // GIF uses 10 ms ticks. Round cumulative positions to avoid drift.
      const delay = Math.max(10, (Math.round(endMs / 10) - Math.round(startMs / 10)) * 10);
      gif.writeFrame(applyPalette(pixels, palette), width, height, { palette, delay, repeat: 0 });
      added++;
      progress?.(added, options.frames);
      if (added % 4 === 0) await new Promise(resolve => setTimeout(resolve, 0));
    }
    signal?.throwIfAborted();
    if (added !== options.frames) throw new Error("视频帧数与所选片段不符，未生成 GIF。");
    gif.finish();
    return { blob: new Blob([gif.bytes()], { type: "image/gif" }), frames: added, width, height };
  } finally {
    input.dispose();
  }
}
