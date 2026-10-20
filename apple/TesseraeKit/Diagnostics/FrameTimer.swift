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

import AppKit
import Foundation
import Metal
import QuartzCore
import os.signpost

/// A bounded opt-in capture. Metal completion and presentation handlers can
/// call back on any thread; all mutable state is protected by the lock.
public final class FrameTimer: @unchecked Sendable {
    public static let shared = FrameTimer()
    public struct Sample: Codable, Sendable {
        public let kind: String
        public let label: String
        public let seconds: Double
        public let tiles: Int
    }
    public struct Token: Sendable {
        fileprivate let generation: UInt64
        fileprivate let started: Double
        fileprivate let kind: String
        fileprivate let label: String
        fileprivate let tiles: Int
        fileprivate let signpost: OSSignpostID
    }
    private let lock = NSLock()
    private let log = OSLog(subsystem: "io.github.sdelavega.Tesserae", category: "FrameTiming")
    private let enabled: Bool
    private var generation: UInt64 = 0
    private var recording = false
    private var label = ""
    private var values: [Sample] = []
    private var lastPresentation: Double?
    private var lastFrame: Double?
    private static let limit = 100_000

    /// `enabled` nil: on only when `TESSERAE_FRAME_TIMING=1`, in every build
    /// configuration, so a Release build can be measured and a Debug session
    /// does not record or emit signposts unless asked to.
    public init(enabled: Bool? = nil) {
        self.enabled = enabled ?? FrameGateConfiguration.timingRequested(in: ProcessInfo.processInfo.environment)
        recording = self.enabled
    }

    /// Whether this timer records at all.
    public var isEnabled: Bool { enabled }

    public func startCapture() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        values.removeAll(keepingCapacity: true)
        label = ""
        lastPresentation = nil
        lastFrame = nil
        recording = enabled
    }

    public func stopCapture() {
        lock.lock(); defer { lock.unlock() }
        recording = false
    }

    public func setLabel(_ label: String) {
        lock.lock(); defer { lock.unlock() }
        self.label = label
        lastPresentation = nil
        lastFrame = nil
    }

    public var samples: [Sample] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    public func begin(_ kind: String, tiles: Int = 0, at now: Double = CACurrentMediaTime()) -> Token? {
        lock.lock(); defer { lock.unlock() }
        guard recording else { return nil }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Treemap interval", signpostID: id, "%{public}@", kind as NSString)
        return Token(generation: generation, started: now, kind: kind, label: label, tiles: tiles, signpost: id)
    }

    public func end(_ token: Token?, at now: Double = CACurrentMediaTime()) {
        guard let token else { return }
        os_signpost(.end, log: log, name: "Treemap interval", signpostID: token.signpost)
        record(token, kind: token.kind, seconds: now - token.started)
    }

    private func record(_ token: Token, kind: String, seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        guard recording, token.generation == generation, seconds.isFinite, seconds >= 0,
            values.count < Self.limit else { return }
        values.append(Sample(kind: kind, label: token.label, seconds: seconds, tiles: token.tiles))
    }

    /// Time between draw callbacks during the same labelled transition.
    public func frameStarted(at now: Double = CACurrentMediaTime()) {
        lock.lock(); defer { lock.unlock() }
        guard recording else { return }
        if let previous = lastFrame, now >= previous, values.count < Self.limit {
            values.append(Sample(kind: "draw-cadence", label: label, seconds: now - previous, tiles: 0))
        }
        lastFrame = now
    }

    /// CPU encoding is timed by the caller, GPU execution by the command
    /// buffer, and presentation latency/cadence by the drawable. These are
    /// distinct measurements; a vsync wait is not GPU execution time.
    public func observe(_ buffer: MTLCommandBuffer, drawable: CAMetalDrawable, tiles: Int) {
        guard let token = begin("present", tiles: tiles) else { return }
        buffer.addCompletedHandler { [self] completed in
            guard completed.status == .completed, completed.gpuStartTime > 0,
                completed.gpuEndTime > completed.gpuStartTime else {
                record(token, kind: "gpu-unavailable", seconds: 0)
                return
            }
            record(token, kind: "gpu", seconds: completed.gpuEndTime - completed.gpuStartTime)
        }
        drawable.addPresentedHandler { [self] presented in
            let time = presented.presentedTime
            guard time > 0 else { return }
            end(token, at: time)
            lock.lock(); defer { lock.unlock() }
            guard recording, token.generation == generation, token.label == label else { return }
            if let previous = lastPresentation, time >= previous, values.count < Self.limit {
                values.append(Sample(kind: "present-cadence", label: token.label, seconds: time - previous, tiles: tiles))
            }
            lastPresentation = time
        }
    }

    public static func percentile99(_ seconds: [Double]) -> Double {
        guard !seconds.isEmpty else { return 0 }
        let sorted = seconds.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * 0.99)) - 1)]
    }
}

