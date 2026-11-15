"""ISO/IEC 18004 字节模式、纠错级别 M、版本 1–10。

布局按公开的 QR 码生成步骤实现：功能图形、数据之字形、格式信息 BCH 和八种掩码。
超出容量时拒绝，不输出无法扫描的图片。
"""

from __future__ import annotations

from gaocaozuo.errors import AppError

# (ecc per block, [(block count, data codewords per block), ...])
_LEVEL_M = {
    1: (10, [(1, 16)]),
    2: (16, [(1, 28)]),
    3: (26, [(1, 44)]),
    4: (18, [(2, 32)]),
    5: (24, [(2, 43)]),
    6: (16, [(4, 27)]),
    7: (18, [(4, 31)]),
    8: (22, [(2, 38), (2, 39)]),
    9: (22, [(3, 36), (2, 37)]),
    10: (26, [(4, 43), (1, 44)]),
}
_BYTE_CAPACITY = {1: 14, 2: 26, 3: 42, 4: 62, 5: 84, 6: 106, 7: 122, 8: 152, 9: 180, 10: 213}
_ALIGN = {
    1: [],
    2: [6, 18],
    3: [6, 22],
    4: [6, 26],
    5: [6, 30],
    6: [6, 34],
    7: [6, 22, 38],
    8: [6, 24, 42],
    9: [6, 26, 46],
    10: [6, 28, 50],
}
_REMAINDER = {1: 0, 2: 7, 3: 7, 4: 7, 5: 7, 6: 7, 7: 0, 8: 0, 9: 0, 10: 0}

_EXP = [0] * 512
_LOG = [0] * 256
_x = 1
for _i in range(255):
    _EXP[_i] = _x
    _LOG[_x] = _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D
for _i in range(255, 512):
    _EXP[_i] = _EXP[_i - 255]


def _mul(a: int, b: int) -> int:
    if a == 0 or b == 0:
        return 0
    return _EXP[_LOG[a] + _LOG[b]]


def _generator(degree: int) -> list[int]:
    poly = [1]
    for i in range(degree):
        poly = _poly_mul(poly, [1, _EXP[i]])
    return poly


def _poly_mul(a: list[int], b: list[int]) -> list[int]:
    result = [0] * (len(a) + len(b) - 1)
    for i, av in enumerate(a):
        for j, bv in enumerate(b):
            result[i + j] ^= _mul(av, bv)
    return result


def _remainder(data: list[int], degree: int) -> list[int]:
    generator = _generator(degree)
    result = list(data) + [0] * degree
    for i in range(len(data)):
        coef = result[i]
        if coef == 0:
            continue
        for j, value in enumerate(generator):
            result[i + j] ^= _mul(value, coef)
    return result[-degree:]


def _size(version: int) -> int:
    return 17 + 4 * version


def _raw_modules(version: int) -> int:
    result = (16 * version + 128) * version + 64
    if version >= 2:
        num_align = version // 7 + 2
        result -= (25 * num_align - 10) * num_align - 55
        if version >= 7:
            result -= 36
    return result


def _format_bits(mask: int) -> int:
    data = mask  # ECC M is 00
    rem = data
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    return ((data << 10) | rem) ^ 0x5412


def _version_bits(version: int) -> int:
    rem = version
    for _ in range(12):
        rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
    return (version << 12) | rem


