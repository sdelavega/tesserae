// Tesserae: a disk-space visualizer.
// Copyright (C) 2026 Stephen de la Vega
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.


import Foundation

/// A coarse file kind for the type-focus colour mode, by lowercased extension.
public enum FileKind: CaseIterable, Hashable, Sendable {
    case video, images, audio, archives, documents

    static let extensions: [FileKind: Set<String>] = [
        .video: ["mp4", "mov", "m4v", "mkv", "avi", "webm", "mts"],
        .images: [
            "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp", "raw", "cr2",
            "cr3", "nef", "arw", "dng", "psd",
        ],
        .audio: ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus"],
        .archives: ["zip", "dmg", "iso", "tar", "gz", "tgz", "xz", "bz2", "7z", "rar", "pkg", "xip"],
        .documents: [
            "pdf", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "ppt", "pptx", "txt",
            "rtf", "md", "epub",
        ],
    ]

    /// The kind of a file with this name (raw bytes, not necessarily UTF-8),
    /// or nil. The extension is what follows the last dot, case-insensitively;
    /// a leading dot alone (".mp4") or a trailing one ("clip.") is no extension.
    public static func kind(forName name: Data) -> FileKind? {
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")),
            dot > name.startIndex, dot < name.endIndex - 1
        else { return nil }
        let ext = String(decoding: name[(dot + 1)...], as: UTF8.self).lowercased()
        return allCases.first { extensions[$0]?.contains(ext) == true }
    }
}
