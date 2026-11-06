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

import CryptoKit
import Darwin
import Foundation
import XCTest
import TesseraeFFI

@testable import TesseraeKit

private let MiB: UInt64 = 1 << 20
private typealias Spec = TestSnapshot.Spec

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

private func temporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tess-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Changes since the last scan

final class ScanHistoryTests: XCTestCase {
    func test_summary_records_large_known_nodes_by_relative_path() throws {
        var policy = ScanHistoryPolicy()
        policy.minimumDirectory = 100
        policy.minimumFile = 500
        var cloud = Spec.file("cloud", 900)
        cloud.dataless = true
        let t = TestSnapshot(.dir("/scan", [
            .dir("a", [.file("big", 600), .file("small", 50)]),
            .dir("tiny", [.file("x", 10)]),
            .dir("c", [cloud]),
        ]))
        let summary = try XCTUnwrap(ScanHistory.summary(of: t.snapshot, scannedAt: Date(timeIntervalSince1970: 1),
                                                        limited: false, policy: policy))
        XCTAssertEqual(text(summary.rootPath), "/scan")
        let recorded = Dictionary(uniqueKeysWithValues: zip(summary.paths.map(text), summary.allocated))
        XCTAssertEqual(recorded, ["": 1560, "a": 650, "a/big": 600, "c": 900],
                       "small and unknown-size nodes are left out; a dataless file has no recorded size")
    }

    private func changedTree() -> TestSnapshot {
        TestSnapshot(.dir("/scan", [
            .dir("grew", [.file("f", 300 * MiB), .file("tinyfile", 1 * MiB)]),
            .dir("shrank", [.file("g", 10 * MiB)]),
            .dir("same", [.file("h", 5 * MiB)]),
            .dir("new", [.file("n", 2048 * MiB)]),
        ]))
    }

    private var changedPolicy: ScanHistoryPolicy {
        var policy = ScanHistoryPolicy()
        policy.minimumFile = 4 * MiB
        return policy
    }

    private func baseline(scannedAt: Date = Date(timeIntervalSince1970: 1000)) -> ScanSummary {
        let entries: [(String, UInt64)] = [("", 266 * MiB), ("grew", 51 * MiB), ("grew/f", 50 * MiB),
                                           ("shrank", 210 * MiB), ("shrank/g", 210 * MiB),
                                           ("same", 5 * MiB), ("same/h", 5 * MiB)]
        return ScanSummary(rootPath: Data("/scan".utf8), scannedAt: scannedAt, limited: false,
                           paths: entries.map { Data($0.0.utf8) }, allocated: entries.map(\.1))
    }

