#!/usr/bin/env swift
// siri-say speaks text with any installed macOS voice, including the Siri voices
// that the `say` command hides. Writes a file, or plays it out loud.
//
//   siri-say --list [en]
//   siri-say [--voice <id>] [--rate 0.48] "<text>"               # speaks out loud
//   siri-say [--voice <id>] [--rate 0.48] --out <file> "<text>"  # writes a file
//
// With no text argument the text is read from stdin:  echo "ciao" | siri-say
//
// Output format follows the extension: .m4a/.aac (AAC), .wav/.aiff (PCM),
// .caf (the synthesiser's own format). MP3 is not supported, since macOS has no
// MP3 encoder. `--out -` writes a WAV to stdout.

import AVFoundation
import Foundation

let VERSION = "0.2.0"
let DEFAULT_RATE: Float = 0.48

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func note(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

// ---- colour -------------------------------------------------------------

/// ANSI styling for stdout, only on a terminal and never when NO_COLOR is set
/// (https://no-color.org) or TERM=dumb, so piping `--help` stays plain text.
let useColor: Bool = {
    let env = ProcessInfo.processInfo.environment
    return isatty(fileno(stdout)) != 0 && env["NO_COLOR"] == nil && env["TERM"] != "dumb"
}()

func paint(_ s: String, _ code: String) -> String {
    useColor ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
}
func heading(_ s: String) -> String { paint(s, "1;33") }   // bold yellow
func cmd(_ s: String) -> String { paint(s, "1;32") }       // bold green
func opt(_ s: String) -> String { paint(s, "36") }         // cyan
func param(_ s: String) -> String { paint(s, "35") }       // magenta
func dim(_ s: String) -> String { paint(s, "38;5;245") }   // gray: "faint" (2) is ignored by some renderers

/// One row of the options table: the flag, its value, and a description whose
/// extra lines are indented under the first. Padding is measured on the plain
/// text, since escape codes take up no room on screen.
func option(_ flag: String, _ value: String = "", _ lines: String...) -> String {
    let plain = value.isEmpty ? flag : "\(flag) \(value)"
    let styled = flag.split(separator: " ").map { opt(String($0)) }.joined(separator: " ")
        + (value.isEmpty ? "" : " " + param(value))
    let width = 24
    let pad = String(repeating: " ", count: max(1, width - plain.count))
    let indent = "\n" + String(repeating: " ", count: width + 2)
    return "  " + styled + pad + lines.joined(separator: indent)
}

func usage(_ status: Int32 = 2) -> Never {
    let me = cmd("siri-say")

    print("""
    \(heading("usage:")) \(me) [\(param("options"))] \(param("\"<text>\""))
           \(param("<command>")) | \(me) [\(param("options"))]

    speaks \(param("<text>")) out loud, or writes it to a file with \(opt("--out")).
    with no text argument the text is read from stdin.

    \(heading("options:"))
    \(option("--voice", "<identifier>", "voice to speak with, see --list",
              dim("default: the system voice, currently"),
              dim(systemVoice().identifier)))
    \(option("--rate", "<0.0-1.0>", "speaking speed: 0.0 slowest, 0.5 normal, 1.0 fastest",
              dim("default: \(DEFAULT_RATE)")))
    \(option("--out", "<file>", "write the audio to a file instead of speaking it",
              ".m4a .aac .wav .aiff .caf, or - for a WAV on stdout"))
    \(option("--play", "", "speak out loud, the default when there is no --out"))
    \(option("--list", "[language]", "list the installed voices, including Siri ones",
              "filter by language prefix, e.g. en or it-IT"))
    \(option("--update", "", "replace this script with the latest version"))
    \(option("--version", "", "print the version"))
    \(option("-h, --help", "", "show this help"))

    \(heading("examples:"))
      \(me) \(opt("--list")) en | grep siri                         \(dim("# English Siri voices"))
      \(me) \(opt("--voice")) com.apple.voice.super-compact.en-US.Samantha "Hello"
      \(me) \(opt("--rate")) 0.3 "Slowly, now"                      \(dim("# slower than normal"))
      \(me) \(opt("--out")) notice.wav "The build has finished"     \(dim("# lossless file"))
      \(me) \(opt("--out")) - "Hello" | ffmpeg -i - hello.mp3       \(dim("# MP3, via ffmpeg"))
      pbpaste | \(me)                                     \(dim("# speak the clipboard"))
      git log -1 --pretty=%s | \(me)                      \(dim("# speak the last commit"))
    """)
    exit(status)   // 0 when asked for, 2 when the arguments were wrong
}

/// Replace the installed script with the latest published version.
/// Mirrors install.sh: same URL, same shebang check.
func update() -> Never {
    let env = ProcessInfo.processInfo.environment
    let ref = env["SIRI_SAY_REF"] ?? "main"
    let source = env["SIRI_SAY_URL"]
        ?? "https://raw.githubusercontent.com/marcomontalbano/siri-say/\(ref)/Sources/siri-say/main.swift"

    // Ask the filesystem whether this is a symlink. Comparing the invoked path
    // with its resolved form would also flag a relative path such as ./siri-say.
    let target = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    let attrs = try? FileManager.default.attributesOfItem(atPath: target)
    if attrs?[.type] as? FileAttributeType == .typeSymbolicLink {
        // A symlink into a checkout: overwriting it would rewrite the repository.
        let real = URL(fileURLWithPath: target).resolvingSymlinksInPath().path
        let dir = URL(fileURLWithPath: real).deletingLastPathComponent().path
        fail("""
        \(target) is a symlink to \(real).
        that looks like a git checkout, so update it there instead:
          git -C \(dir) pull
        """)
    }

    guard let url = URL(string: source), let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8) else {
        fail("could not download \(source)")
    }
    guard text.hasPrefix("#!/usr/bin/env swift") else {
        fail("downloaded file is not the siri-say script. check SIRI_SAY_URL/SIRI_SAY_REF")
    }

    // Read the version out of the downloaded source to report the change.
    let newVersion = text.split(separator: "\n")
        .first { $0.hasPrefix("let VERSION") }
        .flatMap { $0.split(separator: "\"").dropFirst().first.map(String.init) } ?? "?"

    if newVersion == VERSION {
        print("siri-say \(VERSION) is already the latest (\(ref))")
        exit(0)
    }

    // Write beside the target, then move into place, so an interrupted update
    // cannot leave a half-written command behind.
    let tmp = target + ".update"
    do {
        try text.write(toFile: tmp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: target),
                                                  withItemAt: URL(fileURLWithPath: tmp))
    } catch {
        try? FileManager.default.removeItem(atPath: tmp)
        fail("could not write \(target): \(error.localizedDescription)\nif it needs privileges, re-run with sudo")
    }

    print("siri-say \(VERSION) -> \(newVersion)")
    exit(0)
}

