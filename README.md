# MonitorBlock

轻量级 macOS 菜单栏工具，用于在 Apple Silicon Mac 上**随时安全地启用/停用外接显示器、调整多屏布局，并配置关闭屏幕后的自动布局规则**。

## 特性

- **系统级软断开**：动态调用 `CGSConfigureDisplayEnabled`，停用后外接屏从桌面拓扑中移除（窗口收回主屏、鼠标不再滑出、显示器进入无信号待机），需要时一键点亮。
- **实时多屏布局编辑与预设**：可视化拖拽调整显示器相对位置（支持自动贴边吸附与一键设为主屏），可保存多个命名布局预设并在菜单栏一键切换。
- **关闭屏幕后自动切换布局**：为每台外接显示器独立配置“关闭它之后，剩余屏幕的排列方式与主屏”，关闭时自动生效；重新开启该屏时支持自动恢复关闭前的原布局。
- **仅当前会话生效**：严格使用 `kCGConfigureForSession`，不污染系统的 `com.apple.windowserver.displays.plist`，避免重启后永久黑屏。
- **多重安全兜底**：
  - 禁止停用内置屏；
  - 禁止停用最后一块活跃屏幕（例如合盖模式）；
  - 默认勾选“退出时自动恢复外接显示器”；
  - 自动监听显示器拔插与系统休眠唤醒。

## 构建与运行

```bash
# 运行单元测试
swift test

# 打包为标准 macOS 菜单栏应用
chmod +x scripts/bundle_app.sh
./scripts/bundle_app.sh

# 启动应用
open build/MonitorBlock.app
```

也可以将 `build/MonitorBlock.app` 拖入 `/Applications`，并在“系统设置 -> 通用 -> 登录项”中设为开机自启。

## 应急恢复说明

由于本工具严格使用 `kCGConfigureForSession`：
- 如果遇到任何显示状态异常，**重新拔插显示器线缆**或**注销/重启 macOS**即可恢复默认显示状态，无需修改任何系统文件。
