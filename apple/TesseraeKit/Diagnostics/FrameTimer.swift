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

    public init(enabled: Bool? = nil) {
        #if DEBUG
        self.enabled = enabled ?? true
        #else
        self.enabled = enabled ?? (ProcessInfo.processInfo.environment["TESSERAE_FRAME_TIMING"] == "1")
        #endif
        recording = self.enabled
    }

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

/// Runs the actual window's navigation and MTKView, with normal labels/table
/// updates, rather than substituting an offscreen render benchmark.
@MainActor
public final class PhaseGateRunner: ObservableObject {
    @Published public private(set) var status: String?
    @Published public private(set) var isRunning = false
    private var task: Task<Void, Never>?

    public init() {}
    deinit { task?.cancel() }

    public func run(session: AppSession) {
        guard !isRunning else { return }
        guard session.snapshot.nodes.count >= 1_000_000,
            session.snapshot.path(session.snapshot.root) == "/System/Volumes/Data" else {
            status = "Load the Data-volume snapshot (at least one million nodes) before running the phase gate."
            return
        }
        let root = session.snapshot.root
        let targets = session.snapshot.children(root).filter {
            session.snapshot.isDirectory($0) && !session.snapshot.isPermissionDenied($0)
                && session.snapshot.allocated($0) > 0
        }.prefix(5)
        guard targets.count == 5 else { status = "The snapshot has fewer than five sized readable root directories."; return }
        status = "Preparing frame gate…"
        isRunning = true
        task = Task { [weak self, session] in
            defer { self?.isRunning = false }
            let timer = FrameTimer.shared
            session.go(to: root)
            try? await Task.sleep(for: .milliseconds(300))
            timer.startCapture()
            for repetition in 1...3 {
                for node in targets {
                    guard !Task.isCancelled else { timer.stopCapture(); return }
                    let name = session.snapshot.name(node)
                    self?.status = "Frame gate: run \(repetition)/3 · \(name) · in"
                    timer.setLabel("\(repetition) in \(name)")
                    session.navigator.descend(into: node)
                    await Self.settle(session)
                    self?.status = "Frame gate: run \(repetition)/3 · \(name) · out"
                    timer.setLabel("\(repetition) out \(name)")
                    session.go(to: root)
                    await Self.settle(session)
                }
            }
            timer.stopCapture()
            let screen = NSApp.keyWindow?.screen ?? NSScreen.main
            let screenID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let reportedHz = screenID.flatMap { CGDisplayCopyDisplayMode($0)?.refreshRate } ?? 0
            let hz = reportedHz > 0 ? reportedHz : Double(screen?.maximumFramesPerSecond ?? 0)
            struct Capture: Encodable {
                let nodes: Int
                let incomplete: UInt32
                let unreadable: UInt64
                let refreshHz: Double
                let refreshSource: String
                let viewport: String
                let directories: [String]
                let samples: [FrameTimer.Sample]
            }
            let capture = Capture(
                nodes: session.snapshot.nodes.count, incomplete: session.snapshot.stats.incomplete,
                unreadable: session.snapshot.stats.unreadable_count, refreshHz: hz,
                refreshSource: reportedHz > 0 ? "CGDisplayMode.refreshRate" : "NSScreen.maximumFramesPerSecond (fallback)",
                viewport: session.tiles.first.map { "\($0.rect.width) x \($0.rect.height) points" } ?? "none",
                directories: targets.map { session.snapshot.name($0) }, samples: timer.samples)
            // This diagnostics runner is a developer tool. The default file is
            // local to the checkout; no directory listing or trace is uploaded.
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let output = repo.appendingPathComponent("apple/build/phase14-frames.json")
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(capture).write(to: output, options: .atomic)
                self?.status = "Frame gate capture saved: \(output.path)"
            } catch { self?.status = "Frame gate capture failed: \(error.localizedDescription)" }
        }
    }

    private static func settle(_ session: AppSession) async {
        // Allow SwiftUI to install the target tiles and start the display loop.
        try? await Task.sleep(for: .milliseconds(100))
        let deadline = ContinuousClock.now + .seconds(3)
        while session.zoomRunning && ContinuousClock.now < deadline && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Let the final GPU/presentation callbacks arrive before relabelling.
        try? await Task.sleep(for: .milliseconds(100))
    }
}