func qualityName(_ q: AVSpeechSynthesisVoiceQuality) -> String {
    switch q {
    case .default: return "default"
    case .enhanced: return "enhanced"
    case .premium: return "premium"
    @unknown default: return "?"
    }
}

/// `say -v '?'` omits the Siri voices; this list does not.
func listVoices(prefix: String?) {
    let voices = AVSpeechSynthesisVoice.speechVoices()
        .filter { prefix == nil || $0.language.lowercased().hasPrefix(prefix!.lowercased()) }
        .sorted { ($0.language, $0.name) < ($1.language, $1.name) }

    for v in voices {
        let siri = v.identifier.contains("siri") ? "  [siri]" : ""
        print("\(v.language)  \(v.identifier)  \(v.name) (\(qualityName(v.quality)))\(siri)")
    }
    print("\n\(voices.count) voice(s)")
}

/// The voice macOS itself would use: the default for the current language, as
/// set in System Settings > Accessibility > Spoken Content > System Voice.
func systemVoice() -> AVSpeechSynthesisVoice {
    let lang = AVSpeechSynthesisVoice.currentLanguageCode()
    guard let v = AVSpeechSynthesisVoice(language: lang) else {
        fail("no voice available for \(lang). pass one with --voice, see `siri-say --list`")
    }
    return v
}

func resolveVoice(_ id: String) -> AVSpeechSynthesisVoice {
    // Names such as "Voce 2" do not resolve here. An identifier is required.
    guard let v = AVSpeechSynthesisVoice(identifier: id) else {
        fail("voice not found: \(id)\nrun `siri-say --list` to see the identifiers")
    }
    return v
}

func utterance(_ text: String, _ voiceID: String?, _ rate: Float) -> AVSpeechUtterance {
    let u = AVSpeechUtterance(string: text)
    u.voice = voiceID.map(resolveVoice) ?? systemVoice()
    u.rate = rate
    return u
}

// ---- synthesis ----------------------------------------------------------

/// File settings for the output format, chosen from the path's extension.
/// macOS can encode PCM and AAC but *not* MP3: there is no system MP3 encoder.
func settings(forExtension ext: String, matching format: AVAudioFormat) -> [String: Any] {
    let sr = format.sampleRate
    switch ext.lowercased() {
    case "wav", "aif", "aiff":
        return [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sr,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: ext.lowercased() != "wav"]
    case "m4a", "aac":
        return [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sr,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000]
    case "mp3":
        fail("macOS has no MP3 encoder. use .m4a, .wav or .caf, or convert with ffmpeg")
    default:
        // .caf and anything else: the synthesiser's own format, written losslessly.
        return format.settings
    }
}

