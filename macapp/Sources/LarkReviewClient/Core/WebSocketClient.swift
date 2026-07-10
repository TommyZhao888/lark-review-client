import Foundation

/// WS 连接状态机（对齐 Node 版 connect()）：
/// - 连上即发 register（不上报 open_id/name，由服务端按 token 解析下发，防冒名）
/// - 心跳每 heartbeatMs；断连指数退避 1s ×2 封顶 30s，连上重置
/// - everRegistered 后的断开才算「掉线」（弹通知）；重连收到 register_ack 后发 reconnected
/// - register_reject → halted：暂停自动重连，等用户改 token 后手动 reconnect
/// - 每次重连新建 task，用 epoch 防旧 receive 循环触发二次重连
@MainActor
final class WebSocketClient: NSObject {

    // 事件回调（AppRuntime 接线）
    var onRegisterAck: ((RegisterAck, _ wasReconnect: Bool) -> Void)?
    var onReposUpdated: (([ManagedRepo]) -> Void)?
    var onRegisterReject: ((String) -> Void)?
    var onReviewJob: ((ReviewJob) -> Void)?
    var onPrClosed: ((PrClosed) -> Void)?
    var onStateChange: ((AppState.ConnectionState) -> Void)?
    var onDisconnected: ((_ everRegistered: Bool) -> Void)?
    /// 每个收/发的原始文本帧（outbound = client→server），供 WS 消息日志。
    var onFrame: ((_ outbound: Bool, _ text: String) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var epoch = 0                       // 递增代号：旧连接的回调发现代号过期即忽略
    private var config = Config()

    private var reconnectDelay: TimeInterval = 1.0
    private var connected = false
    private var registered = false
    private var everRegistered = false          // 曾成功注册过 → 之后的断开算「重连」
    private var pendingReconnect = false        // 断开后置真，下次 register_ack 时视为重连
    private var halted = false                  // 注册被拒时置真：暂停自动重连
    private var heartbeatTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    var isHalted: Bool { halted }

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    // ---------- 对外操作 ----------

    func start(config: Config) {
        self.config = config
        guard config.isReady else {
            LogStore.shared.log("尚未配置(缺 serverUrl/token)，暂不连接")
            return
        }
        connect()
    }

    /// 设置保存后的热重载：解除 halted，断开旧连接按新配置重连（对齐 reloadAndReconnect）。
    func reconnect(with newConfig: Config) {
        halted = false
        config = newConfig
        reconnectDelay = 1.0
        reconnectTask?.cancel()
        reconnectTask = nil
        guard config.isReady else {
            LogStore.shared.log("配置仍不完整(缺 serverUrl/token)，暂不连接")
            return
        }
        if let task, connected {
            LogStore.shared.log("config 已重载，断开旧连接按新设置重连")
            task.cancel(with: .goingAway, reason: nil)
            // didClose 回调会走 handleDisconnect → 自动重连（halted 已解除）
        } else {
            LogStore.shared.log("config 已就绪，开始连接")
            connect()
        }
    }

    func shutdown() {
        epoch += 1
        heartbeatTask?.cancel()
        pingTask?.cancel()
        reconnectTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    func send(_ msg: OutboundMessage) {
        guard let task, connected else { return }
        guard let text = try? msg.encodedString() else { return }
        onFrame?(true, text)
        let myEpoch = epoch
        task.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, self.epoch == myEpoch else { return }
                self.handleDisconnect()
            }
        }
    }

    // ---------- 连接 ----------

    private func connect() {
        guard let url = URL(string: config.serverUrl) else {
            LogStore.shared.log("serverUrl 非法: \(config.serverUrl)")
            return
        }
        LogStore.shared.log("connecting \(config.serverUrl) …")
        onStateChange?(.connecting)

        epoch += 1
        let myEpoch = epoch
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop(t, myEpoch)
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask, _ myEpoch: Int) {
        Task { [weak self] in
            while true {
                do {
                    let msg = try await t.receive()
                    guard let self, self.epoch == myEpoch else { return }
                    if case let .string(text) = msg {
                        self.onFrame?(false, text)
                        self.handleMessage(text)
                    }
                } catch {
                    guard let self else { return }
                    await MainActor.run {
                        guard self.epoch == myEpoch else { return }
                        self.handleDisconnect()
                    }
                    return
                }
            }
        }
    }

