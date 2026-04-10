import SwiftUI
import UIKit

// MARK: - ImageCache

/// Two-level thumbnail cache: NSCache (memory) + disk.
/// Memory hit = synchronous, zero latency.
/// Disk hit = no network, typically <5ms.
/// Both levels are populated on first network fetch.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let diskDir: URL

    private init() {
        memory.countLimit = 150
        memory.totalCostLimit = 80 * 1024 * 1024 // 80 MB

        diskDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumb-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    // L1 — synchronous memory lookup
    func memoryImage(for url: URL) -> UIImage? {
        memory.object(forKey: cacheKey(url) as NSString)
    }

    // L2 — async disk lookup (runs off main thread)
    func diskImage(for url: URL) async -> UIImage? {
        let path = diskDir.appendingPathComponent(cacheKey(url))
        return await Task.detached(priority: .utility) { [weak self] in
            guard let self,
                  let data = try? Data(contentsOf: path),
                  let img  = UIImage(data: data) else { return nil }
            // Promote into memory so subsequent hits are synchronous
            let cost = Int(img.size.width * img.size.height * img.scale * img.scale) * 4
            self.memory.setObject(img, forKey: self.cacheKey(url) as NSString, cost: cost)
            return img
        }.value
    }

    // Write-through: memory first, then disk asynchronously
    func store(_ image: UIImage, for url: URL) {
        let key  = cacheKey(url)
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale) * 4
        memory.setObject(image, forKey: key as NSString, cost: cost)

        let path = diskDir.appendingPathComponent(key)
        Task.detached(priority: .utility) {
            if let data = image.jpegData(compressionQuality: 0.85) {
                try? data.write(to: path, options: .atomic)
            }
        }
    }

    // FNV-1a: deterministic, stable across launches (unlike Swift's Hasher)
    private func cacheKey(_ url: URL) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}

// MARK: - CachedAsyncImage

/// Drop-in for AsyncImage with memory + disk caching.
/// Usage:
///   CachedAsyncImage(url: url) { img in
///       if let img { img.resizable()... } else { placeholder }
///   }
struct CachedAsyncImage<Content: View>: View {
    private let url: URL?
    private let content: (Image?) -> Content

    @State private var image: UIImage? = nil
    @State private var loadTask: Task<Void, Never>? = nil

    init(url: URL?, @ViewBuilder content: @escaping (Image?) -> Content) {
        self.url = url
        self.content = content
    }

    var body: some View {
        content(image.map { Image(uiImage: $0) })
            .onAppear { load(url: url) }
            .onDisappear { loadTask?.cancel(); loadTask = nil }
            .onChange(of: url) { _, newURL in load(url: newURL) }
    }

    private func load(url: URL?) {
        guard let url else { image = nil; return }

        // L1: memory — synchronous, zero wait
        if let cached = ImageCache.shared.memoryImage(for: url) {
            image = cached
            return
        }

        loadTask?.cancel()
        loadTask = Task {
            // L2: disk — fast, no network
            if let diskImg = await ImageCache.shared.diskImage(for: url) {
                guard !Task.isCancelled else { return }
                image = diskImg
                return
            }

            guard !Task.isCancelled else { return }

            // L3: network — only on first ever load for this URL
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled,
                  let downloaded = UIImage(data: data) else { return }

            ImageCache.shared.store(downloaded, for: url)
            image = downloaded
        }
    }
}
