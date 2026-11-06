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

// MARK: - 配置

struct AppConfig {
    var host: String = "127.0.0.1"
    var port: Int = 4000
    var refreshSeconds: Int = 10
    var apiKey: String = ""
    /// 每日 token 限额，0 表示不限制
    var dailyTokenLimit: Int = 100_000_000

    /// LiteLLM 管理 API：按天汇总的用量（需要 litellm 连接数据库并开启 spend logs）
    var dailyActivityURL: URL? {
        // IPv6 字面量需要方括号
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard var components = URLComponents(string: "http://\(hostPart):\(port)/user/daily/activity") else {
            return nil
        }
        let today = localDateKey()
        // timezone 采用 JS Date.getTimezoneOffset() 约定：UTC+8 为 -480
        let tzOffset = -(TimeZone.current.secondsFromGMT(for: Date()) / 60)
        components.queryItems = [
            URLQueryItem(name: "start_date", value: today),
            URLQueryItem(name: "end_date", value: today),
            URLQueryItem(name: "timezone", value: String(tzOffset)),
            URLQueryItem(name: "include_current_utc_day", value: "true"),
        ]
        return components.url
    }

    var endpointDescription: String {
        "http://\(host):\(port)"
    }
}

let dataDirPath: String = {
    let dir = NSHomeDirectory() + "/.litellmStats"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)

    // 兼容旧版本数据目录 ~/.litellm/menubar
    let legacyDir = NSHomeDirectory() + "/.litellm/menubar"
    let src = legacyDir + "/config.json"
    let dst = dir + "/config.json"
    if fm.fileExists(atPath: src), !fm.fileExists(atPath: dst),
       (try? fm.copyItem(atPath: src, toPath: dst)) != nil {
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst)
    }
    return dir
}()

let configPath = dataDirPath + "/config.json"
let usageCachePath = dataDirPath + "/usage-cache.json"

/// 最近一次成功查询的结果，查询失败时用它在菜单栏继续展示
struct UsageCacheFile: Codable {
    var date: String
    var usage: [String: [String: Double]]
}

func saveUsageCache(_ usage: [String: ModelUsage]) {
    var encoded: [String: [String: Double]] = [:]
    for (alias, model) in usage {
        var values: [String: Double] = [:]
        for key in UsageMetricKey.allCases {
            values[key.rawValue] = model.value(for: key)
        }
        encoded[alias] = values
    }
    let file = UsageCacheFile(date: localDateKey(), usage: encoded)
    guard let data = try? JSONEncoder().encode(file) else { return }
    try? data.write(to: URL(fileURLWithPath: usageCachePath), options: .atomic)
}

func loadUsageCache() -> [String: ModelUsage]? {
    guard let data = FileManager.default.contents(atPath: usageCachePath),
          let file = try? JSONDecoder().decode(UsageCacheFile.self, from: data),
          file.date == localDateKey() else {
        return nil
    }
    var usage: [String: ModelUsage] = [:]
    for (alias, values) in file.usage {
        let model = ModelUsage()
        for key in UsageMetricKey.allCases {
            model.set(key, values[key.rawValue] ?? 0)
        }
        if model.requests > 0 || model.total > 0 {
            usage[alias] = model
        }
    }
    return usage
}

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
    if let limit = obj["daily_token_limit"] as? Int, limit >= 0 { cfg.dailyTokenLimit = limit }
    return cfg
}

