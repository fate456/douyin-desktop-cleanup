抖音会话与残留清理工具
====================

本工具的目标：打开抖音正常使用；从后台彻底退出主程序后，
自动拦截出站连接、清理安装目录内残留，并检查进程是否归零。
关闭窗口但主程序仍在后台时继续等待。用入口启动才能挂载会话守护。

使用
----
日常双击 Start-Douyin.bat。防火墙管理需要一次 UAC 提权，
抖音应用通过普通用户的交互式任务启动，临时启动任务随后移除。
安装目录读取系统注册信息，无需在代码内填写本机路径。
无法自动识别时，设置 DOUYIN_ROOT 环境变量或传入 -DouyinRoot。

Run-DouyinKiller.bat 提供体检、清理、隔离、还原和快捷方式菜单。
首次配置或希望禁用自启时执行 Lockdown，配置前会记录修改前状态。
Install-DouyinShortcut.bat 生成当前项目位置对应的开始菜单快捷方式。
项目搬家后重新运行该安装器；项目本身不携带本机 .lnk。

命令示例（在项目目录执行）
------------------------
只读体检：
  powershell -NoProfile -ExecutionPolicy Bypass -File .\DouyinKiller.ps1 -Action Status
首次配置：
  powershell -NoProfile -ExecutionPolicy Bypass -File .\DouyinKiller.ps1 -Action Lockdown
打开并自动收尾：
  powershell -NoProfile -ExecutionPolicy Bypass -File .\DouyinKiller.ps1 -Action Session
已经退出后的手动收尾：
  powershell -NoProfile -ExecutionPolicy Bypass -File .\DouyinKiller.ps1 -Action Finish
仅清理进程：
  powershell -NoProfile -ExecutionPolicy Bypass -File .\DouyinKiller.ps1 -Action Clean
恢复本工具记录的启动配置并移除隔离：
  powershell -NoProfile -ExecutionPolicy Bypass -File .\DouyinKiller.ps1 -Action Unlock
恢复开始菜单快捷方式：
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-DouyinShortcut.ps1 -Revert
验证开始菜单快捷方式：
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-DouyinShortcut.ps1 -Verify

收尾与恢复规则
--------------
默认每 1 秒检查后台主程序，退出后确认 2 秒，随后开始收尾。
清理先处理守护组件，再处理其他安装目录内进程，最多重试 5 轮。
结束进程前核对可执行路径和创建时间；重开主程序时停止清理并放行。
未知路径不会仅凭名称被结束，也不会被误报为已确认零进程。
发生 API 或复查失败时返回非零退出码，日志记录具体原因。

每次会话启动和收尾时重新发现 exe，补齐新增文件的规则，
移除本工具的失效/重复规则，并校验程序路径、规则数量和启用状态。
守护通过就绪事件确认启动，互斥锁防止重复守护和并发修改。
启动失败后尝试重新拦截网络，后台主程序未启动时也会超时收尾。

服务启动类型、任务启用状态、延迟启动设置和 HardMode 的文件 ACL，
均在本工具修改前记录；重复配置保留第一次记录的值。
Unlock 恢复记录的配置，不会自动启动服务。
旧版未记录的历史原始设置无法推算；没有快照时保留服务和第三方任务，
只移除本工具的隔离。开始菜单快捷方式使用独立原始备份恢复。

本地数据与隐私
--------------
日志、缓存、恢复快照、原始快捷方式和历史恢复资料保存于：
  %LOCALAPPDATA%\DouyinCleanup
内部任务显式继承该目录，SYSTEM 与用户会话共用对应配置。
日志默认遮蔽本机目录、账户和计算机名，轮转后最多保留 6 个日志文件。
Status 默认不写文件；-SaveStatus 会将遮蔽路径后的报告保存到本机数据目录。
项目源码和分享包不包含这些运行资料；.gitignore 也排除常见本地状态文件。
旧项目中的本地资料已经移出项目，移动后核对了文件哈希。

测试与审查
----------
模拟回归：
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Regression.Tests.ps1
真实 OS 隔离测试（需要管理员；使用临时程序和专属规则，不启动实际抖音）：
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Integration.Tests.ps1
快捷方式隔离测试（不会修改实际开始菜单）：
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Shortcut.Tests.ps1
项目和压缩包敏感信息审查：
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Review-Project.ps1
按明确文件清单构建分享包（不包含本地 Git 元数据和运行资料）：
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Release.ps1

artifacts 内保存遮蔽本机信息的测试、实机验收和隐私审查记录。
真实使用验收：用户确认正常播放并退出后台；随后检查主程序、
安装目录内进程及会话守护均为 0，所有当前出站规则均已恢复启用。
分享包使用明确文件清单构建，并检查解压后的每个条目。

边界
----
只识别当前配置的安装目录；路径无法读取时保留进程并报未确认。
如果操作系统拒绝结束进程、第三方重新启动应用或防火墙策略被外部改动，
脚本不能强行绕过系统限制，应依据错误记录处理。
已完成正常播放、后台退出和进程归零验收，没有把规则配置当成抓包证明。

实现参考（微软官方）
------------------
任务的交互登录与 Limited 权限：
  https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtaskprincipal
删除启动任务不会结束已启动程序：
  https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/schtasks-delete
