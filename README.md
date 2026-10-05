# Windows 常用指令集

[![构建 EXE](https://github.com/112-a-eng/win-toolkit/actions/workflows/build-exe.yml/badge.svg)](https://github.com/112-a-eng/win-toolkit/actions/workflows/build-exe.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-0078D4.svg)](#)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE.svg)](#)

给 Windows 用户的一套「命令行 + 图形界面」工具集：**19 章命令速查手册** + **13 个实用脚本**
+ **零依赖图形工具台**，外加一个 245 KB 的单文件 EXE 和免管理员的 MSI 安装包。
纯 PowerShell + WinForms 实现，不需要安装任何第三方组件。

![图形工具台](docs/screenshot.png)

## 快速开始

| 方式 | 做法 | 适合 |
| --- | --- | --- |
| **图形版（推荐）** | 到 [Releases](https://github.com/112-a-eng/win-toolkit/releases/latest) 下载 `win-toolkit.exe`，双击即用 | 不想敲命令 |
| **MSI 安装** | 同一页面下载 `win-toolkit.msi` 双击安装（按用户安装，**不需要管理员**） | 想进「设置 → 应用」里管理 |
| **winget** | `winget install 112-a-eng.WinToolkit` | 喜欢包管理 |
| **源码运行** | `git clone` 后双击 `启动图形工具台.bat`；只要控制台菜单就运行 `scripts\run.bat` | 想改脚本 |

> EXE 只是「启动器 + 资源包」，脚本始终是磁盘上的明文 `.ps1`：
> - 单独放在任何地方 → 自动解包到 `%LOCALAPPDATA%\WinCommandToolkit\app` 再启动
> - 和脚本放在同一目录 → 直接使用旁边那份，改完重开就生效，不必重新打包

## 图形工具台

左侧选工具、右侧填参数、点「▶ 运行」，输出实时彩色显示；任务跑在独立 Runspace 里，界面不会卡死。

- **15 个入口**：13 个功能工具 + 常用命令速查 + 系统工具面板（一键打开服务 / 设备管理器 / 磁盘管理等 18 个系统面板）
- 枚举参数用下拉框选，目录和 CSV 路径带「...」选择按钮
- 危险操作（结束进程 / 清空回收站 / 镜像同步 / 真正改名 / 重置网络）运行前弹窗二次确认
- 非管理员启动时，右上角提供「以管理员身份重启」
- 觉得字小可以加缩放：`.\图形工具台.ps1 -UiScale 1.5`（默认 1.3，布局结构不变、只等比放大）
- 界面自检（不开窗口）：`powershell -ExecutionPolicy Bypass -File .\图形工具台.ps1 -SelfTest`

## 工具一览（15 个）

| 工具 | 做什么 |
| --- | --- |
| 系统信息速查 | OS / CPU / 内存 / 磁盘 / 显卡 / 网络 / 开机时长 / 补丁，WMI 被禁时自动降级 |
| 网络一键诊断 | 网卡 → IP/网关 → 公网 → DNS → 目标连通 → HTTP，最后给修复建议 |
| 端口占用查询 | 查端口被哪个进程占用（含路径与所属用户），可选直接结束 |
| 临时文件清理 | Temp / 更新缓存 / 回收站 / 图标缓存，默认只预览 |
| 文件夹备份 | robocopy 增量或镜像同步，自动写日志 |
| 进程 / 服务速查 | 占资源 Top 进程、异常自启服务、启动项、监听端口 |
| 大文件查找 | 按体积与未修改天数找大文件，可导出 CSV |
| 批量重命名 | 前后缀 / 正则替换 / 序号，默认预览，加 `-Apply` 才执行 |
| 文件哈希校验 | MD5/SHA1/SHA256/SHA512，支持按校验文件逐项比对 |
| 局域网扫描 | 并发 ping 扫网段 + 读 ARP 表，列出在线主机与 MAC |
| 服务管理 | 查询筛选服务，可启停 / 重启 / 改启动类型，含关键服务禁用风险提示 |
| 环境变量 | 查看 / 设置 / 删除用户级与系统级变量，PATH 追加自动去重 |
| 系统修复 | SFC / DISM / DNS 刷新 / 网络重置 / 更新缓存 / 图标缓存，标明耗时与风险 |
| 常用命令速查 | 把常用命令清单直接输出到界面 |
| 系统工具面板 | 一键打开服务 / 设备管理器 / 磁盘管理 / 事件查看器 / 启动文件夹等 |

## 文档

| 文档 | 内容 |
| --- | --- |
| **[docs/命令速查.md](docs/命令速查.md)** | **19 章命令速查手册**：文件目录、系统信息、进程服务、网络排查、磁盘修复、注册表组策略、计划任务、winget、电源关机、远程传输、文本处理、压缩校验、故障速修、批处理语法、快捷键、PowerShell 管道 |
| [docs/winget.md](docs/winget.md) | winget 清单说明与提交流程 |

## 构建与发版

```powershell
.\build\build-exe.ps1              # 打包单文件 EXE（用系统自带 csc.exe，内嵌 19 个文件）
.\build\build-msi.ps1              # 打包 MSI（WiX v3，首次运行自动下载工具链）
.\build\test-gui-handlers.ps1      # 界面事件回归测试（防按钮点了报「找不到指定的文件」）
.\build\capture-screenshot.ps1     # 自动开窗 + 点运行 + 抓图，重新生成上面的截图
```

CI（`.github/workflows/build-exe.yml`）在 push / PR 时编译 EXE + MSI 并跑回归测试；
**推送 `v*` tag 会自动把 `win-toolkit.exe`、`win-toolkit.msi`、`SHA256SUMS.txt` 发布到 Release**。

**MSI 细节**：按用户安装到 `%LOCALAPPDATA%\Programs\Windows常用指令集`，装完出现在「设置 → 应用」里。
实测流程：安装 → 29 个文件 + 开始菜单/桌面快捷方式 + 卸载项注册 → 真实启动图形界面 → 卸载 → 全部清理。

## 注意事项

- 首次运行若提示「禁止运行脚本」，执行一次 `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`；EXE 与 MSI 不需要这一步
- 脚本内含中文，**改动后必须存成 UTF-8（带 BOM）**，否则 Windows PowerShell 5.1 会按 GBK 解析导致乱码
- 脚本自带降级：环境禁用 WMI/CIM 时（受限账户、企业策略）会自动改用注册表、性能计数器、`ipconfig`、`netstat`、`ping.exe`

## 安全提醒

1. `format` `diskpart clean` `del /s` `Remove-Item -Recurse -Force` `reg delete` `takeown /r` 都是**不可逆**操作，执行前先确认路径
2. 改注册表 / 组策略前先 `reg export` 备份
3. 批量操作先用预览模式（本工具包脚本多支持 `-DryRun`，图形界面会在危险操作前二次确认）
4. 只对自己有权限的设备做扫描与端口探测

## License

[MIT](LICENSE)