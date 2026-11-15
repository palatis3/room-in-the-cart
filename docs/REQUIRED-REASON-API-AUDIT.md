# Required-reason API audit

The unsigned arm64 archive under `.build/WidgetFileNov14/device/` imports `fstat` in the app, Share and Widget. The app also imports `lstat` and UserDefaults. Each target now has a reviewed privacy manifest in its resource list. The compiled bundle checker compares each embedded manifest with the source for that target. [Apple’s per-executable guidance](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)

The November 3 [source inventory](/Users/palatis/Documents/Codex/2026-11-03/task/review/tracker/required-reason-source-inventory.json) records 160 source and package manifest files, including 112 shipping source files. It includes source hashes and separates Tests and UITests from shipping code. The subsequent review traced the imported API to its shipping call sites and checked the app and both embedded extensions.

| Category | Actual source and scope | Declaration assessment |
|---|---|---|
| UserDefaults | [RoomInTheCartApp.swift](../ios/App/RoomInTheCartApp.swift) has two appearance `@AppStorage` properties. [WorkspaceAccess.swift](../ios/App/WorkspaceAccess.swift) reads/writes the app's own protection/access state using standard defaults. The pickup feedback consent store also uses standard app defaults, and app reset clears its key | Existing `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1` matches the inspected app-only use |
| File metadata in the app | Recovery capture and the registry inspect local files. The Records document picker obtains scoped access and coordinates a bounded read of the chosen document. The descriptor checks use file type and size. | `C617.1` for container files and `3B52.1` for user-granted files. [Records picker](../ios/Features/Records/RecordsFileDocument.swift) |
| File metadata in Share | The user shares selected text. When a host supplies it as a file, the extension checks the size and type of the temporary representation during the item-provider callback. | `3B52.1` for the user-granted input. [Selected text reader](../ios/Packages/DeviceSurfaces/Sources/DeviceSurfaces/SelectedTextInbox.swift) |
| File metadata in Widget | The widget checks the shared projection file’s type and size before decoding it from its App Group. | `C617.1` for the App Group container. [Widget file reader](../ios/Packages/DeviceSurfaces/Sources/DeviceSurfaces/IOSAdapters.swift) |
| System boot time | The app and feature sources contain four `systemUptime` references. Two belong to the simulator signpost-control build, and two belong to debug contributor fixtures. The ordinary Release archive excludes those code paths | No shipping declaration added for a test-only fixture |
| Disk space | No listed capacity/POSIX disk-space API source hit | No reason inferred |
| Active keyboards | No `activeInputModes` source hit | No reason inferred |

Apple classifies `fstat` and `lstat` under File Timestamp, including calls used to check file size or type. Both SQLite bridges link the system library. [Apple’s API and reason list](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)

The November 4 Xcode report recorded seven linked data types, three with an Analytics purpose. The current API declarations account for subsequent file-reader changes. [Historical archive validation](evidence/native/privacy-archive-20261104/validation.json) · [Historical Xcode privacy report](evidence/native/privacy-archive-20261104/RoomInTheCart-PrivacyReport.pdf)

The seven collection declarations are tracked in the [data-collection inventory](PRIVACY-DATA-INVENTORY.md). Check the final signed build and dependency manifests again if shipping source, SDKs, dependencies or Apple's API list changes.

The public Apple documentation retrieved for reproducibility is retained in the task review folder: [category JSON](/Users/palatis/Documents/Codex/2026-11-03/task/review/tracker/apple-required-reason-categories.json) and [overview Markdown](/Users/palatis/Documents/Codex/2026-11-03/task/review/tracker/apple-required-reason-api.md). Apple's category Markdown view omitted its possible-values table during this inspection, so the official structured documentation supplied the actual API/reason list.
