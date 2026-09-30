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
- **Mac Mini 状态协调（SSH）**：
  - 切到 HDMI 前自动唤醒 Mac Mini 显示输出（解决 Mac Mini 休眠后切不过去）
  - MacBook 显示器休眠时自动让 Mac Mini 也休眠显示器（防止显示器自动切到 Mac Mini）

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
| MacMiniSSH | Mac Mini SSH 地址（如 `user@192.168.x.x`），留空则不启用协调 |
| WakeDuration | 唤醒 Mac Mini 后保持显示输出的秒数（默认 30） |

> 注意：部分显示器的切换命令码和读回码不同（如本例切到 HDMI 用 set 16，读回是 17）。请用"检测显示器信息"向导实测确认。

## Mac Mini SSH 协调设置（可选）

启用后可解决两个联动问题：
1. **Mac Mini 休眠后切不过去**：切到 HDMI 前自动 SSH 唤醒 Mac Mini 显示输出
2. **MacBook 休眠后显示器自动跳 Mac Mini**：MacBook 显示器休眠时自动 SSH 让 Mac Mini 也休眠显示器

**前置条件**：
- Mac Mini 开启「系统设置 → 通用 → 共享 → 远程登录」
- MacBook 与 Mac Mini 在同一局域网
- 配置 SSH 免密登录：
  ```bash
  # MacBook 上生成密钥（如已有可跳过）
  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
  # 把公钥加到 Mac Mini
  ssh-copy-id user@192.168.x.x
  # 或手动在 Mac Mini 上执行：
  mkdir -p ~/.ssh && echo "<公钥内容>" >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
  ```
- 确保 Mac Mini 的 home 目录权限不是 777（SSH 安全要求）：`chmod 755 ~`

## License

MIT
