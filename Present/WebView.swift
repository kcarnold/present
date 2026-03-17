import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    let url: String
    var pageZoom: Double = 1.0
    @Binding var currentURL: String?

    init(url: String, pageZoom: Double = 1.0, currentURL: Binding<String?> = .constant(nil)) {
        self.url = url
        self.pageZoom = pageZoom
        self._currentURL = currentURL
    }

    private var isImageURL: Bool {
        let lower = url.lowercased().split(separator: "?").first.map(String.init) ?? url.lowercased()
        return lower.hasSuffix(".png") || lower.hasSuffix(".gif") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".webp") || lower.hasSuffix(".svg")
    }

    private var isTextSlide: Bool {
        url.hasPrefix("\"") && url.hasSuffix("\"") && url.count >= 2
    }

    private var textSlideHTML: String {
        var content = String(url.dropFirst().dropLast())
        content = content.replacingOccurrences(of: "\\n", with: "\n")
        let lines = content.components(separatedBy: "\n")
        var htmlLines: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                htmlLines.append("<br>")
                continue
            }
            var processed = trimmed
            // Bold
            processed = processed.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
            // Italic
            processed = processed.replacingOccurrences(of: #"\*(.+?)\*"#, with: "<em>$1</em>", options: .regularExpression)
            processed = processed.replacingOccurrences(of: #"_(.+?)_"#, with: "<em>$1</em>", options: .regularExpression)
            if trimmed.hasPrefix("### ") {
                htmlLines.append("<h3>\(processed.dropFirst(4))</h3>")
            } else if trimmed.hasPrefix("## ") {
                htmlLines.append("<h2>\(processed.dropFirst(3))</h2>")
            } else if trimmed.hasPrefix("# ") {
                htmlLines.append("<h1>\(processed.dropFirst(2))</h1>")
            } else {
                htmlLines.append("<p>\(processed)</p>")
            }
        }
        let body = htmlLines.joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html><head><meta name="viewport" content="width=device-width">
        <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{background:#000;color:#fff;display:flex;align-items:center;justify-content:center;width:100vw;height:100vh;font-family:system-ui,-apple-system,sans-serif;font-size:2.2rem;line-height:1.4}
        .content{max-width:900px;padding:3rem;text-align:center}
        h1{font-size:3rem;margin-bottom:0.6em}
        h2{font-size:2.5rem;margin-bottom:0.5em}
        h3{font-size:2rem;margin-bottom:0.4em}
        p{margin-bottom:0.6em}
        </style>
        </head><body><div class="content">\(body)</div></body></html>
        """
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.onNavigate = { url in self.currentURL = url }
        context.coordinator.startListening()
        applyContent(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.webView = webView
        context.coordinator.onNavigate = { url in self.currentURL = url }
        applyContent(in: webView, coordinator: context.coordinator)
    }

    private func applyContent(in webView: WKWebView, coordinator: Coordinator) {
        if isImageURL {
            webView.pageZoom = 1.0
            let resolvedURL = resolveURL(url)
            if coordinator.lastLoadedURL != resolvedURL {
                coordinator.lastLoadedURL = resolvedURL
                let html = """
                <!DOCTYPE html>
                <html><head><meta name="viewport" content="width=device-width">
                <style>*{margin:0;padding:0;overflow:hidden}body{background:#000;display:flex;align-items:center;justify-content:center;width:100vw;height:100vh}img{max-width:100vw;max-height:100vh;object-fit:contain}</style>
                </head><body><img src="\(resolvedURL)"></body></html>
                """
                webView.loadHTMLString(html, baseURL: nil)
            }
        } else if isTextSlide {
            webView.pageZoom = 1.0
            if coordinator.lastLoadedURL != url {
                coordinator.lastLoadedURL = url
                webView.loadHTMLString(textSlideHTML, baseURL: nil)
            }
        } else {
            coordinator.lastLoadedURL = nil
            webView.pageZoom = pageZoom
            loadURL(in: webView)
        }
    }

    private func resolveURL(_ raw: String) -> String {
        if let parsed = URL(string: raw), parsed.scheme != nil {
            return raw
        }
        return "https://\(raw)"
    }

    private func loadURL(in webView: WKWebView) {
        guard let parsed = URL(string: url), parsed.scheme != nil else {
            if let parsed = URL(string: "https://\(url)") {
                webView.load(URLRequest(url: parsed))
            }
            return
        }
        if webView.url != parsed {
            webView.load(URLRequest(url: parsed))
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var lastLoadedURL: String?
        var onNavigate: ((String?) -> Void)?
        private var observer: NSObjectProtocol?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onNavigate?(webView.url?.absoluteString)
        }

        func startListening() {
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: .remoteScroll, object: nil, queue: .main
            ) { [weak self] notification in
                guard let dy = notification.userInfo?["dy"] as? Double,
                      let webView = self?.webView else { return }
                webView.evaluateJavaScript("window.scrollBy(0, \(dy));", completionHandler: nil)
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
