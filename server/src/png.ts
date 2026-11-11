/**
 * 解析 PNG 并校验传真图片约束：灰度（color type 0）、位深 1、宽 ≤ 384、高 ≤ 768、文件 ≤ 64 KB。
 * 除签名和 IHDR 外，还会遍历所有数据块校验长度与 CRC，要求有 IDAT 且以 IEND 结尾，
 * 避免只有 PNG 头、后面是任意字节的文件通过。
 */

export const MAX_IMAGE_BYTES = 64 * 1024;
export const MAX_IMAGE_WIDTH = 384;
export const MAX_IMAGE_HEIGHT = 768;

const SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(bytes: Uint8Array, start: number, end: number): number {
  let c = 0xffffffff;
  for (let i = start; i < end; i++) c = CRC_TABLE[(c ^ bytes[i]!) & 0xff]! ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

export type PngCheck = { ok: true; width: number; height: number } | { ok: false; reason: string };

export function validateFaxPng(bytes: Uint8Array): PngCheck {
  if (bytes.length > MAX_IMAGE_BYTES) return { ok: false, reason: "image is larger than 64 KB" };
  if (bytes.length < 8 + 25 + 12) return { ok: false, reason: "not a PNG file" };
  for (let i = 0; i < SIGNATURE.length; i++) {
    if (bytes[i] !== SIGNATURE[i]) return { ok: false, reason: "not a PNG file" };
  }

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let offset = 8;
  let width = 0;
  let height = 0;
  let sawIdat = false;
  let sawIend = false;
  let first = true;

  while (offset < bytes.length) {
    if (offset + 12 > bytes.length) return { ok: false, reason: "truncated PNG chunk" };
    const length = view.getUint32(offset);
    const typeStart = offset + 4;
    const dataStart = offset + 8;
    const dataEnd = dataStart + length;
    if (length > 0x7fffffff || dataEnd + 4 > bytes.length) return { ok: false, reason: "truncated PNG chunk" };
    const type = String.fromCharCode(bytes[typeStart]!, bytes[typeStart + 1]!, bytes[typeStart + 2]!, bytes[typeStart + 3]!);
    if (view.getUint32(dataEnd) !== crc32(bytes, typeStart, dataEnd)) {
      return { ok: false, reason: `bad CRC in ${type} chunk` };
    }

    if (first) {
      if (type !== "IHDR" || length !== 13) return { ok: false, reason: "first chunk must be IHDR" };
      width = view.getUint32(dataStart);
      height = view.getUint32(dataStart + 4);
      const bitDepth = bytes[dataStart + 8]!;
      const colorType = bytes[dataStart + 9]!;
      const compression = bytes[dataStart + 10]!;
      const filter = bytes[dataStart + 11]!;
      const interlace = bytes[dataStart + 12]!;
      if (colorType !== 0) return { ok: false, reason: "image must be grayscale (color type 0)" };
      if (bitDepth !== 1) return { ok: false, reason: "image must be 1-bit" };
      if (compression !== 0 || filter !== 0 || interlace > 1) return { ok: false, reason: "unsupported PNG parameters" };
      if (width < 1 || height < 1) return { ok: false, reason: "image has zero size" };
      if (width > MAX_IMAGE_WIDTH) return { ok: false, reason: `width must be at most ${MAX_IMAGE_WIDTH}` };
      if (height > MAX_IMAGE_HEIGHT) return { ok: false, reason: `height must be at most ${MAX_IMAGE_HEIGHT}` };
      first = false;
    } else if (type === "IDAT") {
      sawIdat = true;
    } else if (type === "IEND") {
      sawIend = true;
      offset = dataEnd + 4;
      break;
    }
    offset = dataEnd + 4;
  }

  if (!sawIdat) return { ok: false, reason: "PNG has no image data" };
  if (!sawIend) return { ok: false, reason: "PNG is missing IEND" };
  if (offset !== bytes.length) return { ok: false, reason: "unexpected data after IEND" };
  return { ok: true, width, height };
}