func saveConfig(_ cfg: AppConfig) {
    var obj: [String: Any] = [
        "host": cfg.host,
        "port": cfg.port,
        "refresh_seconds": cfg.refreshSeconds
    ]
    if !cfg.apiKey.isEmpty { obj["api_key"] = cfg.apiKey }
    // 始终写入，0 表示明确关闭限额
    obj["daily_token_limit"] = cfg.dailyTokenLimit

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

func localDateKey(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

// MARK: - 管理 API（/user/daily/activity）

struct DailyActivityResponse: Decodable {
    struct Metrics: Decodable {
        let promptTokens: Double?
        let completionTokens: Double?
        let totalTokens: Double?
        let cacheReadInputTokens: Double?
        let apiRequests: Double?
        let failedRequests: Double?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case apiRequests = "api_requests"
            case failedRequests = "failed_requests"
        }
    }

    struct Group: Decodable {
        let metrics: Metrics?
    }

    struct Breakdown: Decodable {
        let modelGroups: [String: Group]?

        enum CodingKeys: String, CodingKey {
            case modelGroups = "model_groups"
        }
    }

    struct Result: Decodable {
        let date: String
        let breakdown: Breakdown?
    }

    let results: [Result]?
}

/// 解析当天各模型（按 model_group 别名）的用量。解析失败返回 nil。
func parseDailyActivity(_ data: Data) -> [String: ModelUsage]? {
    guard let response = try? JSONDecoder().decode(DailyActivityResponse.self, from: data),
          let results = response.results else {
        return nil
    }
    let today = localDateKey()
    guard let result = results.first(where: { $0.date == today }) ?? results.first else {
        return [:]   // 当天没有记录
    }

    var usage: [String: ModelUsage] = [:]
    for (alias, group) in result.breakdown?.modelGroups ?? [:] {
        guard let metrics = group.metrics else { continue }
        let model = ModelUsage()
        model.requests = metrics.apiRequests ?? 0
        model.failed = metrics.failedRequests ?? 0
        model.input = metrics.promptTokens ?? 0
        model.output = metrics.completionTokens ?? 0
        model.total = metrics.totalTokens ?? 0
        model.cached = metrics.cacheReadInputTokens ?? 0
        if model.requests > 0 || model.total > 0 {
            usage[alias] = model
        }
    }
    return usage
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

// MARK: - 每日限额曲线（9:00–19:00 线性分配）

struct UsagePace {
    let limit: Double
    let actual: Double
    let expected: Double
}

/// 按 9:00–19:00 线性分配每日限额，计算当前时刻的应达用量
func usagePace(actual: Double, limit: Int, at date: Date = Date()) -> UsagePace? {
    guard limit > 0 else { return nil }
    let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
    let hour = Double(comps.hour ?? 0)
    let minute = Double(comps.minute ?? 0)
    let second = Double(comps.second ?? 0)
    let seconds = hour * 3600 + minute * 60 + second
    let start = 9.0 * 3600
    let end = 19.0 * 3600
    let limitValue = Double(limit)
    let expected: Double
    if seconds <= start {
        expected = 0
    } else if seconds >= end {
        expected = limitValue
    } else {
        expected = limitValue * (seconds - start) / (end - start)
    }
    return UsagePace(limit: limitValue, actual: actual, expected: expected)
}

/// 限额余量描述：<0.8 充足（绿），0.8–1.0 勉强（黄），1.0–1.2 不足（橙），>1.2 严重不足（红）
func paceDescription(_ pace: UsagePace) -> String {
    if pace.expected <= 0 {
        return pace.actual > 0 ? "提前消耗" : "等待 9:00"
    }
    let ratio = pace.actual / pace.expected
    if ratio < 0.8 { return "充足" }
    if ratio < 1.0 { return "勉强" }
    if ratio <= 1.2 { return "不足" }
    return "严重不足"
}

private struct PaceRGB {
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat
}

private let paceGreen = (light: PaceRGB(r: 0.11, g: 0.60, b: 0.27),
                         dark: PaceRGB(r: 0.32, g: 0.85, b: 0.45))
private let paceYellow = (light: PaceRGB(r: 0.55, g: 0.42, b: 0.00),
                          dark: PaceRGB(r: 1.00, g: 0.84, b: 0.25))
private let paceOrange = (light: PaceRGB(r: 0.62, g: 0.40, b: 0.10),
                          dark: PaceRGB(r: 0.95, g: 0.66, b: 0.34))
private let paceRed = (light: PaceRGB(r: 0.72, g: 0.16, b: 0.13),
                       dark: PaceRGB(r: 0.90, g: 0.38, b: 0.35))

// (比例, 浅色, 深色)：区间内保持纯色，分界处窄幅渐变
private let paceColorStops: [(ratio: Double, light: PaceRGB, dark: PaceRGB)] = [
    (0.00, paceGreen.light, paceGreen.dark),
    (0.76, paceGreen.light, paceGreen.dark),
    (0.84, paceYellow.light, paceYellow.dark),
    (0.96, paceYellow.light, paceYellow.dark),
    (1.04, paceOrange.light, paceOrange.dark),
    (1.16, paceOrange.light, paceOrange.dark),
    (1.24, paceRed.light, paceRed.dark),
    (3.00, paceRed.light, paceRed.dark),
]

private func interpolatePaceRGB(_ ratio: Double, dark: Bool) -> PaceRGB {
    let stops = paceColorStops
    if ratio <= stops[0].ratio {
        return dark ? stops[0].dark : stops[0].light
    }
    for i in 1..<stops.count {
        let prev = stops[i - 1]
        let next = stops[i]
        guard ratio <= next.ratio else { continue }
        let span = next.ratio - prev.ratio
        let t = span > 0 ? CGFloat((ratio - prev.ratio) / span) : 0
        let a = dark ? prev.dark : prev.light
        let b = dark ? next.dark : next.light
        return PaceRGB(r: a.r + (b.r - a.r) * t,
                       g: a.g + (b.g - a.g) * t,
                       b: a.b + (b.b - a.b) * t)
    }
    let last = stops[stops.count - 1]
    return dark ? last.dark : last.light
}

/// 曲线尚未开始且没有用量时返回 nil（使用系统默认文字颜色）
func paceColor(_ pace: UsagePace) -> NSColor? {
    let ratio: Double
    if pace.expected <= 0 {
        guard pace.actual > 0 else { return nil }
        ratio = 3.0
    } else {
        ratio = pace.actual / pace.expected
    }
    return NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let c = interpolatePaceRGB(ratio, dark: dark)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
}

/// 设置界面里的展示形式：100000000 -> 100m
func formatTokenLimit(_ value: Int) -> String {
    if value <= 0 { return "" }
    if value % 1_000_000 == 0 { return "\(value / 1_000_000)m" }
    if value % 1_000 == 0 { return "\(value / 1_000)k" }
    return String(value)
}

/// 支持 10m / 500k 这类写法；空字符串或 0 表示不限制
func parseTokenLimit(_ text: String) -> Int? {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value.isEmpty { return 0 }
    var multiplier = 1.0
    if value.hasSuffix("m") {
        multiplier = 1_000_000
        value.removeLast()
    } else if value.hasSuffix("k") {
        multiplier = 1_000
        value.removeLast()
    } else if value.hasSuffix("b") {
        multiplier = 1_000_000_000
        value.removeLast()
    }
    guard let number = Double(value), number.isFinite, number >= 0 else { return nil }
    let result = number * multiplier
    guard result < Double(Int.max) else { return nil }
    return Int(result)
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var config = AppConfig()
    private var usage: [String: ModelUsage] = [:]
    private var errorText: String?
    private var lastUpdated: Date?
    private var isRefreshing = false
    private static let maxRetries = 3

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

        // 先用本地持久化数据渲染，查询失败时也能显示上次用量
        usage = loadUsageCache() ?? [:]
        updateStatusTitle()

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

    /// 仅用于让限额行保持启用态，避免系统把彩色文字调灰
    @objc private func noopAction() {}


    @objc private func showSettings() {
        let alert = NSAlert()
        alert.messageText = "LiteLLmStats \(appVersion) 设置"
        alert.informativeText = "配置 LiteLLM 网关地址、刷新频率、每日限额和访问密钥。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 204))

        func makeLabel(_ text: String, y: CGFloat) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: 0, y: y, width: 120, height: 20)
            label.alignment = .right
            return label
        }

        func makeField(_ value: String, y: CGFloat, placeholder: String = "") -> NSTextField {
            let field = NSTextField(string: value)
            field.frame = NSRect(x: 130, y: y, width: 240, height: 24)
            field.placeholderString = placeholder
            field.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize,
                                                     weight: .regular)
            return field
        }

        let hostField = makeField(config.host, y: 172)
        let portField = makeField(String(config.port), y: 140)
        let intervalField = makeField(String(config.refreshSeconds), y: 108)
        let limitField = makeField(
            formatTokenLimit(config.dailyTokenLimit),
            y: 76, placeholder: "默认 100m，留空或 0 不限"
        )
        let keyField = makeField(config.apiKey, y: 44,
                                 placeholder: "留空则读取 ~/.litellm/config.yaml")

        let autostartCheckbox = NSButton(checkboxWithTitle: "开机自动启动",
                                         target: nil, action: nil)
        autostartCheckbox.frame = NSRect(x: 130, y: 10, width: 240, height: 20)
        autostartCheckbox.state = isAutostartEnabled() ? .on : .off

        accessory.addSubview(makeLabel("网关地址 / IP", y: 174))
        accessory.addSubview(hostField)
        accessory.addSubview(makeLabel("端口", y: 142))
        accessory.addSubview(portField)
        accessory.addSubview(makeLabel("刷新间隔(秒)", y: 110))
        accessory.addSubview(intervalField)
        accessory.addSubview(makeLabel("每日 Token 限制", y: 78))
        accessory.addSubview(limitField)
        accessory.addSubview(makeLabel("访问密钥", y: 46))
        accessory.addSubview(keyField)
        accessory.addSubview(autostartCheckbox)

        alert.accessoryView = accessory

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let interval = Int(intervalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let limit = parseTokenLimit(limitField.stringValue)

        guard !host.isEmpty, (1...65535).contains(port), (2...3600).contains(interval),
              let dailyLimit = limit else {
            let warning = NSAlert()
            warning.alertStyle = .warning
            warning.messageText = "配置无效"
            warning.informativeText = "地址不能为空，端口范围 1-65535，刷新间隔 2-3600 秒，每日限额需为非负数字（可写 10m / 500k，留空为不限）。"
            warning.runModal()
            return
        }

        config.host = host
        config.port = port
        config.refreshSeconds = interval
        config.dailyTokenLimit = dailyLimit
        config.apiKey = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        saveConfig(config)

        let autostart = autostartCheckbox.state == .on
        setAutostart(enabled: autostart)

        print("[LiteLLmStats] config updated: \(config.endpointDescription) every \(config.refreshSeconds)s autostart=\(autostart)")

        scheduleTimer()
        refresh()
    }

    private func refresh() {
        guard !isRefreshing else { return }
        guard let key = resolveAPIKey(config) else {
            print("[LiteLLmStats] error: api key not found")
            errorText = "未配置访问密钥（config.json 或 config.yaml）"
            updateStatusTitle()
            return
        }
        guard let url = config.dailyActivityURL else {
            print("[LiteLLmStats] error: invalid api url")
            errorText = "网关地址配置无效"
            updateStatusTitle()
            return
        }

        isRefreshing = true
        startRequest(url: url, key: key, attempt: 0)
    }

    private func startRequest(url: URL, key: String, attempt: Int) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? -1
                let failed = error != nil || status != 200
                // 401/403/404/405 通常是配置或权限问题，重试没有意义
                let definitiveError = [401, 403, 404, 405].contains(status)

                if failed && !definitiveError && attempt < Self.maxRetries {
                    print("[LiteLLmStats] retry \(attempt + 1)/\(Self.maxRetries) after error: \(error?.localizedDescription ?? "http \(status)")")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.startRequest(url: url, key: key, attempt: attempt + 1)
                    }
                    return
                }

                if failed {
                    self.isRefreshing = false
                    let message = error?.localizedDescription ?? "HTTP \(status)"
                    print("[LiteLLmStats] api error: \(message)")
                    self.errorText = message
                    self.updateStatusTitle()
                    return
                }

                guard let data = data, let apiUsage = parseDailyActivity(data) else {
                    self.isRefreshing = false
                    print("[LiteLLmStats] api parse failed")
                    self.errorText = "用量接口返回数据无法解析"
                    self.updateStatusTitle()
                    return
                }

                self.usage = apiUsage
                saveUsageCache(apiUsage)
                self.finishSuccess()
            }
        }.resume()
    }

    private func finishSuccess() {
        isRefreshing = false
        errorText = nil
        lastUpdated = Date()
        updateStatusTitle()

        let t = totals()
        print("[LiteLLmStats] ok \(config.endpointDescription) today models=\(usage.count) requests=\(Int(t.req)) tokens=\(Int(t.total)) cached=\(Int(t.cached))")
        if let pace = usagePace(actual: t.total, limit: config.dailyTokenLimit) {
            let ratio = pace.expected > 0 ? pace.actual / pace.expected : 0
            print("[LiteLLmStats] pace limit=\(Int(pace.limit)) expected=\(Int(pace.expected)) ratio=\(String(format: "%.2f", ratio)) state=\(paceDescription(pace))")
        }
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

    private func setStatusTitle(_ text: String, color: NSColor?) {
        guard let button = statusItem.button else { return }
        if let color = color {
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                        weight: .regular)
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
            ])
        } else {
            button.title = text
        }
    }

    private func paceTooltipSuffix(for total: Double) -> String {
        guard let pace = usagePace(actual: total, limit: config.dailyTokenLimit) else {
            return ""
        }
        return String(format: " · 限额 %@（曲线应达 %@，%@）",
                      fmtTokens(pace.limit), fmtTokens(pace.expected), paceDescription(pace))
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }

        if let errorText = errorText {
            let t = totals()
            if t.total > 0 || t.req > 0 {
                // 查询失败时继续显示本地保存的上次用量
                let pace = usagePace(actual: t.total, limit: config.dailyTokenLimit)
                setStatusTitle(" 今日 " + fmtTokens(t.total), color: pace.flatMap(paceColor))
                button.toolTip = "LiteLLM 指标不可用，显示本地缓存数据：\(errorText)"
                    + paceTooltipSuffix(for: t.total)
            } else {
                button.title = " ⚠︎"
                button.toolTip = "LiteLLM 指标不可用：\(errorText)"
            }
            return
        }

        let t = totals()
        let cacheRate = t.input > 0 ? t.cached / t.input * 100 : 0
        let pace = usagePace(actual: t.total, limit: config.dailyTokenLimit)
        setStatusTitle(" 今日 " + fmtTokens(t.total), color: pace.flatMap(paceColor))
        button.toolTip = String(
            format: "LiteLLM 今日用量 · %@ 次请求 · 输入 %@ / 输出 %@ · 缓存命中 %.1f%%",
            fmtCount(t.req), fmtTokens(t.input), fmtTokens(t.output), cacheRate
        ) + paceTooltipSuffix(for: t.total)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.isEnabled = false
        if let errorText = errorText {
            header.title = usage.isEmpty
                ? "⚠︎ \(errorText)"
                : "⚠︎ \(errorText) · 显示本地缓存"
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
            let sortedAliases = usage.keys.sorted { lhs, rhs in
                let l = usage[lhs]!, r = usage[rhs]!
                if l.total != r.total { return l.total > r.total }
                if l.requests != r.requests { return l.requests > r.requests }
                return lhs < rhs
            }
            for alias in sortedAliases {
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

            if let pace = usagePace(actual: t.total, limit: config.dailyTokenLimit) {
                menu.addItem(.separator())
                let percent = pace.expected > 0
                    ? String(format: "%.0f%%", pace.actual / pace.expected * 100)
                    : "—"
                let title = String(
                    format: "每日限额 %@ · 曲线应达 %@ · 当前占曲线 %@（%@）",
                    fmtTokens(pace.limit), fmtTokens(pace.expected), percent,
                    paceDescription(pace)
                )
                // 用空 action 保持启用态：禁用态会被系统整体调灰，黄色在灰色底上几乎看不清
                let limitItem = NSMenuItem(title: title, action: #selector(noopAction),
                                           keyEquivalent: "")
                limitItem.target = self
                limitItem.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.foregroundColor: paceColor(pace) ?? NSColor.labelColor]
                )
                menu.addItem(limitItem)
            }
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
