import Foundation

// Extracted verbatim from PalmierPro/Generation/GeminiClient.swift. ONLY change: `key()` reads
// $GEMINI_API_KEY instead of calling GeminiKeychain.load().
enum GeminiClient {
    /// Floating "latest flash" alias — survives a specific version being retired (Google accepts it
    /// directly; the `~`-prefixed OpenRouter form does not apply here).
    static let defaultModel = "gemini-flash-latest"
    /// Text-only tasks (transcript correction, the 2× stutter judge, term extraction): a flash-LITE model
    /// is plenty, faster, cheaper, AND less congested — the 503s hit the heavy flash models, not lite.
    static let textModel = "gemini-flash-lite-latest"
    /// Tried in order when a request hits a TRANSIENT error (503/429/500/timeout/empty), so one overloaded
    /// model doesn't fail the call. The requested model is tried first; these fill in after it.
    private static let fallbackChain = ["gemini-flash-lite-latest", "gemini-2.5-flash", "gemini-3.1-flash-lite", "gemini-flash-latest"]
    private static let base = "https://generativelanguage.googleapis.com"

    enum GeminiError: LocalizedError {
        case missingKey, http(Int, String), empty, fileUpload(String)
        var errorDescription: String? {
            switch self {
            case .missingKey: "No Gemini API key. Set GEMINI_API_KEY in the environment."
            case .http(let s, let m): "Gemini API \(s): \(m.prefix(300))"
            case .empty: "Gemini returned no text."
            case .fileUpload(let m): "Gemini File API upload failed: \(m)"
            }
        }
    }

    private static func key() throws -> String {
        guard let k = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !k.isEmpty else { throw GeminiError.missingKey }
        return k
    }

    // MARK: - Text

    static func complete(prompt: String, system: String? = nil,
                         model: String = defaultModel, maxTokens: Int = 2048) async throws -> String {
        try await generate(model: model, parts: [["text": prompt]], system: system, maxTokens: maxTokens).text
    }

    /// Text completion that also returns token usage, optionally forcing structured JSON output via
    /// `responseSchema`. For review/proofread tools that report their own cost.
    static func completeWithUsage(prompt: String, system: String? = nil,
                                  model: String = defaultModel, maxTokens: Int = 4000,
                                  responseSchema: [String: Any]? = nil) async throws -> (text: String, usage: Usage) {
        try await generate(model: model, parts: [["text": prompt]], system: system,
                           maxTokens: maxTokens, responseSchema: responseSchema)
    }

    // MARK: - Vision (inline images)

    /// `images` are raw encoded bytes (PNG/JPEG), sent inline as base64.
    static func describe(images: [Data], prompt: String, system: String? = nil,
                         model: String = defaultModel, maxTokens: Int = 400) async throws -> String {
        guard !images.isEmpty else { throw GeminiError.empty }
        var parts: [[String: Any]] = images.map {
            ["inline_data": ["mime_type": "image/jpeg", "data": $0.base64EncodedString()]]
        }
        parts.append(["text": prompt])
        return try await generate(model: model, parts: parts, system: system, maxTokens: maxTokens).text
    }

    // MARK: - Video (File API upload → generateContent)

    /// Uploads a LOCAL video via the resumable File API, waits for it to become ACTIVE, then runs
    /// generateContent referencing the file. `lowRes` halves the per-second token cost and lets long
    /// videos fit; pass a `responseSchema` to force clean structured JSON output.
    static func describeVideo(fileURL: URL, mimeType: String = "video/mp4", prompt: String, system: String? = nil,
                              model: String = defaultModel, maxTokens: Int = 8000, lowRes: Bool = true,
                              responseSchema: [String: Any]? = nil) async throws -> (text: String, usage: Usage) {
        let uri = try await uploadFile(fileURL: fileURL, mimeType: mimeType)
        let parts: [[String: Any]] = [["file_data": ["mime_type": mimeType, "file_uri": uri]], ["text": prompt]]
        return try await generate(model: model, parts: parts, system: system,
                                  maxTokens: maxTokens, lowRes: lowRes, responseSchema: responseSchema)
    }

    /// Verbatim transcription of a short audio file via the File API — used to RE-transcribe a span the
    /// on-device recognizer mis-heard (dropped/merged syllables). `biasHint` (e.g. the deep content map's
    /// dialogue for this window) nudges proper nouns without being treated as the answer. Returns the spoken
    /// text only. Uses the cheap/uncongested text-tier model by default; the fallback chain still applies.
    static func transcribeAudio(fileURL: URL, mimeType: String = "audio/mp4",
                                biasHint: String? = nil, model: String = textModel) async throws -> String {
        let hint = (biasHint?.isEmpty == false)
            ? " The speech is roughly about: \"\(biasHint!.prefix(200))\" — use it only to disambiguate proper nouns/terms, never to paraphrase."
            : ""
        let system = """
        Transcribe the speech in this audio VERBATIM, in its own language. Output ONLY the spoken words, with \
        natural punctuation, and nothing else — no notes, no translation, no timestamps. Keep every word \
        actually said (including repeats / false starts); do not clean up, summarize, or reorder.\(hint)
        """
        return try await describeVideo(fileURL: fileURL, mimeType: mimeType,
                                       prompt: "Transcribe verbatim.", system: system,
                                       model: model, maxTokens: 1024, lowRes: false).text
    }

    // MARK: - Core generateContent

