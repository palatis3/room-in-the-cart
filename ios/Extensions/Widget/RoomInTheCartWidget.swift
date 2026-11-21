import WidgetKit
import SwiftUI
import DeviceSurfaces

private struct CaptureEntry: TimelineEntry {
    let date: Date
    let url: URL?
}
private struct CaptureProvider: TimelineProvider {
    func placeholder(in context: Context) -> CaptureEntry { CaptureEntry(date: Date(), url: nil) }
    func getSnapshot(in context: Context, completion: @escaping (CaptureEntry) -> Void) { completion(entry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CaptureEntry>) -> Void) { completion(Timeline(entries: [entry()], policy: .never)) }
    private func entry() -> CaptureEntry {
        guard let urls = try? IOSSurfaceContainers.urls() else { return CaptureEntry(date: Date(), url: nil) }
        let projection = try? WidgetProjectionFile(directory: IOSSurfaceContainers.directory(groupKey: SurfaceInfo.widgetGroupKey)).read()
        return CaptureEntry(date: Date(), url: urls.url(handle: projection?.routeHandle))
    }
}

struct RoomInTheCartWidget: Widget {
    let kind = "RoomInTheCartCapture"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CaptureProvider()) { entry in
            CaptureWidgetView()
                .widgetURL(entry.url)
                .containerBackground(for: .widget) { Color("surface") }
        }.configurationDisplayName(SurfaceCopy.text("Grocery entry"))
            .description(SurfaceCopy.text("Open the app to review an entry. Private details stay in the app."))
            .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct CaptureWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let title = SurfaceCopy.text("Open grocery entry")
        switch family {
        case .systemSmall:
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    if renderingMode == .fullColor {
                        Image(decorative: "MarketGroceries")
                            .resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 48, alignment: .trailing)
                    } else {
                        Image(systemName: "cart.badge.plus")
                            .font(.title2).widgetAccentable().accessibilityHidden(true)
                    }
                    Divider()
                    entryTitle(title)
                }
                entryTitle(title)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .foregroundStyle(renderingMode == .fullColor ? Color("ink") : Color.primary)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "cart.badge.plus").font(.title3.weight(.semibold)).widgetAccentable()
            }.accessibilityElement(children: .ignore).accessibilityLabel(title)
        case .accessoryRectangular:
            Label {
                Text(title).font(.system(.headline, design: .serif, weight: .semibold))
            } icon: {
                Image(systemName: "cart.badge.plus").widgetAccentable()
            }
        default:
            Label(title, systemImage: "cart.badge.plus")
        }
    }

    private func entryTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(.title3, design: .serif, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FoodEntry: TimelineEntry {
    let date: Date
    let summary: AdultFoodSummaryProjection?
    // An expired timeline entry keeps only its opaque route so a tap reaches the
    // app's unavailable destination after its own current-authority check.
    var expiredRoute: RouteHandle? = nil
}

private struct FoodProvider: TimelineProvider {
    let kind: AdultFoodSummaryKind
    func placeholder(in context: Context) -> FoodEntry { FoodEntry(date: Date(), summary: nil) }
    func getSnapshot(in context: Context, completion: @escaping (FoodEntry) -> Void) {
        completion(placeholder(in: context))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FoodEntry>) -> Void) {
        let now = Date()
        guard context.family == .systemMedium, !context.isPreview,
              let directory = try? IOSSurfaceContainers.directory(groupKey: SurfaceInfo.widgetGroupKey),
              let value = try? AdultFoodSummaryFile(directory: directory, kind: kind).read(),
              value.isFresh(at: now, zone: .current) else {
            completion(Timeline(entries: [FoodEntry(date: now, summary: nil)], policy: .never)); return
        }
        completion(Timeline(entries: [FoodEntry(date: now, summary: value),
                                      FoodEntry(date: value.expiresAt, summary: nil, expiredRoute: value.route)], policy: .atEnd))
    }
}

private protocol AdultFoodWidget: Widget { var kind: AdultFoodSummaryKind { get } }

private extension AdultFoodWidget {
    var title: String { SurfaceCopy.text(kind == .useSoon ? "Use soon" : "Tonight") }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind.widgetKind, provider: FoodProvider(kind: kind)) { entry in
            AdultSummaryWidgetView(kind: kind, title: title, entry: entry)
        }.configurationDisplayName(title)
            .description(SurfaceCopy.text("Show a private summary after turning it on in the app."))
            .supportedFamilies([.systemMedium])
            .containerBackgroundRemovable(false)
            .disfavoredLocations([.lockScreen, .standBy, .iPhoneWidgetsOnMac], for: [.systemMedium])
    }
}

private struct AdultSummaryWidgetView: View {
    let kind: AdultFoodSummaryKind
    let title: String
    let entry: FoodEntry
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.redactionReasons) private var redaction
    @Environment(\.locale) private var locale

    var body: some View {
        let summary = entry.summary.flatMap { value in
            !redaction.contains(.privacy) && value.isFresh(at: Date(), zone: .current) ? value : nil
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Image(systemName: kind == .useSoon ? "calendar" : "fork.knife")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(renderingMode == .fullColor ? Color("accent") : Color.primary)
                    .widgetAccentable()
                    .accessibilityHidden(true)
            }
            Divider()
            if let summary {
                VStack(alignment: .leading, spacing: 2) {
                    if let meal = summary.reviewedTitle {
                        Text(verbatim: meal)
                            .font(.system(.headline, design: .serif, weight: .semibold))
                            .lineLimit(2)
                    }
                    Text(summaryText(summary))
                        .font(.body)
                    Spacer(minLength: 0)
                    let time = summary.writtenAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
                    Text(String(format: SurfaceCopy.text("Updated at %@"), locale: locale, time))
                        .font(.caption)
                        .foregroundStyle(renderingMode == .fullColor ? Color("secondary") : Color.secondary)
                }
                .privacySensitive()
            } else {
                Text(SurfaceCopy.text("Open the app to review this item"))
                    .font(.body)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(renderingMode == .fullColor ? Color("ink") : Color.primary)
        .widgetURL((entry.summary?.route ?? entry.expiredRoute).flatMap { (try? IOSSurfaceContainers.urls())?.url(handle: $0) })
        .containerBackground(for: .widget) { Color("surface") }
    }

    private func summaryText(_ summary: AdultFoodSummaryProjection) -> String {
        if summary.plannedDinner == true, summary.count == 1 { return SurfaceCopy.text("Planned for tonight") }
        let key = kind == .useSoon ? "Batches to check today or earlier: %lld"
            : summary.plannedDinner == true ? "%lld dinners planned" : "Reviewed meal options: %lld"
        return String(format: SurfaceCopy.text(key), locale: locale, Int64(summary.count))
    }
}

private struct TonightWidget: AdultFoodWidget { let kind = AdultFoodSummaryKind.tonight }
private struct UseSoonWidget: AdultFoodWidget { let kind = AdultFoodSummaryKind.useSoon }

@main struct GroceryWidgets: WidgetBundle {
    var body: some Widget {
        RoomInTheCartWidget()
        UseSoonWidget()
        TonightWidget()
    }
}
