import SwiftUI
import WebKit

struct ArticleReaderView: View {
    let item: FeedItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ArticleWebView(url: URL(string: item.url))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(item.sourceTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if let url = URL(string: item.url) {
                            Link(destination: url) {
                                Image(systemName: "safari")
                                    .font(.title3)
                            }
                        }
                    }
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar()
                .background(.ultraThinMaterial)
        }
    }
}

struct ArticleWebView: UIViewRepresentable {
    let url: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.navigationDelegate = context.coordinator

        // Thin progress bar at top of web content
        let progressView = UIProgressView(progressViewStyle: .bar)
        progressView.tintColor = .systemBlue
        progressView.translatesAutoresizingMaskIntoConstraints = false
        webView.addSubview(progressView)
        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: webView.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2)
        ])
        context.coordinator.progressView = progressView

        // Observe loading progress
        context.coordinator.progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { webView, _ in
            let progress = Float(webView.estimatedProgress)
            context.coordinator.progressView?.progress = progress
            context.coordinator.progressView?.isHidden = progress >= 1.0
        }

        if let url {
            context.coordinator.requestedURL = url
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Reload only when the *input* changed (e.g. reused for different article, #46). Comparing
        // `webView.url` against it restarted the article after a redirect or an in-page navigation:
        // the browser's current URL is the result of a load, never the input the representable was
        // given, so any environment-driven `updateUIView` sent the reader back to the original URL.
        guard context.coordinator.requestedURL != url else { return }
        context.coordinator.requestedURL = url
        if let url {
            webView.load(URLRequest(url: url))
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var progressView: UIProgressView?
        var progressObservation: NSKeyValueObservation?
        /// The URL this representable was last asked to load. It is the only input allowed to restart a
        /// load; the web view's own current URL is not an input.
        var requestedURL: URL?

        deinit {
            progressObservation?.invalidate()
        }
    }
}
