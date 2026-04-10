import Foundation
import WebKit
import UIKit

/// Loads a Twitter/X URL in a hidden WKWebView that shares Safari's cookie store.
///
/// Twitter's video player sets `video.src` to either a direct `.mp4` URL or an
/// HLS `.m3u8` manifest, both served from `video.twimg.com`. We intercept at
/// documentStart — same approach as InstagramWebExtractor — to grab the URL
/// before it may be wrapped in a blob.
@MainActor
final class TwitterWebExtractor: NSObject {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<URL?, Never>?
    private var pollTimer: Timer?
    private var done = false

    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: TwitterWebExtractor?
        init(_ target: TwitterWebExtractor) { self.target = target }
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.didReceiveScriptMessage(message)
        }
    }

    deinit {
        pollTimer?.invalidate()
        webView?.stopLoading()
        webView?.removeFromSuperview()
    }

    func extract(from url: URL) async -> URL? {
        await withCheckedContinuation { cont in
            self.continuation = cont

            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            config.mediaTypesRequiringUserActionForPlayback = []

            config.userContentController.add(WeakHandler(self), name: "twitterVideoURL")
            config.userContentController.addUserScript(
                WKUserScript(source: Self.interceptJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )

            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
            wv.alpha = 0
            wv.navigationDelegate = self
            webView = wv

            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) {
                window.addSubview(wv)
            }

            wv.load(URLRequest(url: url))

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.resolve(nil)
            }
        }
    }

    private func didReceiveScriptMessage(_ message: WKScriptMessage) {
        guard message.name == "twitterVideoURL",
              let urlStr = message.body as? String,
              !urlStr.isEmpty,
              let url = URL(string: urlStr) else { return }
        rLog(.ok, step: "Twitter/JS", "Intercepted video URL: \(urlStr.prefix(80))...")
        resolve(url)
    }

    // MARK: - JS strings

    private static let interceptJS = """
    (function() {
        var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.twitterVideoURL;
        if (!h) return;

        function isTwitterVideo(url) {
            if (!url || typeof url !== 'string') return false;
            var u = url.toLowerCase();
            if (!u.includes('video.twimg.com')) return false;
            // Accept mp4 and m3u8; skip individual .ts segments
            return u.includes('.mp4') || u.includes('.m3u8');
        }
        function report(url) { try { if (isTwitterVideo(url)) h.postMessage(url); } catch(e) {} }

        var d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
        if (d && d.set) {
            Object.defineProperty(HTMLMediaElement.prototype, 'src', {
                configurable: true, get: d.get,
                set: function(val) {
                    if (typeof val === 'string' && !val.startsWith('blob:')) report(val);
                    d.set.call(this, val);
                }
            });
        }

        var origFetch = window.fetch;
        window.fetch = function() {
            var url = arguments[0];
            report(typeof url === 'string' ? url : (url instanceof Request ? url.url : null));
            return origFetch.apply(this, arguments);
        };

        var origOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
            if (typeof url === 'string') report(url);
            return origOpen.apply(this, arguments);
        };
    })();
    """

    private static let probeJS = """
    (function(){
        var v = document.querySelector('video');
        if (v) {
            if (v.src && !v.src.startsWith('blob:') && v.src.includes('video.twimg.com')) return v.src;
            if (v.currentSrc && !v.currentSrc.startsWith('blob:') && v.currentSrc.includes('video.twimg.com')) return v.currentSrc;
        }
        var sources = document.querySelectorAll('video source, source');
        for (var i = 0; i < sources.length; i++) {
            var s = sources[i].src || sources[i].getAttribute('src') || '';
            if (s && s.includes('video.twimg.com')) return s;
        }
        return null;
    })()
    """

    private func probe() {
        guard !done else { return }
        webView?.evaluateJavaScript(Self.probeJS) { [weak self] result, _ in
            if let str = result as? String, !str.isEmpty, let url = URL(string: str) {
                rLog(.ok, step: "Twitter/Probe", "DOM poll found: \(str.prefix(80))...")
                self?.resolve(url)
            }
        }
    }

    private func resolve(_ url: URL?) {
        guard !done else { return }
        done = true
        pollTimer?.invalidate()
        pollTimer = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "twitterVideoURL")
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        continuation?.resume(returning: url)
        continuation = nil
    }
}

extension TwitterWebExtractor: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        probe()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.probe()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        rLog(.fail, step: "Twitter/WKWebView", "Nav failed: \(error.localizedDescription)")
        resolve(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        rLog(.fail, step: "Twitter/WKWebView", "Provisional nav failed: \(error.localizedDescription)")
        resolve(nil)
    }
}
