# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build and run
xcodebuild -project Present.xcodeproj -scheme Present -configuration Release build SYMROOT=build
open build/Release/Present.app

# Clean build
rm -rf build

# Create release zip
xcodebuild -project Present.xcodeproj -scheme Present -configuration Release build SYMROOT=build
cd build/Release && zip -r Present.app.zip Present.app
```

There are no tests in this project.

## Architecture

This is a macOS SwiftUI app with 5 source files:

- **`Slide.swift`** — Data model. `Slide` is an `@Observable` class with `id` and `url`. `PresentationState` is the central `@Observable` state object holding the slide list, current index, zoom level, and presentation status. It auto-persists to `UserDefaults` on every slide list change.

- **`PresentApp.swift`** — App entry point. Creates `PresentationState` and `RemoteServer`, wires up menu commands (File > Open/Save, View > Zoom, Presentation > Play), and handles `remotePlay`/`remoteStop` notifications to open/close the presentation window.

- **`ContentView.swift`** — Edit mode UI. `NavigationSplitView` with a sidebar list of URL text fields (drag-to-reorder via `draggable`/`dropDestination`) and a `WebView` detail pane previewing the selected slide.

- **`PresentationWindow.swift`** — Play mode. `PresentationWindowController` opens a borderless fullscreen `NSWindow` containing `PresentationView` (black background + `WebView`). A local `NSEvent` key monitor handles arrow keys (navigate), Escape (exit), and Cmd+=/- (zoom).

- **`WebView.swift`** — `NSViewRepresentable` wrapping `WKWebView`. Handles three content types based on the URL string:
  - **Image URLs** (ends in `.png`/`.gif`/`.jpg`/`.jpeg`/`.webp`/`.svg`): renders as a centered full-window `<img>` tag, ignores zoom
  - **Text slides** (string wrapped in double-quotes `"..."`): renders inline Markdown-like content (headings, bold, italic) as centered HTML on a black background, ignores zoom
  - **Regular URLs**: loads in WKWebView with `pageZoom` applied

- **`RemoteServer.swift`** — Embedded HTTP server on port 9123 using `Network.framework`. Serves a mobile-friendly remote control page at `/` and handles endpoints: `/next`, `/prev`, `/play`, `/stop`, `/zoomin`, `/zoomout`, `/scroll?dy=N`, `/status`, `/slides`, `/goto?i=N`. The `/play` and `/stop` endpoints post `Notification.Name.remotePlay`/`remoteStop` to control presentation mode. Scroll events are forwarded to `WebView.Coordinator` via `remoteScroll` notification.

## Slide Content Types

The `url` field of a `Slide` can be:
1. A regular URL (`https://...`) — loaded in WKWebView
2. An image URL (detected by file extension) — displayed as a full-window image
3. A quoted string (`"text with **bold** and *italic*"`) — rendered as a text slide with basic Markdown support; use `\n` for line breaks
