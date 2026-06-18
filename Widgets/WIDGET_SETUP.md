# Widget Extension setup

These files are written *but not yet attached to a widget target*. To enable the
Lock Screen + Home Screen widgets:

1. In Xcode → File → New → Target → **Widget Extension** (name it `BookMarkWidget`,
   uncheck "Include Configuration App Intent" unless you want it).
2. Delete the boilerplate Swift files Xcode creates for the new target.
3. Add the three files in this folder (`SharedSnapshotStore.swift`, `BookMarkWidget.swift`,
   `WidgetBundle.swift`) to the *widget target only* (uncheck the main app target on
   each file's File Inspector).
4. In **Signing & Capabilities** for both the app and the widget extension, add
   an **App Group** with id `group.com.bdeavilla.bookmark`. This must match
   `Store.appGroupId` in the main app.
5. Build & run. Long-press the home screen → tap **+** → search "BookMark" to
   add a widget.

The main app already writes a `widget-snapshot.json` to the App Group container
every time data changes (see `Store.writeSharedSnapshot()`), so as soon as the
target is configured the widgets will start showing live data.
