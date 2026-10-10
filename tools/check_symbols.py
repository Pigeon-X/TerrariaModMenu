#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
离线校验：把 il2cpp_api.hpp 里用到的 IL2CPP API，逐个拿去真实的
UnityFramework 符号表里查一遍，看能不能解析到可调用的地址。

这是唯一能在没有 iPhone 的情况下"模拟"真机行为的部分 —— 覆盖了
「按名解析」这条通用版主链路。

用法：
    python3 tools/check_symbols.py "Terraria iOS.ipa"
    python3 tools/check_symbols.py /path/to/UnityFramework
"""

import re
import struct
import sys
import zipfile
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
N_TYPE = 0x0E
N_SECT = 0x0E          # Mach-O 里 N_SECT 就是 0x0E
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2


def load_image(arg):
    p = Path(arg)
    if p.is_dir() or p.suffix.lower() in (".ipa", ".zip", ".apk"):
        z = zipfile.ZipFile(p)
        hits = [n for n in z.namelist() if n.endswith("UnityFramework.framework/UnityFramework")]
        if not hits:
            sys.exit("在这个包里找不到 UnityFramework")
        data = z.read(hits[0])
        z.close()
        return data, hits[0]
    return p.read_bytes(), str(p)


def parse(data):
    _, cputype, _, filetype, ncmds, _, _, _ = struct.unpack_from("<8I", data, 0)
    assert struct.unpack_from("<I", data, 0)[0] == MH_MAGIC_64, "不是 64 位 Mach-O"
    segs, symtab, off = [], None, 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        base = cmd & 0x7FFFFFFF
        if base == LC_SEGMENT_64:
            name = data[off + 8:off + 24].rstrip(b"\0").decode()
            vmaddr, vmsize = struct.unpack_from("<QQ", data, off + 24)
            fileoff = struct.unpack_from("<Q", data, off + 40)[0]
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            secs, so = [], off + 72
            for _s in range(nsects):
                saddr, ssize = struct.unpack_from("<QQ", data, so + 32)
                soff = struct.unpack_from("<I", data, so + 48)[0]
                secs.append((saddr, ssize, soff))
                so += 80
            segs.append((name, vmaddr, vmsize, fileoff, secs))
        elif base == LC_SYMTAB:
            symtab = struct.unpack_from("<4I", data, off + 8)
        off += cmdsize
    return cputype, filetype, segs, symtab


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    data, where = load_image(sys.argv[1])
    cputype, filetype, segs, symtab = parse(data)

    def vm2file(a):
        for name, vmaddr, vmsize, fileoff, secs in segs:
            for saddr, ssize, soff in secs:
                if saddr and saddr <= a < saddr + ssize:
                    return soff + (a - saddr)
        return None

    t0 = t1 = 0
    for name, vmaddr, vmsize, fileoff, secs in segs:
        if name == "__TEXT":
            t0, t1 = vmaddr, vmaddr + vmsize

    symoff, nsyms, stroff, strsize = symtab
    table = {}
    for i in range(nsyms):
        o = symoff + i * 16
        n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", data, o)
        if n_strx == 0 or n_value == 0:
            continue
        if (n_type & N_TYPE) != N_SECT:
            continue
        s = stroff + n_strx
        e = data.index(b"\0", s)
        raw = data[s:e].decode("utf-8", "replace")
        if raw:
            table.setdefault(raw[1:] if raw[0] == "_" else raw, n_value)

    def callable_addr(a):
        """和 il2cpp_api.mm 的 make_callable 等价"""
        fo = vm2file(a)
        if fo is None:
            return None, "不在任何 section"
        insn = struct.unpack_from("<I", data, fo)[0]
        is_thunk = (insn & 0x7C000000) == 0x14000000
        if is_thunk:
            return a, "跳转桩"
        if fo + 8 <= len(data):
            deref = struct.unpack_from("<Q", data, fo)[0]
            if t0 <= deref < t1:
                return deref, "指针解引用"
        if t0 <= a < t1:
            return a, "实体小函数"
        return None, "不可执行"

    # 从源码里读出要检查的符号名，保证永远和代码同步
    header = Path(__file__).resolve().parent.parent / "src" / "il2cpp_api.hpp"
    names = re.findall(r'IL2_WRAP\([^,]+,\s*\w+,\s*"([^"]+)"', header.read_text(encoding="utf-8"))
    names = sorted(set(names))

    print(f"镜像: {where}")
    print(f"  cputype={cputype:#x} filetype={filetype} 符号表 {nsyms} 条 -> 入表 {len(table)}")
    print(f"  检查 {len(names)} 个 API（来自 src/il2cpp_api.hpp）\n")

    ok, bad = [], []
    for n in names:
        a = table.get(n)
        if a is None:
            bad.append((n, "符号表里没有这个符号"))
            continue
        fn, how = callable_addr(a)
        (ok if fn else bad).append((n, how + f" @{a:#x}"))

    print(f"✅ 可用 {len(ok)}/{len(names)}")
    for n, how in ok:
        print(f"   {n:<44} {how}")
    if bad:
        print(f"\n❌ 不可用 {len(bad)}")
        for n, why in bad:
            print(f"   {n:<44} {why}")
        sys.exit(1)
    print("\n全部解析通过。")


if __name__ == "__main__":
    main()
