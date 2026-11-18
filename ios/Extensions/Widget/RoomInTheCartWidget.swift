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
            Label(SurfaceCopy.text("Open grocery entry"), systemImage: "cart")
                .font(.headline)
                .widgetURL(entry.url)
                .containerBackground(.fill.tertiary, for: .widget)
        }.configurationDisplayName(SurfaceCopy.text("Grocery entry"))
            .description(SurfaceCopy.text("Open the app to review an entry. Private details stay in the app."))
            .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct FoodEntry: TimelineEntry {
    let date: Date
    let summary: AdultFoodSummaryProjection?
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
                                      FoodEntry(date: value.expiresAt, summary: nil)], policy: .atEnd))
    }
}

private protocol AdultFoodWidget: Widget { var kind: AdultFoodSummaryKind { get } }

private extension AdultFoodWidget {
    var title: String { SurfaceCopy.text(kind == .useSoon ? "Use soon" : "Tonight") }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind.widgetKind, provider: FoodProvider(kind: kind)) { entry in
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                if let summary = entry.summary, summary.isFresh(at: Date(), zone: .current) {
                    let format = SurfaceCopy.text(kind == .useSoon ? "Batches to check today or earlier: %lld" : "Reviewed meal options: %lld")
                    Text(String(format: format, locale: Locale.current, Int64(summary.count)))
                    if let title = summary.reviewedTitle { Text(verbatim: title).lineLimit(2) }
                } else { Text(SurfaceCopy.text("Open the app to review this item")) }
            }.privacySensitive()
                .widgetURL(entry.summary.flatMap { (try? IOSSurfaceContainers.urls())?.url(handle: $0.route) })
                .containerBackground(.fill.tertiary, for: .widget)
        }.configurationDisplayName(title)
            .description(SurfaceCopy.text("Show a private summary after turning it on in the app."))
            .supportedFamilies([.systemMedium])
            .containerBackgroundRemovable(false)
            .disfavoredLocations([.lockScreen, .standBy, .iPhoneWidgetsOnMac], for: [.systemMedium])
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
