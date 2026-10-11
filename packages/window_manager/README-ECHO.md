# Echoes window_manager patch

This is `window_manager` 0.5.2, vendored from pub.dev. The upstream license is
in `LICENSE`. Its Dart and macOS implementations are unchanged.

The Linux plugin synthesizes a mouse button release after a native window move
or resize. Upstream leaves the event's GDK device and window unset, which can
trigger `gdk_device_get_axis: assertion 'GDK_IS_DEVICE (device)' failed` during
GTK event handling. The local patch fills those fields and uses
`GDK_CURRENT_TIME` rather than passing a microsecond monotonic timestamp to a
millisecond GDK field. It is scoped to the Linux plugin.

The Windows plugin reports fullscreen transitions independently of whether
`WM_SIZE` uses `SIZE_MAXIMIZED` or `SIZE_RESTORED`, and emits a transition after
the command if no resize event reported it. Repeated fullscreen requests are
no-ops so they preserve the original window bounds and style for restoration.
