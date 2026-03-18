import SwiftUI
import Combine
import UniformTypeIdentifiers

@main
struct PresentApp: App {
    @State private var state: PresentationState
    @State private var presentationController = PresentationWindowController()
    @State private var server: RemoteServer

    init() {
        let s = PresentationState()
        let srv = RemoteServer()
        srv.start(state: s)
        _state = State(initialValue: s)
        _server = State(initialValue: srv)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .onReceive(NotificationCenter.default.publisher(for: .remotePlay)) { _ in
                    if !state.isPresenting {
                        presentationController.open(state: state)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .remoteStop)) { _ in
                    if state.isPresenting {
                        presentationController.close(state: state)
                    }
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("Open...") {
                    FileDialogHelper.open(state: state)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Save") {
                    if let url = state.currentFileURL {
                        _ = state.saveToFile(url)
                    } else {
                        FileDialogHelper.save(state: state)
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(state.slides.isEmpty)

                Button("Save As...") {
                    FileDialogHelper.save(state: state)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("Export HTML...") {
                    ExportHelper.exportHTML(state: state)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(state.slides.isEmpty)
            }

            CommandMenu("View") {
                Button("Zoom In") {
                    state.zoomIn()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    state.zoomOut()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    state.zoomReset()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            CommandMenu("Presentation") {
                Button("Play") {
                    presentationController.open(state: state)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(state.slides.isEmpty)
            }
        }
    }
}

enum FileDialogHelper {
    @MainActor
    static func open(state: PresentationState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            _ = state.loadFromFile(url)
        }
    }

    @MainActor
    static func save(state: PresentationState) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "presentation.txt"
        if panel.runModal() == .OK, let url = panel.url {
            _ = state.saveToFile(url)
        }
    }
}

enum ExportHelper {
    @MainActor
    static func exportHTML(state: PresentationState) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.html]
        panel.nameFieldStringValue = "presentation.html"
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }

        let slides = state.slides.map { $0.url }
        Task {
            let html = await generateHTML(slides: slides)
            try? html.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    static func generateHTML(slides: [String]) async -> String {
        var sections: [String] = []

        for url in slides {
            if isTextSlide(url) {
                sections.append(renderTextSlide(url))
            } else if isImageURL(url) {
                let resolved = resolveURL(url)
                sections.append("<img src=\"\(escapeHTML(resolved))\">")
            } else {
                let resolved = resolveURL(url)
                let title = await fetchTitle(for: resolved) ?? resolved
                sections.append("<p><a href=\"\(escapeHTML(resolved))\">\(escapeHTML(title))</a></p>")
            }
        }

        let body = sections.joined(separator: "\n<hr>\n")
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <style>
        body { font-family: system-ui, -apple-system, sans-serif; max-width: 800px; margin: 2rem auto; padding: 0 1rem; }
        hr { margin: 2rem 0; }
        img { max-width: 100%; }
        h1, h2, h3 { margin: 0.5em 0; }
        p { margin: 0.5em 0; }
        </style>
        </head><body>
        \(body)
        </body></html>
        """
    }

    private static func isTextSlide(_ url: String) -> Bool {
        url.hasPrefix("\"") && url.hasSuffix("\"") && url.count >= 2
    }

    private static func isImageURL(_ url: String) -> Bool {
        let lower = url.lowercased().split(separator: "?").first.map(String.init) ?? url.lowercased()
        return lower.hasSuffix(".png") || lower.hasSuffix(".gif") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".webp") || lower.hasSuffix(".svg")
    }

    private static func resolveURL(_ raw: String) -> String {
        if let parsed = URL(string: raw), parsed.scheme != nil { return raw }
        return "https://\(raw)"
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func renderTextSlide(_ url: String) -> String {
        var content = String(url.dropFirst().dropLast())
        content = content.replacingOccurrences(of: "\\n", with: "\n")
        if content.hasPrefix("? ") {
            content = String(content.dropFirst(2))
        }
        let lines = content.components(separatedBy: "\n")
        var htmlLines: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                htmlLines.append("<br>")
                continue
            }
            var processed = trimmed
            processed = processed.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
            processed = processed.replacingOccurrences(of: #"\*(.+?)\*"#, with: "<em>$1</em>", options: .regularExpression)
            processed = processed.replacingOccurrences(of: #"_(.+?)_"#, with: "<em>$1</em>", options: .regularExpression)
            if trimmed.hasPrefix("### ") {
                htmlLines.append("<h3>\(String(processed.dropFirst(4)))</h3>")
            } else if trimmed.hasPrefix("## ") {
                htmlLines.append("<h2>\(String(processed.dropFirst(3)))</h2>")
            } else if trimmed.hasPrefix("# ") {
                htmlLines.append("<h1>\(String(processed.dropFirst(2)))</h1>")
            } else {
                htmlLines.append("<p>\(processed)</p>")
            }
        }
        return htmlLines.joined(separator: "\n")
    }

    private static func fetchTitle(for urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            if let range = html.range(of: #"<title[^>]*>(.*?)</title>"#, options: [.regularExpression, .caseInsensitive]) {
                let match = String(html[range])
                let inner = match.replacingOccurrences(of: #"<title[^>]*>"#, with: "", options: .regularExpression)
                                  .replacingOccurrences(of: "</title>", with: "", options: .caseInsensitive)
                let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        } catch {}
        return nil
    }
}
