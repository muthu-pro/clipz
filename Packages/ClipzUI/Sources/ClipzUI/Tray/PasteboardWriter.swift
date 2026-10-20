// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import ClipzCore

/// Writes a captured `ClipboardItem` back to the system pasteboard in
/// whatever form matches the item's kind. Called when the user clicks
/// a row in the tray popover: the clip becomes the current pasteboard
/// content so the user can paste normally in their target app.
///
/// Before writing, we tell `ClipboardWatcher.ignoreNextChange()` so the
/// watcher doesn't turn around and re-capture our own write.
@MainActor
public enum PasteboardWriter {
    public static func write(
        _ item: ClipboardItem,
        fileStore: FileStore,
        watcher: ClipboardWatcher
    ) async {
        await watcher.ignoreNextChange()

        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.kind {
        case .text:
            pb.setString(item.content, forType: .string)

        case .html:
            // Rich HTML for editors that accept it, plus the *full*
            // plain-text form (not the ~500-char search preview) so
            // plain-text targets get the complete text, untruncated.
            pb.setString(item.content, forType: .html)
            pb.setString(HTMLText.plain(from: item.content), forType: .string)

        case .image, .screenshot:
            // Write the file URL so file-receiving apps (Finder, Mail,
            // Messages, Notes) can paste the image as an actual file.
            // Also include the raw bytes typed by the file's real
            // extension so pixel-only consumers (Slack, browser
            // composers, image editors) still get the image. PNG-only
            // was the prior behaviour and silently failed in Finder.
            let url = fileStore.mediaURL(filename: item.content)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            pb.writeObjects([url as NSURL])
            if let data = try? Data(contentsOf: url) {
                let type = imagePasteboardType(
                    forExtension: url.pathExtension.lowercased()
                )
                pb.setData(data, forType: type)
            }

        case .video, .pdf, .doc, .docx, .xls, .xlsx, .numbers:
            let url = fileStore.mediaURL(filename: item.content)
            if FileManager.default.fileExists(atPath: url.path) {
                pb.writeObjects([url as NSURL])
            }
        }
    }

    /// Map a captured image's on-disk extension to the right
    /// `NSPasteboard.PasteboardType`. Anything we don't recognise falls
    /// back to PNG — receivers that care will use the file URL anyway.
    private static func imagePasteboardType(
        forExtension ext: String
    ) -> NSPasteboard.PasteboardType {
        switch ext {
        case "png":          return .png
        case "jpg", "jpeg":  return NSPasteboard.PasteboardType("public.jpeg")
        case "tiff", "tif":  return .tiff
        case "heic", "heif": return NSPasteboard.PasteboardType("public.heic")
        case "gif":          return NSPasteboard.PasteboardType("com.compuserve.gif")
        case "bmp":          return NSPasteboard.PasteboardType("com.microsoft.bmp")
        default:             return .png
        }
    }
}
