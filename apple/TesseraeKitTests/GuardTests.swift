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

import Darwin
import Foundation
import XCTest

@testable import TesseraeKit

final class GuardTests: XCTestCase {
    private func context(root: String = "/Volumes/Work", home: Data = Data("/Users/tester".utf8),
                         app: String = "/Applications/Tesserae.app", volume: String? = nil) -> GuardContext {
        GuardContext(scanRoot: Data(root.utf8), volumeRoot: Data((volume ?? root).utf8), scanRootDevice: 7,
                     appBundle: URL(fileURLWithPath: app), home: home)
    }

    private func observed(device: Int32 = 7, flags: UInt32 = 0, directory: Bool = false,
                          links: UInt16 = 1) -> Observed {
        Observed(device: device, flags: flags, isDirectory: directory, linkCount: links)
    }

    private func check(_ rows: [(String, Verdict)], _ ctx: GuardContext,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(rows.isEmpty, file: file, line: line)
        for (path, expected) in rows {
            XCTAssertTrue(path.hasPrefix("/"), file: file, line: line)
            XCTAssertEqual(policyVerdict(Data(path.utf8), ctx), expected, path, file: file, line: line)
        }
    }

    func test_symlinked_home_spellings_protect_physical_home_library_and_containers() throws {
        let f = DiskImageFixture()
        try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let root = try XCTUnwrap(f.root)
        let physical = root.appendingPathComponent("deep/physical"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        XCTAssertNotEqual(alias.path, alias.resolvingSymlinksInPath().path)
        let ctx = GuardContext(scanRoot: Data(root.path.utf8), volumeRoot: Data("/".utf8), scanRootDevice: 7,
            appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"), home: Data(alias.path.utf8))
        for spelling in [alias.path, alias.resolvingSymlinksInPath().path] {
            for suffix in ["", "/Library"] {
                XCTAssertEqual(policyVerdict(Data((spelling + suffix).utf8), ctx), .denied(.userAccountCore))
            }
            for suffix in ["/Library/Containers/app", "/Library/Group Containers/app"] {
                XCTAssertEqual(policyVerdict(Data((spelling + suffix).utf8), ctx), .warn(.appContainer))
            }
        }
    }

    func test_any_trash_component_is_denied() {
        let ctx = GuardContext(scanRoot: Data("/".utf8), volumeRoot: Data("/".utf8), scanRootDevice: 7,
            appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"), home: Data("/Users/tester".utf8))
        for path in ["/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/.Trash/file", "/Users/other/.tRaSh/file"] {
            XCTAssertEqual(policyVerdict(Data(path.utf8), ctx), .denied(.alreadyInTrash))
        }
    }

    func test_every_denied_prefix() {
        let rows: [(String, Reason)] = [
            ("/System", .osIntegrity), ("/bin", .osIntegrity), ("/sbin", .osIntegrity),
            ("/Library/Apple", .osIntegrity), ("/usr", .osIntegrity),
            ("/private/var/db", .systemState), ("/cores", .systemState),
            ("/private/var/vm", .systemState), ("/private/var/folders", .appTemporaryFiles)
        ]
        XCTAssertEqual(rows.count, 9)
        for (path, reason) in rows {
            check([(path, .denied(reason)), (path + "/x", .denied(reason))], context())
        }
    }

    func test_usr_local_exception() {
        check([("/usr/local", .ok), ("/usr/local/x", .ok), ("/usr/x", .denied(.osIntegrity)),
               ("/usr/locality/x", .denied(.osIntegrity))], context())
    }

    func test_system_managed_and_backup_components() {
        for name in [".Spotlight-V100", ".fseventsd"] {
            check([("/safe/" + name, .denied(.systemManaged)),
                   ("/safe/" + name + "/x", .denied(.systemManaged))], context())
        }
        check([("/safe/Backups.backupdb", .denied(.timeMachineBackup)),
               ("/safe/Backups.backupdb/x", .denied(.timeMachineBackup))], context())
    }

    func test_volume_root_and_first_level_children() {
        for root in ["/", "/System/Volumes/Data", "/Volumes/Work"] {
            let child = root == "/" ? "/ordinary" : root + "/ordinary"
            check([(root, .denied(.volumeRootOrTopLevel)),
                   (child, .denied(.volumeRootOrTopLevel)), (child + "/x", .ok)],
                  context(root: root, app: "/elsewhere/App.app"))
        }
        check([("/Volumes/Worker", .ok), ("/Volumes/Work/ordinary/x", .ok)], context())
        // Both spellings are first-level children of the Data volume.
        check([("/Users", .denied(.volumeRootOrTopLevel)),
               ("/ordinary", .denied(.volumeRootOrTopLevel))], context(root: "/System/Volumes/Data"))
    }

    func test_folder_scan_uses_volume_root_and_firmlinked_forms() {
        let ctx = context(root: "/Users/tester/Downloads", volume: "/System/Volumes/Data")
        XCTAssertNotEqual(ctx.scanRoot, ctx.volumeRoot)
        check([("/Users/tester/Downloads/x", .ok),
               ("/System/Volumes/Data", .denied(.volumeRootOrTopLevel)),
               ("/System/Volumes/Data/Users", .denied(.volumeRootOrTopLevel)),
               ("/Users", .denied(.volumeRootOrTopLevel)),
               ("/", .denied(.volumeRootOrTopLevel))], ctx)
        check([("/Volumes/Img", .denied(.volumeRootOrTopLevel)),
               ("/Volumes/Img/a", .denied(.volumeRootOrTopLevel)),
               ("/Volumes/Img/a/b", .ok)],
              context(root: "/Volumes/Img/a", volume: "/Volumes/Img"))
    }

    func test_volume_root_helper_reads_mount_point() throws {
        XCTAssertEqual(try volumeRoot(of: Data("/".utf8)), Data("/".utf8))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("justfile").path))
        // df independently reports the kernel mount point; Foundation's volume URL
        // can instead report / for firmlinked locations on the Data volume.
        let df = Process()
        df.executableURL = URL(fileURLWithPath: "/bin/df")
        df.arguments = ["-P", repo.path]
        let pipe = Pipe()
        df.standardOutput = pipe
        try df.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        df.waitUntilExit()
        XCTAssertEqual(df.terminationStatus, 0)
        let lines = try XCTUnwrap(String(data: output, encoding: .utf8)).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let fields = try XCTUnwrap(lines.last).split(maxSplits: 5, whereSeparator: { $0.isWhitespace })
        XCTAssertEqual(fields.count, 6)
        let mount = String(try XCTUnwrap(fields.last)).trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(mount.hasPrefix("/"))
        XCTAssertNotEqual(String(mount), repo.path)
        XCTAssertEqual(try volumeRoot(of: Data(repo.path.utf8)), Data(mount.utf8))
    }

    func test_user_account_core_and_container_ancestors() {
        for home in ["/Users/tester", "/System/Volumes/Data/Users/tester"] {
            let ctx = context(home: Data(home.utf8), volume: "/System/Volumes/Data")
            for spelling in ["/Users/tester", "/System/Volumes/Data/Users/tester"] {
                check([(spelling, .denied(.userAccountCore)),
                       (spelling + "/Library", .denied(.userAccountCore)),
                       (spelling + "/Documents", .ok),
                       (spelling + "/Library/Caches/x", .ok)], ctx)
            }
        }
        // An ancestor with no denial still contains app data, even for an
        // unusual home on a nested mount. Other policy denials still win.
        let nested = context(home: Data("/Volumes/Img/accounts/tester".utf8), volume: "/Volumes/Img")
        check([("/Volumes/Img/accounts", .denied(.volumeRootOrTopLevel))], nested)
        let deep = context(home: Data("/Volumes/Img/accounts/team/tester".utf8), volume: "/Volumes/Img")
        check([("/Volumes/Img/accounts/team", .warn(.appContainer))], deep)
        let priority = context(root: "/Users/tester", volume: "/Users")
        XCTAssertEqual(combinedVerdict(Data("/Users/tester".utf8), observed(device: 8), priority),
                       .denied(.userAccountCore))
    }

    func test_non_canonical_paths_are_denied_first() {
        let paths = ["/usr/local/../bin", "/Users/tester/./Library/Containers/x",
                     "/Users/tester/../tester/.Trash/x", "/./System/x", "/../System/x",
                     "System/x", "", "/System/./x", "/private/var/db/../x"]
        XCTAssertEqual(paths.count, 9)
        let all = observed(device: 8, flags: UInt32(SF_RESTRICTED | UF_IMMUTABLE))
        for path in paths {
            let raw = Data(path.utf8)
            XCTAssertTrue(raw.isEmpty || raw.first != 0x2f || raw.split(separator: 0x2f).contains {
                $0 == Data(".".utf8) || $0 == Data("..".utf8)
            })
            XCTAssertEqual(policyVerdict(raw, context()), .denied(.nonCanonicalPath), path)
            XCTAssertEqual(combinedVerdict(raw, all, context()), .denied(.nonCanonicalPath), path)
        }
        check([("/safe/.../x", .ok), ("/safe/.hidden/x", .ok)], context())
    }

    func test_app_bundle_ancestors_and_contents() {
        check([("/", .denied(.selfOrAncestorOfApp)),
               ("/Applications", .denied(.selfOrAncestorOfApp)),
               ("/Applications/Tesserae.app", .denied(.selfOrAncestorOfApp)),
               ("/Applications/Tesserae.app/Contents/MacOS/Tesserae", .denied(.selfOrAncestorOfApp)),
               ("/Applications/Tesserae.app2", .ok), ("/Application", .ok),
               ("/System/Volumes/Data/Applications/Tesserae.app/x", .denied(.selfOrAncestorOfApp))], context())
        check([("/Applications/Tesserae.app/x", .denied(.selfOrAncestorOfApp))],
              context(app: "/System/Volumes/Data/Applications/Tesserae.app"))
    }

    func test_containers_and_their_parent_folders_warn() {
        for name in ["Containers", "Group Containers"] {
            for prefix in ["", "/System/Volumes/Data"] {
                let path = prefix + "/Users/tester/Library/" + name
                check([(path, .warn(.appContainer)), (path + "/com.example/x", .warn(.appContainer))], context())
            }
        }
        check([("/Users/other/Library/Containers/x", .ok),
               ("/Users/tester/Library/ContainersExtra/x", .ok)], context())
        check([("/Users/tester/Library/Containers/x", .warn(.appContainer))],
              context(home: Data("/System/Volumes/Data/Users/tester".utf8)))
    }

    func test_data_volume_paths_are_judged_by_their_firmlinked_path() {
        check([("/System/Volumes/Data/private/var/db/x", .denied(.systemState)),
               ("/System/Volumes/Data/usr/local/x", .ok),
               ("/System/Volumes/Data/Users/tester/Documents/x", .ok),
               ("/sYsTeM/vOlUmEs/dAtA/private/var/vm/x", .denied(.systemState)),
               ("/System/Volumes/Database/Users/x", .denied(.osIntegrity)),
               ("/System/Volumes/Data/System/Volumes/Data/Users/x", .denied(.osIntegrity))], context())
    }

    func test_cloud_only_item_warns_and_frees_nothing() {
        let cloud = observed(flags: UInt32(SF_DATALESS))
        XCTAssertNotEqual(cloud.flags, 0)
        XCTAssertEqual(physicsVerdict(cloud, context()), .warn(.cloudOnly))
        XCTAssertEqual(combinedVerdict(Data("/safe/file".utf8), cloud, context()), .warn(.cloudOnly))
        // Reclaim accounting consumes this warning in Task 5; the guard never reports bytes.
        XCTAssertEqual(physicsVerdict(observed(), context()), .ok)
    }

    func test_items_in_a_trash_are_denied() {
        check([("/Users/tester/.Trash", .denied(.alreadyInTrash)),
               ("/Users/tester/.Trash/file", .denied(.alreadyInTrash)),
               ("/System/Volumes/Data/Users/tester/.Trash/file", .denied(.alreadyInTrash)),
               ("/safe/.Trashes", .denied(.alreadyInTrash)),
               ("/safe/.Trashes/501/file", .denied(.alreadyInTrash)),
               ("/safe/.tRaShEs/file", .denied(.alreadyInTrash)),
               ("/Users/other/.Trash/file", .denied(.alreadyInTrash)), ("/Users/tester/.TrashExtra/x", .ok)], context())
        check([("/Users/tester/.Trash/x", .denied(.alreadyInTrash))],
              context(home: Data("/System/Volumes/Data/Users/tester".utf8)))
    }

    func test_other_hard_links_warn() {
        let file = observed(links: 2)
        XCTAssertFalse(file.isDirectory)
        XCTAssertGreaterThan(file.linkCount, 1)
        XCTAssertEqual(physicsVerdict(file, context()), .warn(.otherHardLinks))
        XCTAssertEqual(physicsVerdict(observed(links: UInt16.max), context()), .warn(.otherHardLinks))
        XCTAssertEqual(physicsVerdict(observed(directory: true, links: 2), context()), .ok)
        XCTAssertEqual(physicsVerdict(observed(links: 1), context()), .ok)
        XCTAssertEqual(physicsVerdict(observed(links: 0), context()), .ok)
    }

    func test_component_matching_not_string_prefix() {
        check([("/usrlocal/x", .ok), ("/Systematic/x", .ok), ("/binary/x", .ok),
               ("/safe/.TrashesExtra/x", .ok), ("/safe/.Spotlight-V100Extra/x", .ok),
               ("/safe/.fseventsdExtra/x", .ok), ("/safe/Backups.backupdbExtra/x", .ok),
               ("/private/var/dbExtra/x", .ok), ("/safe/usr/x", .ok),
               ("/safe/System/Volumes/Data/usr/x", .ok)], context())
    }

    func test_case_folded_system_prefixes_are_denied() {
        check([("/sYsTeM/x", .denied(.osIntegrity)), ("/BIN/x", .denied(.osIntegrity)),
               ("/SBIN/x", .denied(.osIntegrity)), ("/LIBRARY/aPpLe/x", .denied(.osIntegrity)),
               ("/USR/x", .denied(.osIntegrity)), ("/USR/LOCAL/x", .ok),
               ("/PRIVATE/VAR/DB/x", .denied(.systemState)),
               ("/CORES/x", .denied(.systemState)), ("/PRIVATE/VAR/VM/x", .denied(.systemState)),
               ("/PRIVATE/VAR/FOLDERS/x", .denied(.appTemporaryFiles)),
               ("/safe/.SPOTLIGHT-V100/x", .denied(.systemManaged)),
               ("/safe/.FSEVENTSD/x", .denied(.systemManaged)),
               ("/safe/BACKUPS.BACKUPDB/x", .denied(.timeMachineBackup))], context())
    }

    func test_other_device_is_denied() {
        let other = observed(device: 8)
        XCTAssertNotEqual(other.device, context().scanRootDevice)
        XCTAssertEqual(physicsVerdict(other, context()), .denied(.otherVolume))
        XCTAssertEqual(physicsVerdict(observed(), context()), .ok)
    }

    func test_each_physics_flag_is_denied() {
        for (flag, reason) in [(UInt32(SF_RESTRICTED), Reason.restricted),
                               (UInt32(UF_IMMUTABLE), .immutable), (UInt32(SF_IMMUTABLE), .immutable)] {
            XCTAssertNotEqual(flag, 0)
            XCTAssertEqual(physicsVerdict(observed(flags: flag), context()), .denied(reason))
        }
        XCTAssertEqual(physicsVerdict(observed(flags: UInt32(UF_HIDDEN)), context()), .ok)
    }

    func test_denied_beats_warn_and_warn_beats_ok() {
        let container = Data("/Users/tester/Library/Containers/x".utf8)
        let safe = Data("/safe/file".utf8)
        XCTAssertEqual(policyVerdict(container, context()), .warn(.appContainer))
        XCTAssertEqual(combinedVerdict(container, observed(flags: UInt32(SF_RESTRICTED)), context()), .denied(.restricted))
        XCTAssertEqual(combinedVerdict(Data("/usr/x".utf8), observed(flags: UInt32(SF_DATALESS)), context()), .denied(.osIntegrity))
        XCTAssertEqual(combinedVerdict(container, observed(), context()), .warn(.appContainer))
        XCTAssertEqual(combinedVerdict(safe, observed(flags: UInt32(SF_DATALESS)), context()), .warn(.cloudOnly))
        XCTAssertEqual(combinedVerdict(safe, observed(), context()), .ok)
    }

    func test_multiple_denials_follow_table_order() {
        let all = observed(device: 8, flags: UInt32(SF_RESTRICTED | UF_IMMUTABLE | SF_DATALESS), links: 2)
        XCTAssertEqual(combinedVerdict(Data("/usr/.Trashes/x".utf8), all, context()), .denied(.osIntegrity))
        check([("/private/var/db/.Trashes/x", .denied(.systemState)),
               ("/private/var/folders/Backups.backupdb/x", .denied(.appTemporaryFiles)),
               ("/safe/.Spotlight-V100/.Trashes/x", .denied(.alreadyInTrash)),
               ("/safe/.Spotlight-V100/Backups.backupdb/x", .denied(.systemManaged))], context())
        check([("/safe/Backups.backupdb", .denied(.timeMachineBackup))], context(root: "/safe"))
        XCTAssertEqual(combinedVerdict(Data("/Volumes/Work/x".utf8), all, context()), .denied(.volumeRootOrTopLevel))
        XCTAssertEqual(combinedVerdict(Data("/Applications/Tesserae.app".utf8), all, context()), .denied(.otherVolume))
        XCTAssertEqual(combinedVerdict(Data("/Applications/Tesserae.app".utf8), observed(flags: UInt32(SF_RESTRICTED)), context()), .denied(.selfOrAncestorOfApp))
        XCTAssertEqual(physicsVerdict(observed(flags: UInt32(SF_RESTRICTED | SF_IMMUTABLE)), context()), .denied(.restricted))
        XCTAssertEqual(physicsVerdict(observed(flags: UInt32(SF_IMMUTABLE | SF_DATALESS)), context()), .denied(.immutable))
    }

    func test_multiple_warnings_follow_table_order() {
        let warnings = observed(flags: UInt32(SF_DATALESS), links: 2)
        XCTAssertGreaterThan(warnings.linkCount, 1)
        XCTAssertNotEqual(warnings.flags, 0)
        XCTAssertEqual(combinedVerdict(Data("/Users/tester/Library/Containers/x".utf8), warnings, context()), .warn(.appContainer))
        XCTAssertEqual(physicsVerdict(warnings, context()), .warn(.cloudOnly))
    }

    func test_raw_non_utf8_components_are_preserved() {
        let home = Data("/Users/".utf8) + Data([0xff])
        let otherHome = Data("/Users/".utf8) + Data([0xfe])
        XCTAssertNil(String(data: home, encoding: .utf8))
        XCTAssertNotEqual(home, otherHome)
        let ctx = context(home: home)
        XCTAssertEqual(policyVerdict(home + Data("/.Trash/x".utf8), ctx), .denied(.alreadyInTrash))
        XCTAssertEqual(policyVerdict(otherHome + Data("/.Trash/x".utf8), ctx), .denied(.alreadyInTrash))
        XCTAssertEqual(policyVerdict(home + Data("/Library/Containers/x".utf8), ctx), .warn(.appContainer))
        XCTAssertEqual(policyVerdict(Data("/safe/".utf8) + Data([0xff]) + Data("/.Trashes/x".utf8), ctx), .denied(.alreadyInTrash))
        XCTAssertEqual(policyVerdict(Data("/bin".utf8) + Data([0xff]) + Data("/x".utf8), ctx), .ok)
    }
}
