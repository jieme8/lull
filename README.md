# Lull

空闲一段时间后，自动把窗口让开、露出桌面；顺手给常用 App 配一套全局快捷键。macOS 菜单栏小工具，Objective-C 写的，单文件构建，不需要 Xcode。

```
你离开 2 分钟 → 窗口全部让开，屏幕只剩壁纸
你回来 → 点 Dock 或 Command-Tab，窗口原位回来
按 ⌘⌥2 → 打开 Chrome（没启动就启动，已启动就把窗口带回来）
```

## 两种"显示桌面"模式

| 模式 | 效果 | 需要的权限 |
|---|---|---|
| 隐藏所有窗口 | 把每个普通 App `hide()` 掉。窗口不丢，点一下回来 | **无**（零权限，实测不需要辅助功能/自动化授权） |
| 原生显示桌面 | 发一次系统 Show Desktop 按键，效果等同手动按 F11 | 辅助功能（一次性授权） |

原生模式是默认值；没授权时会自动退回隐藏模式并提示，不会什么都不做。

## 实测结论（这个项目里最值钱的部分）

踩了很久的坑，都写进代码注释和断言里了：

1. **macOS 必须留一个普通 App 当"前台"来绘制桌面。** 所以"把所有窗口藏干净"用 `hide()` 是做不到的：你把访达也藏掉，系统就会复活另一个 App 的窗口，补几轮都在两者之间来回跳（8 轮实验不收敛）。正确做法是**永不隐藏访达**，让这个名额稳定落在它身上。
2. **别信 API 的返回值。** `hide()` 返回 `NO` 但目标确实被藏了；`activateWithOptions:` 返回 `YES` 但 App 没到前台；`RegisterEventHotKey` 返回 `noErr` 但组合键已被别的程序占用（Carbon 不报跨进程冲突）。判断成败只能看外部事实：窗口列表、前台 App、进程。
3. **"已运行的 App 按快捷键没反应"** 的根因：那个 App 在运行但一个窗口都没有（聊天/Electron 类关掉窗口后很常见），`activate` 只是置前，屏幕上自然没变化。走 `NSWorkspace openApplicationAtURL:` 会额外发一个 reopen 事件，App 才会把窗口建回来。
4. **分布式通知不排队。** App 刚启动、观察者还没注册时投递会永久丢失，所以 CLI 握手要重发 + nonce 校验，而不是等固定秒数。

## 构建

要求：macOS 13+，Command Line Tools（`xcode-select --install`）。

```bash
./build.sh            # 编译 → 打包 → 生成图标 → 签名 → 装到 ~/Applications → 启动
./build.sh --check    # 零警告编译检查 + 17 条回归断言（提交前跑这个）
./build.sh --build    # 只编译到 build/
./build.sh --tools    # 编译辅助工具到 build/tools/
./build.sh --verify   # 只跑回归断言
```

`build.sh` 会逐个试哪个 SDK 真能链接，而不是直接信 `xcrun` 的默认值 —— 部分机器上的 CLT 会装到一个 `.tbd` 含未知架构的坏 SDK。签名优先用钥匙串里已有的开发者身份（这样辅助功能授权能跨编译保持），没有则退回 ad-hoc 并打印警告。

可调环境变量：`INSTALL_DIR`、`ICON_DESIGN`（0/1/2 三套图标）、`SIGN_IDENTITY`。

## 命令行

CLI 和菜单栏 App 是同一个二进制，`--hide-now` / `--run-hotkey` / `--doctor` 会通过分布式通知交给常驻实例执行，所以测的就是真实路径。

```bash
Lull --doctor          # 体检：模式/授权/阈值/每条快捷键触发次数/屏上窗口快照/自检结论
Lull --hide-now        # 立即显示桌面
Lull --list-hotkeys    # 列出快捷键配置
Lull --run-hotkey 2    # 打开第 2 条对应的 App
Lull --autostart on    # 注册/取消登录项（SMAppService）
```

出问题先跑 `--doctor`，它会把"注册成功但从未收到按键""路径失效""原生模式未授权"这类看不见的状态直接打出来。日志在 `~/Library/Logs/Lull.log`。

## 回归验证

`tools/verify.m` 里 17 条断言，每条对应上面踩过的一个真实坑，包括：

- 静态禁令：源码里再出现 `activateWithOptions:` 做激活、把 `hide()` 返回值当判据、或删掉"访达不隐藏"那条不变量 → 直接失败（检查会先剥掉注释，避免"解释为什么不用某 API"的注释自己触发禁令）
- 靶子测试：用 TextEdit 实测"隐藏后窗口真的消失""已运行的 App 经 open 能把窗口带回来""前台确实是它"，全部以窗口数和前台归属作证，不看任何返回值
- 挂起/恢复状态机：设置窗口开着时热键必须全部反注册（否则录制时按的键会被已有热键吃掉），关窗后必须重新注册

`--verify` 会短暂启动/隐藏/退出 TextEdit 作为靶子，约 15 秒。

## 目录

```
main.m          菜单栏 App、空闲闸门、模式分派、日志、CLI
probes.m        唯一的事实来源：空闲时间、窗口快照、前台 App、显示器状态
hotkeys.m       快捷键模型 + Carbon 注册 + 设置窗口（含录制控件）
icons.m         菜单栏图标字形（三种样式，带状态：暂停/已露出/进度环）
showdesktop.m   原生 Show Desktop 按键 + 辅助功能授权处理
tools/          verify.m 回归断言、make_icon.m 图标生成、render_icons.m 预览、audit/ 探针
```

图标全部代码绘制，无外部素材；菜单栏图标和 App 图标共用同一套形状语言（屏幕框 + 地平线 + 太阳）。

## 配置

存在 `UserDefaults`（domain `com.hujie.lull`），改完立即生效，不需要重新编译：
`enabled` · `idleThreshold`（秒，预设 5s–10min）· `desktopMode` · `skipWhenLocked` · `skipWhenFullscreen` · `iconStyle` · `hotkeys`

## 已知限制

- **个别 App 在 `hide()` 之后窗口仍留在屏上**（实测遇到：CC Switch、系统设置）。这类 App 的 `hidden` 标志确实变成了 1，是它自己不让窗口走，`unhide` 再 `hide` 也按不住 —— 不是本项目没藏。实测只有原生「显示桌面」能移开它们（原生模式下所有窗口都会被移到屏幕外，包括这类）。`--doctor` 会把这些 App 单列成"抗隐藏残留"，日志里的复核也会说明原因，不会让你误以为是 bug。
- 隐藏模式下访达自己的浏览窗口会留在屏幕上 —— 这是上面第 1 条（必须留一个前台 App）的必然结果。要连它一起移开就用原生模式。
- 触发精度 ±3 秒（轮询间隔）。
- 快捷键用纯 `⌃` 组合时，如果已被别的程序占用，Carbon 不会报错，表现成"按了没反应"；用 `--doctor` 能看到哪条从未收到按键。
- 原生模式依赖系统 Show Desktop 快捷键保持启用（默认 F11）。
