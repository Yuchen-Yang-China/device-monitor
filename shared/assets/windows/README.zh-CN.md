# Windows 图标素材

本目录用于通过局域网共享给 Windows Monitor 项目，不需要共享整个 Mac Monitor 源码仓库。

文件：

- `DeviceMonitor.ico`：Windows 应用图标，可用于可执行文件、窗口和安装包。
- `DeviceMonitor-1024.png`：1024 × 1024 PNG 源图，适合生成其他尺寸或用于商店素材。

交给 Windows 上的 Codex：

> 请把 DeviceMonitor.ico 复制进 Windows Monitor 项目的 Assets 目录，并将其设置为应用窗口、生成的 exe 和安装包图标。若项目是 .NET，可在项目文件中设置 ApplicationIcon；同时保留 PNG 作为高清源素材。修改后请完成 Release 构建并检查任务栏、窗口标题栏和 exe 文件图标。
