import Foundation
import AVFoundation
import Darwin

/// macOS treats every audio input, including loopback devices such as
/// BlackHole, as a microphone. Without Microphone permission CoreAudio still
/// delivers buffers, but every sample is zero. A command-line tool inherits the
/// permission of the app that launched it (Terminal, Ghostty, an editor), and an
/// app with the hardened runtime but without the audio-input entitlement can
/// never show the prompt, so the request is silently denied.
public enum MicrophoneAccessState: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
    case restricted

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        default: self = .notDetermined
        }
    }
}

public enum MicrophoneAccess {
    public static func currentState() -> MicrophoneAccessState {
        MicrophoneAccessState(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// Returns when Microphone access is granted. Asks macOS for access when it
    /// was never decided, so the permission prompt appears before capture
    /// starts. Throws an actionable error instead of letting capture record
    /// silence.
    public static func ensureGranted(deviceName: String,
                                     timeout: TimeInterval = 120) throws {
        var state = currentState()
        if state == .notDetermined {
            let app = hostAppName() ?? "your terminal app"
            print("Asking macOS for Microphone access for \(app) "
                  + "(needed to read '\(deviceName)'). Click Allow if macOS asks.")
            let result = RequestResult()
            let done = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                result.set(granted)
                done.signal()
            }
            if done.wait(timeout: .now() + timeout) == .timedOut {
                throw BasaltError(
                    "macOS did not answer the Microphone request in \(Int(timeout)) s. "
                        + denialHint(state: .notDetermined, hostApp: hostAppName()))
            }
            state = result.granted ? .authorized : currentState()
        }
        guard state == .authorized else {
            throw BasaltError(
                "No Microphone access, so '\(deviceName)' would record only silence. "
                    + denialHint(state: state, hostApp: hostAppName()))
        }
    }

    /// The exact action the user must take for a given permission state.
    public static func denialHint(state: MicrophoneAccessState, hostApp: String?) -> String {
        let app = hostApp ?? "your terminal app"
        switch state {
        case .authorized:
            return "Microphone access is granted for \(app)."
        case .denied:
            return "Open System Settings > Privacy & Security > Microphone, turn on "
                + "\(app), quit and reopen \(app), then run the command again."
        case .restricted:
            return "A device-management profile blocks Microphone access for \(app). "
                + "Run the command from Terminal.app on a Mac without that restriction."
        case .notDetermined:
            return "macOS did not show a Microphone prompt for \(app) and did not grant "
                + "access (an app without the audio-input entitlement cannot ask). "
                + "Run the command in Terminal.app and click Allow when macOS asks. "
                + "If you clicked Don't Allow before, open System Settings > Privacy & "
                + "Security > Microphone and turn on Terminal."
        }
    }

    /// Name of the outermost app bundle that launched this process. macOS
    /// asks that app for Microphone permission on behalf of this tool.
    public static func hostAppName() -> String? {
        var paths: [String] = []
        var pid = getpid()
        for _ in 0..<32 {
            guard pid > 1 else { break }
            if let path = executablePath(pid) { paths.append(path) }
            guard let parent = parentPID(pid), parent != pid else { break }
            pid = parent
        }
        return hostAppName(fromAncestorPaths: paths)
    }

    /// `paths` runs from this process to its oldest ancestor. The last
    /// executable inside a `.app` bundle names the responsible app.
    static func hostAppName(fromAncestorPaths paths: [String]) -> String? {
        for path in paths.reversed() {
            if let component = path.split(separator: "/").first(where: {
                $0.hasSuffix(".app")
            }) {
                return String(component.dropLast(4))
            }
        }
        return nil
    }

    private final class RequestResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var granted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func set(_ granted: Bool) {
            lock.lock()
            value = granted
            lock.unlock()
        }
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
