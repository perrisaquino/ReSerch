import SwiftUI
import WebKit

struct TikTokPlayerView: UIViewRepresentable {
    let videoId: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = false

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body { width: 100%; height: 100%; background: #000; }
            iframe {
                position: absolute;
                top: 0; left: 0;
                width: 100%; height: 100%;
                border: none;
            }
        </style>
        </head>
        <body>
        <iframe
            src="https://www.tiktok.com/embed/v2/\(videoId)"
            allow="encrypted-media; autoplay"
            allowfullscreen>
        </iframe>
        </body>
        </html>
        """
        // Base URL must be tiktok.com or the embed is blocked by CORS
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.tiktok.com"))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
