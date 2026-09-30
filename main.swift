//  MonitorSourceSwitcher
//  极简状态栏小应用：一键切换 MEITIANHAO 便携显示器的 TypeC / HDMI 信源
//  左键点击 = 切换；右键点击 = 菜单；图标随当前信源动态切换；图标可从 Resources 替换

import Cocoa

// ===== 配置（可从 Resources/config.plist 覆盖） =====
// 注意：MEITIANHAO 的切换命令码和读回码不同
//   切到 TypeC：set 15，读回 15
//   切到 HDMI ：set 16，读回 17   ← 用 16 切才能停住，用 17 切会被切回
struct AppConfig {
    let displayId: String
    let typecSetCode: String   // 切到 TypeC 的命令码
    let hdmiSetCode: String    // 切到 HDMI 的命令码
    let typecReadCode: String  // TypeC 状态读回码
    let hdmiReadCode: String   // HDMI 状态读回码
    let m1ddcPath: String
    let macMiniSSH: String     // Mac Mini SSH 地址（如 user@192.168.x.x），空则不启用协调
    let wakeDuration: Int      // 唤醒 Mac Mini 后保持显示输出的秒数

    static func load() -> AppConfig {
        let def = AppConfig(
            displayId: "YOUR-DISPLAY-UUID-HERE",
            typecSetCode: "15",
            hdmiSetCode: "16",
            typecReadCode: "15",
            hdmiReadCode: "17",
            m1ddcPath: "/opt/homebrew/bin/m1ddc",
            macMiniSSH: "",
            wakeDuration: 30
        )
        guard let path = Bundle.main.path(forResource: "config", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: String] else {
            return def
        }
        return AppConfig(
            displayId: dict["DisplayId"] ?? def.displayId,
            typecSetCode: dict["TypeCSetCode"] ?? def.typecSetCode,
            hdmiSetCode: dict["HdmiSetCode"] ?? def.hdmiSetCode,
            typecReadCode: dict["TypeCReadCode"] ?? def.typecReadCode,
            hdmiReadCode: dict["HdmiReadCode"] ?? def.hdmiReadCode,
            m1ddcPath: dict["M1ddcPath"] ?? def.m1ddcPath,
            macMiniSSH: dict["MacMiniSSH"] ?? def.macMiniSSH,
            wakeDuration: Int(dict["WakeDuration"] ?? "30") ?? def.wakeDuration
        )
    }
}

