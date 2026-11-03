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

@main struct RoomInTheCartWidget: Widget {
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
