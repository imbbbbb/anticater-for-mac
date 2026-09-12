# 反方向ANTICATER

[English](README.en.md)

ANTICATER 桌面音量旋钮配置工具的 macOS 原生版本。在原版 app 的基础上二次开发，功能与协议与其保持一致，代码使用 Swift + SwiftUI 重新实现，不包含原版的任何源码或二进制文件。

原版为 x86_64 单架构 Qt 程序，在 Apple Silicon 设备上需经 Rosetta 2 运行，而 Rosetta 2 将于 macOS 28 移除。本项目提供原生 arm64 实现，并按 macOS 平台惯例重新设计了界面。

版本 1.2 · 要求 macOS 13 或更高版本 · 仅供非商业使用

---

![主界面](docs/images/main-window.png)

## 功能

可配置旋钮的五个物理动作：左旋转、右旋转、按压、长按左旋、长按右旋。每个动作支持以下类型：

| 类型 | 说明 |
|---|---|
| 单个按键 | 任意键盘按键，支持多段序列与延时 |
| 组合键 | Ctrl / Shift / Alt / Command 任意组合 |
| 多媒体 | 音量、播放控制等 Consumer 页功能 |
| 鼠标划屏 | 鼠标按键、滚轮、四方向划屏、点赞 |
| Procreate | 原版对应页面的 31 条预设（名称说明见下） |

另支持灯效切换、菜单栏常驻与开机自启。

配置保存在旋钮固件中，设置完成后无需保持本软件运行，更换电脑后配置依然有效。本软件仅用于修改配置。

![Procreate 预设](docs/images/procreate.png)

## 安装

从 [Releases](../../releases) 下载 DMG，将应用拖入「应用程序」。

应用为 ad-hoc 签名，未申请 Apple 开发者证书，也未经公证，首次打开会被 Gatekeeper 拦截：

- macOS 14 及更早：右键点击图标选择「打开」，在系统提示框中再次点击「打开」。
- macOS 15 及更高：右键「打开」已不再提供绕过入口。请先双击一次（会被拒绝），再进入「系统设置 → 隐私与安全性」，在底部找到该应用并点击「仍要打开」。

应用为 arm64 单架构，**仅支持 Apple Silicon 机型**，Intel Mac 无法运行。

运行不需要「输入监控」等隐私权限，配置通道位于厂商自定义页 `0xFF00`，非键盘页。

## 使用

修改配置需连接 USB 数据线。蓝牙侧为独立的 HID 设备，不提供 `0xFF00` 配置接口。

在左侧选择旋钮动作，在右侧选择类型并修改设置，通过右上角「写入旋钮」提交。修改先暂存于编辑区，提交前可随时放弃；写入完成后自动回读校验，未写入成功的项目会明确列出。

数据线中途拔出时会自动断开连接并保留编辑区内容，插回后自动重连。

### 连不上时

界面提示「没找到旋钮」时，按以下顺序排查：

1. 确认走的是 USB 数据线，而非蓝牙或 2.4G 接收器——配置通道只存在于 USB 接口。
2. 更换数据线。部分线材只有供电线芯，接上能亮灯但不会枚举出 USB 设备。
3. 绕开扩展坞与 USB Hub，直接插入机身接口。
4. 退出原版 ANTICATER 软件。设备被其他进程占用时无法打开。

仍然无法连接时，打开菜单栏中的「诊断信息…」（报错弹窗里的「查看诊断信息…」通向同一窗口），核对内容后点「拷贝全部」，贴入 [issue](../../issues)。诊断内容包含：

- 本机 HID 设备清单：厂商 ID、产品 ID、usage pairs、连接方式
- 本次运行的事件日志：连接、打开、读写操作及其结果，保留最近 500 条

事件日志仅保存在内存中，不写入磁盘，退出应用即消失；固定保留最近 500 条，更早的自动被覆盖，因此不会持续增长，也无需定期清理。

日志默认**不记录报文内容**，因此不会包含所配置的按键与宏。确需排查协议层问题时，按这个顺序操作：

1. 在诊断窗口打开「记录详细日志」；
2. 回去把问题**重新复现一次**；
3. 回到诊断窗口点「刷新」，再「拷贝全部」。

开关只对打开之后发生的操作生效，不会补全此前已记录的条目——顺序颠倒会得到一份没有报文的日志。该开关不会持久化，重启应用后自动关闭。

诊断内容不会自动上传，仅在点击「拷贝全部」时写入剪贴板。

也可在终端中运行同一诊断：

```bash
"/Applications/ANTICATER 原生版.app/Contents/MacOS/anticater-dump" --diagnose
```

## 联网行为

本软件唯一的联网行为是检查更新：向 GitHub 的公开 API 请求本仓库最新 Release 的版本号，与当前版本比较。请求不携带任何标识信息，也不上报本机情况。

该功能可在菜单栏面板中通过「启动时检查更新」关闭，关闭后仅在手动点击「检查更新」时发起请求。除此之外，本软件不进行任何网络通信。

## 构建

```bash
swift build -c release
./make-app.sh          # 生成 .app
./make-dmg.sh          # 生成 DMG
./Tools/make-icon.sh   # 重新生成图标（改了 make-icon.swift 才需要）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

运行测试需指定 `DEVELOPER_DIR`。若 `xcode-select -p` 指向 CommandLineTools，其中不包含 XCTest。

版本号的唯一来源为 `Sources/AntiCaterCore/Version.swift`，`make-app.sh` 据此填写 Info.plist，发布 Release 时应使用相同值。

## 项目结构

```
Sources/
  AntiCaterCore/     协议编解码、HID 传输、链路监测、更新检查（不依赖 UI）
  AntiCaterUI/       SwiftUI 界面与 DeviceModel
  AntiCaterApp/      可执行目标，只有 main.swift
  anticater-dump/    命令行工具，读取当前配置
  anticater-restore/ 应急工具，会无条件覆盖左右旋配置，使用前请阅读源码注释
Tests/
  AntiCaterCoreTests/  协议编解码与版本比较
  AntiCaterUITests/    DeviceModel 状态机，用假设备模拟拔线与写入失败
Tools/               图标生成脚本
```

界面单独成库（`AntiCaterUI`）而不是直接放在可执行目标里，唯一目的是让 `DeviceModel` 能被测试引用 —— SwiftPM 的 executableTarget 无法作为测试依赖。

## 协议说明

设备协议无公开文档，本项目的实现基于对自有设备通信过程的观察。配置接口为 VID `0x514C` / PID `0x8850`，HID usage page `0xFF00` usage `0x01`，Report ID 3，收发定长 64 字节。

部分编号为推断结果，并非全部经过验证。代码注释中逐条标注了各项来源，其中需要说明的有两处：

- `Proto.mouseActions`：四个划屏方向的编号由排列顺序反推，另有三组修饰键组合由同一修饰键的对称项推得。
- `Proto.procreatePresets`：31 个键码经过验证；键码与名称的对应关系为推断结果，仅首尾两条（⌘] 放大 1%、⌘Z 撤销）经过独立验证。使用时建议以键码为准。

本项目未实现固件升级或刷写功能。

## 免责声明

本项目为非官方实现，与 ANTICATER 厂商无隶属关系，亦未获得其认可，不包含原版程序的任何代码或二进制文件。

如厂商认为本项目存在不妥之处，可通过 issue 联系，本项目将配合处理。

使用本软件修改旋钮配置的后果由使用者自行承担。

## 许可

[PolyForm Noncommercial License 1.0.0](LICENSE)。允许在个人使用、学习、研究等非商业场景下使用、修改与分发，商业用途不在授权范围内。
