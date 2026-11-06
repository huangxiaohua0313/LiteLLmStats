import Cocoa

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - 数据模型

final class ModelUsage {
    var requests: Double = 0
    var failed: Double = 0
    var input: Double = 0
    var output: Double = 0
    var total: Double = 0
    var cached: Double = 0
    var reasoning: Double = 0
}

enum UsageMetricKey: String, CaseIterable {
    case requests, failed, input, output, total, cached, reasoning
}

let counterMetricNames: [String: UsageMetricKey] = [
    "litellm_requests_metric_total": .requests,
    "litellm_proxy_failed_requests_metric_total": .failed,
    "litellm_input_tokens_metric_total": .input,
    "litellm_output_tokens_metric_total": .output,
    "litellm_total_tokens_metric_total": .total,
    "litellm_input_cached_tokens_metric_total": .cached,
    "litellm_output_reasoning_tokens_metric_total": .reasoning,
]

let createdMetricNames: [String: UsageMetricKey] = [
    "litellm_requests_metric_created": .requests,
    "litellm_proxy_failed_requests_metric_created": .failed,
    "litellm_input_tokens_metric_created": .input,
    "litellm_output_tokens_metric_created": .output,
    "litellm_total_tokens_metric_created": .total,
    "litellm_input_cached_tokens_metric_created": .cached,
    "litellm_output_reasoning_tokens_metric_created": .reasoning,
]

extension ModelUsage {
    func value(for key: UsageMetricKey) -> Double {
        switch key {
        case .requests: return requests
        case .failed: return failed
        case .input: return input
        case .output: return output
        case .total: return total
        case .cached: return cached
        case .reasoning: return reasoning
        }
    }

    func set(_ key: UsageMetricKey, _ value: Double) {
        switch key {
        case .requests: requests = value
        case .failed: failed = value
        case .input: input = value
        case .output: output = value
        case .total: total = value
        case .cached: cached = value
        case .reasoning: reasoning = value
        }
    }
}

struct MetricsSnapshot {
    var usage: [String: ModelUsage] = [:]
    // 每个模型每类指标最早的 _created 时间戳（该计数从何时开始累加）
    var created: [String: [String: Double]] = [:]
}

// MARK: - 配置

struct AppConfig {
    var host: String = "127.0.0.1"
    var port: Int = 4000
    var refreshSeconds: Int = 10
    var apiKey: String = ""

    var metricsURL: URL? {
        // IPv6 字面量需要方括号
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: "http://\(hostPart):\(port)/metrics/")
    }

    var endpointDescription: String {
        "http://\(host):\(port)"
    }
}

let configPath: String = {
    let dir = NSHomeDirectory() + "/.litellm/menubar"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/config.json"
}()

func loadConfig() -> AppConfig {
    var cfg = AppConfig()
    guard let data = FileManager.default.contents(atPath: configPath),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        saveConfig(cfg)
        return cfg
    }
    if let host = obj["host"] as? String, !host.isEmpty { cfg.host = host }
    if let port = obj["port"] as? Int, (1...65535).contains(port) { cfg.port = port }
    if let seconds = obj["refresh_seconds"] as? Int, seconds >= 2 { cfg.refreshSeconds = seconds }
    if let key = obj["api_key"] as? String { cfg.apiKey = key }
    return cfg
}

func saveConfig(_ cfg: AppConfig) {
    var obj: [String: Any] = [
        "host": cfg.host,
        "port": cfg.port,
        "refresh_seconds": cfg.refreshSeconds
    ]
    if !cfg.apiKey.isEmpty { obj["api_key"] = cfg.apiKey }

    guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                 options: [.prettyPrinted, .sortedKeys]) else {
        return
    }
    try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                           ofItemAtPath: configPath)
}

func loadMasterKeyFromYAML() -> String? {
    let path = NSHomeDirectory() + "/.litellm/config.yaml"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    for rawLine in text.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("master_key:") else { continue }
        var value = String(line.dropFirst("master_key:".count))
            .trimmingCharacters(in: .whitespaces)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty ? nil : value
    }
    return nil
}

func resolveAPIKey(_ cfg: AppConfig) -> String? {
    if !cfg.apiKey.isEmpty { return cfg.apiKey }
    return loadMasterKeyFromYAML()
}

// MARK: - 开机自启

let agentLabel = "local.llm.litellm-stats"

func userAgentPlistPath() -> String {
    NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
}

func systemAgentPlistPath() -> String {
    "/Library/LaunchAgents/\(agentLabel).plist"
}

@discardableResult
func runLaunchctl(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        return -1
    }
}

