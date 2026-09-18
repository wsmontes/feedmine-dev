import SwiftUI
import UIKit
import FeedDomain

struct FeedItemCardView: View, Equatable {
    /// Skips action closures (not Equatable) and @State/@AppStorage/
    /// @Environment properties (tracked independently by SwiftUI).
    ///
    /// The media slot and the chrome are part of the comparison: they are what decides whether this
    /// card's structure changes at all, and a presentation change that does not move them must not
    /// invalidate the row.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
        && lhs.mediaSlot == rhs.mediaSlot
        && lhs.affordances == rhs.affordances
        && lhs.isRead == rhs.isRead
        && lhs.isBookmarked == rhs.isBookmarked
        && lhs.isInBookmarkBox == rhs.isInBookmarkBox
    }
    let item: FeedItem
    let isRead: Bool
    let isBookmarked: Bool
    /// The media decision for this card: local bytes, a deterministic placeholder, a reserved empty
    /// frame, or no slot at all (PR-13). There is no `.loading` and no URL, so this view cannot start
    /// a download, and it never inspects `item` to decide what a slot holds.
    var mediaSlot: CardMediaSlot = .none
    /// The chrome the runtime decided: placeholder kind, overlay glyph, badges, duration and what a
    /// tap means. Defaulted for callers that have not stated one (`.undecided` draws nothing
    /// protocol-specific), never filled in by guessing from the data.
    var affordances: CardPresentation.Affordances = .undecided
    var onBookmark: (() -> Void)? = nil
    var onViewSource: (() -> Void)? = nil
    var onAddSourceToCollection: (() -> Void)? = nil
    /// Fired after a successful "Copy Link" action so the screen can show
    /// its toast — the card owns the context menu, so this screen-level
    /// feedback has to be threaded down.
    var onCopy: (() -> Void)? = nil
    var onImageTap: (() -> Void)? = nil
    var isInBookmarkBox: Bool = false
    @AppStorage("fontSize") private var fontSize = "medium"
    @State private var engine = CircadianEngine.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isLandscape: Bool { horizontalSizeClass == .regular }
    /// Structural: does this card have a resolved image to display?
    /// Only `.local` reserves the hero slot with bytes. `.placeholder`, `.empty` and `.none`
    /// never become a fake image here.
    ///
    /// Because this slot is the card's only height difference between a
    /// text-only card and a hero card, a published card can never gain it: a
    /// late image would grow the card and shift every card below it. The store
    /// serves late images through the next publication instead
    /// (`FeedDisplayState` has no in-place card swap).
    private var hasImage: Bool { mediaSlot.localImage != nil }

    /// Test-facing property — mirrors hasImage so tests can verify that
    /// presentation-driven image decisions are correct without rendering.
    var hasImageTest: Bool { hasImage }

    private var titleFont: Font {
        switch fontSize {
        case "small": return engine.font(for: .cardTitle, size: 14)
        case "large": return engine.font(for: .cardTitle, size: 20)
        default: return engine.font(for: .cardTitle)
        }
    }

    private var bodyFont: Font {
        switch fontSize {
        case "small": return .system(size: 12)
        case "large": return .system(size: 15)
        default: return .system(size: 13)
        }
    }

    var body: some View {
        Group {
            if isLandscape {
                landscapeCard
            } else {
                portraitCard
            }
        }
        .opacity(isRead ? 0.92 : 1)
    }

    /// Base hero view — the placeholder itself defines the 16:9 frame so it
    /// always fills the slot completely. The real image sits on top as an overlay.
    ///
    /// Which placeholder this is comes from the presentation, not from the item: `.podcast` draws the
    /// episode artwork surface, every other kind draws its deterministic asset.
    @ViewBuilder
    private var heroBase: some View {
        if case .placeholder(.podcast) = mediaSlot, mediaSlot.localImage == nil {
            podcastPlaceholder
        } else {
            placeholderImage(MainFeedCardBridge.placeholderKind(affordances.placeholder))
                .resizable()
                .aspectRatio(contentMode: .fill)
                .opacity(0.5)
        }
    }

    // MARK: - Portrait Card

    private var portraitCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hero image — native media or a bounded article-page candidate.
            if mediaSlot.reservesFrame {
                // Use a transparent 16:9 mold as the layout container. Applying
                // `.aspectRatio(..., .fill)` directly to `heroBase` lets the
                // square placeholder's intrinsic ratio drive the proposed size.
                GeometryReader { geometry in
                    ZStack {
                        heroBase
                            .frame(width: geometry.size.width, height: geometry.size.height)

                        // Render resolved image directly from the presentation.
                        // Zero async work — the pipeline already resolved it.
                        if let local = mediaSlot.localImage {
                            Image(uiImage: local.image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .overlay(isRead ? Color.black.opacity(0.15) : nil)
                        }
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipped()
                .overlay {
                    if onImageTap != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .highPriorityGesture(TapGesture().onEnded { onImageTap?() })
                    }
                }
                .overlay {
                    mediaOverlay
                }
                .overlay(alignment: .topTrailing) {
                    cardOverlays
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                // Source row after image
                sourceRow
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            } else {
                // No image — source row directly at top with extra top padding
                sourceRow
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
            }

            // Title
            Text(item.title)
                .font(titleFont)
                .fontWeight(engine.activeFontWeight ?? .semibold)
                .lineLimit(2)
                .foregroundStyle(isRead ? .secondary : .primary)
                .padding(.horizontal, 12)
                .padding(.top, hasImage ? 10 : 6)

            // Excerpt
            Text(item.excerpt)
                .font(bodyFont)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.horizontal, 12)
                .padding(.top, 6)

            // Meta row — date only
            HStack {
                Text(formattedDate(item.publishedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, engine.cardPadding)
        }
        .frame(maxWidth: .infinity)
        .background(engine.accent.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: engine.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: engine.cardRadius)
                .stroke(engine.accent.opacity(0.06), lineWidth: 0.5)
        )
        .overlay(alignment: .leading) {
            // Left border accent — category color, dimmed when read
            RoundedRectangle(cornerRadius: 2)
                .fill(categoryColor(item.category).opacity(isRead ? 0.25 : 0.8))
                .frame(width: 3)
                .padding(.vertical, 12)
                .padding(.leading, 1)
        }
        .contextMenu { cardContextMenu }
    }

    // MARK: - Landscape Card

    private var landscapeCard: some View {
        HStack(spacing: 12) {
            // Thumb — show for images or podcasts (audio placeholder)
            if mediaSlot.reservesFrame {
                Group {
                    if case .placeholder(.podcast) = mediaSlot, mediaSlot.localImage == nil {
                        podcastPlaceholder
                    } else {
                        placeholderImage(MainFeedCardBridge.placeholderKind(affordances.placeholder))
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: 90, height: 90)
                .clipped()
                .overlay {
                    if let local = mediaSlot.localImage {
                        Image(uiImage: local.image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        if onImageTap != nil {
                            Color.clear
                                .contentShape(Rectangle())
                                .highPriorityGesture(TapGesture().onEnded { onImageTap?() })
                        }
                    }
            }

            // Content
            VStack(alignment: .leading, spacing: 0) {
                // Source name
                Text(item.sourceTitle)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(item.title)
                    .font(titleFont)
                    .fontWeight(engine.activeFontWeight ?? .semibold)
                    .lineLimit(2)
                    .foregroundStyle(isRead ? .secondary : .primary)
                    .padding(.top, 4)

                Text(item.excerpt)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 3)

                HStack {
                    Text(formattedDate(item.publishedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(engine.accent.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(engine.accent.opacity(0.06), lineWidth: 0.5)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(categoryColor(item.category).opacity(isRead ? 0.25 : 0.8))
                .frame(width: 3)
                .padding(.vertical, 10)
                .padding(.leading, 1)
        }
        .contextMenu { cardContextMenu }
    }

    /// Decorative placeholder asset for one content kind and the active circadian palette, e.g.
    /// "Placeholder-Video-amber". The kind is the presentation's decision (PR-13); this only turns it
    /// into an asset name.
    private func placeholderImage(_ kind: PlaceholderKind) -> Image {
        let suffix = CircadianEngine.shared.paletteFamily.placeholderSuffix
        switch kind {
        case .video: return Image("Placeholder-Video-\(suffix)")
        case .podcast: return Image("Placeholder-Podcast-\(suffix)")
        case .forum: return Image("Placeholder-Forum-\(suffix)")
        case .article: return Image("Placeholder-Article-\(suffix)")
        }
    }

    private var podcastPlaceholder: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color.purple.opacity(0.25), Color.indigo.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Concentric rings suggesting audio playback
            ForEach(0..<3) { i in
                Circle()
                    .strokeBorder(Color.purple.opacity(0.12), lineWidth: 1)
                    .scaleEffect(0.4 + CGFloat(i) * 0.2)
            }

            // Center play button
            Circle()
                .fill(Color.purple.opacity(0.18))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.purple.opacity(0.6))
                        .offset(x: 1)
                }

            // Waveform at bottom
            VStack {
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(Color.purple.opacity(0.20))
                    .offset(y: 12)
            }
        }
    }

    // MARK: - Source Row (portrait only)

    private var sourceRow: some View {
        HStack(spacing: 4) {
            Text(item.sourceTitle)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(1)

            // Badges are the presentation's decision (PR-13): this only chooses the label, the colour
            // and the order, which is the same order the runtime stated.
            ForEach(Array(affordances.badges.enumerated()), id: \.offset) { _, badge in
                switch badge {
                case .podcast:
                    mediaBadge(String(localized: "Podcast"), color: .purple)
                    if let duration = affordances.durationLabel {
                        Text(duration).font(.caption2).foregroundStyle(.secondary)
                    }
                case .video:
                    mediaBadge(String(localized: "Video"), color: .red)
                case .new:
                    mediaBadge(String(localized: "New"), color: .blue)
                }
            }

            Spacer()

            // Bookmark on text-only cards
            if !hasImage {
                if isInBookmarkBox {
                    Menu {
                        BookmarkBoxContextMenu(itemID: item.id)
                        Divider()
                        Button(role: .destructive) {
                            onBookmark?()
                        } label: {
                            Label(String(localized: "Remove from Box"), systemImage: "bookmark.slash")
                        }
                    } label: {
                        Image(systemName: "bookmark.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                    .buttonStyle(.plain)
                    // Inside a box the control is this menu, not the button below: the identifier and
                    // the value are one contract, and the contract has two spellings because the box's
                    // action is different (`card.bookmark` toggles, `card.bookmarkBox` moves or removes).
                    // Without it a box's page had no observable control at all - measured 2026-09-18,
                    // baseline §8.62.
                    .accessibilityIdentifier("card.bookmarkBox")
                } else {
                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        onBookmark?()
                    } label: {
                        Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                            .font(.caption)
                            .foregroundStyle(isBookmarked ? .yellow : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    // The identifier and the value are one contract: `card.bookmark` is what a test
                    // targets (`ScreenID.cardBookmark`), and the value is the only way the state is
                    // observable from outside — the label is an SF Symbol image, so the filled and
                    // empty states are otherwise indistinguishable to XCUITest. Added for the
                    // reverse half of the ADR-004 D12 window (plan §14 PR-17 item 2): a bookmark
                    // taken while `v2Full` owns the feed must hydrate after a rollback to build 17.
                    .accessibilityIdentifier("card.bookmark")
                    .accessibilityValue(isBookmarked ? "bookmarked" : "not bookmarked")
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isBookmarked)
                }
            }
        }
    }

    // MARK: - Shared

    @ViewBuilder
    private var cardOverlays: some View {
        if isInBookmarkBox {
            Menu {
                BookmarkBoxContextMenu(itemID: item.id)
                Divider()
                Button(role: .destructive) {
                    onBookmark?()
                } label: {
                    Label(String(localized: "Remove from Box"), systemImage: "bookmark.slash")
                }
            } label: {
                Image(systemName: "bookmark.fill")
                    .font(.title3)
                    .foregroundStyle(.yellow)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.15), radius: 4)
                    .padding(12)
            }
            .buttonStyle(.plain)
            // The card-band spelling of the same contract (`card.bookmarkBox`); the button below is
            // `card.bookmark`. Both identifiers are what a test targets and what the value states.
            .accessibilityIdentifier("card.bookmarkBox")
        } else {
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                onBookmark?()
            } label: {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.title3)
                    .foregroundStyle(isBookmarked ? .yellow : .white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.15), radius: 4)
                    .padding(12)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            // Same contract as the text-only button above: `card.bookmark` plus the value, because
            // the label is a symbol image and the two states are otherwise indistinguishable from
            // outside the app.
            .accessibilityIdentifier("card.bookmark")
            .accessibilityValue(isBookmarked ? "bookmarked" : "not bookmarked")
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isBookmarked)
        }
    }

    @ViewBuilder
    private var mediaOverlay: some View {
        if let overlay = affordances.overlay {
            Image(systemName: overlay == .play ? "play.fill" : "headphones")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.35), in: Circle())
        }
    }

    private func mediaBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2).fontWeight(.heavy)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var cardContextMenu: some View {
        BookmarkBoxContextMenu(itemID: item.id)
        if let onViewSource {
            Button(action: onViewSource) {
                Label(String(localized: "View Source"), systemImage: "rectangle.stack")
            }
        }
        if let onAddSourceToCollection {
            Button(action: onAddSourceToCollection) {
                Label(String(localized: "Add Source to Collection"), systemImage: "rectangle.stack.badge.plus")
            }
        }
        Button {
            UIPasteboard.general.url = URL(string: item.url)
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            onCopy?()
        } label: {
            Label(String(localized: "Copy Link"), systemImage: "doc.on.doc")
        }
        Button {
            if let image = renderCardAsImage(item: item) {
                let av = UIActivityViewController(activityItems: [image], applicationActivities: nil)
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let root = windowScene.windows.first?.rootViewController {
                    root.present(av, animated: true)
                }
            }
        } label: {
            Label(String(localized: "Share as Image"), systemImage: "photo.artframe")
        }
        Button {
            if let url = URL(string: item.url) { UIApplication.shared.open(url) }
        } label: {
            Label(String(localized: "Open in Safari"), systemImage: "safari")
        }
        ShareLink(item: URL(string: item.url) ?? URL(string: "https://feedmine.app")!) {
            Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
        }
    }

    // MARK: - Helpers

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private func formattedDate(_ date: Date) -> String {
        let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        if Date().timeIntervalSince(date) < 7 * 24 * 3600 { return relative }
        return Self.shortDateFormatter.string(from: date)
    }

    private func categoryColor(_ category: String) -> Color {
        ComponentToken.categoryColor(for: category)
    }
}
