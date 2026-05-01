import Foundation
import WebKit
import UIKit

struct InstagramWebResult {
    let videoURL: URL?              // nil when this is a carousel result
    let apiJSON: [String: Any]?
    let domMeta: [String: Any]?
    let carousel: CarouselPayload?   // populated when post is a carousel
    let mixedCarouselHasVideo: Bool  // true when sidecar has at least one video child

    init(videoURL: URL?, apiJSON: [String: Any]? = nil, domMeta: [String: Any]? = nil,
         carousel: CarouselPayload? = nil, mixedCarouselHasVideo: Bool = false) {
        self.videoURL = videoURL
        self.apiJSON = apiJSON
        self.domMeta = domMeta
        self.carousel = carousel
        self.mixedCarouselHasVideo = mixedCarouselHasVideo
    }
}

/// Loads an Instagram (or Threads) URL in a hidden WKWebView that shares Safari's cookie store.
///
/// Two interception layers run in parallel:
///   1. A documentStart script that overrides `fetch()`, `XHR.open`, and `video.src`
///      so we grab the CDN URL *before* Instagram converts it to a `blob:` reference.
///   2. A polling DOM probe as a fallback for edge cases the script intercept misses.
@MainActor
final class InstagramWebExtractor: NSObject {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<InstagramWebResult?, Never>?
    private var pollTimer: Timer?
    private var done = false
    private var mediaID: Int64?
    private var apiJSON: [String: Any]?
    private var domMeta: [String: Any]?
    private var interceptedVideoURL: URL?
    private var apiWaitTask: Task<Void, Never>?
    private var startURL: URL?

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

    // resolve() handles all UIKit/timer cleanup on the MainActor before releasing
    // the web view. Doing it here would run on whatever thread releases the last
    // reference, which crashes UIKit calls under Swift 6.