def _mask_bit(mask: int, x: int, y: int) -> bool:
    if mask == 0:
        return (x + y) % 2 == 0
    if mask == 1:
        return y % 2 == 0
    if mask == 2:
        return x % 3 == 0
    if mask == 3:
        return (x + y) % 3 == 0
    if mask == 4:
        return (y // 2 + x // 3) % 2 == 0
    if mask == 5:
        return (x * y) % 2 + (x * y) % 3 == 0
    if mask == 6:
        return ((x * y) % 2 + (x * y) % 3) % 2 == 0
    return ((x + y) % 2 + (x * y) % 3) % 2 == 0


def _codewords(payload: bytes, version: int) -> list[int]:
    ecc, groups = _LEVEL_M[version]
    capacity = sum(count * length for count, length in groups)
    bits: list[int] = []

    def add(value: int, length: int) -> None:
        for shift in range(length - 1, -1, -1):
            bits.append((value >> shift) & 1)

    add(0x4, 4)
    add(len(payload), 8)
    for byte in payload:
        add(byte, 8)
    capacity_bits = capacity * 8
    for _ in range(min(4, capacity_bits - len(bits))):
        bits.append(0)
    while len(bits) % 8:
        bits.append(0)
    pad = (0xEC, 0x11)
    pad_index = 0
    while len(bits) < capacity_bits:
        add(pad[pad_index], 8)
        pad_index ^= 1
    data = [sum(bits[i + b] << (7 - b) for b in range(8)) for i in range(0, len(bits), 8)]
    blocks: list[tuple[list[int], list[int]]] = []
    offset = 0
    for count, length in groups:
        for _ in range(count):
            block = data[offset : offset + length]
            offset += length
            blocks.append((block, _remainder(block, ecc)))
    out: list[int] = []
    longest = max(len(block) for block, _ in blocks)
    for i in range(longest):
        for block, _ecc in blocks:
            if i < len(block):
                out.append(block[i])
    for i in range(ecc):
        for _block, block_ecc in blocks:
            out.append(block_ecc[i])
    return out


def _format_coords(size: int) -> list[tuple[int, int]]:
    coords = [(8, i) for i in range(6)]
    coords.extend([(8, 7), (8, 8), (7, 8)])
    coords.extend((14 - i, 8) for i in range(9, 15))
    coords.extend((size - 1 - i, 8) for i in range(8))
    coords.extend((8, size - 15 + i) for i in range(8, 15))
    return coords


def _blank(version: int) -> tuple[list[list[bool]], list[list[bool]]]:
    size = _size(version)
    modules = [[False] * size for _ in range(size)]
    function = [[False] * size for _ in range(size)]

    def set_fn(x: int, y: int, dark: bool) -> None:
        modules[y][x] = dark
        function[y][x] = True

    def finder(ox: int, oy: int) -> None:
        for dy in range(-1, 8):
            for dx in range(-1, 8):
                x, y = ox + dx, oy + dy
                if not (0 <= x < size and 0 <= y < size):
                    continue
                if 0 <= dx <= 6 and 0 <= dy <= 6:
                    dark = dx in {0, 6} or dy in {0, 6} or (2 <= dx <= 4 and 2 <= dy <= 4)
                    set_fn(x, y, dark)
                else:
                    set_fn(x, y, False)

    finder(0, 0)
    finder(size - 7, 0)
    finder(0, size - 7)
    for i in range(size):
        set_fn(6, i, i % 2 == 0)
        set_fn(i, 6, i % 2 == 0)
    centers = _ALIGN[version]
    count = len(centers)
    for y_index, cy in enumerate(centers):
        for x_index, cx in enumerate(centers):
            if (x_index, y_index) in {(0, 0), (0, count - 1), (count - 1, 0)}:
                continue
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    dark = max(abs(dx), abs(dy)) != 1
                    set_fn(cx + dx, cy + dy, dark)
    set_fn(8, 4 * version + 9, True)
    for x, y in _format_coords(size):
        set_fn(x, y, False)
    if version >= 7:
        bits = _version_bits(version)
        for i in range(18):
            bit = ((bits >> i) & 1) == 1
            a = size - 11 + i % 3
            b = i // 3
            set_fn(a, b, bit)
            set_fn(b, a, bit)
    return modules, function


def _draw_format(modules: list[list[bool]], function: list[list[bool]], mask: int) -> None:
    bits = _format_bits(mask)
    for index, (x, y) in enumerate(_format_coords(len(modules))):
        modules[y][x] = ((bits >> index) & 1) == 1
        function[y][x] = True


def _place(modules: list[list[bool]], function: list[list[bool]], data: list[int]) -> None:
    size = len(modules)
    i = 0
    total = len(data) * 8
    right = size - 1
    while right >= 1:
        if right == 6:
            right = 5
        for vert in range(size):
            for j in range(2):
                x = right - j
                upward = ((right + 1) & 2) == 0
                y = size - 1 - vert if upward else vert
                if not function[y][x] and i < total:
                    modules[y][x] = ((data[i >> 3] >> (7 - (i & 7))) & 1) == 1
                    i += 1
        right -= 2


def _apply_mask(modules: list[list[bool]], function: list[list[bool]], mask: int) -> None:
    size = len(modules)
    for y in range(size):
        for x in range(size):
            if not function[y][x] and _mask_bit(mask, x, y):
                modules[y][x] = not modules[y][x]


def _penalty(modules: list[list[bool]]) -> int:
    size = len(modules)
    score = 0
    for row in modules:
        run = 1
        for x in range(1, size):
            if row[x] == row[x - 1]:
                run += 1
                if run == 5:
                    score += 3
                elif run > 5:
                    score += 1
            else:
                run = 1
    for x in range(size):
        run = 1
        for y in range(1, size):
            if modules[y][x] == modules[y - 1][x]:
                run += 1
                if run == 5:
                    score += 3
                elif run > 5:
                    score += 1
            else:
                run = 1
    for y in range(size - 1):
        for x in range(size - 1):
            if modules[y][x] == modules[y][x + 1] == modules[y + 1][x] == modules[y + 1][x + 1]:
                score += 3
    dark = sum(sum(row) for row in modules)
    percent = dark * 100 // (size * size)
    score += abs(percent - 50) // 5 * 10
    return score


def _choose_version(payload: bytes) -> int:
    for version, capacity in _BYTE_CAPACITY.items():
        if len(payload) <= capacity:
            return version
    raise AppError("文本超过二维码容量（版本 10、纠错 M，最多 213 字节），请缩短后再生成。", "invalid")


def encode(text: str) -> list[list[bool]]:
    if not text:
        raise AppError("二维码内容不能为空。", "invalid")
    payload = text.encode("utf-8")
    if len(payload) > 2000:
        raise AppError("二维码内容须为 1–2000 字节。", "invalid")
    version = _choose_version(payload)
    data = _codewords(payload, version)
    best = None
    best_score = None
    for mask in range(8):
        modules, function = _blank(version)
        free = sum(1 for row in function for cell in row if not cell)
        raw = _raw_modules(version)
        if free != raw or (raw - _REMAINDER[version]) // 8 != len(data):
            raise AppError("二维码功能图形与码字容量不一致，已停止输出。", "invalid")
        _place(modules, function, data)
        _apply_mask(modules, function, mask)
        _draw_format(modules, function, mask)
        score = _penalty(modules)
        if best_score is None or score < best_score:
            best = modules
            best_score = score
    if best is None:
        raise AppError("二维码生成失败。", "invalid")
    return best


def to_png(modules: list[list[bool]], scale: int = 8, quiet: int = 4) -> bytes:
    from gaocaozuo.images import encode_png

    size = len(modules)
    span = size + quiet * 2
    width = span * scale
    rgb = bytearray(width * width * 3)
    for y in range(width):
        my = y // scale - quiet
        for x in range(width):
            mx = x // scale - quiet
            dark = 0 <= mx < size and 0 <= my < size and modules[my][mx]
            value = 0 if dark else 255
            dest = (y * width + x) * 3
            rgb[dest : dest + 3] = bytes((value, value, value))
    return encode_png(width, width, bytes(rgb))


def _read_format(modules: list[list[bool]]) -> int:
    bits = 0
    for index, (x, y) in enumerate(_format_coords(len(modules))[:15]):
        if modules[y][x]:
            bits |= 1 << index
    masked = bits ^ 0x5412
    data = masked >> 10
    rem = data
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    if ((data << 10) | rem) != masked:
        raise AppError("二维码格式信息校验失败。", "invalid")
    if data >> 3 != 0:
        raise AppError("二维码不是纠错级别 M。", "invalid")
    return data & 7


def decode_text(modules: list[list[bool]]) -> str:
    size = len(modules)
    if (size - 17) % 4:
        raise AppError("二维码尺寸无效。", "invalid")
    version = (size - 17) // 4
    if version not in _LEVEL_M:
        raise AppError("二维码版本超出解码范围。", "invalid")
    mask = _read_format(modules)
    _, function = _blank(version)
    _draw_format([[False] * size for _ in range(size)], function, mask)
    bits = []
    right = size - 1
    while right >= 1:
        if right == 6:
            right = 5
        for vert in range(size):
            for j in range(2):
                x = right - j
                upward = ((right + 1) & 2) == 0
                y = size - 1 - vert if upward else vert
                if not function[y][x]:
                    dark = modules[y][x]
                    if _mask_bit(mask, x, y):
                        dark = not dark
                    bits.append(1 if dark else 0)
        right -= 2
    ecc, groups = _LEVEL_M[version]
    total = sum(count * (length + ecc) for count, length in groups)
    raw = bits[: total * 8]
    codewords = [sum(raw[i + b] << (7 - b) for b in range(8)) for i in range(0, len(raw), 8)]
    # Undo interleave.
    lengths = []
    for count, length in groups:
        lengths.extend([length] * count)
    data_blocks: list[list[int]] = [[] for _ in lengths]
    index = 0
    longest = max(lengths)
    for i in range(longest):
        for block_index, length in enumerate(lengths):
            if i < length:
                data_blocks[block_index].append(codewords[index])
                index += 1
    data: list[int] = []
    for block in data_blocks:
        data.extend(block)
    bit_string = []
    for byte in data:
        for shift in range(7, -1, -1):
            bit_string.append((byte >> shift) & 1)

    def take(n: int) -> int:
        value = 0
        for _ in range(n):
            value = (value << 1) | bit_string.pop(0)
        return value

    mode = take(4)
    if mode != 0x4:
        raise AppError("只解码字节模式二维码。", "invalid")
    length = take(8)
    payload = bytes(take(8) for _ in range(length))
    return payload.decode("utf-8")