    func test_change_index_classifies_recorded_nodes_and_inherits_below_them() {
        let t = changedTree()
        let index = ChangeIndex(snapshot: t.snapshot, baseline: baseline(), policy: changedPolicy)
        XCTAssertEqual(index.baselineDate, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(index.change(t.index["grew"]!), .grewMedium)
        XCTAssertEqual(index.change(t.index["f"]!), .grewMedium)
        XCTAssertEqual(index.change(t.index["tinyfile"]!), .grewMedium, "unrecorded nodes take their folder's change")
        XCTAssertEqual(index.change(t.index["shrank"]!), .shrankLarge)
        XCTAssertEqual(index.change(t.index["same"]!), .unchanged)
        XCTAssertEqual(index.change(t.index["new"]!), .appeared)
        XCTAssertEqual(index.change(t.index["n"]!), .appeared)
        XCTAssertEqual(index.change(UInt32.max), .unchanged)
        XCTAssertEqual(index.largestGrowth.map(\.node), [t.index["new"]!, t.index["f"]!],
                       "growth is reported where it is concentrated: the new folder, then the grown file")
        XCTAssertEqual(index.largestGrowth.first?.appeared, true)
        XCTAssertEqual(index.largestGrowth.last?.bytes, 250 * MiB)
    }

    func test_small_relative_changes_are_noise() {
        let policy = ScanHistoryPolicy()
        XCTAssertEqual(ChangeIndex.classify(delta: Int64(MiB) - 1, old: 10 * MiB, policy: policy), .unchanged)
        XCTAssertEqual(ChangeIndex.classify(delta: 5 * Int64(MiB), old: 1000 * MiB, policy: policy), .unchanged,
                       "under 1% of the earlier size")
        XCTAssertEqual(ChangeIndex.classify(delta: 5 * Int64(MiB), old: 100 * MiB, policy: policy), .grewSmall)
        XCTAssertEqual(ChangeIndex.classify(delta: 2048 * Int64(MiB), old: 100 * MiB, policy: policy), .grewLarge)
        XCTAssertEqual(ChangeIndex.classify(delta: -5 * Int64(MiB), old: 100 * MiB, policy: policy), .shrankSmall)
    }

    func test_change_mode_colours_by_class_and_is_neutral_without_a_baseline() {
        let t = changedTree()
        let index = ChangeIndex(snapshot: t.snapshot, baseline: baseline(), policy: changedPolicy)
        let grew = colourIndex(t.index["grew"]!, depth: 1, in: t.snapshot, mode: .change(index))
        XCTAssertEqual(Int(grew), Palette.firstColourIndex + Int(ChangeIndex.Change.grewMedium.rawValue) - 1)
        XCTAssertEqual(colourIndex(t.index["same"]!, depth: 1, in: t.snapshot, mode: .change(index)),
                       UInt16(Palette.neutralIndex))
        XCTAssertEqual(colourIndex(t.index["grew"]!, depth: 1, in: t.snapshot, mode: .change(nil)),
                       UInt16(Palette.neutralIndex))
        for dark in [false, true] {
            XCTAssertEqual(Palette.colours(.change(nil), dark: dark).count,
                           Palette.firstColourIndex + ChangeIndex.Change.allCases.count - 1)
        }
    }

    func test_store_round_trips_and_compare_records_only_complete_scans() throws {
        let directory = try temporaryDirectory("history")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScanHistoryStore(directory: directory)
        let t = changedTree()
        XCTAssertNil(store.load(root: Data("/scan".utf8)))
        try store.save(baseline())
        XCTAssertEqual(store.load(root: Data("/scan".utf8)), baseline())
        XCTAssertNil(store.load(root: Data("/other".utf8)))

        let later = Date(timeIntervalSince1970: 2000)
        XCTAssertNil(ScanHistory.compareAndRecord(snapshot: t.snapshot, store: store, scannedAt: later,
                                                  limited: true, complete: false, policy: changedPolicy),
                     "a limited scan is not compared with a full one")
        XCTAssertEqual(store.load(root: Data("/scan".utf8)), baseline(), "an incomplete scan is not recorded")
        let index = try XCTUnwrap(ScanHistory.compareAndRecord(snapshot: t.snapshot, store: store, scannedAt: later,
                                                               limited: false, complete: true, policy: changedPolicy))
        XCTAssertEqual(index.change(t.index["new"]!), .appeared)
        XCTAssertEqual(store.load(root: Data("/scan".utf8))?.scannedAt, later, "the complete scan is the new baseline")
    }

    @MainActor
    func test_app_compares_a_rescan_with_the_previous_scan() async throws {
        let fm = FileManager.default
        let home = try temporaryDirectory("history-app")
        let history = try temporaryDirectory("history-store")
        defer { try? fm.removeItem(at: home); try? fm.removeItem(at: history) }
        try Data(repeating: 0x41, count: 8192).write(to: home.appendingPathComponent("file"))
        let suite = "Tesserae.HistoryTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppModel(coordinator: ScanCoordinator(progressInterval: 0.001), accessLoader: { .granted },
                           onboardingStore: OnboardingStore(defaults: defaults), homeDirectory: home,
                           historyStore: ScanHistoryStore(directory: history))
        await app.waitForAccess()
        app.scan(home)
        for _ in 0..<2000 {
            if app.scanState == .finished, app.session != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await app.waitForHistory()
        XCTAssertNil(app.changeIndex, "the first scan has nothing to compare with")
        XCTAssertFalse(app.changesLoading)
        let first = try XCTUnwrap(app.session)
        app.rescan()
        for _ in 0..<2000 {
            if app.scanState == .finished, let session = app.session, session !== first { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await app.waitForHistory()
        XCTAssertNotNil(app.changeIndex, "the rescan is compared with the first scan")
        app.setColourMode(.change(nil))
        XCTAssertEqual(app.colourChoice, 3)
        guard case .change(let index) = app.colourMode else { return XCTFail("change mode") }
        XCTAssertTrue(index === app.changeIndex)
        XCTAssertEqual(app.changeLegend(dark: false).count, ChangeIndex.Change.allCases.count)
    }
}

// MARK: - Duplicate files

private struct FakeReader: ContentReader {
    let contents: [String: Data]

    func digest(of path: Data, fileID: UInt64?, expectedSize: UInt64, limit: UInt64?, stop: () -> Bool) -> Data? {
        guard let content = contents[text(path)], UInt64(content.count) == expectedSize else { return nil }
        let bytes = limit.map { content.prefix(Int($0)) } ?? content
        return Data(SHA256.hash(data: bytes))
    }
}

final class DuplicateFinderTests: XCTestCase {
    private func file(_ name: String, _ content: Data, modified: Int64 = 0) -> Spec {
        .file(name, UInt64(content.count), modified: modified)
    }

    func test_groups_identical_files_and_skips_what_must_not_be_read() throws {
        let hello = Data("hello".utf8), world = Data("world".utf8)
        let longA = Data(repeating: 0, count: 70_000)
        var longB = longA
        longB[longB.count - 1] = 1
        var cloud = file("cloud", hello)
        cloud.dataless = true
        var link = file("link", hello)
        link.hardlinkDuplicate = true
        let t = TestSnapshot(.dir("/scan", [
            file("a", hello, modified: 20), file("b", hello, modified: 10), file("c", world), file("d", Data("hello!!".utf8)),
            cloud, link,
            .dir("sub", [file("e", hello, modified: 30), file("long1", longA), file("long2", longA), file("long3", longB)]),
        ]))
        var contents: [String: Data] = [:]
        for name in ["a", "b", "cloud", "link"] { contents["/scan/" + name] = hello }
        contents["/scan/c"] = world
        contents["/scan/d"] = Data("hello!!".utf8)
        contents["/scan/sub/e"] = hello
        contents["/scan/sub/long1"] = longA
        contents["/scan/sub/long2"] = longA
        contents["/scan/sub/long3"] = longB

        var reported: [DuplicateFinder.Progress] = []
        let groups = try XCTUnwrap(DuplicateFinder.find(in: t.snapshot, under: t.snapshot.root, minimumSize: 1,
                                                        reader: FakeReader(contents: contents),
                                                        progress: { reported.append($0) }))
        XCTAssertEqual(groups.map(\.members), [
            [t.index["long1"]!, t.index["long2"]!],
            [t.index["b"]!, t.index["a"]!, t.index["e"]!],
        ], "largest waste first; oldest copy first; prefix-equal files compared whole; cloud and hard links ignored")
        XCTAssertEqual(groups[1].reclaimable, 10)
        XCTAssertEqual(reported.last?.filesRead, reported.last?.filesToRead)

        let sub = try XCTUnwrap(DuplicateFinder.find(in: t.snapshot, under: t.index["sub"]!, minimumSize: 1,
                                                     reader: FakeReader(contents: contents)))
        XCTAssertEqual(sub.map(\.members), [[t.index["long1"]!, t.index["long2"]!]], "only the current view is searched")
        XCTAssertEqual(DuplicateFinder.find(in: t.snapshot, under: t.snapshot.root, minimumSize: 6,
                                            reader: FakeReader(contents: contents))?.count, 1, "minimum size applies")
    }

    func test_a_stopped_search_returns_nothing() {
        let t = TestSnapshot(.dir("/scan", [.file("a", 5), .file("b", 5)]))
        XCTAssertNil(DuplicateFinder.find(in: t.snapshot, under: t.snapshot.root, minimumSize: 1,
                                          reader: FakeReader(contents: [:]), stop: { true }))
    }

    func test_production_reader_hashes_local_files_and_checks_identity() throws {
        let directory = try temporaryDirectory("dupes")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("file")
        let content = Data(repeating: 0x5a, count: 3 << 20)
        try content.write(to: url)
        let path = Data(url.path.utf8)
        var info = Darwin.stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        let id = info.st_ino
        let reader = ProductionContentReader()
        XCTAssertEqual(reader.digest(of: path, fileID: id, expectedSize: UInt64(content.count), limit: nil, stop: { false }),
                       Data(SHA256.hash(data: content)))
        XCTAssertEqual(reader.digest(of: path, fileID: nil, expectedSize: UInt64(content.count), limit: 10, stop: { false }),
                       Data(SHA256.hash(data: content.prefix(10))))
        XCTAssertNil(reader.digest(of: path, fileID: id &+ 1, expectedSize: UInt64(content.count), limit: nil, stop: { false }),
                     "a replaced file is not compared")
        XCTAssertNil(reader.digest(of: path, fileID: id, expectedSize: 1, limit: nil, stop: { false }), "a resized file is not compared")
        XCTAssertNil(reader.digest(of: path, fileID: id, expectedSize: UInt64(content.count), limit: nil, stop: { true }))
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertNil(reader.digest(of: Data(link.path.utf8), fileID: nil, expectedSize: UInt64(content.count), limit: nil,
                                   stop: { false }), "symlinks are not followed")
    }
}

// MARK: - Rebuildable folders

final class RegenerableFinderTests: XCTestCase {
    private func tree() -> TestSnapshot {
        TestSnapshot(.dir("/scan", [
            .dir("proj", [.dir("node_modules", [.file("x", 2 * MiB), .dir("node_modules", [.file("y", 2 * MiB)])]),
                          .file("package.json", 1)]),
            .dir("Library", [
                .dir("Developer", [
                    .dir("Xcode", [.dir("DerivedData", [.file("z", 3 * MiB)]),
                                   .dir("iOS DeviceSupport", [.file("w", 4 * MiB)])]),
                    .dir("CoreSimulator", [.dir("Caches", [.file("v", 2 * MiB)])]),
                ]),
                .dir("Caches", [.dir("Homebrew", [.file("u", 5 * MiB)]), .dir("com.apple.Safari", [.file("t", 9 * MiB)])]),
            ]),
            .dir("rust", [.dir("target", [.file("CACHEDIR.TAG", 1), .file("out", 6 * MiB)])]),
            .dir("swiftpkg", [.file("Package.swift", 1), .dir(".build", [.file("s", 2 * MiB)])]),
            .dir("loose", [.dir(".build", [.file("s2", 2 * MiB)])]),
            .dir(".npm", [.dir("_cacache", [.file("r", 2 * MiB)])]),
            .dir("small", [.dir("node_modules", [.file("q", 10)])]),
        ]))
    }

    private func found(_ items: [RegenerableItem], _ t: TestSnapshot) -> Set<String> {
        Set(items.map { text(t.snapshot.rawPath($0.node)) + " " + $0.kind.rawValue })
    }

    func test_finds_tool_caches_and_build_output_but_not_app_caches() {
        let t = tree()
        let items = RegenerableFinder.find(in: t.snapshot, under: t.snapshot.root, verifyTag: { _ in true })
        XCTAssertEqual(found(items, t), [
            "/scan/proj/node_modules nodeModules",
            "/scan/Library/Developer/Xcode/DerivedData xcodeDerivedData",
            "/scan/Library/Developer/Xcode/iOS DeviceSupport xcodeDeviceSupport",
            "/scan/Library/Developer/CoreSimulator/Caches simulatorCaches",
            "/scan/Library/Caches/Homebrew packageCache",
            "/scan/rust/target cacheDirectoryTag",
            "/scan/swiftpkg/.build swiftBuild",
            "/scan/.npm/_cacache packageCache",
        ], "nested matches, app caches, a .build without Package.swift and small folders are left out")
        XCTAssertEqual(items.first?.allocated, 6 * MiB + 1, "largest first: the tagged folder with its tag file")
        XCTAssertEqual(items.first(where: { $0.kind == .nodeModules })?.allocated, 4 * MiB, "the outer folder covers the nested one")
    }

    func test_a_cache_tag_must_carry_the_signature_and_rules_see_above_the_view() {
        let t = tree()
        let items = RegenerableFinder.find(in: t.snapshot, under: t.snapshot.root, verifyTag: { _ in false })
        XCTAssertFalse(items.contains { $0.kind == .cacheDirectoryTag })
        let xcode = RegenerableFinder.find(in: t.snapshot, under: t.index["Xcode"]!, verifyTag: { _ in true })
        XCTAssertEqual(found(xcode, t), ["/scan/Library/Developer/Xcode/DerivedData xcodeDerivedData",
                                         "/scan/Library/Developer/Xcode/iOS DeviceSupport xcodeDeviceSupport"],
                       "a view inside Developer still knows its ancestors")
    }

    func test_reads_the_cachedir_signature() throws {
        let directory = try temporaryDirectory("cachetag")
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("good"), bad = directory.appendingPathComponent("bad")
        try Data("Signature: 8a477f597d28d172789f06886806bc55\n# a cache\n".utf8).write(to: good)
        try Data("Signature: nope".utf8).write(to: bad)
        XCTAssertTrue(RegenerableFinder.readTag(Data(good.path.utf8)))
        XCTAssertFalse(RegenerableFinder.readTag(Data(bad.path.utf8)))
        XCTAssertFalse(RegenerableFinder.readTag(Data(directory.appendingPathComponent("missing").path.utf8)))
    }
}

// MARK: - Saved and excluded locations

final class LocationsTests: XCTestCase {
    func test_exclusions_apply_inside_the_root_only_once() {
        let root = URL(fileURLWithPath: "/Volumes/Disk/Projects", isDirectory: true)
        let applicable = ExclusionFilter.applicable([
            URL(fileURLWithPath: "/Volumes/Disk/Projects/a/b"), URL(fileURLWithPath: "/Volumes/Disk/Projects/a"),
            URL(fileURLWithPath: "/Volumes/Disk/Projects/a/"), URL(fileURLWithPath: "/Volumes/Disk/Projects"),
            URL(fileURLWithPath: "/Volumes/Disk/ProjectsOld"), URL(fileURLWithPath: "/Users/me/Movies"),
            URL(fileURLWithPath: "/Volumes/Disk/Projects/z/../c"),
        ], root: root, exists: { _ in true })
        XCTAssertEqual(applicable.map(\.path), ["/Volumes/Disk/Projects/a", "/Volumes/Disk/Projects/c"])
    }

    func test_startup_disk_exclusions_are_met_under_the_data_volume() {
        let root = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        let applicable = ExclusionFilter.applicable([
            URL(fileURLWithPath: "/Users/me/Movies"), URL(fileURLWithPath: "/System/Volumes/Data/Users/me/Music"),
            URL(fileURLWithPath: "/Volumes/USB"),
        ], root: root, exists: { $0 != "/System/Volumes/Data/Volumes/USB" })
        XCTAssertEqual(applicable.map(\.path), ["/System/Volumes/Data/Users/me/Movies", "/System/Volumes/Data/Users/me/Music"])
    }

    @MainActor
    func test_settings_persist_without_duplicates() throws {
        let suite = "Tesserae.LocationsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LocationSettings(defaults: defaults)
        settings.addSaved(URL(fileURLWithPath: "/Users/me/Projects"))
        settings.addSaved(URL(fileURLWithPath: "/Users/me/Projects/"))
        settings.addExcluded(URL(fileURLWithPath: "/Users/me/Projects/build"))
        XCTAssertTrue(settings.isSaved(URL(fileURLWithPath: "/Users/me/Projects")))
        let reloaded = LocationSettings(defaults: defaults)
        XCTAssertEqual(reloaded.saved.map(\.path), ["/Users/me/Projects"])
        XCTAssertEqual(reloaded.excluded.map(\.path), ["/Users/me/Projects/build"])
        reloaded.removeSaved(URL(fileURLWithPath: "/Users/me/Projects"))
        reloaded.removeExcluded(URL(fileURLWithPath: "/Users/me/Projects/build"))
        XCTAssertEqual(LocationSettings(defaults: defaults).saved, [])
        XCTAssertEqual(LocationSettings(defaults: defaults).excluded, [])
    }

    @MainActor
    func test_exclusions_reach_the_engine_and_the_report() async throws {
        let fm = FileManager.default
        let home = try temporaryDirectory("exclusions")
        defer { try? fm.removeItem(at: home) }
        let skipped = home.appendingPathComponent("Skip me"), kept = home.appendingPathComponent("Keep")
        for directory in [skipped, kept] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 8192).write(to: directory.appendingPathComponent("file"))
        }
        let suite = "Tesserae.ExclusionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let c = ScanCoordinator(progressInterval: 0.001, factory: { root, options in
            let paths = (0..<Int(options.skip_count)).map { String(cString: options.skip![$0]!) }
            XCTAssertEqual(paths, [skipped.path], "only exclusions under the root are passed")
            return ScanHandle(root: root, options: options)
        })
        let app = AppModel(coordinator: c, accessLoader: { .granted }, onboardingStore: OnboardingStore(defaults: defaults),
                           homeDirectory: home,
                           exclusionProvider: { [skipped, URL(fileURLWithPath: "/elsewhere/entirely")] })
        await app.waitForAccess()
        app.scan(home)
        for _ in 0..<2000 {
            if app.scanState == .finished, app.session != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let session = try XCTUnwrap(app.session)
        XCTAssertEqual(session.snapshot.stats.files, 1)
        let reasons = session.scanReport.skipped.map { $0.reason }
        XCTAssertEqual(reasons, [ScanReport.excludedReason], "an excluded folder is not reported as a limited scan")
    }
}

