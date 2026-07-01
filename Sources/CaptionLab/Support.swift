import Foundation

/// Minimal stand-in for the main app's structured logger. The extracted Transcription front-end calls
/// `Log.transcription.{notice,warning,error}` with `telemetry:`/`data:` labels; here they just go to
/// stderr so the extracted code stays byte-for-byte faithful.
enum Log {
    static let transcription = Logger()
    static let editor = Logger()

    struct Logger {
        func notice(_ message: String, telemetry: String? = nil, data: [String: Any] = [:]) {
            emit("NOTICE", message)
        }
        func warning(_ message: String, telemetry: String? = nil, data: [String: Any] = [:]) {
            emit("WARN", message)
        }
        func error(_ message: String, telemetry: String? = nil, data: [String: Any] = [:]) {
            emit("ERROR", message)
        }
        private func emit(_ level: String, _ message: String) {
            FileHandle.standardError.write(Data("[\(level)] \(message)\n".utf8))
        }
    }
}
