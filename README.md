# 抖音清道夫 · Douyin Desktop Cleanup

**刷视频时正常使用，退出后台后自动清理抖音残留进程。**

[![Windows](https://img.shields.io/badge/Windows-10%20%2F%2011-0078D4?logo=windows)](https://github.com/fate456/douyin-desktop-cleanup)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell)](https://github.com/fate456/douyin-desktop-cleanup)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Checks](https://github.com/fate456/douyin-desktop-cleanup/actions/workflows/checks.yml/badge.svg)](https://github.com/fate456/douyin-desktop-cleanup/actions/workflows/checks.yml)

[**下载最新版**](https://github.com/fate456/douyin-desktop-cleanup/releases/latest) · [详细使用说明](README.txt) · [反馈问题](https://github.com/fate456/douyin-desktop-cleanup/issues)

> A Windows PowerShell tool for Douyin desktop: launch normally, then automatically clean up verified leftover processes after the app fully exits from the background. Includes outbound firewall isolation and reversible configuration changes.

## 为什么做这个工具？

退出抖音后，还想确认后台有没有残留？这个工具把启动、等待退出、清理和复查串成一次会话，免去每次打开任务管理器手动处理。

| 使用阶段 | 工具行为 |
| --- | --- |
| 通过项目入口打开抖音 | 放行出站连接，启动会话守护，以普通用户权限启动抖音 |
| 正常刷视频，或关闭窗口但仍留在后台 | 等待主程序退出，保护正在使用的进程 |
| 从托盘或后台彻底退出主程序 | 确认退出后启用出站隔离，清理安装目录内已确认的残留进程 |
| 清理结束 | 再次扫描；无法确认或清理失败时明确报错 |

**这里的“退出”是退出后台主程序。** 仅点窗口的关闭按钮，如果抖音仍在托盘运行，守护会继续等待。默认每 1 秒检查，退出确认时间为 2 秒，清理还需要一定时间。

## 三步开始

1. 从 [Releases](https://github.com/fate456/douyin-desktop-cleanup/releases/latest) 下载 `DouyinCleanup.zip`，解压到一个固定目录。
2. 日常双击 **`Start-Douyin.bat`**，允许 UAC 提示。管理员权限用于防火墙控制，抖音本身以普通用户权限启动。
3. 正常使用抖音；用完后从托盘或后台彻底退出，工具会自动收尾。

面向 Windows 10 / 11，依赖系统自带的 Windows PowerShell 5.1、Windows 防火墙和任务计划程序。安装目录默认从注册表识别；识别失败时可设置 `DOUYIN_ROOT` 环境变量，或使用 `-DouyinRoot` 参数。

可选配置：打开 **`Run-DouyinKiller.bat`** 使用菜单。`Lockdown` 会记录修改前状态，再禁用识别到的抖音自启服务和任务；`Unlock` 恢复记录的状态并移除本工具的隔离。需要开始菜单入口时，运行 **`Install-DouyinShortcut.bat`**。

## 做了哪些可靠性处理？

- **按实际路径识别进程**：只处理配置的抖音安装目录内、路径可确认的进程；结束前再核对路径和创建时间。
- **保护正常使用和重新打开**：主程序存活时保留组件；收尾期间检测到重新打开会停止清理并恢复放行。
- **守护先就绪再启动**：启动握手与互斥锁防止重复守护和并发修改；启动失败也会尝试恢复隔离。
- **跟随安装目录变化**：每次会话重新发现 exe，补齐新增规则，移除本工具的失效、重复规则。
- **配置可以恢复**：修改前保存服务、任务和可选 ACL 快照；重复配置保留首次状态。快捷方式单独备份原始字节。
- **本地资料留在本机**：日志、缓存、恢复快照位于 `%LOCALAPPDATA%\DouyinCleanup`，日志遮蔽本机路径、账户和主机名。

## 验证与边界

当前版本完成了 **44 项模拟回归**、真实 Windows 隔离测试和快捷方式测试。在一次实际抖音会话中，使用者确认视频播放正常并退出后台，随后检查到主程序、安装目录内进程和会话守护均为 **0**。脱敏记录见 [artifacts](artifacts)。GitHub Actions 会运行模拟回归与源码隐私扫描。

实际验收来自一台 Windows 设备；不同抖音版本和系统策略仍可能影响结果。路径不可读取、系统拒绝结束进程或第三方再次启动应用时，工具会报告失败或未确认。出站规则的配置验证不等同于网络抓包验证。

恢复只能依据本工具保存的快照；旧版本没有记录的原始设置无法推算。`Unlock` 不会自动启动服务。**请保留本地数据目录，直到不再需要恢复。**

## 常用命令

在项目目录运行；涉及系统修改的操作需要管理员权限。

```powershell
# 只读体检
powershell -NoProfile -ExecutionPolicy Bypass -File .\DouyinKiller.ps1 -Action Status

# 正常打开，并在退出后台后自动收尾
powershell -NoProfile -ExecutionPolicy Bypass -File .\DouyinKiller.ps1 -Action Session

# 已退出抖音后的手动收尾
powershell -NoProfile -ExecutionPolicy Bypass -File .\DouyinKiller.ps1 -Action Finish

# 恢复记录的配置并移除隔离
powershell -NoProfile -ExecutionPolicy Bypass -File .\DouyinKiller.ps1 -Action Unlock
```

开发与验证命令见 [README.txt](README.txt)。真实 OS 测试使用临时程序及专属规则；不会启动实际抖音。

## 反馈与参与

欢迎在 [Issues](https://github.com/fate456/douyin-desktop-cleanup/issues) 提交 Windows 版本、抖音版本、复现步骤和脱敏后的错误信息。请先检查附件，移除用户名、本机路径、恢复快照和其他个人资料。

如果它帮你省去了手动清理后台的麻烦，欢迎点一个 **Star ⭐**，也欢迎提交改进。

MIT 开源许可。独立社区工具，与抖音官方没有关联。
