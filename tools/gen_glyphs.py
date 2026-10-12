#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从源码里提取界面用到的中文字，生成 src/ui/glyph_extra.hpp。

为什么需要它：ImGui 只加载「常用简体中文」(约 2500 字) 来压图集大小
（全量 2 万字会被 iOS 的 watchdog 杀掉，见交接文档 5.4）。
但界面文案里会出现一些不在常用表里的字 —— 比如「屏」「渲」「帧」——
它们会渲染成问号。这里把源码里实际用到的字全提出来，额外加进字形表。

改完界面文案后跑一次：
    python3 tools/gen_glyphs.py
"""

import glob
import io
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "src", "ui", "glyph_extra.hpp")

PATTERNS = [
    "src/**/*.mm", "src/**/*.hpp", "src/**/*.cpp",
    "preview/**/*.mm", "preview/**/*.cpp",
    "simhost/**/*.mm",
]


def main():
    chars = set()
    files = []
    for pat in PATTERNS:
        files += glob.glob(os.path.join(ROOT, pat), recursive=True)

    for f in files:
        # 跳过这个生成出来的头文件本身，免得自我循环
        if os.path.abspath(f) == os.path.abspath(OUT):
            continue
        try:
            s = io.open(f, encoding="utf-8").read()
        except Exception:
            continue
        for ch in s:
            o = ord(ch)
            if 0x4E00 <= o <= 0x9FFF:          # 汉字
                chars.add(ch)
            elif 0x3000 <= o <= 0x303F:        # 中文标点
                chars.add(ch)
            elif 0xFF00 <= o <= 0xFFEF:        # 全角符号
                chars.add(ch)

    text = "".join(sorted(chars))
    # 转成 C++ 字符串字面量里的转义（只留 ASCII 安全的形式：直接用 UTF-8 原样写）
    body = (
        "#pragma once\n"
        "//\n"
        "// 【自动生成，别手改】由 tools/gen_glyphs.py 从源码里提取。\n"
        "//\n"
        "// 界面文案里用到、但不在 ImGui「常用简体中文」表里的字。\n"
        "// 不额外加载的话，这些字会渲染成问号（例如「屏」「渲」「帧」）。\n"
        "// 改完文案重新跑：python3 tools/gen_glyphs.py\n"
        "//\n"
        "namespace glyphs {\n"
        f"inline const char* kExtra = \"{text}\";\n"
        "}  // namespace glyphs\n"
    )
    io.open(OUT, "w", encoding="utf-8").write(body)
    print(f"扫了 {len(files)} 个文件，提取 {len(text)} 个字符")
    print(f"写入 {os.path.relpath(OUT, ROOT)}（{len(body.encode('utf-8'))} 字节）")


if __name__ == "__main__":
    main()
