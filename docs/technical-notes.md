# 技术说明

项目主要面向「没有内置屏的 Mac 主机（Mac mini / Mac Studio / Mac Pro）+ 第三方外接显示器」这个组合，因此亮度与显示器音量都走显示器的 DDC/CI 通道，而不是系统面向内置屏的私有 API。

README 里讲的是「能做什么」，这里记录「怎么做的」和背后的取舍，方便贡献者上手，也方便遇到奇怪问题时定位。

## 架构一览

| 模块 | 技术 | 说明 |
|---|---|---|
| 亮度 | IOKit `IOAVService` + DDC/CI | 直连显示器 I2C，一次写入约 2.7 ms |
| 显示器音量 | DDC/CI VCP `0x62` | 显示器自带音箱的音量 |
| 系统音量 | CoreAudio `'vmvc'` / `'mute'` | 读写默认输出设备的虚拟主音量 |
| 快捷键 | Carbon `RegisterEventHotKey` | 系统级注册，不需要 TCC 授权 |
| 代理读取 | SystemConfiguration `SCDynamicStoreCopyProxies` | 进程内读取，约 1 ms |
| 代理写入 | `networksetup` 子进程 | admin 组预授权，不弹窗；单次约 75 ms |
| HUD | `NSPanel`（`.nonactivatingPanel`） | 不抢焦点，跨 Space 显示 |

## 目录结构

```
Sources/
  main.swift              程序入口，创建 NSApplication
  MenuBarController.swift 状态栏项、菜单与动作分发
  Hotkeys.swift           键码、修饰键与配置文件模型
  HotkeyManager.swift     Carbon 热键注册与回调
  DDC.swift               IOAVService + DDC/CI 读写显示器
  Audio.swift             CoreAudio 系统音量与静音
  Proxy.swift             系统代理读取与切换
  HUD.swift               屏幕下方的浮动提示面板
tools/
  make-icons.swift        生成应用图标与菜单栏图标
  preview-icons.swift     生成图标对比预览图
build.sh                  构建 app bundle 并做 ad-hoc 签名
icons/                    构建用的图标资源（由 tools/make-icons.swift 生成）
docs/
  technical-notes.md      实现细节与设计取舍
  images/                 README 用到的截图与渲染图
```

## 设计取舍

**为什么亮度不用 `DisplayServices`**：那套私有 API 面向内置屏。在没有内置屏的 Mac 上实测返回 `kIOReturnUnsupported`，只能走 DDC。

**为什么快捷键不用 `CGEventTap`**：`CGEventTap` 需要辅助功能授权，会弹窗。Carbon 的 `RegisterEventHotKey` 在注册热键这条路径上不需要授权。

**为什么用 ⇧ 作为默认修饰键**：`⌘F5` 是旁白开关，`⌥⌘F5` 是辅助功能快捷键，`⌥⌘F8` 是缩放。⇧F1–⇧F12 在 macOS 上没有默认绑定，既不与系统快捷键竞争，也不会挤占旁白用户的组合键。

**为什么代理写入不用进程内 API**：`SCPreferencesPathSetValue` 看起来能改，但 `SCPreferencesCommitChanges` 在非 root 进程里会静默失败（代理状态不变），所以只能交给 `networksetup`。而 `system.preferences.network` 这条授权规则对 admin 组成员是预授权的，子进程方式反而不弹窗。

**为什么代理三项一起切**：只开一半协议会让部分流量绕过代理，故障现象很难排查，所以 HTTP / HTTPS / SOCKS 作为一个整体开关。

**为什么显示器要支持重连**：初始化可能在显示器就绪之前跑（登录时、唤醒瞬间、刚插上线）。早期版本在探测失败后把可用状态固定为 false，亮度会一直失效到重启；现在每个入口都会先尝试重连，失败才放弃。

**为什么 HUD 用非激活面板**：`NSPanel` + `.nonactivatingPanel` 不会抢走当前窗口的键盘焦点，调亮度时不会打断正在输入的内容。

## 配置文件

路径：`~/Library/Application Support/Lumen/config.json`（首次启动时自动生成，菜单里「快捷键 → 打开配置文件…」可直接定位）。

