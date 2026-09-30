# 显示器信源切换器 (MonitorSourceSwitcher)

一键切换 2 台 Mac 在同一显示器的显示信源。如：MacBook Pro 连接 TypeC / Mac Mini 连接 HDMI。支持手动检测校准信源代码。

By Jaret

## 功能

- 状态栏小图标，左键一键切换 TypeC / HDMI 信源
- 图标随当前信源自动切换（MacBook / Mac Mini）
- 切换中显示 loading 动画
- 右键菜单：切换信源 / 检测显示器信息（交互向导）/ 关于 / 退出
- 换电脑/换显示器时，右键"检测显示器信息"走向导，自动测试代码并保存配置
- 自定义图标：替换 Resources 下的 typec.png / hdmi.png / AppIcon.icns

## 依赖

- Apple Silicon Mac (M1/M2/M3/M4)
- [m1ddc](https://github.com/tao-jie/m1ddc) (`brew install m1ddc`)

## 编译

```bash
swiftc main.swift -o MonitorSourceSwitcher -framework Cocoa -target arm64-apple-macos12
```

## 打包成 .app

```bash
APP="MonitorSourceSwitcher.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp MonitorSourceSwitcher "$APP/Contents/MacOS/"
chmod +x "$APP/Contents/MacOS/MonitorSourceSwitcher"
cp Info.plist "$APP/Contents/"
cp config.plist ICONS.txt "$APP/Contents/Resources/"
cp icons/AppIcon.icns "$APP/Contents/Resources/"
cp icons/typec.png icons/hdmi.png "$APP/Contents/Resources/" 2>/dev/null
```

## 配置

首次使用：右键状态栏图标 → 检测显示器信息，按向导选显示器、应用自动切代码问你屏幕显示哪台电脑，自动保存。

或手动编辑 `config.plist`：

| 字段 | 说明 |
|---|---|
| DisplayId | 目标显示器 UUID（`m1ddc display list` 查） |
| TypeCSetCode | 切到 TypeC 的命令码 |
| HdmiSetCode | 切到 HDMI 的命令码 |
| TypeCReadCode | TypeC 状态读回码 |
| HdmiReadCode | HDMI 状态读回码 |
| M1ddcPath | m1ddc 可执行文件路径 |

> 注意：部分显示器的切换命令码和读回码不同（如本例切到 HDMI 用 set 16，读回是 17）。请用"检测显示器信息"向导实测确认。

## License

MIT
