# MiniControl

MiniControl 是原生 macOS 菜单栏工具，面向用 MacBook 的键盘和触控板，通过 Universal Control 操作 Mac mini 及其外接显示器的工作流。

## 功能与工作流

- 显示器图标 / `⌃⌥M`：通过 SSH 在 Mini 执行 `/usr/bin/caffeinate -u -t 3`，请求唤醒 Mini 自己的显示器。Mini 本体须保持运行；命令成功不代表屏幕已确认亮起。
- 光标图标 / `⌃⌥U`：检查并按需连接系统“连接键盘和鼠标至”中的目标；需要时重扫 Air 和 Mini。强制修复使用 `killall UniversalControl`。
- 可选 UC 日志事件监听，自动恢复含 30 秒启动保护和冷却；登录启动、日志轮转及手动导出辅助功能树。

流程：Air 点击图标 → SSH → Mini 的显示器唤醒 → Apple Watch（可选）解锁 → Universal Control 共享键鼠。Apple Watch 不负责唤醒显示器。

SSH 失败时可短暂尝试 AirPlay：连接 → 检测虚拟显示器 → 断开 → 核实清理。SSH 返回成功但屏幕仍未亮时可手动选择备用脉冲。正常状态应是两台 Mac 各自显示桌面，UC 只共享键鼠。系统拒绝、应用崩溃或连接迟到时不能保证自动清理成功；请检查并手动停止残留的 AirPlay。

## 需求与设置

需要 Apple Silicon Mac、macOS 13 或更高版本、支持 Universal Control 的 MacBook 和 Mac mini，且两台设备满足 Apple 的 Wi-Fi、蓝牙、Handoff、同一 Apple 账户等要求。Mini 开启“系统设置 → 通用 → 共享 → 远程登录”，推荐 SSH 密钥认证；Mini 需在屏幕关闭时保持运行。Apple Watch 可选。

先在终端完成 SSH 主机密钥验证和免密认证，然后在 MiniControl 设置中填写目标设备显示名称、SSH 主机名及用户名（示例：`user@mac-mini.local`）。应用使用非交互 SSH 和严格主机密钥验证，不保存密码或私钥，也不会自动信任未知主机。辅助功能权限用于系统设置中的键鼠连接和 AirPlay 清理；授权后重启应用。

## 安装与构建

Release ZIP 包含 `MiniControl.app`。此版本仅为 **ad hoc 签名，未经过 Apple 公证**；GitHub 下载的应用可能被 Gatekeeper 阻止或提示。请在系统设置的“隐私与安全性”中查看提示并自行决定是否打开。不要关闭 SIP 或全局关闭系统安全功能。

本机源码构建：安装 Apple 命令行开发工具，在项目目录运行 `make release`。只使用系统 Swift / AppKit / SwiftUI，无 Electron、Node、Python 运行时或第三方依赖。未包含 Xcode 工程。

## 安全、资源与限制

不修改 SIP、不安装内核扩展或 root daemon、不上传遥测、不调用云服务。标准 SSH 会访问用户的 SSH 配置和密钥。日志在 `~/Library/Logs/MiniControl/`，自动轮转（约 5 MiB/文件，总计约 30 MiB）；辅助功能树只在用户主动选择时导出，可能包含设备名称。Debug 模式重启后关闭。

本机一次 10 分钟测试：主进程约 15–27 MiB，`log stream` 约 4 MiB，采样大多接近 0% CPU，但日志监听出现过短时峰值；结果因机器和日志活动而异。

UC 自动监听依赖日志关键词，不一定能判断是否属于目标设备或证明恢复成功，可能误触发。需要时可从 UC 菜单关闭自动修复。AirPlay 连接建立或断开可能失败，旧连接的启动迁移和重启后登录项尚未充分验证。无已知第三方代码：实现使用 macOS 公共框架及系统命令，受开源项目设计启发，但未引入其二进制或复制代码。

MIT 许可证。请参考 [调试指南](docs/DEBUG.md)。

## 参考

按项目需求，UC 恢复思路参考了 [uc-force](https://github.com/rappdw/uc-force)；本项目独立实现，没有引入其二进制或复制其源码。该参考仓库在本次检查时未提供可识别的 SPDX 许可证信息。