func isAutostartEnabled() -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: userAgentPlistPath()) ||
          fm.fileExists(atPath: systemAgentPlistPath()) else {
        return false
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print-disabled", "gui/\(getuid())"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return true
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return !output.contains("\"\(agentLabel)\" => true")
}

func writeUserAgentPlist(executablePath: String) {
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>\(agentLabel)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(executablePath)</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <dict>
            <key>SuccessfulExit</key>
            <false/>
        </dict>
        <key>StandardOutPath</key>
        <string>\(NSHomeDirectory())/Library/Logs/LiteLLmStats.out.log</string>
        <key>StandardErrorPath</key>
        <string>\(NSHomeDirectory())/Library/Logs/LiteLLmStats.err.log</string>
    </dict>
    </plist>

    """
    let path = userAgentPlistPath()
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? plist.write(toFile: path, atomically: true, encoding: .utf8)
}

func setAutostart(enabled: Bool) {
    let domain = "gui/\(getuid())/\(agentLabel)"
    if enabled {
        runLaunchctl(["enable", domain])
        let fm = FileManager.default
        if !fm.fileExists(atPath: userAgentPlistPath()) &&
           !fm.fileExists(atPath: systemAgentPlistPath()) {
            let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
            writeUserAgentPlist(executablePath: executable)
        }
    } else {
        runLaunchctl(["disable", domain])
    }
}

// MARK: - Prometheus 文本解析

func parseLabelPairs(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    let pattern = #"([A-Za-z_][A-Za-z0-9_]*)="([^"]*)""#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return result }
    let ns = text as NSString
    let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
    for m in matches where m.numberOfRanges == 3 {
        result[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
    }
    return result
}

func parseMetrics(_ text: String) -> MetricsSnapshot {
    var snapshot = MetricsSnapshot()

    text.enumerateLines { line, _ in
        guard !line.hasPrefix("#"),
              let open = line.firstIndex(of: "{"),
              let close = line.lastIndex(of: "}") else { return }

        let name = String(line[..<open])
        let labelText = String(line[line.index(after: open)..<close])
        let valueText = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard let value = Double(valueText) else { return }

        let labels = parseLabelPairs(labelText)
        var alias = labels["requested_model"] ?? ""
        if alias.isEmpty || alias == "None" {
            alias = labels["model"] ?? ""
        }
        guard !alias.isEmpty, alias != "None" else { return }

        if let key = counterMetricNames[name] {
            guard value != 0 else { return }
            let usage = snapshot.usage[alias] ?? ModelUsage()
            usage.set(key, usage.value(for: key) + value)
            snapshot.usage[alias] = usage
        } else if let key = createdMetricNames[name] {
            guard value > 0 else { return }
            var byMetric = snapshot.created[alias] ?? [:]
            if byMetric[key.rawValue].map({ value < $0 }) ?? true {
                byMetric[key.rawValue] = value
            }
            snapshot.created[alias] = byMetric
        }
    }

    return snapshot
}

// MARK: - 今日用量（把 Prometheus 累计计数换算成当天用量）

final class DailyUsageTracker {
    private struct MetricState: Codable {
        var created: Double?   // 当前计数器序列的创建时间
        var last: Double       // 上次读到的累计值
        var acc: Double        // 今天累计（跨重启累加）
    }

    private struct Persisted: Codable {
        var date: String
        var state: [String: [String: MetricState]]
    }

    private let path: String
    private var dateKey: String
    private var state: [String: [String: MetricState]] = [:]

    init(path: String) {
        self.path = path
        self.dateKey = Self.todayKey()
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        load()
    }

    private static func todayKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func midnightTimestamp() -> Double {
        Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
    }

    private func rolloverIfNeeded() {
        let today = Self.todayKey()
        if today != dateKey {
            dateKey = today
            state = [:]
        }
    }

    /// 输入本次抓到的累计计数，返回各模型“今天”的用量。
    func ingest(_ snapshot: MetricsSnapshot) -> [String: ModelUsage] {
        rolloverIfNeeded()
        let midnight = midnightTimestamp()

        var result: [String: ModelUsage] = [:]

        for (alias, rawUsage) in snapshot.usage {
            var aliasState = state[alias] ?? [:]

            for key in UsageMetricKey.allCases {
                let value = rawUsage.value(for: key)
                let created = snapshot.created[alias]?[key.rawValue]

                let metricState: MetricState
                if var existing = aliasState[key.rawValue] {
                    if let c = created, let old = existing.created, c > old + 1 {
                        // litellm 重启后计数器序列重建：今天新建的计数全量属于今天
                        if c >= midnight { existing.acc += value }
                        existing.created = c
                        existing.last = value
                    } else {
                        // 同一计数取增量；数值变小说明计数器被重置
                        let delta = value >= existing.last ? value - existing.last : value
                        existing.acc += delta
                        existing.last = value
                        if existing.created == nil, let c = created { existing.created = c }
                    }
                    metricState = existing
                } else if let c = created, c >= midnight {
                    // 该计数今天才创建，当前累计值全部是今天的
                    metricState = MetricState(created: c, last: value, acc: value)
                } else {
                    // 计数跨天，无法区分今天之前的量，从当前值起算
                    metricState = MetricState(created: created, last: value, acc: 0)
                }

                aliasState[key.rawValue] = metricState
            }

            state[alias] = aliasState

            let today = ModelUsage()
            for key in UsageMetricKey.allCases {
                today.set(key, aliasState[key.rawValue]?.acc ?? 0)
            }
            if today.requests > 0 || today.total > 0 || today.input > 0 || today.output > 0 {
                result[alias] = today
            }
        }

        save()
        return result
    }

    private func load() {
        guard let data = FileManager.default.contents(atPath: path),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data),
              persisted.date == Self.todayKey() else {
            return
        }
        state = persisted.state
    }

    private func save() {
        let persisted = Persisted(date: dateKey, state: state)
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

// MARK: - 格式化

func fmtTokens(_ value: Double) -> String {
    if value >= 1_000_000 { return String(format: "%.2fM", value / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
    return String(format: "%.0f", value)
}

func fmtCount(_ value: Double) -> String {
    String(format: "%.0f", value)
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var config = AppConfig()
    private var usage: [String: ModelUsage] = [:]
    private var errorText: String?
    private var lastUpdated: Date?
    private lazy var tracker = DailyUsageTracker(
        path: NSHomeDirectory() + "/.litellm/menubar/daily.json"
    )

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[LiteLLmStats] started \(Date()) v\(appVersion)")
        NSApp.setActivationPolicy(.accessory)

        config = loadConfig()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.horizontal.fill",
                                   accessibilityDescription: "LiteLLM")
            button.imagePosition = .imageLeading
            button.title = " …"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                           weight: .regular)
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        print("[LiteLLmStats] statusItem visible=\(statusItem.isVisible) button=\(statusItem.button != nil) policy=\(NSApp.activationPolicy().rawValue) config=\(config.endpointDescription) every=\(config.refreshSeconds)s")

        scheduleTimer()
        refresh()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(2, config.refreshSeconds))
        let repeating = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(repeating, forMode: .common)
        timer = repeating
    }

    @objc private func refreshAction() {
        refresh()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    @objc private func showSettings() {
        let alert = NSAlert()
        alert.messageText = "LiteLLmStats \(appVersion) 设置"
        alert.informativeText = "配置 LiteLLM 网关地址、刷新频率和访问密钥。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 172))

        func makeLabel(_ text: String, y: CGFloat) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: 0, y: y, width: 100, height: 20)
            label.alignment = .right
            return label
        }

        func makeField(_ value: String, y: CGFloat, placeholder: String = "") -> NSTextField {
            let field = NSTextField(string: value)
            field.frame = NSRect(x: 110, y: y, width: 260, height: 24)
            field.placeholderString = placeholder
            field.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize,
                                                     weight: .regular)
            return field
        }

        let hostField = makeField(config.host, y: 140)
        let portField = makeField(String(config.port), y: 108)
        let intervalField = makeField(String(config.refreshSeconds), y: 76)
        let keyField = makeField(config.apiKey, y: 44,
                                 placeholder: "留空则读取 ~/.litellm/config.yaml")

        let autostartCheckbox = NSButton(checkboxWithTitle: "开机自动启动",
                                         target: nil, action: nil)
        autostartCheckbox.frame = NSRect(x: 110, y: 10, width: 260, height: 20)
        autostartCheckbox.state = isAutostartEnabled() ? .on : .off

        accessory.addSubview(makeLabel("网关地址 / IP", y: 142))
        accessory.addSubview(hostField)
        accessory.addSubview(makeLabel("端口", y: 110))
        accessory.addSubview(portField)
        accessory.addSubview(makeLabel("刷新间隔(秒)", y: 78))
        accessory.addSubview(intervalField)
        accessory.addSubview(makeLabel("访问密钥", y: 46))
        accessory.addSubview(keyField)
        accessory.addSubview(autostartCheckbox)

        alert.accessoryView = accessory

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let interval = Int(intervalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        guard !host.isEmpty, (1...65535).contains(port), (2...3600).contains(interval) else {
            let warning = NSAlert()
            warning.alertStyle = .warning
            warning.messageText = "配置无效"
            warning.informativeText = "地址不能为空，端口范围 1-65535，刷新间隔 2-3600 秒。"
            warning.runModal()
            return
        }

        config.host = host
        config.port = port
        config.refreshSeconds = interval
        config.apiKey = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        saveConfig(config)

        let autostart = autostartCheckbox.state == .on
        setAutostart(enabled: autostart)

        print("[LiteLLmStats] config updated: \(config.endpointDescription) every \(config.refreshSeconds)s autostart=\(autostart)")

        scheduleTimer()
        refresh()
    }

    private func refresh() {
        guard let url = config.metricsURL else {
            print("[LiteLLmStats] error: invalid metrics url")
            errorText = "网关地址配置无效"
            updateStatusTitle()
            return
        }
        guard let key = resolveAPIKey(config) else {
            print("[LiteLLmStats] error: api key not found")
            errorText = "未配置访问密钥（config.json 或 config.yaml）"
            updateStatusTitle()
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    print("[LiteLLmStats] network error: \(error.localizedDescription)")
                    self.errorText = error.localizedDescription
                    self.updateStatusTitle()
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200,
                      let data = data,
                      let text = String(data: data, encoding: .utf8) else {
                    print("[LiteLLmStats] http error: \(String(describing: response))")
                    self.errorText = "metrics 接口请求失败"
                    self.updateStatusTitle()
                    return
                }

                let snapshot = parseMetrics(text)
                self.usage = self.tracker.ingest(snapshot)
                self.errorText = nil
                self.lastUpdated = Date()
                self.updateStatusTitle()

                let t = self.totals()
                let cumulative = snapshot.usage.values.reduce(0.0) { $0 + $1.total }
                print("[LiteLLmStats] ok \(self.config.endpointDescription) today models=\(self.usage.count) requests=\(Int(t.req)) tokens=\(Int(t.total)) cached=\(Int(t.cached)) cumulative=\(Int(cumulative))")
            }
        }.resume()
    }

    private func totals() -> (req: Double, failed: Double, input: Double, output: Double,
                              total: Double, cached: Double, reasoning: Double) {
        var req = 0.0, failed = 0.0, input = 0.0, output = 0.0
        var total = 0.0, cached = 0.0, reasoning = 0.0
        for u in usage.values {
            req += u.requests
            failed += u.failed
            input += u.input
            output += u.output
            total += u.total
            cached += u.cached
            reasoning += u.reasoning
        }
        return (req, failed, input, output, total, cached, reasoning)
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }

        if let errorText = errorText {
            button.title = " ⚠︎"
            button.toolTip = "LiteLLM 指标不可用：\(errorText)"
            return
        }

        let t = totals()
        let cacheRate = t.input > 0 ? t.cached / t.input * 100 : 0
        button.title = " 今日 " + fmtTokens(t.total)
        button.toolTip = String(
            format: "LiteLLM 今日用量 · %@ 次请求 · 输入 %@ / 输出 %@ · 缓存命中 %.1f%%",
            fmtCount(t.req), fmtTokens(t.input), fmtTokens(t.output), cacheRate
        )
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.isEnabled = false
        if let errorText = errorText {
            header.title = "⚠︎ \(errorText)"
        } else if let lastUpdated = lastUpdated {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            header.title = "LiteLLM 今日用量 · 更新于 \(formatter.string(from: lastUpdated))"
        } else {
            header.title = "LiteLLM 今日用量 · 加载中…"
        }
        menu.addItem(header)

        let endpoint = NSMenuItem(
            title: "\(config.endpointDescription) · 每 \(config.refreshSeconds) 秒刷新",
            action: nil, keyEquivalent: ""
        )
        endpoint.isEnabled = false
        menu.addItem(endpoint)

        if !usage.isEmpty {
            menu.addItem(.separator())
            for alias in usage.keys.sorted() {
                let u = usage[alias]!
                let cacheRate = u.input > 0 ? u.cached / u.input * 100 : 0
                let title = String(
                    format: "%@   %@ 次 · %@ tok · 缓存 %.0f%%",
                    alias, fmtCount(u.requests), fmtTokens(u.total), cacheRate
                )
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }

            menu.addItem(.separator())
            let t = totals()
            let cacheRate = t.input > 0 ? t.cached / t.input * 100 : 0
            let totalsItem = NSMenuItem(
                title: String(
                    format: "今日合计   %@ 次 · 输入 %@ / 输出 %@ · 缓存 %.1f%%",
                    fmtCount(t.req), fmtTokens(t.input), fmtTokens(t.output), cacheRate
                ),
                action: nil, keyEquivalent: ""
            )
            totalsItem.isEnabled = false
            menu.addItem(totalsItem)
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "立即刷新",
                                     action: #selector(refreshAction), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "设置…",
                                      action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "退出",
                                  action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
