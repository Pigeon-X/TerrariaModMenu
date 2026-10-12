#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 TerrariaModMenu.dylib 注入进 Terraria 的 IPA。

做的事：
  1. 往 Payload/<App>.app/Frameworks/ 放进 TerrariaModMenu.dylib
  2. 给主可执行文件加一条 LC_LOAD_DYLIB（@executable_path/Frameworks/TerrariaModMenu.dylib）
  3. 重新打出 IPA

改完的包签名一定失效，装之前要用你自己的证书重签
（Sideloadly / AltStore / TrollStore）。

用法：
    python inject_ipa.py "Terraria iOS.ipa" -o "Terraria-mod.ipa"
    python inject_ipa.py in.ipa -o out.ipa --dylib build/TerrariaModMenu.dylib
"""

import argparse
import os
import plistlib
import re
import shutil
import struct
import sys
import tempfile
import zipfile

MH_MAGIC_64 = 0xFEEDFACF
MH_EXECUTE = 2
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
LC_LOAD_DYLIB = 0xC

DYLIB_INSTALL_NAME = "@executable_path/Frameworks/TerrariaModMenu.dylib"
DYLIB_BASENAME = "TerrariaModMenu.dylib"


def log(msg):
    print(msg, flush=True)


def die(msg, code=1):
    sys.stderr.write("错误: " + msg + "\n")
    sys.exit(code)


# --------------------------------------------------------------------------- #
# Mach-O
# --------------------------------------------------------------------------- #
def _load_commands(data):
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, _res = \
        struct.unpack_from("<8I", data, 0)
    if magic != MH_MAGIC_64:
        die(f"主可执行文件不是 64 位 Mach-O（magic={magic:#x}）")
    if filetype != MH_EXECUTE:
        die(f"主可执行文件 filetype={filetype}，不是 MH_EXECUTE")
    cmds = []
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmdsize == 0:
            die("load command 长度异常（0）")
        cmds.append((off, cmd, cmdsize))
        off += cmdsize
    return filetype, ncmds, sizeofcmds, cmds


def _has_dylib(data, cmds, name):
    for off, cmd, _size in cmds:
        if (cmd & 0x7FFFFFFF) == LC_LOAD_DYLIB:
            nameoff = struct.unpack_from("<I", data, off + 8)[0]
            end = data.index(b"\0", off + nameoff)
            if data[off + nameoff:end].decode("utf-8", "replace") == name:
                return True
    return False


def _min_section_offset(data, cmds):
    lowest = None
    for off, cmd, _size in cmds:
        if (cmd & 0x7FFFFFFF) != LC_SEGMENT_64:
            continue
        nsects = struct.unpack_from("<I", data, off + 64)[0]
        so = off + 72
        for _ in range(nsects):
            sec_off = struct.unpack_from("<I", data, so + 48)[0]
            if sec_off:
                lowest = sec_off if lowest is None else min(lowest, sec_off)
            so += 80
    return lowest


def _zero_code_signature(out):
    """把 LC_CODE_SIGNATURE 标记成空签名（dataoff=0, datasize=0）。

    ⚠️ 默认**不要**走这里。TrollStore 用的是 ldid，而 ldid 重签时会按
    LC_CODE_SIGNATURE 的 dataoff 把文件截断、再在末尾追加新签名；
    dataoff=0 会让它截到 0 字节，紧接着 `assert(end <= size)` 直接炸：

        ldid.cpp(1483): _assert(): end <= size
        trollstorehelper returning 175

    真实的 App Store 包本来就是带签名的，重签工具（ldid / Sideloadly）
    都是"替换"签名 —— 所以保留原来的 LC_CODE_SIGNATURE 才是对的。
    """
    _ft, _n, _sz, cmds = _load_commands(bytes(out))
    for off, cmd, _size in cmds:
        if (cmd & 0x7FFFFFFF) == LC_CODE_SIGNATURE:
            struct.pack_into("<II", out, off + 8, 0, 0)   # dataoff=0, datasize=0
            return True
    return False


def patch_macho(data, dylib_path, strip_codesig=False):
    """在 load commands 末尾插入一条 LC_LOAD_DYLIB。"""
    filetype, ncmds, sizeofcmds, cmds = _load_commands(data)

    if _has_dylib(data, cmds, dylib_path):
        log("   load command 里已经有这条 dylib，跳过插入")
        return data

    name = dylib_path.encode("utf-8")
    pad = (-(len(name) + 1)) % 8
    lc_size = 24 + len(name) + 1 + pad
    lc = (struct.pack("<IIIIII", LC_LOAD_DYLIB, lc_size, 24, 2, 0x10000, 0x10000)
          + name + b"\0" * (1 + pad))
    assert len(lc) == lc_size

    new_end = 32 + sizeofcmds + lc_size
    limit = _min_section_offset(data, cmds) or (32 + sizeofcmds)
    if new_end > limit:
        die(f"主可执行文件头部没有足够空隙（需要 {new_end}，只有 {limit}）。")

    out = bytearray(data)
    out[32 + sizeofcmds:32 + sizeofcmds + lc_size] = lc
    struct.pack_into("<I", out, 16, ncmds + 1)          # ncmds
    struct.pack_into("<I", out, 20, sizeofcmds + lc_size)  # sizeofcmds

    if strip_codesig:
        _zero_code_signature(out)
    log(f"   已插入 LC_LOAD_DYLIB -> {dylib_path}（{lc_size} 字节，剩余空隙 {limit - new_end}）")
    return bytes(out)


# --------------------------------------------------------------------------- #
# IPA
# --------------------------------------------------------------------------- #
def find_app_dir(names):
    for n in names:
        m = re.match(r"^(Payload/[^/]+\.app)/", n)
        if m:
            return m.group(1), m.group(1) + "/"
    die("IPA 里找不到 Payload/*.app")


def read_executable_name(zf, app_dir):
    plist_path = app_dir + "/Info.plist"
    with zf.open(plist_path) as f:
        raw = f.read()
    try:
        info = plistlib.loads(raw)
        name = info.get("CFBundleExecutable")
        if name:
            return name
    except Exception:
        pass
    m = re.search(rb"<key>CFBundleExecutable</key>\s*<string>([^<]+)</string>", raw)
    if m:
        return m.group(1).decode("utf-8")
    die("读不出 CFBundleExecutable")


def main():
    ap = argparse.ArgumentParser(description="把 TerrariaModMenu.dylib 注入 IPA")
    ap.add_argument("ipa", help="原始 IPA")
    ap.add_argument("-o", "--out", required=True, help="输出 IPA")
    ap.add_argument("--dylib", default="build/TerrariaModMenu.dylib", help="要注入的 dylib")
    ap.add_argument("--framework", default=DYLIB_INSTALL_NAME,
                    help="写进 load command 的路径")
    ap.add_argument("--strip-codesig", action="store_true",
                    help="把旧的 LC_CODE_SIGNATURE 置空（默认**不**这么做，见下）")
    args = ap.parse_args()

    if not os.path.isfile(args.ipa):
        die(f"找不到 IPA：{args.ipa}")
    if not os.path.isabs(args.dylib):
        # 相对路径按仓库根目录解析，方便随便在哪个目录调用
        repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        cand = os.path.join(repo_root, args.dylib)
        if os.path.isfile(cand):
            args.dylib = cand
    if not os.path.isfile(args.dylib):
        die(f"找不到 dylib：{args.dylib}（先在 macOS / CI 上跑 make）")

    with open(args.dylib, "rb") as f:
        dylib_bytes = f.read()
    log(f"dylib: {args.dylib}（{len(dylib_bytes):,} 字节）")

    zf = zipfile.ZipFile(args.ipa, "r")
    names = zf.namelist()
    app_dir, _ = find_app_dir(names)
    exe_name = read_executable_name(zf, app_dir)
    exe_path = f"{app_dir}/{exe_name}"
    dylib_dest = f"{app_dir}/Frameworks/{DYLIB_BASENAME}"
    log(f"目标 App: {app_dir}")
    log(f"主可执行文件: {exe_path}")

    if exe_path not in names:
        die(f"IPA 里没有 {exe_path}")

    exe_data = zf.read(exe_path)
    log(f"原始可执行文件 {len(exe_data):,} 字节")
    patched = patch_macho(exe_data, args.framework,
                          strip_codesig=args.strip_codesig)

    # 注意：dylib 可能原本不在包里（首次注入），所以两个都要放进 replace；
    # 主循环里遇到同名条目就替换，循环结束后剩下的作为新条目补写。
    replace = {exe_path: patched, dylib_dest: dylib_bytes}

    log(f"开始重新打包 -> {args.out}")
    with zipfile.ZipFile(args.out, "w", allowZip64=True) as out:
        for info in zf.infolist():
            data = replace.pop(info.filename, None)
            if data is None:
                data = zf.read(info.filename)
            zi = zipfile.ZipInfo(info.filename, date_time=info.date_time)
            zi.compress_type = info.compress_type
            zi.external_attr = info.external_attr
            zi.create_system = info.create_system
            out.writestr(zi, data)
        # 新增的 dylib
        for path, data in replace.items():
            zi = zipfile.ZipInfo(path, date_time=(2024, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = 0o100644 << 16
            out.writestr(zi, data)
            log(f"   已写入 {path}")
    zf.close()

    log("")
    log(f"完成：{args.out}")
    log("注意：签名已失效，安装前必须用你自己的证书重签"
        "（Sideloadly / AltStore / TrollStore）。")
    log("首次运行后日志在 App 沙盒的 Documents/TerrariaModMenu.log。")


if __name__ == "__main__":
    main()