    /// URLSessionWebSocketDelegate didOpen 触发：发 register + 起心跳/ping。
    private func handleOpen() {
        reconnectDelay = 1.0
        connected = true
        onStateChange?(.connected)
        let myEpoch = epoch
        Task { @MainActor [weak self] in
            guard let self, self.epoch == myEpoch else { return }
            let hostname = await detectHostname()
            guard self.epoch == myEpoch else { return }
            self.send(.register(
                token: self.config.token,
                hostname: hostname,
                repos: Array(self.config.repos.keys),
                version: CLIENT_VERSION,
                quota: QuotaMonitor.shared.current(config: self.config)
            ))
        }
        startHeartbeat()
        startPing()
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let interval = config.heartbeatInterval
        let myEpoch = epoch
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, self.epoch == myEpoch, !Task.isCancelled else { return }
                self.send(.heartbeat(quota: QuotaMonitor.shared.current(config: self.config)))
            }
        }
    }

    /// 协议层 ping：网络静默死连接（合盖换网）时 receive 可能长时间不报错，30s ping 兜底。
    private func startPing() {
        pingTask?.cancel()
        let myEpoch = epoch
        pingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.epoch == myEpoch, !Task.isCancelled, let task = self.task else { return }
                task.sendPing { [weak self] error in
                    guard error != nil else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.epoch == myEpoch else { return }
                        self.handleDisconnect()
                    }
                }
            }
        }
    }

    // ---------- 消息处理 ----------

    private func handleMessage(_ text: String) {
        guard let msg = InboundMessage.parse(text) else { return }
        switch msg {
        case .registerAck(let ack):
            registered = true
            halted = false
            let wasReconnect = pendingReconnect
            pendingReconnect = false
            everRegistered = true
            onStateChange?(.registered)
            LogStore.shared.log("registered as \(ack.name ?? "?") (\(ack.open_id ?? "?")) ✓  本机 v\(CLIENT_VERSION)，服务端推荐 v\(ack.recommended_version ?? "?")")
            onRegisterAck?(ack, wasReconnect)

        case .reposUpdated(let upd):
            if let repos = upd.managed_repos {
                LogStore.shared.log("服务端受管 repo 清单已更新: [\(repos.map(\.repo).joined(separator: ", "))]")
                onReposUpdated?(repos)
            }

        case .registerReject(let rej):
            // 不退出：停止自动重连，等用户在设置里改 token（对齐 Node，避免鸡生蛋）。
            halted = true
            registered = false
            let reason = rej.reason ?? "unknown"
            LogStore.shared.log("注册被拒: \(reason)(token 不对)。已暂停自动重连，请在设置里更换 token 后保存。")
            heartbeatTask?.cancel()
            pingTask?.cancel()
            onStateChange?(.halted(reason))
            onRegisterReject?(reason)
            task?.cancel(with: .normalClosure, reason: nil)

        case .reviewJob(let job):
            LogStore.shared.log("got review_job \(job.job_id) pr=#\(job.pr_num) repo=\(job.repo) branch=\(job.branch ?? "")\(job.provider == "azdo" ? " provider=azdo" : "")")
            onReviewJob?(job)

        case .prClosed(let pc):
            onPrClosed?(pc)
        }
    }

    // ---------- 断连与重连 ----------

    private func handleDisconnect() {
        let wasEverRegistered = everRegistered
        connected = false
        registered = false
        heartbeatTask?.cancel()
        pingTask?.cancel()
        task = nil
        epoch += 1   // 作废本连接的一切后续回调

        if halted {
            LogStore.shared.log("已暂停自动重连(等待改 token)。")
            return
        }
        onStateChange?(.disconnected)
        // 曾注册过才算「掉线重连」（首次连不上不弹）。
        if wasEverRegistered, !pendingReconnect {
            pendingReconnect = true
            onDisconnected?(true)
        }
        LogStore.shared.log("disconnected; reconnecting in \(Int(reconnectDelay * 1000))ms")
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.halted else { return }
            self.connect()
        }
    }
}

extension WebSocketClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self, webSocketTask === self.task else { return }
            self.handleOpen()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        Task { @MainActor [weak self] in
            guard let self, webSocketTask === self.task else { return }
            self.handleDisconnect()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self, task === self.task else { return }
            self.handleDisconnect()
        }
    }
}