// MARK: - Safety regressions from the 0.2.3 review

final class CleanupSafetyTests: XCTestCase {
    private func context(_ snapshot: Snapshot) -> GuardContext {
        GuardContext(scanRoot: snapshot.rawPath(snapshot.root), volumeRoot: Data("/".utf8),
            scanRootDevice: snapshot.rootDevice, appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"),
            home: Data("/Users/tester".utf8))
    }

    func test_node_modules_requires_a_parent_manifest() {
        for manifest in [false, true] {
            var children: [Spec] = [.dir("node_modules", [.file("output", 2 * MiB)])]
            if manifest { children.append(.file("package.json", 1)) }
            let tree = TestSnapshot(.dir("/scan", children))
            let found = RegenerableFinder.find(in: tree.snapshot, under: tree.snapshot.root, verifyTag: { _ in false })
            XCTAssertEqual(found.count, manifest ? 1 : 0)
        }
    }

    func test_unknown_descendants_prevent_rebuildable_preselection() throws {
        var skipped = Spec.dir("private-work", [])
        skipped.skippedByRequest = true
        var cloud = Spec.file("cloud", 10)
        cloud.dataless = true
        for unknown in [skipped, .denied("locked"), cloud] {
            let tree = TestSnapshot(.dir("/scan", [.file("package.json", 1),
                .dir("node_modules", [.file("known", 2 * MiB), unknown])]))
            let found = RegenerableFinder.find(in: tree.snapshot, under: tree.snapshot.root, verifyTag: { _ in false })
            let item = try XCTUnwrap(found.first)
            XCTAssertFalse(item.preselected)
            XCTAssertNotNil(item.selectionReason)
        }
    }

