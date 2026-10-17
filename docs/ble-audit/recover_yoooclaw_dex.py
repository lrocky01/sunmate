#!/usr/bin/env python3
"""为已核对 SHA-256 的 YoooClaw 2.3.0 APK 重建离线分析 DEX。

不启动 APK，不修改输入，不解密密钥。依据残留 map_list/string_data 重建
112 字节 DEX 头及 string_ids；所有 code_item/class_data 原样保留。
产物是分析副本，不是厂商原始、签名或可安装的发行包。
"""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import zipfile
import zlib


APK_SHA256 = "e638958d143b518829a3db4d16cb4f8db1b19c64d49149458b98684c16e2137f"
# 原始 classes.dex 内的绝对起点、块长度、块内 map_list 偏移。
SEGMENTS = (
    (0xE344, 0xC22611, 0xB9F29C),
    (0xC30958, 0xB5104F, 0xAD1324),
    (0x17819A8, 0x61BF5C, 0x61BE80),
)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def rebuild(data, start, size, map_offset):
    original = data[start:start + size]
    raw = bytearray(original)
    count = struct.unpack_from("<I", raw, map_offset)[0]
    assert count == 18, "map_list 数量不匹配"
    rows = [struct.unpack_from("<HHII", raw, map_offset + 4 + 12 * i)
            for i in range(count)]
    mapping = {kind: (n, offset) for kind, unused, n, offset in rows}
    assert mapping[0x1000] == (1, map_offset)
    assert mapping[1][1] == 112
    string_count, pos = mapping[0x2002]
    assert string_count == mapping[1][0]
    pointers = []
    for _ in range(string_count):
        pointers.append(pos)
        while raw[pos] & 128:
            pos += 1
        pos += 1
        pos = raw.index(0, pos) + 1
    mismatch = [i for i, p in enumerate(pointers)
                if struct.unpack_from("<I", raw, 112 + i * 4)[0] != p]
    assert mismatch == list(range(996)), "损坏范围超出已核对的前 4096 字节"

    raw[:112] = bytes(112)
    raw[:8] = b"dex\n035\x00"
    struct.pack_into("<8I", raw, 32, size, 112, 0x12345678, 0, 0,
                     map_offset, *mapping[1])
    for kind, offset in ((2, 64), (3, 72), (4, 80), (5, 88), (6, 96)):
        struct.pack_into("<2I", raw, offset, *mapping[kind])
    data_offset = min(offset for kind, unused, n, offset in rows if kind >= 0x1000)
    struct.pack_into("<2I", raw, 104, size - data_offset, data_offset)
    for i, pos in enumerate(pointers):
        struct.pack_into("<I", raw, 112 + 4 * i, pos)
    raw[12:32] = hashlib.sha1(raw[32:]).digest()
    struct.pack_into("<I", raw, 8, zlib.adler32(raw[12:]) & 0xFFFFFFFF)
    assert raw[4096:] == original[4096:], "不允许更改代码或其它后续数据"
    return bytes(raw), {
        "source_offset": hex(start), "size": size,
        "map_offset": hex(map_offset), "class_count": mapping[6][0],
        "string_count": string_count, "rebuilt_string_indices": [0, 995],
        "bytes_from_4096_unchanged": True,
        "original_segment_sha256": sha256(original),
        "reconstructed_sha256": sha256(raw),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("output", type=Path, help="必须不存在的新目录")
    args = parser.parse_args()
    apk = args.apk.read_bytes()
    if sha256(apk) != APK_SHA256:
        raise SystemExit("APK SHA-256 不匹配，拒绝套用固定布局")
    with zipfile.ZipFile(args.apk) as archive:
        dex = archive.read("classes.dex")
    results = [rebuild(dex, *segment) for segment in SEGMENTS]
    args.output.mkdir(parents=True, exist_ok=False)
    evidence = {"apk_sha256": APK_SHA256, "input_path": str(args.apk.resolve()),
                "scope": "static reconstructed analysis copies; no APK execution",
                "segments": []}
    for i, (payload, info) in enumerate(results, 1):
        name = f"recovered-{i}.dex"
        (args.output / name).write_bytes(payload)
        info["output"] = name
        evidence["segments"].append(info)
    (args.output / "recovery-evidence.json").write_text(
        json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(args.output.resolve()),
                      "class_counts": [x[1]["class_count"] for x in results]},
                     ensure_ascii=False))


if __name__ == "__main__":
    main()
