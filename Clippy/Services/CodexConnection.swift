import AppKit
import Foundation

/// Uses Codex's supported JSON-RPC interface. OAuth tokens are owned by Codex,
/// in a Clippy-specific credential store, and never read by this app.
@MainActor
final class CodexConnection: ObservableObject {
    static let shared = CodexConnection()
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var status = "Connect your ChatGPT account to use its Codex allowance."
    @Published var userCode: String?
    @Published var verificationURL: URL?

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var sequence = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var startup: Task<Void, Error>?
    private var loginID: String?
    private var loginAttempt: UUID?
    private var loginTimeout: Task<Void, Never>?
    private var activeThread: String?
    private var answer = ""
    private var completion: CheckedContinuation<String, Error>?
    private var replyTimeout: Task<Void, Never>?
    private var generation = UUID()
    private let executableOverride: URL?
    private let rootOverride: URL?

    init(executableURL: URL? = nil, rootURL: URL? = nil) {
        executableOverride = executableURL
        rootOverride = rootURL
    }

    private var root: URL {
        rootOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippy/Codex", isDirectory: true)
    }

    func connect() async {
        guard !isConnecting else { return }
        let attempt = UUID()
        loginAttempt = attempt
        isConnecting = true
        status = "Opening ChatGPT sign-in…"
        do {
            try await start()
            guard loginAttempt == attempt, isConnecting else { return }
            let result = try await rpc("account/login/start", [
                "type": "chatgpt", "useHostedLoginSuccessPage": true
            ])
            guard loginAttempt == attempt, isConnecting else {
                if let id = result["loginId"] as? String {
                    sendNotificationRequest("account/login/cancel", ["loginId": id])
                }
                return
            }
            guard let id = result["loginId"] as? String,
                  let address = result["authUrl"] as? String,
                  let url = URL(string: address), url.scheme == "https",
                  ["auth.openai.com", "chatgpt.com"].contains(url.host ?? "") else {
                throw TextAIError.message("ChatGPT sign-in isn't available. Please try again.")
            }
            loginID = id
            userCode = nil
            verificationURL = url
            status = "Complete ChatGPT sign-in in your browser."
            NSWorkspace.shared.open(url)
            loginTimeout?.cancel()
            loginTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000_000)
                guard !Task.isCancelled else { return }
                self?.cancelLogin()
            }
        } catch {
            guard loginAttempt == attempt else { return }
            isConnecting = false
            status = safeMessage(error)
        }
    }

    func refreshAccount() async {
        do {
            try await start()
            let result = try await rpc("account/read", ["refreshToken": false])
            let account = result["account"] as? [String: Any]
            isConnected = account?["type"] as? String == "chatgpt"
            status = isConnected ? "ChatGPT connected. Your Codex plan limits apply." : "Connect your ChatGPT account to use its Codex allowance."
        } catch {
            isConnected = false
            status = safeMessage(error)
        }
    }

    func disconnectAccount() async {
        cancelReply()
        cancelLogin()
        do {
            try await start()
            _ = try await rpc("account/logout")
            isConnected = false
            status = "ChatGPT disconnected from Clippy."
            stop()
        } catch {
            status = "Couldn't sign out. Try again before removing Clippy."
        }
    }

    func cancelLogin() {
        loginAttempt = nil
        if let loginID { sendNotificationRequest("account/login/cancel", ["loginId": loginID]) }
        loginID = nil
        userCode = nil
        verificationURL = nil
        isConnecting = false
        loginTimeout?.cancel()
        loginTimeout = nil
        if !isConnected { status = "Sign-in cancelled. You can connect again." }
    }

    func reply(to prompt: String) async throws -> String {
        try await start()
        try Task.checkCancellation()
        let account = try await rpc("account/read", ["refreshToken": false])["account"] as? [String: Any]
        guard account?["type"] as? String == "chatgpt" else {
            isConnected = false
            throw TextAIError.message("Connect your ChatGPT account in Settings first.")
        }
        isConnected = true
        let result = try await rpc("thread/start", [
            "cwd": root.appendingPathComponent("workspace").path,
            "ephemeral": true,
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "environments": [],
            "baseInstructions": "You are Clippy, a concise text assistant. Answer only from the user's message. You have no access to their clipboard or files. Do not use tools, browse, execute commands, or modify anything.",
            "config": [
                "features.shell_tool": false,
                "features.unified_exec": false,
                "features.apply_patch_freeform": false,
                "features.multi_agent": false,
                "tools.view_image": false,
                "web_search": "disabled"
            ]
        ])
        try Task.checkCancellation()
        guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
            throw TextAIError.message("Couldn't start a ChatGPT conversation.")
        }
        activeThread = id
        answer = ""
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                replyTimeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 180_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(TextAIError.message("ChatGPT took too long. Try again.")))
                    self?.stop()
                }
                Task {
                    do {
                        _ = try await rpc("turn/start", [
                            "threadId": id,
                            "input": [["type": "text", "text": prompt]],
                            "environments": []
                        ])
                    } catch {
                        if activeThread == id { finish(.failure(error)) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.activeThread == id { self?.cancelReply() }
            }
        }
    }

    func cancelReply() {
        guard activeThread != nil || completion != nil else { return }
        finish(.failure(CancellationError()))
        // Closing the stdio server cancels its running turn and any descendants.
        stop()
    }

    private func start() async throws {
        if let startup { return try await startup.value }
        if process?.isRunning == true { return }
        let task = Task { try await launch() }
        startup = task
        defer { startup = nil }
        try await task.value
    }

    private func launch() async throws {
        let executable = executableOverride ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/codex")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw TextAIError.message("The ChatGPT component is missing. Reinstall the complete Clippy app.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("workspace"), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        // This directory belongs only to Clippy. Do not load the user's Codex
        // configuration, MCP servers, hooks, plugins, or existing credentials.
        let config = """
        cli_auth_credentials_store = "keyring"
        forced_login_method = "chatgpt"
        web_search = "disabled"
        [analytics]
        enabled = false
        [history]
        persistence = "none"
        [features]
        shell_tool = false
        unified_exec = false
        apply_patch_freeform = false
        multi_agent = false
        shell_snapshot = false
        apps = false
        plugins = false
        hooks = false
        computer_use = false
        browser_use = false
        browser_use_external = false
        browser_use_full_cdp_access = false
        in_app_browser = false
        image_generation = false
        view_image = false
        code_mode_host = false
        skill_search = false
        skill_mcp_dependency_install = false
        workspace_dependencies = false
        remote_plugin = false
        skip_host_skill_discovery = true
        [tools]
        view_image = false
        """
        try config.write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let child = Process()
        child.executableURL = executable
        child.arguments = ["app-server", "--listen", "stdio://"]
        child.currentDirectoryURL = root.appendingPathComponent("workspace")
        // Do not inherit API keys, override endpoints, proxies, or developer hooks.
        let inherited = ProcessInfo.processInfo.environment
        var env = [String: String]()
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] { env[key] = inherited[key] }
        env["PATH"] = "/usr/bin:/bin"
        env["CODEX_HOME"] = root.path
        child.environment = env
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = FileHandle.nullDevice
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        buffer = Data()
        let token = UUID()
        generation = token
        output?.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                if bytes.isEmpty { self.transportEnded(); return }
                self.receive(bytes)
            }
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard self?.generation == token else { return }
                self?.transportEnded()
            }
        }
        process = child
        do {
            try child.run()
            _ = try await rpc("initialize", [
                "clientInfo": ["name": "clippy", "title": "Clippy", "version": "1.3.0"],
                "capabilities": ["experimentalApi": true]
            ])
            try send(["method": "initialized", "params": [:]])
        } catch {
            stop()
            throw TextAIError.message("Couldn't start the ChatGPT component. Reinstall Clippy or try again.")
        }
    }

    private func rpc(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        sequence += 1
        let id = sequence
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.pending.removeValue(forKey: id)?.resume(throwing: TextAIError.message("ChatGPT didn't respond. Please try again."))
                self.timeouts.removeValue(forKey: id)
            }
            do { try send(["id": id, "method": method, "params": params]) }
            catch {
                timeouts.removeValue(forKey: id)?.cancel()
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    private func sendNotificationRequest(_ method: String, _ params: [String: Any]) {
        sequence += 1
        try? send(["id": sequence, "method": method, "params": params])
    }

    private func send(_ json: [String: Any]) throws {
        guard process?.isRunning == true, let input else { throw TextAIError.message("ChatGPT is disconnected.") }
        var data = try JSONSerialization.data(withJSONObject: json)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(_ bytes: Data) {
        buffer.append(bytes)
        guard buffer.count <= 4_000_000 else { transportEnded(); return }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let data = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let method = json["method"] as? String {
                if let id = json["id"] {
                    // No tool executions, permission grants, or other server requests.
                    try? send(["id": id, "error": ["code": -32601, "message": "Clippy supports text replies only."]])
                } else {
                    event(method, json["params"] as? [String: Any] ?? [:])
                }
            } else if let id = json["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                timeouts.removeValue(forKey: id)?.cancel()
                if json["error"] != nil {
                    continuation.resume(throwing: TextAIError.message("Codex couldn't complete this request. Check your ChatGPT access and try again."))
                } else {
                    continuation.resume(returning: json["result"] as? [String: Any] ?? [:])
                }
            }
        }
    }

    private func event(_ method: String, _ params: [String: Any]) {
        switch method {
        case "account/login/completed":
            guard let id = params["loginId"] as? String, id == loginID else { return }
            isConnecting = false
            loginID = nil
            userCode = nil
            verificationURL = nil
            loginTimeout?.cancel()
            isConnected = params["success"] as? Bool == true
            status = isConnected ? "ChatGPT connected. Your Codex plan limits apply." : "Sign-in wasn't completed. Try again."
        case "account/updated":
            isConnected = params["authMode"] as? String == "chatgpt"
        case "item/completed":
            guard params["threadId"] as? String == activeThread,
                  let item = params["item"] as? [String: Any],
                  item["type"] as? String == "agentMessage",
                  let text = item["text"] as? String else { return }
            if item["phase"] as? String != "commentary" { answer = text }
        case "turn/completed":
            guard params["threadId"] as? String == activeThread else { return }
            let turn = params["turn"] as? [String: Any]
            if turn?["status"] as? String == "completed", !answer.isEmpty {
                finish(.success(answer))
            } else {
                finish(.failure(TextAIError.message("ChatGPT couldn't finish the answer. Check your plan limits and try again.")))
            }
        default: break
        }
    }

    private func finish(_ result: Result<String, Error>) {
        replyTimeout?.cancel()
        replyTimeout = nil
        let callback = completion
        completion = nil
        activeThread = nil
        answer = ""
        callback?.resume(with: result)
    }

    private func transportEnded() {
        finish(.failure(TextAIError.message("The ChatGPT connection ended. Try again.")))
        stop()
        isConnected = false
        status = "The ChatGPT connection ended. Try again."
    }

    func stop() {
        finish(.failure(CancellationError()))
        cancelLogin()
        generation = UUID()
        output?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        let callbacks = Array(pending.values)
        pending.removeAll()
        for callback in callbacks { callback.resume(throwing: TextAIError.message("ChatGPT is disconnected.")) }
        buffer = Data()
    }

    private func safeMessage(_ error: Error) -> String {
        (error as? TextAIError)?.errorDescription ?? "Couldn't connect ChatGPT. Please try again."
    }
}