    func extract(from url: URL, mediaID: Int64? = nil) async -> InstagramWebResult? {
        self.mediaID = mediaID
        self.startURL = url
        return await withCheckedContinuation { cont in
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
            // Desktop UA bypasses Instagram's "Open in App" mobile interstitial
            wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
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

    // Called when the injected JS reports a CDN URL or the full API JSON via postMessage
    private func didReceiveScriptMessage(_ message: WKScriptMessage) {
        guard message.name == "igVideoURL" else { return }

        // Dict payload = tagged message: {kind: "api", data: {...}} or {kind: "videoURL", url: "..."}
        if let body = message.body as? [String: Any], let kind = body["kind"] as? String {
            switch kind {
            case "api":
                if let data = body["data"] as? [String: Any] {
                    apiJSON = data
                    rLog(.ok, step: "Instagram/JS", "API JSON received (\(data.count) top-level keys)")
                    // Carousel detection: if the post is a sidecar (with or without video children),
                    // resolve immediately with a CarouselPayload. The video pollers/timers are torn
                    // down by the existing resolve() cleanup path.
                    let kind = InstagramCarouselExtractor.detectKind(from: data)
                    if kind == .carousel || kind == .mixedCarousel {
                        let postURL = webView?.url ?? startURL
                        if let postURL,
                           let payload = try? InstagramCarouselExtractor.parse(json: data, postURL: postURL) {
                            let result = InstagramWebResult(
                                videoURL: nil,
                                apiJSON: data,
                                domMeta: self.domMeta,
                                carousel: payload,
                                mixedCarouselHasVideo: kind == .mixedCarousel
                            )
                            self.resolve(result)
                            return
                        }
                    }
                    // If we already have a good video URL, we can resolve now.
                    if let u = interceptedVideoURL, !u.absoluteString.contains("bytestart=") {
                        resolveAfterDOMMeta(videoURL: u)
                        return
                    }
                    // Otherwise extract a video URL from the API JSON itself.
                    if let items = data["items"] as? [[String: Any]],
                       let first = items.first,
                       let vs = first["video_versions"] as? [[String: Any]],
                       let vfirst = vs.first,
                       let urlStr = vfirst["url"] as? String,
                       let u = URL(string: urlStr) {
                        resolveAfterDOMMeta(videoURL: u)
                    }
                }
                return
            case "videoURL":
                guard let urlStr = body["url"] as? String,
                      !urlStr.isEmpty,
                      let url = URL(string: urlStr) else { return }
                handleVideoURL(url, raw: urlStr)
                return
            default:
                return
            }
        }

        // Back-compat: plain string payload = intercepted CDN URL
        if let urlStr = message.body as? String,
           !urlStr.isEmpty,
           let url = URL(string: urlStr) {
            handleVideoURL(url, raw: urlStr)
        }
    }

    private func handleVideoURL(_ url: URL, raw urlStr: String) {
        interceptedVideoURL = url

        // If this is a DASH segment (has bytestart param), it won't play directly.
        // Hold off and give the in-page API fetch up to 3s to return a proper MP4 URL.
        if urlStr.contains("bytestart=") {
            rLog(.warn, step: "Instagram/JS", "DASH segment intercepted — waiting for API fetch to return direct MP4...")
            apiWaitTask?.cancel()
            apiWaitTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, !self.done else { return }
                rLog(.warn, step: "Instagram/JS", "API fetch did not return a better URL — skipping DASH segment")
                self.resolve(nil)
            }
            return
        }

        rLog(.ok, step: "Instagram/JS", "Intercepted CDN URL: \(urlStr.prefix(80))...")
        resolveAfterDOMMeta(videoURL: url)
    }

    // Runs the DOM metadata probe if we haven't already, then resolves with the result.
    // Instagram's private API returns login_required without Safari's cookies, so the DOM
    // is the reliable source for caption/thumbnail/author when the app isn't logged in.
    private func resolveAfterDOMMeta(videoURL: URL) {
        guard !done else { return }
        if domMeta != nil {
            resolve(InstagramWebResult(videoURL: videoURL, apiJSON: apiJSON, domMeta: domMeta))
            return
        }
        webView?.evaluateJavaScript(Self.domMetaJS) { [weak self] result, _ in
            guard let self else { return }
            if let dict = result as? [String: Any] {
                self.domMeta = dict
                let present = dict.keys.sorted().filter { k in
                    if let s = dict[k] as? String { return !s.isEmpty }
                    return dict[k] != nil && !(dict[k] is NSNull)
                }
                rLog(.ok, step: "Instagram/DOM", "Populated: \(present.joined(separator: ","))")
                if let raw = dict["rawDesc"] as? String, !raw.isEmpty {
                    rLog(step: "Instagram/DOM", "og:description snippet: \(raw)")
                }
            } else {
                rLog(.warn, step: "Instagram/DOM", "DOM meta probe returned no dict")
            }
            self.resolve(InstagramWebResult(videoURL: videoURL, apiJSON: self.apiJSON, domMeta: self.domMeta))
        }
    }

    // MARK: - JS strings

    /// Injected at documentStart — overrides fetch/XHR/video.src to capture the
    /// CDN URL before Instagram turns it into a blob: reference.
    private static let interceptJS = """
    (function() {
        var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.igVideoURL;
        if (!h) return;
        var reported = false;
        var lastCDNUrl = null;

        function isCDN(url) {
            if (!url || typeof url !== 'string') return false;
            var u = url.toLowerCase();
            return u.includes('cdninstagram.com') || u.includes('.fbcdn.net');
        }

        // Strict video check for direct reporting via fetch/XHR
        function isVideoFetch(url) {
            if (!url || typeof url !== 'string') return false;
            var u = url.toLowerCase().split('?')[0];
            if (!isCDN(u)) return false;
            // Classic mp4 / DASH segment / HLS extensions
            if (u.endsWith('.mp4') || u.endsWith('.m4v') || u.endsWith('.m4s') ||
                u.endsWith('.m4a') || u.endsWith('.m3u8') || u.endsWith('.mpd') ||
                u.endsWith('.ts')) return true;
            // Known path keywords
            if (u.includes('/video/') || u.includes('/videos/')) return true;
            // Instagram CDN type codes: t50.x and t66.x are video; t51.x is photo
            if (u.includes('/v/t50.') || u.includes('/v/t66.') || u.includes('/v/t7.') || u.includes('/v/t15.') || u.includes('/v/t2.')) return true;
            return false;
        }

        function report(url) {
            if (reported) return;
            reported = true;
            try { h.postMessage({kind: 'videoURL', url: url}); } catch(e) {}
        }

        // 1. video.src setter — direct CDN src OR blob: (MSE) fallback to lastCDNUrl
        var d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
        if (d && d.set) {
            Object.defineProperty(HTMLMediaElement.prototype, 'src', {
                configurable: true, get: d.get,
                set: function(val) {
                    if (typeof val === 'string') {
                        if (!val.startsWith('blob:') && isCDN(val)) {
                            report(val);
                        } else if (val.startsWith('blob:') && lastCDNUrl) {
                            // MSE path: Instagram set a blob: src — report the last CDN URL we tracked
                            report(lastCDNUrl);
                        }
                    }
                    d.set.call(this, val);
                }
            });
        }

        // 2. fetch() override — track all CDN fetches; immediately report video-looking ones
        var origFetch = window.fetch;
        window.fetch = function() {
            var arg = arguments[0];
            var urlStr = typeof arg === 'string' ? arg : (arg instanceof Request ? arg.url : null);
            if (urlStr && isCDN(urlStr)) {
                lastCDNUrl = urlStr;
                if (isVideoFetch(urlStr)) report(urlStr);
            }
            return origFetch.apply(this, arguments);
        };

        // 3. XHR fallback — same tracking logic as fetch
        var origOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
            if (typeof url === 'string' && isCDN(url)) {
                lastCDNUrl = url;
                if (isVideoFetch(url)) report(url);
            }
            return origOpen.apply(this, arguments);
        };

        // 4. URL.createObjectURL intercept — when Instagram wraps a MediaSource in a blob,
        //    report the last CDN URL we saw (the video data came from there)
        var origCreate = URL.createObjectURL;
        if (origCreate) {
            URL.createObjectURL = function(obj) {
                var result = origCreate.call(URL, obj);
                if (typeof MediaSource !== 'undefined' && obj instanceof MediaSource && lastCDNUrl) {
                    setTimeout(function() { if (!reported) report(lastCDNUrl); }, 300);
                }
                return result;
            };
        }
    })();
    """

    /// DOM metadata scraper — reads og:* meta tags plus any application/ld+json that
    /// Instagram embeds in the page. This runs inside the already-loaded WKWebView so
    /// it does not require an authenticated API call.
    ///
    /// Returns a dict with keys: title, description, thumbnailURL, author, handle,
    /// caption, likeCount, commentCount, uploadDate. Fields are "" or null if absent.
    private static let domMetaJS = """
    (function(){
        function get(sel) {
            var el = document.querySelector(sel);
            return el ? (el.getAttribute('content') || el.getAttribute('src') || '') : '';
        }
        var ogTitle = get('meta[property="og:title"]');
        var ogDesc = get('meta[property="og:description"]');
        var ogImage = get('meta[property="og:image"]');
        var twSite = get('meta[name="twitter:site"]');
        var twCreator = get('meta[name="twitter:creator"]');

        var author = '';
        var handle = '';
        var caption = '';
        var likeCount = null;
        var commentCount = null;
        var uploadDate = '';

        // Twitter card meta is the most reliable source of @handle on IG public pages.
        if (twCreator && twCreator.indexOf('@') === 0) handle = twCreator;
        else if (twSite && twSite.indexOf('@') === 0) handle = twSite;

        // og:title usually "Username on Instagram: ..." or just a username with reel count
        var m = ogTitle.match(/^(.+?)\\s+on\\s+Instagram/i);
        if (m) author = m[1].trim();

        // og:description: "12.3K likes, 45 comments - {author} on April 22, 2026: \\"{caption}\\"."
        // or: "{author} on Instagram: \\"{caption}\\""
        // Allow optional trailing period after closing quote.
        var capM = ogDesc.match(/:\\s*[\\"\\u201C](.+?)[\\"\\u201D]\\.?\\s*$/s);
        if (capM) caption = capM[1];
        // Parse display name from "- {Name} on " pattern in og:description.
        if (!author) {
            var nameM = ogDesc.match(/-\\s+(.+?)\\s+on\\s+/);
            if (nameM) author = nameM[1].trim();
        }
        var likeM = ogDesc.match(/([\\d,.]+[KMB]?)\\s+likes?/i);
        if (likeM) {
            var n = likeM[1].replace(/,/g, '');
            var mul = 1;
            if (/K$/i.test(n)) { mul = 1000; n = n.slice(0, -1); }
            else if (/M$/i.test(n)) { mul = 1000000; n = n.slice(0, -1); }
            else if (/B$/i.test(n)) { mul = 1000000000; n = n.slice(0, -1); }
            var v = parseFloat(n);
            if (!isNaN(v)) likeCount = Math.round(v * mul);
        }
        var commM = ogDesc.match(/([\\d,.]+[KMB]?)\\s+comments?/i);
        if (commM) {
            var n2 = commM[1].replace(/,/g, '');
            var mul2 = 1;
            if (/K$/i.test(n2)) { mul2 = 1000; n2 = n2.slice(0, -1); }
            else if (/M$/i.test(n2)) { mul2 = 1000000; n2 = n2.slice(0, -1); }
            else if (/B$/i.test(n2)) { mul2 = 1000000000; n2 = n2.slice(0, -1); }
            var v2 = parseFloat(n2);
            if (!isNaN(v2)) commentCount = Math.round(v2 * mul2);
        }

        // Pull richer structured data from ld+json blocks (Instagram embeds these)
        var scripts = document.querySelectorAll('script[type="application/ld+json"]');
        for (var i = 0; i < scripts.length; i++) {
            try {
                var d = JSON.parse(scripts[i].textContent);
                var arr = Array.isArray(d) ? d : [d];
                for (var j = 0; j < arr.length; j++) {
                    var it = arr[j];
                    if (!it) continue;
                    if (it.uploadDate && !uploadDate) uploadDate = it.uploadDate;
                    if (it.caption && !caption) caption = it.caption;
                    if (it.author) {
                        if (it.author.alternateName && !handle) {
                            handle = '@' + String(it.author.alternateName).replace(/^@/, '');
                        }
                        if (it.author.name && (!author || author.length === 0)) author = it.author.name;
                    }
                    // ld+json sometimes uses `description` rather than `caption`.
                    if (it.description && !caption) caption = it.description;
                    if (Array.isArray(it.interactionStatistic)) {
                        it.interactionStatistic.forEach(function(s){
                            if (!s) return;
                            var t = (s.interactionType || '').toString().toLowerCase();
                            var c = parseInt(s.userInteractionCount, 10);
                            if (isNaN(c)) return;
                            if (t.indexOf('like') !== -1 && likeCount === null) likeCount = c;
                            if (t.indexOf('comment') !== -1 && commentCount === null) commentCount = c;
                        });
                    }
                }
            } catch(e){}
        }

        // Fallback: first profile-looking anchor on the page. Skip reserved paths.
        if (!handle) {
            var reserved = {reel:1, reels:1, p:1, tv:1, explore:1, accounts:1, direct:1, stories:1, about:1};
            var anchors = document.querySelectorAll('a[href^="/"]');
            for (var k = 0; k < anchors.length; k++) {
                var href = anchors[k].getAttribute('href') || '';
                var um = href.match(/^\\/([A-Za-z0-9._]+)\\/?(?:\\?|#|$)/);
                if (um && !reserved[um[1].toLowerCase()]) { handle = '@' + um[1]; break; }
            }
        }

        return {
            title: ogTitle || '',
            description: ogDesc || '',
            thumbnailURL: ogImage || '',
            author: author || '',
            handle: handle || '',
            caption: caption || '',
            likeCount: likeCount,
            commentCount: commentCount,
            uploadDate: uploadDate || '',
            // Diagnostic: truncated og:description so Swift-side logs can show what IG served.
            rawDesc: (ogDesc || '').slice(0, 200)
        };
    })()
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
            guard let self else { return }
            if let str = result as? String, !str.isEmpty, let url = URL(string: str) {
                rLog(.ok, step: "Instagram/Probe", "DOM poll found: \(str.prefix(80))...")
                self.resolveAfterDOMMeta(videoURL: url)
            }
        }
    }

    private func resolve(_ result: InstagramWebResult?) {
        guard !done else { return }
        done = true
        pollTimer?.invalidate()
        pollTimer = nil
        apiWaitTask?.cancel()
        apiWaitTask = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "igVideoURL")
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        continuation?.resume(returning: result)
        continuation = nil
    }

}

extension InstagramWebExtractor: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let landedURL = webView.url?.absoluteString ?? "unknown"
        rLog(step: "Instagram/WKWebView", "Page loaded: \(landedURL.prefix(80))")
        if landedURL.contains("accounts/login") || landedURL.contains("challenge") {
            rLog(.warn, step: "Instagram/WKWebView", "Redirected to login/challenge — cookies may not be shared")
        }

        // Fetch direct MP4 from Instagram private API using the page's session cookies.
        // This runs inside the WKWebView so cookies are included automatically —
        // the result is a standard MP4 URL, not a DASH segment.
        if let mid = mediaID {
            let apiJS = """
            (function() {
                var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.igVideoURL;
                if (!h) return;
                fetch('https://i.instagram.com/api/v1/media/\(mid)/info/', {
                    credentials: 'include',
                    headers: {
                        'X-IG-App-ID': '936619743392459',
                        'User-Agent': 'Instagram 275.0.0.27.98 Android (33/13; 420dpi; 1080x2400; samsung; SM-G998B; p3q; qcom; en_US; 458229258)'
                    }
                })
                .then(function(r) { return r.json(); })
                .then(function(d) {
                    // Send the full API payload so Swift can parse caption, thumbnail,
                    // author, counts, duration — the cookies here make this call succeed
                    // where URLSession without cookies hits a login wall.
                    try { h.postMessage({kind: 'api', data: d}); } catch(e) {}
                    var items = d.items;
                    if (!items || !items[0]) return;
                    var vs = items[0].video_versions;
                    if (vs && vs[0] && vs[0].url) { h.postMessage({kind: 'videoURL', url: vs[0].url}); return; }
                    var dv = items[0].video_dash_manifest || items[0].video_url;
                    if (dv) h.postMessage({kind: 'videoURL', url: dv});
                })
                .catch(function(e) {});
            })();
            """
            webView.evaluateJavaScript(apiJS, completionHandler: nil)
        }

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
