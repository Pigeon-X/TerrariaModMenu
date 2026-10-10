# Terraria iOS Mod Menu

给 **iOS 版 Terraria（Unity IL2CPP）** 用的 mod 菜单，个人使用。

- **通用版**：所有 IL2CPP API 都靠**按名字解析**（解析 `UnityFramework` 的 Mach-O 符号表），
  不写死任何偏移；游戏更新后大概率照常能用。
- **专用版**：在通用版基础上，额外用一份**针对具体版本的偏移表**换取更快的启动和额外功能。

两个版本共用同一套源码，编译期开关切换。

## 它长什么样

一个注入进 IPA 的 `TerrariaModMenu.dylib`：

- 在 Unity 的 Metal 渲染循环里叠一层 ImGui 界面；
- 内嵌 **Lua 5.4**，从 App 的 `Documents/Mods/<Mod名>/` 读 `main.lua`；
- 通过 IL2CPP 反射给 Lua 暴露 `Native.*`（反射 / 调用 / 读写字段 / Hook）、
  `UI.*`（ImGui 控件）、`Runtime.*`（协程）、`Log` 等；
- 每个 Mod 在控制台里是一个 Tab。

## 现状 / 路线图

| 阶段 | 内容 | 状态 |
|---|---|---|
| 1 | 工程骨架、构建链、CI、注入脚本、IL2CPP 按名解析、日志 | 已完成 |
| 2 | Metal 渲染钩子 + ImGui 界面 + 触摸输入 + 悬浮窗 | 已完成（待编译验证） |
| 3 | Lua 宿主 + Mod 加载器（mod.json / main.lua / onLoad/onUpdate/onUnload） | 待做 |
| 4 | Lua API 全量对齐（Native/UI/Runtime/Texture/Net/Trp/Zip/Audio） | 待做 |
| 5 | 专用版偏移表（iOS 1.4.5.8.1） | 待做 |

> ⚠️ 代码是在无法本机编译的环境里写的，**首次在 macOS / CI 上编译大概率还要修几轮错误**。
> 工作流已经配好，直接跑就能看到报错。

## 已实测确认的前提（对着 Terraria iOS 1.4.5.8.1 脱壳包查的）

| 事实 | 数值 | 意义 |
|---|---|---|
| `UnityFramework` 符号表 | **未剥离**，16,449 个符号 | 可以自己解析 |
| 其中 `il2cpp_*` | **237 个** | IL2CPP API 齐活 |
| 导出表里的 `il2cpp` | 0 | `dlsym()` **拿不到**，必须自己查符号表 |
| 游戏方法名符号（`Terraria`/`Player`/`NPC`…） | 0 | 游戏逻辑只能走 IL2CPP 反射 |
| 主可执行文件 `Terraria` | 87,616 字节，头部空隙 **13,984 字节** | 够插一条 `LC_LOAD_DYLIB`（只要 ~72 字节） |
| 注入结果（本机已实测） | `ncmds 26→27`、dylib 就位、zip 完整性通过 | 注入链路 OK |

## 阶段 1 的验收方法

1. 编译出 `TerrariaModMenu.dylib`，注入 IPA，重签安装；
2. 启动游戏（第一次可能闪退，再进一次）；
3. 看沙盒里的 `Documents/TerrariaModMenu.log`，应该能看到：

```
[xx:xx:xx] ==== TerrariaModMenu 载入 (built ...) ====
[xx:xx:xx] IL2CPP 符号表已解析：16449 个符号，镜像=.../UnityFramework
[xx:xx:xx] 自检：类 Terraria.Main 命中
[xx:xx:xx] 自检完成：按名解析 + 反射链路 OK
```

看到这些就说明**整个地基是通的**，后面堆 UI 和 Lua 只是体力活。

## 构建

需要 macOS + Xcode 命令行工具。本机没有 Mac 的话，用仓库自带的 GitHub Actions
（`.github/workflows/build.yml`）跑 `macos-latest` 出包。

```bash
./scripts/fetch_deps.sh      # 拉 imgui / lua / Dobby
make generic                 # 通用版 -> build/TerrariaModMenu.dylib
make specific                # 专用版 -> build/TerrariaModMenu.dylib
```

## 注入

```bash
python3 scripts/inject_ipa.py "Terraria.ipa" -o "Terraria-mod.ipa"
```

脚本会：把 `TerrariaModMenu.dylib` 放进 `Payload/Terraria.app/Frameworks/`，
给主可执行文件 `Terraria` 加一条 `LC_LOAD_DYLIB`，并清掉旧签名。
之后用你自己的证书重签（Sideloadly / AltStore / TrollStore）。

> 想加载 dylib，设备需要**越狱**，或者用 **TrollStore** 这类可加载应用内 dylib 的安装方式。

三种环境都能装，任选：

| 环境 | 做法 |
|---|---|
| 越狱 | 直接注入 + `ldid -S` / 任意签名工具重签 |
| TrollStore | 注入后交给 TrollStore 安装（它自己伪签名） |
| 自签注入工具（轻松签 / ESign / Sideloadly 注入 dylib 等） | **连本脚本都不用**，直接把 `TerrariaModMenu.dylib` 当成"插件"加进 Terraria，由工具完成注入和签名 |

## 界面操作

- 进游戏后左上角出现一个悬浮窗（默认可见）；隐藏后左侧留一个 **M** 小钮，点它重新打开。
- 「日志」页是启动/自检输出；「状态」页看 IL2CPP 解析情况；每个 Mod 会有自己的 Tab。
- 打开菜单时，落在窗口上的触摸会被吃掉，不会漏到游戏里（避免误操作）。

## 目录

```
src/
  entry.mm          构造函数入口：等 UnityFramework 加载 -> 解析 API -> 装钩子
  il2cpp_api.*      IL2CPP 按名解析（解析 Mach-O 符号表，无硬编码偏移）
  mm_log.hpp        日志（NSLog + 文件）
  platform/         平台相关（Metal 钩子、触摸）
  lua/              Lua 宿主与 API 绑定
  mods/             Mod 加载器
scripts/
  fetch_deps.sh     拉第三方源码
  inject_ipa.py     注入 dylib 并打包 IPA
```

## 授权

仅供个人学习研究使用。
