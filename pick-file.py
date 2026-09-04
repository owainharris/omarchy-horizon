#!/usr/bin/env python3
"""Open a GTK file chooser out of process and print the selected image path."""

from __future__ import annotations

import os
import sys

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gio, GLib, Gtk  # noqa: E402


class ImagePicker(Gtk.Application):
    def __init__(self, selected_path: str = "") -> None:
        super().__init__(application_id="dev.kudos.SpanWallpaperPicker")
        self.selected_path = selected_path

    def do_activate(self) -> None:
        dialog = Gtk.FileDialog.new()
        dialog.set_title("Choose an image to span")
        dialog.set_modal(True)

        images = Gtk.FileFilter()
        images.set_name("Images")
        for mime_type in (
            "image/jpeg",
            "image/png",
            "image/webp",
            "image/gif",
            "image/bmp",
        ):
            images.add_mime_type(mime_type)
        all_files = Gtk.FileFilter()
        all_files.set_name("All files")
        all_files.add_pattern("*")

        filters = Gio.ListStore.new(Gtk.FileFilter)
        filters.append(images)
        filters.append(all_files)
        dialog.set_filters(filters)
        dialog.set_default_filter(images)

        if self.selected_path:
            directory = os.path.dirname(os.path.abspath(self.selected_path))
            if os.path.isdir(directory):
                dialog.set_initial_folder(Gio.File.new_for_path(directory))

        self.hold()

        def finish(chooser: Gtk.FileDialog, result: Gio.AsyncResult) -> None:
            exit_code = 0
            try:
                selected = chooser.open_finish(result)
                path = selected.get_path() if selected is not None else None
                if path:
                    print(path, flush=True)
            except GLib.Error as error:
                cancelled = error.matches(
                    Gtk.DialogError.quark(), int(Gtk.DialogError.CANCELLED)
                ) or error.matches(
                    Gtk.DialogError.quark(), int(Gtk.DialogError.DISMISSED)
                )
                if not cancelled:
                    print(f"Could not open the image chooser: {error.message}", file=sys.stderr)
                    exit_code = 1
            self.release()
            self.quit()
            self.exit_code = exit_code

        dialog.open(None, None, finish)


def main() -> int:
    selected_path = sys.argv[1] if len(sys.argv) > 1 else ""
    app = ImagePicker(selected_path)
    app.exit_code = 0
    app.run([])
    return app.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
