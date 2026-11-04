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