/// How the phase gate is set up, from the environment (read once at launch):
///
/// * `TESSERAE_FRAME_TIMING=1` turns `FrameTimer.shared` on, in any build
///   configuration; the gate needs it.
/// * `TESSERAE_FRAME_GATE_AUTORUN=<absolute path>` makes the app scan that
///   root on launch, fill the main screen's visible frame, run the gate, write
///   the capture and quit.
/// * `TESSERAE_FRAME_GATE_OUT=<absolute path>` is where the capture goes;
///   by default `tesserae-frame-gate.json` in `NSTemporaryDirectory()`.
public struct FrameGateConfiguration: Equatable, Sendable {
    public struct Invalid: Error, CustomStringConvertible {
        public let description: String
    }

    public let timingEnabled: Bool
    public let autorunRoot: URL?
    public let output: URL

    public static func timingRequested(in environment: [String: String]) -> Bool {
        environment["TESSERAE_FRAME_TIMING"] == "1"
    }

    public init(environment: [String: String], temporaryDirectory: URL) throws {
        timingEnabled = Self.timingRequested(in: environment)
        func absolute(_ key: String) throws -> URL? {
            guard let value = environment[key], !value.isEmpty else { return nil }
            guard value.hasPrefix("/") else { throw Invalid(description: "\(key) must be an absolute path, not \(value)") }
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        autorunRoot = try absolute("TESSERAE_FRAME_GATE_AUTORUN")
        if autorunRoot != nil && !timingEnabled {
            throw Invalid(description: "TESSERAE_FRAME_GATE_AUTORUN needs TESSERAE_FRAME_TIMING=1")
        }
        output = try absolute("TESSERAE_FRAME_GATE_OUT")
            ?? temporaryDirectory.appendingPathComponent("tesserae-frame-gate.json")
    }

    /// This process's configuration.
    public static let current: Result<FrameGateConfiguration, Invalid> = Result {
        try FrameGateConfiguration(
            environment: ProcessInfo.processInfo.environment,
            temporaryDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
    }.mapError { $0 as? Invalid ?? Invalid(description: "\($0)") }
}

/// Runs the actual window's navigation and MTKView, with normal labels/table
/// updates, rather than substituting an offscreen render benchmark: the five
/// largest sized, readable directories directly under the root, each entered
/// and left three times.
@MainActor
public final class PhaseGateRunner: ObservableObject {
    public enum Outcome: Equatable, Sendable {
        case saved(URL)
        case failed(String)
    }

    @Published public private(set) var status: String?
    @Published public private(set) var isRunning = false
    private var task: Task<Void, Never>?
    private let timer: FrameTimer
    private let pause: Duration

    /// `pause` scales the settling waits and the 3 s zoom deadline (tests shorten them).
    public init(timer: FrameTimer = .shared, pause: Duration = .milliseconds(100)) {
        self.timer = timer
        self.pause = pause
    }

    deinit { task?.cancel() }

    /// Runs the gate on `session` if its snapshot is a scan of `requiredRoot`
    /// with at least `minimumNodes` nodes, writes the capture to `output`
    /// and reports the outcome.
    public func run(
        session: AppSession, requiredRoot: String, minimumNodes: Int, output: URL,
        completion: @escaping @MainActor (Outcome) -> Void = { _ in }
    ) {
        func fail(_ reason: String) {
            status = reason
            completion(.failed(reason))
        }
        guard !isRunning else { return fail("The frame gate is already running.") }
        let snapshot = session.snapshot
        guard snapshot.root != Tile.noNode else { return fail("The snapshot is empty.") }
        let required = URL(fileURLWithPath: requiredRoot).standardizedFileURL.path
        let scanned = URL(fileURLWithPath: snapshot.path(snapshot.root)).standardizedFileURL.path
        guard scanned == required, snapshot.nodes.count >= minimumNodes else {
            return fail(
                "Load a scan of \(required) with at least \(minimumNodes.formatted()) nodes before running the phase gate"
                    + " (this one is \(scanned), \(snapshot.nodes.count.formatted()) nodes).")
        }
        let root = snapshot.root
        let targets = Array(snapshot.children(root).filter {
            snapshot.isDirectory($0) && !snapshot.isPermissionDenied($0) && snapshot.allocated($0) > 0
        }.prefix(5))
        guard targets.count == 5 else { return fail("The snapshot has fewer than five sized readable root directories.") }
        status = "Preparing frame gate…"
        isRunning = true
        let timer = self.timer, pause = self.pause
        task = Task { [weak self, session] in
            defer { self?.isRunning = false }
            session.go(to: root)
            try? await Task.sleep(for: pause * 3)
            timer.startCapture()
            var settleTimeouts = 0
            for repetition in 1...3 {
                for node in targets {
                    guard !Task.isCancelled else {
                        timer.stopCapture()
                        return completion(.failed("The frame gate was cancelled."))
                    }
                    let name = snapshot.name(node)
                    self?.status = "Frame gate: run \(repetition)/3 · \(name) · in"
                    timer.setLabel("\(repetition) in \(name)")
                    session.navigator.descend(into: node)
                    if await !Self.settle(session, pause: pause) { settleTimeouts += 1 }
                    self?.status = "Frame gate: run \(repetition)/3 · \(name) · out"
                    timer.setLabel("\(repetition) out \(name)")
                    session.go(to: root)
                    if await !Self.settle(session, pause: pause) { settleTimeouts += 1 }
                }
            }
            timer.stopCapture()
            let screen = NSApp?.keyWindow?.screen ?? NSScreen.main
            let screenID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let reportedHz = screenID.flatMap { CGDisplayCopyDisplayMode($0)?.refreshRate } ?? 0
            let hz = reportedHz > 0 ? reportedHz : Double(screen?.maximumFramesPerSecond ?? 0)
            struct Capture: Encodable {
                let root: String
                let build: String
                let nodes: Int
                let incomplete: UInt32
                let unreadable: UInt64
                let refreshHz: Double
                let refreshSource: String
                let viewport: String
                let directories: [String]
                /// Transitions whose zoom had not ended after 3 s (the view
                /// was not drawing): a capture with any is not a valid gate run.
                let settleTimeouts: Int
                let samples: [FrameTimer.Sample]
            }
            #if DEBUG
            let build = "Debug"
            #else
            let build = "Release"
            #endif
            let capture = Capture(
                root: scanned, build: build,
                nodes: snapshot.nodes.count, incomplete: snapshot.stats.incomplete,
                unreadable: snapshot.stats.unreadable_count, refreshHz: hz,
                refreshSource: reportedHz > 0 ? "CGDisplayMode.refreshRate" : "NSScreen.maximumFramesPerSecond (fallback)",
                viewport: session.tiles.first.map { "\($0.rect.width) x \($0.rect.height) points" } ?? "none",
                directories: targets.map { snapshot.name($0) }, settleTimeouts: settleTimeouts,
                samples: timer.samples)
            // A local developer measurement: nothing is uploaded. The capture
            // names only the root's immediate child directories.
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(capture).write(to: output, options: .atomic)
                guard settleTimeouts == 0 else {
                    let reason = "Frame gate capture saved to \(output.path), but \(settleTimeouts) of 30 transitions"
                        + " did not finish animating within 3 s (was the window visible?); it is not a valid run."
                    self?.status = reason
                    return completion(.failed(reason))
                }
                self?.status = "Frame gate capture saved: \(output.path)"
                completion(.saved(output))
            } catch {
                let reason = "Frame gate capture failed: \(error.localizedDescription)"
                self?.status = reason
                completion(.failed(reason))
            }
        }
    }

    /// Waits for the transition's zoom to end; false if it was still running
    /// after 30 pauses (3 s by default).
    private static func settle(_ session: AppSession, pause: Duration) async -> Bool {
        // Allow SwiftUI to install the target tiles and start the display loop.
        try? await Task.sleep(for: pause)
        let deadline = ContinuousClock.now + pause * 30
        while session.zoomRunning && ContinuousClock.now < deadline && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let settled = !session.zoomRunning
        // Let the final GPU/presentation callbacks arrive before relabelling.
        try? await Task.sleep(for: pause)
        return settled
    }
}

/// `TESSERAE_FRAME_GATE_AUTORUN`: scan the root, fill the main screen's
/// visible frame, run the gate, write the capture, quit. Progress and the
/// outcome go to standard error; the exit status is 0 only if a capture was
/// saved.
@MainActor
public enum FrameGateAutorun {
    public static func run(root: URL, output: URL, model: AppModel, runner: PhaseGateRunner) async {
        func log(_ line: String) { FileHandle.standardError.write(Data(("tesserae frame gate: " + line + "\n").utf8)) }
        func quit(_ code: Int32) {
            if code == 0 { NSApp.terminate(nil) } else { exit(code) }
        }
        log("scanning \(root.path)")
        model.scan(root)
        // Fill the screen as soon as the window exists; the scan runs meanwhile.
        while !Task.isCancelled {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                let screen = window.screen ?? NSScreen.main {
                // Launched from a shell the app may not be frontmost, and an
                // occluded window's MTKView never draws.
                NSApp.activate(ignoringOtherApps: true)
                window.setFrame(screen.visibleFrame, display: true)
                window.makeKeyAndOrderFront(nil)
                log("window \(Int(screen.visibleFrame.width)) x \(Int(screen.visibleFrame.height)) points")
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        var lastReport = ContinuousClock.now
        scanning: while !Task.isCancelled {
            switch model.scanState {
            case .failed(let errno):
                log("scan failed: \(String(cString: strerror(errno)))")
                return quit(1)
            case .finished:
                break scanning
            case .scanning(let progress) where ContinuousClock.now - lastReport > .seconds(10):
                lastReport = .now
                log("scanned \(progress.dirs) folders, \(progress.files) files")
            case .idle, .scanning:
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let session = model.session else {
            log("the scan produced no snapshot")
            return quit(1)
        }
        // Let the window settle at its new size and lay out.
        let deadline = ContinuousClock.now + .seconds(10)
        while session.tiles.isEmpty && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(500))
        log("running on \(session.snapshot.nodes.count) nodes")
        let outcome = await withCheckedContinuation { (done: CheckedContinuation<PhaseGateRunner.Outcome, Never>) in
            runner.run(session: session, requiredRoot: root.path, minimumNodes: 0, output: output) { done.resume(returning: $0) }
        }
        switch outcome {
        case .saved(let url):
            log("capture saved to \(url.path)")
            quit(0)
        case .failed(let reason):
            log(reason)
            quit(1)
        }
    }
}
