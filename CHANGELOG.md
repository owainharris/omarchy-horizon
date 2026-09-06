# Changelog

## 0.3.0

- Rename the plugin to Horizon. The plugin id, commands, and state directory
  keep the `span-wallpaper` name.
- Add an original icon and marketplace preview image, and rewrite the README
  around install, usage, and removal.
- Replace shell helpers with bounded Python source/state handling and atomic,
  descriptor-relative state publication in a private directory.
- Supervise helper output, deadlines, cancellation, and process groups. Reap
  orphaned descendants and terminate pipe holders even after their leader exits.
- Use a minimal helper environment, system executable paths, and plain-text
  rendering for dynamic monitor names, filenames, and diagnostics.
- Prevent an in-flight render or stale state read from restoring a cleared span.
- Cancel file selection and import when the controls are dismissed.
- Reject retained-image FIFOs without blocking; keep state reads relative to
  the verified directory and use the first frame of animated images.
- Document dependency installation, supported formats, and operational limits.
- Add exact-pixel crop, animation, filesystem, process-lifecycle, and controller
  regression checks.

## 0.2.0

- Initial marketplace submission: visual monitor selection, persistent spanning,
  three scaling modes, a bar widget, and automatic display relayout.