    func test_dataless_cache_tag_is_never_verified_and_failed_policy_refuses_read() throws {
        var tag = Spec.file("CACHEDIR.TAG", 43)
        tag.dataless = true
        let tree = TestSnapshot(.dir("/scan", [.dir("cache", [tag, .file("out", 2 * MiB)])]))
        let found = RegenerableFinder.find(in: tree.snapshot, under: tree.snapshot.root, verifyTag: { _ in
            XCTFail("a dataless tag must not be opened")
            return true
        })
        XCTAssertTrue(found.isEmpty)
        let directory = try temporaryDirectory("tag-policy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("CACHEDIR.TAG")
        try RegenerableFinder.cacheTagSignature.write(to: file)
        XCTAssertFalse(RegenerableFinder.readTagOnThread(Data(file.path.utf8), policy: { false }))
        XCTAssertTrue(RegenerableFinder.readTagOnThread(Data(file.path.utf8), policy: {
            XCTAssertFalse(Thread.isMainThread)
            return setiopolicy_np(3, 1, 1) == 0
        }))
    }

    func test_duplicate_no_node_returns_no_candidates() {
        let tree = TestSnapshot(.dir("/scan", [.file("a", 1), .file("b", 1)]))
        XCTAssertTrue(DuplicateFinder.candidates(in: tree.snapshot, under: Tile.noNode,
            overlay: SizeOverlay(), minimumSize: 1).isEmpty)
    }

    @MainActor
    func test_modified_duplicate_or_keeper_is_refused_at_staging() async throws {
        let directory = try temporaryDirectory("duplicate-stamps")
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = Data("same contents".utf8)
        let a = directory.appendingPathComponent("a"), b = directory.appendingPathComponent("b")
        for changed in [a, b] {
            try content.write(to: a); try content.write(to: b)
            let tree = TestSnapshot(.dir(directory.path, [.file("a", UInt64(content.count)), .file("b", UInt64(content.count))]))
            let groups = try XCTUnwrap(DuplicateFinder.find(in: tree.snapshot, under: tree.snapshot.root,
                minimumSize: 1, reader: ProductionContentReader()))
            XCTAssertEqual(groups.count, 1)
            let ctx = context(tree.snapshot)
            let app = AppModel(coordinator: ScanCoordinator(), contextLoader: { _ in ctx })
            app.replaceSnapshot(tree.snapshot)
            let selected = [tree.index["b"]!]
            XCTAssertNil(DuplicateFinder.stagingRefusal(selected: selected, groups: groups, snapshot: tree.snapshot, staged: []))
            let old = try XCTUnwrap(DuplicateStamp.read(Data(changed.path.utf8)))
            let handle = try FileHandle(forWritingTo: changed)
            try handle.write(contentsOf: Data("new! contents".utf8))
            try handle.close()
            // Force a deterministic timestamp change even on a coarse filesystem.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 42)], ofItemAtPath: changed.path)
            let fresh = try XCTUnwrap(DuplicateStamp.read(Data(changed.path.utf8)))
            XCTAssertEqual(old.inode, fresh.inode)
            XCTAssertEqual(old.size, fresh.size)
            XCTAssertNotNil(DuplicateFinder.stagingRefusal(selected: selected, groups: groups, snapshot: tree.snapshot, staged: []))
            app.stage(nodes: selected, duplicateGroups: groups)
            await app.waitForStaging()
            XCTAssertNotNil(app.safetyRefusal)
            XCTAssertEqual(app.session?.reclaim.stagedNodes, [])
        }
    }

    @MainActor
    func test_staged_keeper_or_ancestor_blocks_last_copy() async throws {
        let directory = try temporaryDirectory("duplicate-keeper")
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in [folder.appendingPathComponent("a"), directory.appendingPathComponent("b")] {
            try Data("same".utf8).write(to: url)
        }
        let tree = TestSnapshot(.dir(directory.path, [.dir("folder", [.file("a", 4)]), .file("b", 4)]))
        let groups = try XCTUnwrap(DuplicateFinder.find(in: tree.snapshot, under: tree.snapshot.root,
            minimumSize: 1, reader: ProductionContentReader()))
        XCTAssertEqual(groups.count, 1)
        let selected = [tree.index["b"]!]
        XCTAssertNil(DuplicateFinder.stagingRefusal(selected: selected, groups: groups, snapshot: tree.snapshot, staged: []))
        let ctx = context(tree.snapshot)
        let app = AppModel(coordinator: ScanCoordinator(), contextLoader: { _ in ctx })
        for staged in [tree.index["a"]!, tree.index["folder"]!] {
            app.replaceSnapshot(tree.snapshot)
            let session = try XCTUnwrap(app.session)
            session.reclaim.publish(Reclaim.prepare([staged], in: tree.snapshot, context: ctx,
                stat: ProductionFileStat(), overlay: SizeOverlay(), existing: []), context: ctx)
            XCTAssertEqual(session.reclaim.stagedNodes, [staged])
            XCTAssertNotNil(DuplicateFinder.stagingRefusal(selected: selected, groups: groups,
                snapshot: tree.snapshot, staged: [staged]))
            app.safetyRefusal = nil
            app.stage(nodes: selected, duplicateGroups: groups)
            await app.waitForStaging()
            XCTAssertNotNil(app.safetyRefusal)
            XCTAssertEqual(session.reclaim.stagedNodes, [staged])
        }
    }

    @MainActor
    func test_sheet_staging_then_selection_of_keeper_or_ancestor_is_refused() async throws {
        let directory = try temporaryDirectory("duplicate-normal-staging")
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in [folder.appendingPathComponent("a"), directory.appendingPathComponent("b")] {
            try Data("same".utf8).write(to: url)
        }
        let tree = TestSnapshot(.dir(directory.path, [.dir("folder", [.file("a", 4)]), .file("b", 4)]))
        let groups = try XCTUnwrap(DuplicateFinder.find(in: tree.snapshot, under: tree.snapshot.root,
            minimumSize: 1, reader: ProductionContentReader()))
        XCTAssertEqual(groups.count, 1)
        let ctx = context(tree.snapshot)
        let app = AppModel(coordinator: ScanCoordinator(), contextLoader: { _ in ctx })
        for keeper in [tree.index["a"]!, tree.index["folder"]!] {
            app.replaceSnapshot(tree.snapshot)
            let session = try XCTUnwrap(app.session)
            var didStage = false
            app.stage(nodes: [tree.index["b"]!], duplicateGroups: groups, onStaged: { didStage = true })
            await app.waitForStaging()
            XCTAssertTrue(didStage)
            XCTAssertEqual(session.reclaim.stagedNodes, [tree.index["b"]!])
            session.selection.nodes = [keeper]
            app.safetyRefusal = nil
            didStage = false
            app.stageSelection(onStaged: { didStage = true })
            await app.waitForStaging()
            XCTAssertFalse(didStage, "Refused selection must not open Reclaim Space")
            XCTAssertNotNil(app.safetyRefusal)
            XCTAssertEqual(session.reclaim.stagedNodes, [tree.index["b"]!])
            didStage = false
            app.stage(nodes: [keeper], onStaged: { didStage = true })
            await app.waitForStaging()
            XCTAssertFalse(didStage, "Refusal must not open Reclaim Space")
        }
    }

    @MainActor
    func test_completed_duplicate_search_evicts_stale_groups_only_under_its_root() async throws {
        let directory = try temporaryDirectory("duplicate-refresh")
        defer { try? FileManager.default.removeItem(at: directory) }
        for folder in ["inside", "outside"] {
            let url = directory.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for name in ["a", "b"] {
                try Data(folder.utf8).write(to: url.appendingPathComponent(name))
            }
        }
        let tree = TestSnapshot(.dir(directory.path, [
            .dir("inside", [.file("a", 6), .file("b", 6)]),
            .dir("outside", [.file("a", 7), .file("b", 7)])]))
        let snapshot = tree.snapshot
        let inside = tree.index["inside"]!, outside = tree.index["outside"]!
        let insideMembers = Array(snapshot.children(inside))
        let outsideMembers = Array(snapshot.children(outside))
        let old = try XCTUnwrap(DuplicateFinder.find(in: snapshot, under: snapshot.root,
            minimumSize: 1, reader: ProductionContentReader()))
        XCTAssertEqual(old.count, 2)
        let ctx = context(snapshot)
        let app = AppModel(coordinator: ScanCoordinator(), contextLoader: { _ in ctx })
        app.replaceSnapshot(snapshot)
        let session = try XCTUnwrap(app.session)
        session.rememberDuplicateGroups(old)
        // Change a member without rescanning: the old guard refuses staging.
        let changed = insideMembers[1]
        try Data("edited".utf8).write(to: URL(fileURLWithPath: snapshot.displayPath(changed)))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 42)],
            ofItemAtPath: snapshot.displayPath(changed))
        XCTAssertNotNil(DuplicateFinder.stagingRefusal(selected: [insideMembers[0]],
            groups: session.duplicateGroups, snapshot: snapshot, staged: []))
        let fresh = try XCTUnwrap(DuplicateFinder.find(in: snapshot, under: inside,
            minimumSize: 1, reader: ProductionContentReader()))
        XCTAssertTrue(fresh.isEmpty)
        session.replaceDuplicateGroups(fresh, under: inside)
        XCTAssertEqual(session.duplicateGroups, old.filter { Set($0.members) == Set(outsideMembers) })
        XCTAssertNil(DuplicateFinder.stagingRefusal(selected: [insideMembers[0]],
            groups: session.duplicateGroups, snapshot: snapshot, staged: []))
        var didStage = false
        app.stage(nodes: [insideMembers[0]], onStaged: { didStage = true })
        await app.waitForStaging()
        XCTAssertTrue(didStage, "Following the refusal remedy permits legitimate staging")
        XCTAssertNotNil(DuplicateFinder.stagingRefusal(selected: outsideMembers,
            groups: session.duplicateGroups, snapshot: snapshot, staged: []),
            "A narrower search must preserve keep-one guards outside its root")
        // A subsequent nonempty completion installs fresh groups and stamps.
        try Data("inside".utf8).write(to: URL(fileURLWithPath: snapshot.displayPath(changed)))
        let restored = try XCTUnwrap(DuplicateFinder.find(in: snapshot, under: inside,
            minimumSize: 1, reader: ProductionContentReader()))
        XCTAssertEqual(restored.count, 1)
        session.replaceDuplicateGroups(restored, under: inside)
        XCTAssertEqual(session.duplicateGroups.count, 2)
        XCTAssertTrue(session.duplicateGroups.contains(restored[0]))
    }

    @MainActor
    func test_scan_root_inside_never_scan_is_refused() async throws {
        let suite = "Tesserae.RefusalTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = URL(fileURLWithPath: "/scan/private")
        let coordinator = ScanCoordinator(factory: { _, _ in
            XCTFail("excluded roots must not reach the scanner")
            return nil
        })
        let app = AppModel(coordinator: coordinator, accessLoader: { .granted },
            onboardingStore: OnboardingStore(defaults: defaults), exclusionProvider: { [root] })
        await app.waitForAccess()
        for url in [root, root.appendingPathComponent("child")] {
            app.scan(url)
            XCTAssertNotNil(app.safetyRefusal)
            XCTAssertFalse(app.scanPending)
            XCTAssertNil(app.session)
        }
    }

    func test_data_volume_spelling_is_normalized_for_exclusions_and_history() throws {
        let plain = URL(fileURLWithPath: "/Users/example/private")
        let data = URL(fileURLWithPath: "/System/Volumes/Data/Users/example/private")
        XCTAssertTrue(ExclusionFilter.refuses(data.appendingPathComponent("child"), exclusions: [plain]))
        XCTAssertTrue(ExclusionFilter.refuses(plain, exclusions: [data]))
        XCTAssertEqual(ExclusionFilter.applicable([plain], root: data.deletingLastPathComponent(), exists: { _ in true }).map { $0.standardized.path }, [data.standardized.path])
        XCTAssertFalse(ExclusionFilter.refuses(URL(fileURLWithPath: "/Users/example/private-other"), exclusions: [plain]))
        let directory = try temporaryDirectory("history-alias")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScanHistoryStore(directory: directory)
        XCTAssertEqual(store.fileURL(for: Data(plain.path.utf8)), store.fileURL(for: Data(data.path.utf8)))
        let summary = ScanSummary(rootPath: Data(plain.path.utf8), scannedAt: Date(), limited: false,
            paths: [Data()], allocated: [1])
        try store.save(summary)
        XCTAssertEqual(store.load(root: Data(data.path.utf8)), summary)
    }

    func test_limited_baseline_does_not_overwrite_full_and_scope_mismatch_does_not_compare() throws {
        let directory = try temporaryDirectory("history-scope")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScanHistoryStore(directory: directory)
        let tree = TestSnapshot(.dir("/scan", [.file("large", 2 * MiB)]))
        let first = Date(timeIntervalSince1970: 1), second = Date(timeIntervalSince1970: 2)
        let root = Data("/scan".utf8)
        let scope = ScanHistory.scope(limited: false, exclusions: [])
        _ = ScanHistory.compareAndRecord(snapshot: tree.snapshot, store: store, scannedAt: first,
            limited: false, complete: true, scope: scope)
        _ = ScanHistory.compareAndRecord(snapshot: tree.snapshot, store: store, scannedAt: second,
            limited: true, complete: true, scope: ScanHistory.scope(limited: true, exclusions: []))
        XCTAssertEqual(store.load(root: root)?.scannedAt, first)
        XCTAssertEqual(store.load(root: root, limited: true)?.scannedAt, second)
        XCTAssertNotNil(ScanHistory.compareAndRecord(snapshot: tree.snapshot, store: store, scannedAt: second,
            limited: false, complete: false, scope: scope))
        XCTAssertNil(ScanHistory.compareAndRecord(snapshot: tree.snapshot, store: store, scannedAt: second,
            limited: false, complete: false, scope: ScanHistory.scope(limited: false, exclusions: [Data("/scan/private".utf8)])))
        XCTAssertEqual(ScanHistory.scope(limited: false, exclusions: [Data("/Users/example".utf8)]),
            ScanHistory.scope(limited: false, exclusions: [Data("/System/Volumes/Data/Users/example".utf8)]))
    }

    func test_matching_unreadable_sets_compare_and_changed_set_becomes_baseline() throws {
        let directory = try temporaryDirectory("history-unreadable")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScanHistoryStore(directory: directory)
        var stats = TessScanStats(); stats.unreadable_count = 2
        let first = TestSnapshot(.dir("/scan", [.denied("locked"), .denied("other")]), stats: stats,
            unreadable: [Data("/scan/locked".utf8), Data("/scan/other".utf8)])
        let same = TestSnapshot(.dir("/scan", [.denied("locked"), .denied("other")]), stats: stats,
            unreadable: [Data("/scan/other".utf8), Data("/scan/locked/nested".utf8), Data("/scan/locked".utf8)])
        let different = TestSnapshot(.dir("/scan", [.denied("locked")]), stats: stats,
            unreadable: [Data("/scan/locked".utf8)])
        let granted = TestSnapshot(.dir("/scan", [.dir("locked", [])]))
        XCTAssertTrue(ScanHistory.isComplete(first.snapshot))
        func record(_ tree: TestSnapshot, at time: Double) -> ChangeIndex? {
            ScanHistory.compareAndRecord(snapshot: tree.snapshot, store: store,
                scannedAt: Date(timeIntervalSince1970: time), limited: false, complete: true)
        }
        XCTAssertNil(record(first, at: 1))
        XCTAssertEqual(record(same, at: 2)?.baselineDate, Date(timeIntervalSince1970: 1))
        XCTAssertNil(record(different, at: 3))
        XCTAssertEqual(store.load(root: Data("/scan".utf8))?.scannedAt, Date(timeIntervalSince1970: 3))
        XCTAssertEqual(record(different, at: 4)?.baselineDate, Date(timeIntervalSince1970: 3))
        XCTAssertNil(record(granted, at: 5))
        XCTAssertEqual(record(granted, at: 6)?.baselineDate, Date(timeIntervalSince1970: 5))
    }

    func test_older_save_cannot_replace_newer_baseline() throws {
        let directory = try temporaryDirectory("history-order")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScanHistoryStore(directory: directory)
        let root = Data("/scan".utf8)
        for timestamp in [2, 1] {
            try store.save(ScanSummary(rootPath: root, scannedAt: Date(timeIntervalSince1970: Double(timestamp)),
                limited: false, paths: [Data()], allocated: [UInt64(timestamp)]))
        }
        XCTAssertEqual(store.load(root: root)?.allocated, [2])
    }

    func test_history_retains_fifty_roots_and_clear_empties_files() throws {
        let directory = try temporaryDirectory("history-retention")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScanHistoryStore(directory: directory)
        for index in 0..<50 {
            for limited in [false, true] {
                let summary = ScanSummary(rootPath: Data("/scan/\(index)".utf8), scannedAt: Date(),
                    limited: limited, paths: [Data()], allocated: [1])
                try store.save(summary)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))],
                    ofItemAtPath: store.fileURL(for: summary.rootPath, limited: limited).path)
            }
        }
        // Reading the oldest root makes it recently used, in either mode.
        XCTAssertNotNil(store.load(root: Data("/scan/0".utf8), limited: true))
        try store.save(ScanSummary(rootPath: Data("/scan/50".utf8), scannedAt: Date(),
            limited: false, paths: [Data()], allocated: [1]))
        let retained = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(retained.count, 101)
        XCTAssertEqual(try retained.filter { try !Data(contentsOf: $0).isEmpty }.count, 99)
        for limited in [false, true] {
            XCTAssertEqual(try Data(contentsOf: store.fileURL(for: Data("/scan/1".utf8), limited: limited)), Data())
        }
        XCTAssertNotNil(store.load(root: Data("/scan/0".utf8)))
        XCTAssertNil(store.load(root: Data("/scan/1".utf8)))
        XCTAssertNil(store.load(root: Data("/scan/1".utf8), limited: true))
        try store.clear()
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)), Set(retained))
        for url in retained { XCTAssertEqual(try Data(contentsOf: url), Data()) }
        XCTAssertNil(store.load(root: Data("/scan/0".utf8)))
        // A cleared filename is reused for the next baseline.
        try store.save(ScanSummary(rootPath: Data("/scan/0".utf8), scannedAt: Date(),
            limited: false, paths: [Data()], allocated: [2]))
        XCTAssertNotNil(store.load(root: Data("/scan/0".utf8)))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)), Set(retained))
    }

    func test_legacy_history_is_emptied_on_first_v2_write() throws {
        let directory = try temporaryDirectory("history-legacy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScanHistoryStore(directory: directory)
        let oldRoot = Data("/old-root".utf8)
        let name = store.fileURL(for: oldRoot).lastPathComponent.replacingOccurrences(of: "-full", with: "")
        let legacy = directory.appendingPathComponent(name)
        let old = try PropertyListSerialization.data(fromPropertyList: ["version": 1, "rootPath": oldRoot], format: .binary, options: 0)
        try old.write(to: legacy)
        XCTAssertNil(store.load(root: oldRoot))
        try store.save(ScanSummary(rootPath: Data("/new-root".utf8), scannedAt: Date(),
            limited: false, paths: [Data()], allocated: [1]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try Data(contentsOf: legacy), Data())
        XCTAssertNil(store.load(root: oldRoot))
        let retiredAt = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: retiredAt], ofItemAtPath: legacy.path)
        try store.save(ScanSummary(rootPath: Data("/another-root".utf8), scannedAt: Date(),
            limited: false, paths: [Data()], allocated: [1]))
        let modified = try legacy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(modified, retiredAt, "Already-empty legacy files must not be rewritten")
    }

    func test_history_prune_tolerates_empty_filename_components() throws {
        let directory = try temporaryDirectory("history-stray")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScanHistoryStore(directory: directory)
        for name in ["-.plist", "--.plist", ".plist"] {
            try Data([1]).write(to: directory.appendingPathComponent(name))
        }
        let root = Data("/scan".utf8)
        try store.save(ScanSummary(rootPath: root, scannedAt: Date(), limited: false, paths: [Data()], allocated: [1]))
        XCTAssertNotNil(store.load(root: root))
    }

    func test_duplicate_search_failure_finishes_in_failed_state() async {
        let tree = TestSnapshot(.dir("/scan", [.file("a", MiB), .file("b", MiB)]))
        let result = await DuplicateFinder.run(in: tree.snapshot, under: tree.snapshot.root, overlay: SizeOverlay(), policy: {
            XCTAssertFalse(Thread.isMainThread)
            return false
        })
        XCTAssertNil(result)
        XCTAssertEqual(DuplicateSearchState.finished(result), .failed)
        XCTAssertEqual(DuplicateSearchState.finished([]), .done([]))
    }

    @MainActor
    func test_never_scan_rejects_volume_roots_and_ignores_old_root_exclusions() throws {
        let suite = "Tesserae.VolumeExclusionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LocationSettings(defaults: defaults)
        let roots = ["/", "/System/Volumes/Data", "/Volumes/Backup"].map { URL(fileURLWithPath: $0) }
        for root in roots { settings.addExcluded(root) }
        XCTAssertTrue(settings.excluded.isEmpty)
        for root in roots {
            XCTAssertFalse(ExclusionFilter.refuses(root.appendingPathComponent("child"), exclusions: roots))
            XCTAssertTrue(ExclusionFilter.applicable(roots, root: root, exists: { _ in true }).isEmpty)
        }
        settings.addExcluded(URL(fileURLWithPath: "/scan/private"))
        XCTAssertEqual(settings.excluded.map { $0.standardized.path }, ["/scan/private"])
        XCTAssertTrue(ExclusionFilter.refuses(URL(fileURLWithPath: "/scan/private/child"), exclusions: settings.excluded))
    }

    func test_clear_invalidates_inflight_history_save() throws {
        let directory = try temporaryDirectory("history-clear-race")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScanHistoryStore(directory: directory)
        let generation = store.generation
        try store.clear()
        let summary = ScanSummary(rootPath: Data("/scan".utf8), scannedAt: Date(), limited: false,
            paths: [Data()], allocated: [1])
        try store.save(summary, generation: generation)
        XCTAssertNil(store.load(root: summary.rootPath))
    }

    func test_cancelled_history_worker_does_not_save() async throws {
        let directory = try temporaryDirectory("history-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScanHistoryStore(directory: directory)
        let tree = TestSnapshot(.dir("/scan", [.file("f", MiB)]))
        let snapshot = tree.snapshot
        let work = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return ScanHistory.compareAndRecord(snapshot: snapshot, store: store, scannedAt: Date(),
                limited: false, complete: true)
        }
        let result = await work.value
        XCTAssertNil(result)
        XCTAssertNil(store.load(root: Data("/scan".utf8)))
    }

    func test_history_heap_keeps_only_largest_entries() throws {
        let tree = TestSnapshot(.dir("/scan", (1...100).map { .dir("dir\($0)", [.file("f\($0)", UInt64($0))]) }))
        var policy = ScanHistoryPolicy(); policy.limit = 4; policy.minimumDirectory = 1; policy.minimumFile = 1000
        let summary = try XCTUnwrap(ScanHistory.summary(of: tree.snapshot, scannedAt: Date(), limited: false, policy: policy))
        XCTAssertEqual(summary.paths.count, 4)
        XCTAssertEqual(Set(summary.paths.map(text)), ["", "dir100", "dir99", "dir98"])
    }

    func test_shrink_below_threshold_keeps_its_own_classification() {
        let tree = TestSnapshot(.dir("/scan", [.dir("shrinking", [.file("small", MiB / 2)]),
            .dir("growing", [.file("big", 7 * MiB / 2)])]))
        let baseline = ScanSummary(rootPath: Data("/scan".utf8), scannedAt: Date(), limited: false,
            paths: [Data(), Data("shrinking".utf8), Data("growing".utf8)], allocated: [4 * MiB, 2 * MiB, 2 * MiB])
        let index = ChangeIndex(snapshot: tree.snapshot, baseline: baseline)
        XCTAssertEqual(index.change(tree.snapshot.root), .unchanged)
        XCTAssertEqual(index.change(tree.index["shrinking"]!), .shrankSmall)
    }
}