    /// Token usage + an approximate USD cost. Token counts are exact (from the API's usageMetadata);
    /// the cost is a rough estimate at Flash-tier rates and will drift if Google changes pricing.
    struct Usage: Sendable {
        let promptTokens: Int
        let outputTokens: Int
        /// Approx USD at Gemini Flash rates ($0.30 / 1M input, $2.50 / 1M output).
        var approxUSD: Double {
            Double(promptTokens) / 1_000_000 * 0.30 + Double(outputTokens) / 1_000_000 * 2.50
        }
        var summary: String {
            String(format: "tokens: %d in / %d out (~$%.4f approx @ Flash rates)", promptTokens, outputTokens, approxUSD)
        }
    }

    /// Tries the requested model, then the fallback chain on a transient error, so an overloaded/503 model
    /// doesn't fail the whole call. A non-transient error (bad key, 400) stops immediately — no point retrying.
    private static func generate(model: String, parts: [[String: Any]], system: String?,
                                 maxTokens: Int, lowRes: Bool = false,
                                 responseSchema: [String: Any]? = nil) async throws -> (text: String, usage: Usage) {
        let chain = [model] + fallbackChain.filter { $0 != model }
        var lastError: Error = GeminiError.empty
        for m in chain {
            do {
                return try await attempt(model: m, parts: parts, system: system, maxTokens: maxTokens, lowRes: lowRes, responseSchema: responseSchema)
            } catch {
                lastError = error
                guard isTransient(error) else { throw error }
            }
        }
        throw lastError
    }

    private static func isTransient(_ e: Error) -> Bool {
        if case GeminiError.http(let s, _) = e { return s == 503 || s == 429 || s == 500 || s == 502 }
        if case GeminiError.empty = e { return true }      // truncated/empty → another model may answer
        if e is URLError { return true }                   // timeout / network blip
        return false
    }

    private static func attempt(model: String, parts: [[String: Any]], system: String?,
                                maxTokens: Int, lowRes: Bool = false,
                                responseSchema: [String: Any]? = nil) async throws -> (text: String, usage: Usage) {
        let k = try key()
        var gen: [String: Any] = ["maxOutputTokens": maxTokens]
        if lowRes { gen["mediaResolution"] = "MEDIA_RESOLUTION_LOW" }
        if let responseSchema {
            gen["responseMimeType"] = "application/json"
            gen["responseSchema"] = responseSchema
        }
        var body: [String: Any] = ["contents": [["parts": parts]], "generationConfig": gen]
        if let system, !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }

        var req = URLRequest(url: URL(string: "\(base)/v1beta/models/\(model):generateContent?key=\(k)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try assertOK(data, resp)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = obj["candidates"] as? [[String: Any]], let first = cands.first,
              let content = first["content"] as? [String: Any],
              let ps = content["parts"] as? [[String: Any]],
              let text = ps.compactMap({ $0["text"] as? String }).first, !text.isEmpty else {
            throw GeminiError.empty
        }
        let meta = obj["usageMetadata"] as? [String: Any]
        let usage = Usage(promptTokens: (meta?["promptTokenCount"] as? Int) ?? 0,
                          outputTokens: (meta?["candidatesTokenCount"] as? Int) ?? 0)
        // Feed the session cost dashboard. promptTokensDetails carries the per-modality split — audio/video
        // input is priced differently from text on some tiers, so keep the AV share separate.
        var avTokens = 0
        if let details = meta?["promptTokensDetails"] as? [[String: Any]] {
            for d in details where ["AUDIO", "VIDEO", "IMAGE"].contains((d["modality"] as? String) ?? "") {
                avTokens += (d["tokenCount"] as? Int) ?? 0
            }
        }
        GeminiUsageLedger.record(model: model, promptTokens: usage.promptTokens,
                                 avPromptTokens: avTokens, outputTokens: usage.outputTokens)
        return (text, usage)
    }

    // MARK: - File API resumable upload

    private static func uploadFile(fileURL: URL, mimeType: String) async throws -> String {
        let k = try key()
        let data = try Data(contentsOf: fileURL)
        // 1) start a resumable session
        var start = URLRequest(url: URL(string: "\(base)/upload/v1beta/files?key=\(k)")!)
        start.httpMethod = "POST"
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(data.count), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": fileURL.lastPathComponent]])
        let (sd, sr) = try await URLSession.shared.data(for: start)
        try assertOK(sd, sr)
        guard let uploadURL = (sr as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let u = URL(string: uploadURL) else {
            throw GeminiError.fileUpload("no upload URL")
        }
        // 2) upload bytes + finalize
        var up = URLRequest(url: u)
        up.httpMethod = "POST"
        up.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        up.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        let (ud, ur) = try await URLSession.shared.upload(for: up, from: data)
        try assertOK(ud, ur)
        guard let fobj = try JSONSerialization.jsonObject(with: ud) as? [String: Any],
              let file = fobj["file"] as? [String: Any],
              let name = file["name"] as? String, let uri = file["uri"] as? String else {
            throw GeminiError.fileUpload("bad file response")
        }
        // 3) poll until ACTIVE (video files transcode asynchronously)
        for _ in 0..<150 {
            let g = URLRequest(url: URL(string: "\(base)/v1beta/\(name)?key=\(k)")!)
            let (gd, gr) = try await URLSession.shared.data(for: g)
            try assertOK(gd, gr)
            let state = (try? JSONSerialization.jsonObject(with: gd) as? [String: Any])?["state"] as? String ?? ""
            if state == "ACTIVE" { return uri }
            if state == "FAILED" { throw GeminiError.fileUpload("file processing FAILED") }
            try await Task.sleep(for: .seconds(2))
        }
        throw GeminiError.fileUpload("file never became ACTIVE")
    }

    private static func assertOK(_ data: Data, _ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { throw GeminiError.http(-1, "non-HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw GeminiError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