```json
{
  "bindings": {
    "brightnessUp":   { "key": 122, "modifiers": 512 },
    "brightnessDown": { "key": 120, "modifiers": 512 },
    "volumeDown":     { "key": 96,  "modifiers": 512 },
    "volumeUp":       { "key": 97,  "modifiers": 512 },
    "toggleMute":     { "key": 118, "modifiers": 512 },
    "openPanel":      { "key": 103, "modifiers": 512 }
  },
  "brightnessStep": 0.0625,
  "volumeStep": 0.0625,
  "volumeTarget": "system"
}
```

- `key` 是 macOS 虚拟键码：F1=122、F2=120、F3=99、F4=118、F5=96、F6=97、F7=98、F8=100、F9=101、F10=109、F11=103、F12=111；方向键 ↑=126、↓=125、←=123、→=124
- `modifiers` 是 Carbon 修饰键掩码：⌃=4096、⌥=2048、⇧=512、⌘=256，可相加。例如 `512` = ⇧，`256` = ⌘，`6144` = ⌃⌥，`768` = ⇧⌘
- `brightnessStep` / `volumeStep` — 每次按键的变化量（1/16 = 0.0625）
- `volumeTarget` — `"system"` 或 `"monitor"`

改完在菜单里点「快捷键 → 重新载入配置」即可生效，不用重启。某个组合键已被其他程序占用时，菜单里对应条目会标出「⚠︎ 占用」。

## 图标生成

应用图标和菜单栏图标都由 `tools/make-icons.swift` 用 AppKit 代码绘制，不是提交的二进制素材——改颜色或几何后重跑脚本即可，不会出现「找不到原始设计文件」的问题。

```bash
swift tools/make-icons.swift icons warm   # 生成 PNG、iconset 和菜单栏图标
iconutil -c icns icons/AppIcon.iconset -o icons/AppIcon.icns
```

`build.sh` 会把 `icons/AppIcon.icns` 和 `icons/menubar.png` 拷进 bundle，并在 Info.plist 里声明 `CFBundleIconFile`。菜单栏图标是 template 图（纯黑 + alpha），系统会按浅色/深色菜单栏自动上色。

设计上让**左边太阳、右边声波**共用同一个圆心：太阳圆盘同时充当声波的发射源，这样一个图形同时说清「亮度」和「音量」两件事，而不是两个不相关的图标拼在一起。

`swift tools/preview-icons.swift icons docs/images/icon-preview.png` 会输出各候选在实际尺寸（220 / 64 / 32 / 16）下的对比图，对应 README「更多」一节里那张图。

## 构建与签名

```bash
./build.sh                      # 产出 build/Lumen.app
cp -R build/Lumen.app /Applications/
```

- 用 `swiftc -O -whole-module-optimization` 编译，目标默认 `arm64-apple-macos13.0`；在 Intel Mac 上构建需要改 `build.sh` 里的 `-target`
- 签名是 `codesign --sign -`（ad-hoc），没有公证。自行构建的 app 直接运行即可；若经过网络传输，可能还需要 `xattr -dr com.apple.quarantine build/Lumen.app`
- 依赖 Xcode Command Line Tools 的 `swiftc`：`xcode-select --install`
- Info.plist 里 `LSUIElement = true`，因此 app 不显示 Dock 图标

## 已知限制

- **内置屏**：亮度与显示器音量的通路是外接屏的 DDC/CI，MacBook 内置屏不在覆盖范围内
- **DDC 兼容性**：并非所有显示器都实现 DDC/CI，部分型号需要先在显示器 OSD 里打开「DDC/CI」选项；个别型号对亮度以外的 VCP 码支持有限
- **单显示器**：程序会选中第一台应答 DDC 读请求的外接屏，多屏场景下暂不支持逐个选择
- **Fn 键**：不少外接 Windows 键盘的 Fn 不会上报给 macOS——单独按收不到事件，事件层也不出现 `maskSecondaryFn`，`Fn+F1` 与 `F1` 的 HID 用法相同。因此只能绑定真实修饰键（⇧ / ⌃ / ⌥ / ⌘）
- **代理依赖 `networksetup`**：该命令位于 `/usr/sbin/networksetup`，程序按绝对路径调用；如果系统未来调整该工具的行为，代理开关需要跟着改
