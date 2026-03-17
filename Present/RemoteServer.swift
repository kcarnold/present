import Foundation
import Network

extension Notification.Name {
    static let remotePlay = Notification.Name("remotePlay")
    static let remoteStop = Notification.Name("remoteStop")
    static let remoteScroll = Notification.Name("remoteScroll")
}

@MainActor
final class RemoteServer {
    private var listener: NWListener?
    private var state: PresentationState?

    func start(state: PresentationState) {
        self.state = state
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: 9123)
        } catch {
            print("RemoteServer: failed to create listener: \(error)")
            return
        }
        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }
        listener?.stateUpdateHandler = { newState in
            print("RemoteServer: \(newState)")
        }
        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            let request = String(data: data, encoding: .utf8) ?? ""
            let response = self.route(request)
            let responseData = Data(response.utf8)
            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func route(_ raw: String) -> String {
        let firstLine = raw.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let path = parts.count >= 2 ? String(parts[1]) : "/"

        switch path {
        case "/next":
            state?.goToNext()
            return jsonResponse("ok")
        case "/prev":
            state?.goToPrevious()
            return jsonResponse("ok")
        case "/play":
            NotificationCenter.default.post(name: .remotePlay, object: nil)
            return jsonResponse("ok")
        case "/stop":
            NotificationCenter.default.post(name: .remoteStop, object: nil)
            return jsonResponse("ok")
        case "/zoomin":
            state?.zoomIn()
            return jsonResponse("ok")
        case "/zoomout":
            state?.zoomOut()
            return jsonResponse("ok")
        case _ where path.hasPrefix("/scroll"):
            if let query = path.split(separator: "?").last,
               let dyParam = query.split(separator: "=").last,
               let dy = Double(dyParam) {
                NotificationCenter.default.post(name: .remoteScroll, object: nil, userInfo: ["dy": dy])
            }
            return jsonResponse("ok")
        case "/status":
            return statusResponse()
        case "/slides":
            return slidesResponse()
        case _ where path.hasPrefix("/goto"):
            if let q = path.split(separator: "?").last,
               let p = q.split(separator: "=").last,
               let i = Int(p), let s = state, i >= 0, i < s.slides.count {
                s.currentIndex = i
            }
            return jsonResponse("ok")
        default:
            return htmlResponse()
        }
    }

    private func jsonResponse(_ status: String) -> String {
        let body = "{\"status\":\"\(status)\"}"
        return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    private func statusResponse() -> String {
        let index = state?.currentIndex ?? 0
        let total = state?.slides.count ?? 0
        let prev  = total > 0 ? (index - 1 + total) % total : 0
        let next  = total > 0 ? (index + 1) % total : 0
        let dict: [String: Any] = [
            "slide":      index + 1,
            "total":      total,
            "presenting": state?.isPresenting ?? false,
            "url":        state?.currentSlide?.url ?? "",
            "prevUrl":    total > 0 ? (state?.slides[prev].url ?? "") : "",
            "nextUrl":    total > 0 ? (state?.slides[next].url ?? "") : "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let body = String(data: data, encoding: .utf8) else {
            return jsonResponse("error")
        }
        return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    private func slidesResponse() -> String {
        let slides  = state?.slides ?? []
        let current = state?.currentIndex ?? 0
        let arr: [[String: Any]] = slides.enumerated().map { i, s in
            ["index": i, "url": s.url, "current": i == current]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let body = String(data: data, encoding: .utf8) else {
            return jsonResponse("error")
        }
        return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    private func htmlResponse() -> String {
        let body = Self.htmlPage
        return "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    static let htmlPage = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <title>Present Remote</title>
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body {
        font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
        background: #1a1a2e; color: #eee;
        display: flex; flex-direction: column; align-items: center;
        height: 100dvh; padding: 20px; gap: 12px;
        -webkit-user-select: none; user-select: none;
      }
      #status { font-size: 1.6rem; font-weight: 600; text-align: center; }
      #url { font-size: 0.8rem; opacity: 0.4; word-break: break-all; text-align: center; max-width: 90vw; }
      .nav-row { display: flex; gap: 12px; width: 100%; max-width: 400px; }
      .nav-row button { flex: 1; min-height: 60px; font-size: 1.2rem; font-weight: 600;
        border: none; border-radius: 14px; cursor: pointer;
        transition: transform 0.1s, opacity 0.1s; }
      .nav-row button:active { transform: scale(0.95); opacity: 0.8; }
      .btn-play { background: #0f3460; color: #53d8fb; }
      .btn-stop { background: #e94560; color: #fff; }
      .btn-all { background: #16213e; color: #aaa; flex: none !important; width: 60px; }
      .play-row { display: flex; gap: 12px; width: 100%; max-width: 400px; flex: 1; min-height: 0; }
      .nav-cards { display: flex; flex-direction: column; gap: 12px; flex: 1; min-height: 0; }
      .nav-card {
        display: flex; flex-direction: column; align-items: flex-start;
        gap: 4px; padding: 14px 16px; text-align: left;
        border: none; border-radius: 14px; cursor: pointer;
        transition: transform 0.1s, opacity 0.1s; min-height: 0;
      }
      .nav-card:active { transform: scale(0.95); opacity: 0.8; }
      .btn-prev { flex: 1; background: #16213e; color: #e94560; }
      .btn-next { flex: 2; background: #16213e; color: #53d8fb; }
      .nav-label { font-size: 1.5rem; font-weight: 600; }
      .nav-url { font-size: 0.75rem; opacity: 0.6; word-break: break-all; font-weight: 400; }
      .scroll-strip {
        width: 50px; flex-shrink: 0; background: #16213e; border-radius: 14px;
        display: flex; align-items: center; justify-content: center;
        color: #555; font-size: 1.2rem; touch-action: none; cursor: grab;
        align-self: stretch;
      }
      .scroll-strip:active { cursor: grabbing; background: #1a2740; }
      .zoom-row { display: flex; gap: 12px; width: 100%; max-width: 400px; }
      .btn-zoom { flex: 1; padding: 0; font-size: 1.3rem; font-weight: 600;
        background: #16213e; color: #aaa; border: none; border-radius: 14px;
        cursor: pointer; min-height: 60px;
        transition: transform 0.1s, opacity 0.1s; }
      .btn-zoom:active { transform: scale(0.95); opacity: 0.8; }
      html { touch-action: manipulation; }
      #listOverlay {
        position: fixed; inset: 0; background: #1a1a2e;
        display: flex; flex-direction: column; padding: 20px; gap: 12px;
        z-index: 10;
      }
      .list-header { display: flex; justify-content: space-between; align-items: center;
        font-size: 1.2rem; font-weight: 600; }
      .list-header button { background: #16213e; color: #aaa; border: none;
        border-radius: 10px; padding: 8px 14px; font-size: 1.1rem; cursor: pointer; }
      #slideList { list-style: none; overflow-y: auto; flex: 1; }
      #slideList li { padding: 14px; border-radius: 10px; margin-bottom: 8px;
        background: #16213e; font-size: 0.9rem; word-break: break-all; cursor: pointer; }
      #slideList li.current { background: #0f3460; color: #53d8fb; }
    </style>
    </head>
    <body>
      <div id="status">Connecting...</div>
      <div id="url"></div>
      <div class="nav-row">
        <button id="playBtn" class="btn-play" onclick="togglePlay()">&#9654; Start</button>
        <button class="btn-all" onclick="toggleList()">&#9776;</button>
      </div>
      <div class="play-row">
        <div class="nav-cards">
          <button class="btn-prev nav-card" onclick="send('/prev')">
            <span class="nav-label">&lsaquo; Prev</span>
            <span class="nav-url" id="prevUrl"></span>
          </button>
          <button class="btn-next nav-card" onclick="send('/next')">
            <span class="nav-label">Next &rsaquo;</span>
            <span class="nav-url" id="nextUrl"></span>
          </button>
        </div>
        <div class="scroll-strip" id="scrollStrip">&#8597;</div>
      </div>
      <div class="zoom-row">
        <button class="btn-zoom" onclick="send('/zoomout')">A-</button>
        <button class="btn-zoom" onclick="send('/zoomin')">A+</button>
      </div>
      <div id="listOverlay" style="display:none">
        <div class="list-header">
          <span>All Slides</span>
          <button onclick="toggleList()">&#10005;</button>
        </div>
        <ul id="slideList"></ul>
      </div>
      <script>
        let presenting = false;
        function send(path) {
          fetch(path).catch(() => {});
        }
        function togglePlay() {
          send(presenting ? '/stop' : '/play');
        }
        function toggleList() {
          const overlay = document.getElementById('listOverlay');
          if (overlay.style.display !== 'none') { overlay.style.display = 'none'; return; }
          fetch('/slides').then(r => r.json()).then(slides => {
            const ul = document.getElementById('slideList');
            ul.innerHTML = '';
            slides.forEach(s => {
              const li = document.createElement('li');
              if (s.current) li.className = 'current';
              li.textContent = (s.index + 1) + '. ' + s.url;
              li.onclick = () => { send('/goto?index=' + s.index); overlay.style.display = 'none'; };
              ul.appendChild(li);
            });
            overlay.style.display = 'flex';
          });
        }
        function poll() {
          fetch('/status').then(r => r.json()).then(d => {
            document.getElementById('status').textContent =
              'Slide ' + d.slide + ' / ' + d.total;
            document.getElementById('url').textContent = d.url || '';
            document.getElementById('prevUrl').textContent = d.prevUrl || '';
            document.getElementById('nextUrl').textContent = d.nextUrl || '';
            presenting = d.presenting;
            const btn = document.getElementById('playBtn');
            if (presenting) {
              btn.textContent = '\\u25A0 Stop';
              btn.className = 'btn-stop';
            } else {
              btn.textContent = '\\u25B6 Start';
              btn.className = 'btn-play';
            }
          }).catch(() => {
            document.getElementById('status').textContent = 'Disconnected';
          });
        }
        setInterval(poll, 1000);
        poll();

        const strip = document.getElementById('scrollStrip');
        let lastY = null;
        let pendingDy = 0;
        let sendTimer = null;
        function flushScroll() {
          if (pendingDy !== 0) {
            fetch('/scroll?dy=' + Math.round(pendingDy)).catch(() => {});
            pendingDy = 0;
          }
          sendTimer = null;
        }
        strip.addEventListener('touchstart', e => {
          e.preventDefault();
          lastY = e.touches[0].clientY;
          pendingDy = 0;
        }, {passive: false});
        strip.addEventListener('touchmove', e => {
          e.preventDefault();
          const y = e.touches[0].clientY;
          if (lastY !== null) {
            pendingDy += (y - lastY) * 2;
            lastY = y;
            if (!sendTimer) {
              sendTimer = setTimeout(flushScroll, 50);
            }
          }
        }, {passive: false});
        strip.addEventListener('touchend', () => {
          lastY = null;
          flushScroll();
          if (sendTimer) { clearTimeout(sendTimer); sendTimer = null; }
        });
      </script>
    </body>
    </html>
    """
}