/// Synthesise `text` into `path`. Returns the duration and the voice used.
func synthesize(text: String, voiceID: String?, rate: Float,
                path: String) -> (seconds: Double, voice: AVSpeechSynthesisVoice) {
    let u = utterance(text, voiceID, rate)
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)

    let synth = AVSpeechSynthesizer()
    var file: AVAudioFile?
    var frames: AVAudioFramePosition = 0
    var finished = false
    var writeError: Error?

    synth.write(u) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        // A zero-length buffer marks the end of the utterance.
        if pcm.frameLength == 0 { finished = true; return }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url,
                                       settings: settings(forExtension: url.pathExtension,
                                                          matching: pcm.format),
                                       commonFormat: pcm.format.commonFormat,
                                       interleaved: pcm.format.isInterleaved)
            }
            try file?.write(from: pcm)
            frames += AVAudioFramePosition(pcm.frameLength)
        } catch {
            writeError = error
            finished = true
        }
    }

    // Buffers arrive on the main run loop, so it has to be pumped: blocking the
    // main thread here (on a semaphore, say) yields zero frames and looks
    // exactly like a voice that refused to synthesise.
    pump(while: { !finished }, timeout: 120)

    if let e = writeError { fail("write failed: \(e.localizedDescription)") }
    guard let f = file, frames > 0 else { fail("no audio produced by \(u.voice?.identifier ?? "?")") }
    let seconds = Double(frames) / f.fileFormat.sampleRate

    // The file is only finalised when it is deallocated, and container formats
    // write their header last (an unreleased .m4a has no moov atom and is
    // unreadable). The synthesiser holds the callback, and with it this
    // reference, so release it explicitly.
    file = nil
    return (seconds, u.voice ?? systemVoice())
}

func pump(while condition: () -> Bool, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while condition() && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

/// Speak out loud, writing nothing.
final class PlaybackWatcher: NSObject, AVSpeechSynthesizerDelegate {
    var done = false
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { done = true }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { done = true }
}

func play(text: String, voiceID: String?, rate: Float) {
    let synth = AVSpeechSynthesizer()
    let watcher = PlaybackWatcher()
    synth.delegate = watcher
    synth.speak(utterance(text, voiceID, rate))
    pump(while: { !watcher.done }, timeout: 300)
}

// ---- arguments ----------------------------------------------------------

var args = Array(CommandLine.arguments.dropFirst())
// No arguments at all is only an error on a terminal: `echo hi | siri-say` is valid.
if args.isEmpty && isatty(fileno(stdin)) != 0 { usage() }

if args.first == "--update" { update() }

if args.first == "--version" {
    print("siri-say \(VERSION)")
    exit(0)
}

if args.first == "--list" {
    listVoices(prefix: args.count > 1 ? args[1] : nil)
    exit(0)
}

var voiceID: String?   // nil = the system voice
var rate = DEFAULT_RATE
var out: String?
var spoken = false   // implied when no --out is given
var text: String?

while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--voice":
        if args.isEmpty { usage() }
        voiceID = args.removeFirst()
    case "--out":
        if args.isEmpty { usage() }
        out = args.removeFirst()
    case "--rate":
        if args.isEmpty { usage() }
        guard let r = Float(args.removeFirst()) else { usage() }
        rate = r
    case "--play":
        spoken = true
    case "-h", "--help": usage(0)
    default:
        // Anything else starting with "-" is a typo or an option this version
        // does not have. Speaking it out loud would be a baffling answer.
        if arg.hasPrefix("-") {
            fail("unknown option: \(arg)\nrun `siri-say --help` for the options")
        }
        if text != nil { usage() }
        text = arg
    }
}

// No text argument: read stdin, but only when it is piped or redirected. On a
// bare terminal that would just hang, so print the usage instead.
if text == nil && isatty(fileno(stdin)) == 0 {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    text = String(data: data, encoding: .utf8)
}

guard var text else { usage() }
text = text.trimmingCharacters(in: .whitespacesAndNewlines)
if text.isEmpty { fail("no text to speak") }
if spoken && out != nil { fail("--play and --out are mutually exclusive") }

if out == nil {
    play(text: text, voiceID: voiceID, rate: rate)
    exit(0)
}

guard let out else { usage() }   // unreachable: no --out means speaking

// stdout: synthesise a WAV to a temp file, then stream it out.
if out == "-" {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("siri-say-\(getpid()).wav").path
    _ = synthesize(text: text, voiceID: voiceID, rate: rate, path: tmp)
    guard let data = FileManager.default.contents(atPath: tmp) else { fail("could not read \(tmp)") }
    FileHandle.standardOutput.write(data)
    try? FileManager.default.removeItem(atPath: tmp)
    exit(0)
}

let result = synthesize(text: text, voiceID: voiceID, rate: rate, path: out)
print(String(format: "%@  %.2fs  (%@)", out, result.seconds, result.voice.identifier))