// ===== AppDelegate =====
final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let cfg = AppConfig.load()
    private var pollTimer: Timer?
    private var lastInput: Int = -1
    private var isSwitching = false
    // 切换中 loading 动画
    private var loadingTimer: Timer?
    private var frameIdx = 0
    private let loadingFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    // SSH 设置界面控件引用
    private weak var sshAlert: NSAlert?
    private weak var sshToggle: NSSwitch?
    private weak var sshAddrField: NSTextField?
    private weak var sshPwdField: NSSecureTextField?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单项
        let toggleItem = NSMenuItem(title: "切换信源", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        let detectItem = NSMenuItem(title: "检测显示器信息", action: #selector(detectDisplays), keyEquivalent: "")
        detectItem.target = self
        menu.addItem(detectItem)
        let sshItem = NSMenuItem(title: "SSH 协调设置", action: #selector(sshSettings), keyEquivalent: "")
        sshItem.target = self
        menu.addItem(sshItem)
        let aboutItem = NSMenuItem(title: "关于", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        // 状态栏按钮：左键切换，右键菜单
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusBarClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // 初始图标
        refreshIcon()

        // 定时检查（显示器可能自动切回），仅刷新图标，不切换
        pollTimer = Timer.scheduledTimer(timeInterval: 5.0, target: self,
                                         selector: #selector(refreshIcon), userInfo: nil, repeats: true)
        RunLoop.main.add(pollTimer!, forMode: .common)

        // 监听 MacBook 显示器睡眠 → 通知 Mac Mini 也睡显示器，防止显示器自动切到 HDMI
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sshMacMiniAsync("pmset displaysleepnow")
        }
    }

    // 点击处理
    @objc private func statusBarClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent, let button = statusItem.button else {
            toggle(); return
        }
        if event.type == .rightMouseUp {
            // 右键弹菜单
            let origin = NSPoint(x: 0, y: button.bounds.height + 4)
            menu.popUp(positioning: nil, at: origin, in: button)
        } else {
            toggle()
        }
    }

    // 切换信源
    @objc func toggle() {
        guard !isSwitching else { return }
        isSwitching = true
        startLoading()
        // 超时保护：12 秒后强制结束 loading，防止 SSH/切换异常导致永远卡住
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self = self, self.isSwitching else { return }
            self.isSwitching = false
            self.stopLoading()
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let current = self.getCurrentInput()
            // 用 ReadCode 判断当前状态，用 SetCode 切换
            let target: String
            let targetRead: String
            if let c = current, String(c) == self.cfg.hdmiReadCode {
                // 当前 HDMI -> 切 TypeC
                target = self.cfg.typecSetCode
                targetRead = self.cfg.typecReadCode
            } else {
                // 当前 TypeC/其它 -> 切 HDMI（用 hdmiSetCode=16 才能停住）
                target = self.cfg.hdmiSetCode
                targetRead = self.cfg.hdmiReadCode
            }
            // 切到 HDMI 前，先唤醒 Mac Mini 的显示输出（解决问题1：Mac Mini 睡了切不过去）
            // 用 nohup 后台运行，避免 caffeinate -t N 阻塞 SSH 导致切换卡住
            if target == self.cfg.hdmiSetCode {
                _ = self.sshMacMiniSync("nohup caffeinate -u -t \(self.cfg.wakeDuration) >/dev/null 2>&1 &")
                Thread.sleep(forTimeInterval: 0.8)  // 给 Mac Mini 一点时间恢复视频输出
            }
            self.setInput(target)
            Thread.sleep(forTimeInterval: 2.0)
            // 确认是否切对（用 ReadCode 判断）
            for attempt in 0..<3 {
                if let after = self.getCurrentInput(), String(after) == targetRead {
                    break
                }
                self.setInput(target)
                Thread.sleep(forTimeInterval: 2.0)
            }
            DispatchQueue.main.async {
                self.isSwitching = false
                self.stopLoading()
                self.refreshIcon(force: true)
            }
        }
    }

    // 切换中 loading 动画（盲文旋转字符 spinner）
    private func startLoading() {
        frameIdx = 0
        loadingTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let button = self.statusItem.button else { return }
            button.image = nil
            button.title = self.loadingFrames[self.frameIdx % self.loadingFrames.count]
            self.frameIdx += 1
        }
        loadingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopLoading() {
        loadingTimer?.invalidate()
        loadingTimer = nil
        if let button = statusItem.button { button.title = "" }
    }

    // 读取当前输入源
    private func getCurrentInput() -> Int? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: cfg.m1ddcPath)
        task.arguments = ["display", cfg.displayId, "get", "input"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Int(s)
    }

    // 设置输入源
    private func setInput(_ code: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: cfg.m1ddcPath)
        task.arguments = ["display", cfg.displayId, "set", "input", code]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run() } catch { return }
        task.waitUntilExit()
    }

    // 通过 SSH 在 Mac Mini 上执行命令（同步，阻塞调用线程）
    // 用于切换到 HDMI 前唤醒 Mac Mini 显示输出
    private func sshMacMiniSync(_ command: String) -> Bool {
        guard !cfg.macMiniSSH.isEmpty else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                          cfg.macMiniSSH, command]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    // SSH 异步执行（不阻塞，用于显示器睡眠通知时的快速响应）
    private func sshMacMiniAsync(_ command: String) {
        guard !cfg.macMiniSSH.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.sshMacMiniSync(command)
        }
    }

    // 刷新图标（force 时强制更新，用于切换后）
    @objc func refreshIcon(force: Bool = false) {
        if isSwitching && !force { return }   // 切换中保持 loading，不被定时器刷新打断
        let input = getCurrentInput() ?? Int(cfg.typecReadCode)!
        if !force && input == lastInput { return }
        lastInput = input
        applyIcon(input: input)
    }

    private func applyIcon(input: Int) {
        let isHDMI = (input == Int(cfg.hdmiReadCode)!)
        let icon = loadIcon(isHDMI: isHDMI)
        if let button = statusItem.button {
            button.image = icon
            let tip = isHDMI
                ? "当前: HDMI · Mac Mini  (点击切到 TypeC · MacBook)"
                : "当前: TypeC · MacBook  (点击切到 HDMI · Mac Mini)"
            button.toolTip = tip
        }
    }

    // 加载图标：优先 Resources/png，回退 SF Symbol
    private func loadIcon(isHDMI: Bool) -> NSImage {
        let name = isHDMI ? "hdmi" : "typec"
        if let p = Bundle.main.path(forResource: name, ofType: "png"),
           let img = NSImage(contentsOfFile: p) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = false   // 用户的彩色 png 原样显示
            return img
        }
        // 回退：SF Symbol（模板色，适配深浅模式）
        let symbol = isHDMI ? "desktopcomputer" : "laptopcomputer"
        let conf = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
           let img = base.withSymbolConfiguration(conf) {
            img.isTemplate = true
            return img
        }
        return NSImage()
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "显示器信源切换器 V1.0"
        alert.informativeText = """
一键切换 2 台 Mac 在同一显示器的显示信源。
如：MacBook Pro 连接 TypeC / Mac Mini 连接 HDMI。
支持手动检测校准信源代码。

By Jaret
"""
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - SSH 协调设置（开关式交互：开关→输入框→保存按钮逐级启用）
    @objc func sshSettings() {
        let alert = NSAlert()
        alert.messageText = "SSH 协调设置"
        // 已配置则脱敏提示，不暴露完整地址
        let infoText: String
        if cfg.macMiniSSH.isEmpty {
            infoText = "开启后可协调两台 Mac 的显示器休眠状态。\n需在 Mac Mini 开启「系统设置 → 通用 → 共享 → 远程登录」。"
        } else {
            infoText = "当前已配置：\(maskedAddress(cfg.macMiniSSH))\n开启后可协调两台 Mac 的显示器休眠状态。\n需在 Mac Mini 开启「系统设置 → 通用 → 共享 → 远程登录」。"
        }
        alert.informativeText = infoText

        // accessoryView：文字+开关整体靠右，地址+密码输入框在下方
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))

        // 开关行：文字在前，开关在后，整体靠右对齐
        let toggleLabel = NSTextField(labelWithString: "开启 SSH 协调")
        toggleLabel.frame = NSRect(x: 158, y: 76, width: 100, height: 18)
        toggleLabel.font = NSFont.systemFont(ofSize: 13)
        toggleLabel.alignment = .right

        let toggle = NSSwitch(frame: NSRect(x: 262, y: 74, width: 40, height: 24))
        toggle.state = cfg.macMiniSSH.isEmpty ? .off : .on
        toggle.target = self
        toggle.action = #selector(sshToggleChanged(_:))

        // 地址 + 密码输入框
        let addrField = NSTextField(frame: NSRect(x: 0, y: 42, width: 300, height: 24))
        addrField.placeholderString = "用户名@IP地址"
        addrField.delegate = self

        let pwdField = NSSecureTextField(frame: NSRect(x: 0, y: 10, width: 300, height: 24))
        pwdField.placeholderString = "Mac Mini 登录密码（仅首次配置需要）"

        accessory.addSubview(toggleLabel)
        accessory.addSubview(toggle)
        accessory.addSubview(addrField)
        accessory.addSubview(pwdField)
        alert.accessoryView = accessory

        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        sshAlert = alert
        sshToggle = toggle
        sshAddrField = addrField
        sshPwdField = pwdField
        updateSSHUI()

        let response = alert.runModal()

        sshAlert = nil
        sshToggle = nil
        sshAddrField = nil
        sshPwdField = nil

        guard response == .alertFirstButtonReturn else { return }

        let enabled = toggle.state == .on
        let addr = addrField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pwd = pwdField.stringValue

        if !enabled {
            // 关闭协调
            saveMacMiniSSH("")
            simpleAlert("已关闭 SSH 协调", "MacBook 休眠时不再通知 Mac Mini，切换 HDMI 时也不再自动唤醒。")
            return
        }

        if addr.isEmpty { return }

        // 后台自动配置免密登录
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            guard let pubKey = self.ensureSSHKey() else {
                DispatchQueue.main.async {
                    self.simpleAlert("配置失败", "无法生成 SSH 密钥，请检查 ~/.ssh 目录权限。")
                }
                return
            }

            // 密码为空：已配置过免密，直接测试
            if pwd.isEmpty {
                let ok = self.sshMacMiniSyncWithAddress(addr, "echo ok")
                DispatchQueue.main.async {
                    if ok {
                        self.saveMacMiniSSH(addr)
                        self.simpleAlert("连接成功", "已保存 SSH 地址，协调功能已启用。")
                    } else {
                        self.simpleAlert("连接失败", "免密连接未通过。请输入 Mac Mini 登录密码以配置免密登录。")
                    }
                }
                return
            }

            // 用密码写入公钥
            let setupOk = self.setupSSHAuth(address: addr, password: pwd, pubKey: pubKey)
            DispatchQueue.main.async {
                if setupOk {
                    let testOk = self.sshMacMiniSyncWithAddress(addr, "echo ok")
                    if testOk {
                        self.saveMacMiniSSH(addr)
                        self.simpleAlert("配置成功", "SSH 免密登录已配置并测试通过。\n协调功能已启用。")
                    } else {
                        let retry = NSAlert()
                        retry.messageText = "公钥已写入，但免密测试未通过"
                        retry.informativeText = "已尝试写入公钥，但免密连接测试失败。\n可能原因：Mac Mini 的 ~/.ssh 权限不对，或 SSH 配置禁用了公钥认证。\n\n是否仍要保存地址？"
                        retry.addButton(withTitle: "仍要保存")
                        retry.addButton(withTitle: "取消")
                        if retry.runModal() == .alertFirstButtonReturn {
                            self.saveMacMiniSSH(addr)
                        }
                    }
                } else {
                    self.simpleAlert("配置失败", "无法连接到 \(self.maskedAddress(addr))。\n请确认：\n1. Mac Mini 已开启远程登录\n2. 用户名和密码正确\n3. 两台 Mac 在同一局域网")
                }
            }
        }
    }

    // 开关状态变化 → 更新输入框和保存按钮
    @objc func sshToggleChanged(_ sender: NSSwitch) {
        updateSSHUI()
    }

    // 输入框内容变化 → 更新保存按钮
    func controlTextDidChange(_ obj: Notification) {
        updateSSHUI()
    }

    // 根据开关状态和地址内容更新 UI 可用性
    private func updateSSHUI() {
        guard let alert = sshAlert, let toggle = sshToggle,
              let addr = sshAddrField, let pwd = sshPwdField else { return }
        let on = toggle.state == .on
        addr.isEnabled = on
        pwd.isEnabled = on
        let hasAddr = !addr.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 保存按钮：开关开 且 地址非空 才亮起；开关关时也可点击（用于关闭协调）
        alert.buttons[0].isEnabled = !on || (on && hasAddr)
    }

    // 确保本机有 SSH key（ed25519），返回公钥内容
    private func ensureSSHKey() -> String? {
        let sshDir = "\(NSHomeDirectory())/.ssh"
        let keyPath = "\(sshDir)/id_ed25519"
        let fm = FileManager.default
        if !fm.fileExists(atPath: keyPath) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            task.arguments = ["-t", "ed25519", "-f", keyPath, "-N", "", "-q"]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            do { try task.run() } catch { return nil }
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
        }
        let pubPath = keyPath + ".pub"
        return try? String(contentsOfFile: pubPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 用密码方式 SSH 到 Mac Mini，写入公钥实现免密登录
    private func setupSSHAuth(address: String, password: String, pubKey: String) -> Bool {
        // 创建临时 askpass 脚本（通过环境变量传密码，避免 shell 转义问题）
        let askpassPath = "/tmp/mss_askpass_\(UUID().uuidString).sh"
        let script = "#!/bin/sh\necho \"$MSS_SSH_PASSWORD\"\n"
        do {
            try script.write(toFile: askpassPath, atomically: true, encoding: .utf8)
        } catch { return false }
        chmod(askpassPath, 0o755)
        defer { try? FileManager.default.removeItem(atPath: askpassPath) }

        // 公钥用 base64 编码，避免特殊字符和引号问题
        guard let pubKeyData = pubKey.data(using: .utf8) else { return false }
        let pubKeyB64 = pubKeyData.base64EncodedString()
        let remoteCmd = "mkdir -p ~/.ssh && echo '\(pubKeyB64)' | base64 -d >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && echo OK"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = ["-o", "StrictHostKeyChecking=no",
                          "-o", "PreferredAuthentications=password",
                          "-o", "PubkeyAuthentication=no",
                          "-o", "NumberOfPasswordPrompts=1",
                          "-o", "ConnectTimeout=10",
                          address, remoteCmd]
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = askpassPath
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = ":0"
        env["MSS_SSH_PASSWORD"] = password
        task.environment = env
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // 用指定地址执行 SSH（免密模式，用于测试）
    private func sshMacMiniSyncWithAddress(_ address: String, _ command: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", address, command]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    // 保存 MacMiniSSH 到 config.plist
    private func saveMacMiniSSH(_ address: String) {
        guard let path = Bundle.main.path(forResource: "config", ofType: "plist"),
              var dict = NSDictionary(contentsOfFile: path) as? [String: String] else { return }
        dict["MacMiniSSH"] = address
        (dict as NSDictionary).write(toFile: path, atomically: true)
    }

    // 脱敏显示 SSH 地址：user@192.168.1.100 -> u***@192.168.1.***
    private func maskedAddress(_ address: String) -> String {
        let parts = address.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return "***" }
        let user = parts[0]
        let host = parts[1]
        let maskedUser = user.prefix(1) + "***"
        let hostParts = host.split(separator: ".")
        let maskedHost: String
        if hostParts.count == 4 {
            maskedHost = "\(hostParts[0]).\(hostParts[1]).\(hostParts[2]).***"
        } else {
            maskedHost = "***"
        }
        return "\(maskedUser)@\(maskedHost)"
    }

    // 交互式重新检测向导（产品化：应用自动切代码、问用户屏幕显示什么、自动保存）
    @objc func detectDisplays() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let sem = DispatchSemaphore(value: 0)

            // 1. 解析显示器列表
            let list = self.runM1ddcString(["display", "list"])
            let entries = self.parseDisplays(list)
            guard !entries.isEmpty else {
                self.runOnMain { self.simpleAlert("未检测到显示器", "请确认 m1ddc 已安装 (brew install m1ddc) 且外接显示器已连接") }
                return
            }

            // 2. 选目标显示器
            var chosenIdx = -1
            self.runOnMain {
                let alert = NSAlert()
                alert.messageText = "重新检测：选择要切换的显示器"
                alert.informativeText = "向导会自动尝试多个信源代码，每次问你屏幕显示的是哪台电脑。请确保两台电脑都开着并输出画面。"
                alert.alertStyle = .informational
                let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
                popup.addItems(withTitles: entries.enumerated().map { "\($0+1). \($1.name)" })
                alert.accessoryView = popup
                alert.addButton(withTitle: "开始检测")
                alert.addButton(withTitle: "取消")
                alert.window.initialFirstResponder = popup
                NSApp.activate(ignoringOtherApps: true)
                let resp = alert.runModal()
                chosenIdx = (resp == .alertFirstButtonReturn) ? popup.indexOfSelectedItem : -1
                sem.signal()
            }
            sem.wait()
            guard chosenIdx >= 0 else { return }
            let display = entries[chosenIdx]

            // 3. 逐个测试代码，问用户屏幕显示什么
            var typecSet = "", typecRead = "", hdmiSet = "", hdmiRead = ""
            let codes = [15, 16, 17, 18, 27]
            for c in codes {
                self.setInput(String(c))
                Thread.sleep(forTimeInterval: 4)
                let r = self.getCurrentInput() ?? -1
                var choice = -1
                self.runOnMain {
                    let alert = NSAlert()
                    alert.messageText = "已发送代码 \(c)（读回 \(r)）"
                    alert.informativeText = "MEITIANHAO 屏幕现在显示的是哪台电脑的内容？"
                    alert.addButton(withTitle: "本机 MacBook")
                    alert.addButton(withTitle: "另一台 Mac Mini")
                    alert.addButton(withTitle: "都不是 / 黑屏")
                    alert.addButton(withTitle: "终止检测")
                    alert.alertStyle = .informational
                    NSApp.activate(ignoringOtherApps: true)
                    let resp = alert.runModal()
                    if resp == .alertFirstButtonReturn { choice = 0 }
                    else if resp == .alertSecondButtonReturn { choice = 1 }
                    else if resp == .alertThirdButtonReturn { choice = 2 }
                    else { choice = -2 }
                    sem.signal()
                }
                sem.wait()
                if choice == -2 { return }   // 用户终止
                if choice == 0 && typecSet.isEmpty {
                    typecSet = String(c); typecRead = String(r)
                } else if choice == 1 && hdmiSet.isEmpty {
                    hdmiSet = String(c); hdmiRead = String(r)
                }
                if !typecSet.isEmpty && !hdmiSet.isEmpty { break }
            }

            // 4. 保存或提示失败
            if typecSet.isEmpty || hdmiSet.isEmpty {
                self.runOnMain {
                    self.simpleAlert("检测未完成",
                        "TypeC(MacBook) 切换码: \(typecSet.isEmpty ? "未找到" : typecSet)\n" +
                        "HDMI(Mac Mini) 切换码: \(hdmiSet.isEmpty ? "未找到" : hdmiSet)\n\n" +
                        "请确保两台电脑都开着并输出画面，且 MEITIANHAO 已连上两路信号后重试。")
                }
                return
            }
            self.saveConfig(uuid: display.uuid, typecSet: typecSet, typecRead: typecRead,
                            hdmiSet: hdmiSet, hdmiRead: hdmiRead)
            self.runOnMain {
                let alert = NSAlert()
                alert.messageText = "检测完成，配置已自动保存 ✓"
                alert.informativeText = """
显示器: \(display.name)
UUID: \(display.uuid)

TypeC(MacBook): 切换码 \(typecSet)，读回码 \(typecRead)
HDMI(Mac Mini): 切换码 \(hdmiSet)，读回码 \(hdmiRead)

点击“重启生效”后 app 自动重启。
"""
                alert.alertStyle = .informational
                alert.addButton(withTitle: "重启生效")
                alert.addButton(withTitle: "稍后")
                NSApp.activate(ignoringOtherApps: true)
                let resp = alert.runModal()
                if resp == .alertFirstButtonReturn {
                    // 重启 app
                    let task = Process()
                    task.launchPath = "/bin/sh"
                    task.arguments = ["-c", "sleep 1; open \"\(Bundle.main.bundlePath)\""]
                    try? task.run()
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // 运行 m1ddc 返回字符串输出（通用，用于 display list 等不带 displayId 的命令）
    private func runM1ddcString(_ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: cfg.m1ddcPath)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "(执行失败: \(error))" }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // 解析 m1ddc display list 的输出 → [(name, uuid)]
    private func parseDisplays(_ list: String) -> [(name: String, uuid: String)] {
        var result: [(name: String, uuid: String)] = []
        let regex = try? NSRegularExpression(pattern: "\\(([A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12})\\)")
        for line in list.components(separatedBy: "\n") {
            guard let r = regex?.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
                  let rng = Range(r.range(at: 1), in: line) else { continue }
            let uuid = String(line[rng])
            var name = "(未知)"
            if let br = line.firstIndex(of: "]"), let lp = line.firstIndex(of: "(") {
                let after = line.index(after: br)
                let n = String(line[after..<lp]).trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { name = n }
            }
            result.append((name: name, uuid: uuid))
        }
        return result
    }

    // 保存配置到 app 内 config.plist
    private func saveConfig(uuid: String, typecSet: String, typecRead: String,
                            hdmiSet: String, hdmiRead: String) {
        let dict: [String: String] = [
            "DisplayId": uuid,
            "TypeCSetCode": typecSet,
            "HdmiSetCode": hdmiSet,
            "TypeCReadCode": typecRead,
            "HdmiReadCode": hdmiRead,
            "M1ddcPath": cfg.m1ddcPath,
            "MacMiniSSH": cfg.macMiniSSH,
            "WakeDuration": String(cfg.wakeDuration)
        ]
        if let path = Bundle.main.path(forResource: "config", ofType: "plist") {
            (dict as NSDictionary).write(toFile: path, atomically: true)
        }
    }

    // 主线程执行
    private func runOnMain(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    // 简单信息框
    private func simpleAlert(_ title: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// ===== 启动 =====
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 无 Dock 图标
app.run()
