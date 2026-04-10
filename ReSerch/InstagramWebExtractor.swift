import Foundation
import WebKit
import UIKit

/// Loads an Instagram (or Threads) URL in a hidden WKWebView that shares Safari's cookie store.
///
/// Two interception layers run in parallel:
///   1. A documentStart script that overrides `fetch()`, `XHR.open`, and `video.src`
///      so we grab the CDN URL *before* Instagram converts it to a `blob:` reference.
///   2. A polling DOM probe as a fallback for edge cases the script intercept misses.
@MainActor
final class InstagramWebExtractor: NSObject {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<URL?, Never>?
    private var pollTimer: Timer?
    private var done = false

    // Weak wrapper breaks the retain cycle:
    // WKUserContentController holds a strong reference to its message handlers,
    // so registering `self` directly would pin the extractor in memory forever.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: InstagramWebExtractor?
        init(_ target: InstagramWebExtractor) { self.target = target }
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
            config.websiteDataStore = .default()    // shares Safari cookies — picks up Instagram login
            config.mediaTypesRequiringUserActionForPlayback = []

            // Register the message handler BEFORE creating the web view
            config.userContentController.add(WeakHandler(self), name: "igVideoURL")

            // Inject the intercept script at document start so our overrides run
            // before any of Instagram's JavaScript has a chance to execute
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

            // Hard timeout — give Instagram extra time for slow JS hydration
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(22))
                self?.resolve(nil)
            }
        }
    }

    // Called when the injected JS reports a CDN URL via postMessage
    private func didReceiveScriptMessage(_ message: WKScriptMessage) {
        guard message.name == "igVideoURL",
              let urlStr = message.body as? String,
              !urlStr.isEmpty,
              let url = URL(string: urlStr) else { return }
        rLog(.ok, step: "Instagram/JS", "Intercepted CDN URL: \(urlStr.prefix(80))...")
        resolve(url)
    }

    // MARK: - JS strings

    /// Injected at documentStart — overrides fetch/XHR/video.src to capture the
    /// CDN URL before Instagram turns it into a blob: reference.
    private static let interceptJS = """
    (function() {
        var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.igVideoURL;
        if (!h) return;

        function isVideoCDN(url) {
            if (!url || typeof url !== 'string') return false;
            var u = url.toLowerCase();
            if (!u.includes('cdninstagram.com') && !u.includes('.fbcdn.net')) return false;
            var path = u.split('?')[0];
            // Exclude image-only extensions
            if (path.endsWith('.jpg') || path.endsWith('.jpeg') ||
                path.endsWith('.png') || path.endsWith('.webp') || path.endsWith('.gif')) return false;
            return true;
        }
        function report(url) { try { if (isVideoCDN(url)) h.postMessage(url); } catch(e) {} }

        // 1. video.src setter — catches direct src assignments
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

        // 2. fetch() override — catches the CDN request that produces the blob
        var origFetch = window.fetch;
        window.fetch = function() {
            var url = arguments[0];
            report(typeof url === 'string' ? url : (url instanceof Request ? url.url : null));
            return origFetch.apply(this, arguments);
        };

        // 3. XHR fallback
        var origOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
            if (typeof url === 'string') report(url);
            return origOpen.apply(this, arguments);
        };
    })();
    """

    /// Polling probe — runs after page load as a backup.
    private static let probeJS = """
    (function(){
        var v = document.querySelector('video');
        if (v) {
            if (v.src && !v.src.startsWith('blob:') &&
                (v.src.includes('cdninstagram') || v.src.includes('fbcdn'))) return v.src;
            if (v.currentSrc && !v.currentSrc.startsWith('blob:') &&
                (v.currentSrc.includes('cdninstagram') || v.currentSrc.includes('fbcdn'))) return v.currentSrc;
        }
        var sources = document.querySelectorAll('video source, source');
        for (var i = 0; i < sources.length; i++) {
            var s = sources[i].src || sources[i].getAttribute('src') || '';
            if (s && !s.startsWith('blob:') && (s.includes('cdninstagram') || s.includes('fbcdn'))) return s;
        }
        var el = document.querySelector('[data-video-url]');
        if (el) { var u = el.getAttribute('data-video-url'); if (u) return u; }
        var scripts = document.querySelectorAll('script[type="application/json"]');
        for (var j = 0; j < scripts.length; j++) {
            var t = scripts[j].textContent || '';
            var m = t.match(/"video_url":"(https:[^"]+)"/);
            if (m) return m[1].replace(/\\\\u0026/g,'&').replace(/\\\\//g,'/');
            m = t.match(/"playback_url":"(https:[^"]+)"/);
            if (m) return m[1].replace(/\\\\u0026/g,'&').replace(/\\\\//g,'/');
        }
        return null;
    })()
    """

    // MARK: - Internals

    private func probe() {
        guard !done else { return }
        webView?.evaluateJavaScript(Self.probeJS) { [weak self] result, _ in
            if let str = result as? String, !str.isEmpty, let url = URL(string: str) {
                rLog(.ok, step: "Instagram/Probe", "DOM poll found: \(str.prefix(80))...")
                self?.resolve(url)
            }
        }
    }

    private func resolve(_ url: URL?) {
        guard !done else { return }
        done = true
        pollTimer?.invalidate()
        pollTimer = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "igVideoURL")
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        continuation?.resume(returning: url)
        continuation = nil
    }
}

extension InstagramWebExtractor: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        probe()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.probe()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        rLog(.fail, step: "Instagram/WKWebView", "Nav failed: \(error.localizedDescription)")
        resolve(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        rLog(.fail, step: "Instagram/WKWebView", "Provisional nav failed: \(error.localizedDescription)")
        resolve(nil)
    }
}
