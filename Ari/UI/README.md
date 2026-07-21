# Ari/UI

Native SwiftUI read UI (Phase 2, slice S6 — see `docs/plans/arikit-native-read-ui.md`).

This folder is a **file-system-synchronized group** in `Ari.xcodeproj` (objectVersion 77): any
`*.swift` added here is compiled into the `Ari` app target automatically — no pbxproj edit needed.
View models live separately in the `AriViewModels` package (`AriKit/Sources/AriViewModels/`); this
folder holds only SwiftUI views + the `AVPlayer` glue.
