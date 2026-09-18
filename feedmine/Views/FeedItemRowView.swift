import SwiftUI
import FeedDomain

struct FeedItemRowView: View {
    let item: FeedItem
    let isRead: Bool
    let isBookmarked: Bool
    /// The media decision for this row: local bytes, a deterministic placeholder, a reserved empty
    /// frame, or no slot at all (PR-13). The row never inspects `item` to decide what the thumbnail
    /// holds, and there is no `.loading` state and no URL, so it cannot start a download.
    var mediaSlot: CardMediaSlot = .none
    /// The chrome the runtime decided: placeholder kind and what the media slot does on a tap.
    var affordances: CardPresentation.Affordances = .undecided
    var onImageTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Thumbnail — local bytes, the compact podcast surface, or a reserved empty frame
            if mediaSlot.reservesFrame {
                Group {
                    switch mediaSlot {
                    case .local(let image):
                        Image(uiImage: image.image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .placeholder(.podcast):
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.purple.opacity(0.15))
                            .overlay {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(Color.purple.opacity(0.5))
                                    .offset(x: 1)
                            }
                    case .placeholder(let kind):
                        placeholderImage(kind)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .opacity(0.5)
                    // A reserved frame with nothing to draw keeps the surface stable and shows no
                    // stand-in asset: a fake thumbnail is worse than an empty one.
                    case .empty, .none:
                        Color.clear
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(isRead ? Color.black.opacity(0.15) : nil)
                .overlay {
                    if onImageTap != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .highPriorityGesture(TapGesture().onEnded { onImageTap?() })
                    }
                }
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(item.category)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(categoryColor(item.category))
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(item.sourceTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }

                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .foregroundStyle(isRead ? .secondary : .primary)

                Text(formattedDate(item.publishedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .opacity(isRead ? 0.7 : 1)
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private func formattedDate(_ date: Date) -> String {
        // Reuse a cached formatter — allocating RelativeDateTimeFormatter per
        // row (this runs on every row render) is expensive. Safe as a shared
        // static: rows render on the main actor. Matches FeedItemCardView.
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func categoryColor(_ category: String) -> Color {
        ComponentToken.categoryColor(for: category)
    }
}
