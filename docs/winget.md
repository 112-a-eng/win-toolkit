# winget 清单

这里是 `112-a-eng.WinToolkit` 的 winget 清单（manifest），用来把本工具包收录进 `winget`。

## 三个文件的分工

| 文件 | 作用 |
| --- | --- |
| `112-a-eng.WinToolkit.yaml` | 版本清单：包 ID + 版本号 |
| `112-a-eng.WinToolkit.installer.yaml` | 安装清单：下载地址 + SHA256 + 安装类型（portable） |
| `112-a-eng.WinToolkit.locale.zh-CN.yaml` | 本地化清单：名称、描述、协议、标签 |

## 本地校验与试装

```powershell
# 1. 校验清单格式是否符合 winget 规范
winget validate --manifest .\winget

# 2. 用本地清单直接安装（会从 Release 下载 EXE 并校验 SHA256）
winget install --manifest .\winget --accept-package-agreements --accept-source-agreements

# 3. 验证
win-toolkit                 # 生成的命令，直接拉起图形工具台
winget list 112-a-eng.WinToolkit

# 4. 卸载
winget uninstall 112-a-eng.WinToolkit
```

## 更新版本时

1. 改 `build/build-exe.ps1` 或脚本 → 推送 → CI 自动编译并发布 Release
2. 从 Release 的 `SHA256SUMS.txt` 里取新的 SHA256
3. 更新本目录三个文件里的 `PackageVersion` 与 `InstallerSha256`、`InstallerUrl`
4. 提交，然后向 [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs) 提 PR

## 提交到官方仓库（可选）

```powershell
# 一次性：fork microsoft/winget-pkgs，然后把 manifest 放进
#   manifests\1\112-a-eng\WinToolkit\1.0.0\
# 再对新仓库开 PR，官方 CI 会跑 winget 校验，通过后即可 winget install
```
