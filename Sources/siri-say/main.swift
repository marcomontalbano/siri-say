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

let VERSION = "0.3.0"
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
    \(option("--lang", "<code>", "speak with the best installed voice for a language,",
              "Siri first, e.g. it or en-GB"))
    \(option("--rate", "<0.0-1.0>", "speaking speed: 0.0 slowest, 0.5 normal, 1.0 fastest",
              dim("default: \(DEFAULT_RATE)")))
    \(option("--out", "<file>", "write the audio to a file instead of speaking it",
              ".m4a .aac .wav .aiff .caf, or - for a WAV on stdout"))
    \(option("--play", "", "speak out loud, the default when there is no --out"))
    \(option("--list", "[language]", "list the installed Siri, personal and enhanced voices",
              "filter by language prefix, e.g. en or it-IT"))
    \(option("--list --all", "", "also list the built-in, lower-quality voices"))
    \(option("--manage-voices", "", "open System Settings to download more voices"))
    \(option("--allow-personal-voice", "", "allow access to your Personal Voice, to list and use it"))
    \(option("--update", "", "replace this script with the latest version"))
    \(option("--version", "", "print the version"))
    \(option("-h, --help", "", "show this help"))

    \(heading("examples:"))
      \(me) \(opt("--list")) en | grep siri                         \(dim("# English Siri voices"))
      \(me) \(opt("--voice")) com.apple.voice.super-compact.en-US.Samantha "Hello"
      \(me) \(opt("--lang")) it "Ciao"                              \(dim("# best Italian voice"))
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
    // Homebrew owns its install: overwriting it would desync it from `brew list`.
    let resolved = URL(fileURLWithPath: target).resolvingSymlinksInPath().path
    if resolved.contains("/Cellar/siri-say/") {
        fail("siri-say was installed with Homebrew, update it with:\n  brew upgrade siri-say")
    }

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

/// A kind of voice in `--list`, in the order the groups are printed.
enum VoiceGroup: CaseIterable {
    case siri, personal, enhanced, other, classic, legacy, novelty, eloquence

    var title: String {
        switch self {
        case .siri: return "Siri"
        case .personal: return "Personal"
        case .enhanced: return "Enhanced"
        case .classic: return "Classic"
        case .legacy: return "Legacy"
        case .novelty: return "Novelty"
        case .eloquence: return "Eloquence"
        case .other: return "Other"
        }
    }

    var summary: String {
        switch self {
        case .siri: return "natural voices, the ones Siri speaks with"
        case .personal: return "your own voice, created in Personal Voice"
        case .enhanced: return "higher-quality voices downloaded from System Settings"
        case .classic: return "compact system voices, built into macOS"
        case .legacy: return "older macOS voices"
        case .novelty: return "voice effects that sing, bubble or whisper"
        case .eloquence: return "robotic voices, the same eight in every language"
        case .other: return "voices that fit none of the groups above"
        }
    }

    /// Hidden from `--list` unless `--all` is given: built-in, lower-quality voices.
    /// Other stays visible so a kind of voice macOS adds later is not missed.
    var isHiddenByDefault: Bool {
        switch self {
        case .siri, .personal, .enhanced, .other: return false
        case .classic, .legacy, .novelty, .eloquence: return true
        }
    }

    init(_ voice: AVSpeechSynthesisVoice) {
        let id = voice.identifier
        if id.hasPrefix("com.apple.siri.") { self = .siri }
        else if isPersonal(voice) { self = .personal }
        else if voice.quality == .enhanced || voice.quality == .premium { self = .enhanced }
        else if id.hasPrefix("com.apple.voice.") { self = .classic }
        else if id.hasPrefix("com.apple.eloquence.") { self = .eloquence }
        else if isNovelty(voice) { self = .novelty }
        else if id.hasPrefix("com.apple.speech.") { self = .legacy }
        else { self = .other }
    }
}

/// Whether macOS flags the voice as a novelty one; the flag exists from macOS 14.
func isNovelty(_ voice: AVSpeechSynthesisVoice) -> Bool {
    guard #available(macOS 14, *) else { return false }
    return voice.voiceTraits.contains(.isNoveltyVoice)
}

/// Whether this is the user's own Personal Voice; the flag exists from macOS 14.
func isPersonal(_ voice: AVSpeechSynthesisVoice) -> Bool {
    guard #available(macOS 14, *) else { return false }
    return voice.voiceTraits.contains(.isPersonalVoice)
}

/// Why a Personal Voice may be missing from `--list`, or nil when it would be
/// listed: macOS only lists it once the user has allowed access.
func personalVoiceHint() -> String? {
    guard #available(macOS 14, *) else { return nil }
    switch AVSpeechSynthesizer.personalVoiceAuthorizationStatus {
    case .notDetermined:
        return "run `siri-say --allow-personal-voice` to list your Personal Voice, if you have one"
    case .denied:
        return "access to your Personal Voice is denied. allow it in System Settings >\n"
            + "Accessibility > Personal Voice"
    default:
        return nil
    }
}

/// Asks macOS for access to the user's Personal Voice, which shows a dialog the
/// first time, and reports the answer.
func allowPersonalVoice() -> Never {
    guard #available(macOS 14, *) else { fail("Personal Voice needs macOS 14 or later") }
    var answer: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus?
    AVSpeechSynthesizer.requestPersonalVoiceAuthorization { answer = $0 }
    pump(while: { answer == nil }, timeout: 300)

    switch answer {
    case .authorized:
        let personalVoices = AVSpeechSynthesisVoice.speechVoices().filter(isPersonal)
        if personalVoices.isEmpty {
            print("access allowed, but there is no Personal Voice yet.")
            print("create one in System Settings > Accessibility > Personal Voice.")
        } else {
            print("access allowed. speak with it using:")
            for v in personalVoices { print("  siri-say --voice \(v.identifier) \"Hello\"") }
        }
        exit(0)
    case .denied:
        fail("access denied. allow it in System Settings > Accessibility > Personal Voice")
    case .unsupported:
        fail("this Mac does not support Personal Voice")
    default:
        fail("no answer from macOS. run it again from a terminal and answer the dialog")
    }
}

/// Pads `plain` to `width` and styles it; padding is measured on the plain text,
/// since escape codes take up no room on screen.
func column(_ plain: String, _ width: Int, _ style: (String) -> String = { $0 }) -> String {
    style(plain) + String(repeating: " ", count: max(0, width - plain.count))
}

/// Prints the installed voices, grouped by kind. `say -v '?'` omits the Siri
/// voices; this list does not. On a terminal each group gets a heading and a
/// summary; piped, only the voice lines are printed, identifier second, so
/// `grep` and `awk '{print $2}'` keep working.
func listVoices(prefix: String?, includeHidden: Bool) {
    let isTerminal = isatty(fileno(stdout)) != 0
    let matching = AVSpeechSynthesisVoice.speechVoices()
        .filter { prefix == nil || $0.language.lowercased().hasPrefix(prefix!.lowercased()) }
        .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    let voicesByGroup = Dictionary(grouping: matching, by: VoiceGroup.init)

    var shownCount = 0
    var hiddenCount = 0
    for group in VoiceGroup.allCases {
        guard let voices = voicesByGroup[group] else { continue }
        if group.isHiddenByDefault && !includeHidden {
            hiddenCount += voices.count
            continue
        }
        shownCount += voices.count

        let languageWidth = voices.map(\.language.count).max() ?? 0
        let identifierWidth = voices.map(\.identifier.count).max() ?? 0
        let nameWidth = voices.map(\.name.count).max() ?? 0
        let indent = isTerminal ? "  " : ""

        if isTerminal {
            if shownCount > voices.count { print() }
            print(heading(group.title))
            print(dim(group.summary))
        }
        for v in voices {
            let siri = group == .siri ? "  " + param("[siri]") : ""
            print(indent
                  + column(v.language, languageWidth, dim) + "  "
                  + column(v.identifier, identifierWidth, opt) + "  "
                  + column(v.name, nameWidth) + "  "
                  + dim(qualityName(v.quality))
                  + siri)
        }
    }

    guard isTerminal else {
        // stderr, so a script reading stdout still gets no lines, while an agent
        // reading both learns why the list is empty.
        if shownCount == 0 && hiddenCount > 0 {
            note("""
            no Siri or enhanced voices installed, \(hiddenCount) hidden
            run with --all to show them, or --manage-voices to download better ones
            """)
        }
        return
    }
    if shownCount == 0 && hiddenCount > 0 {
        print(dim("""
        no Siri or enhanced voices installed, \(hiddenCount) hidden
        run with --all to show them, or --manage-voices to download better ones
        """))
    } else {
        var footer = "\(shownCount) \(shownCount == 1 ? "voice" : "voices")"
        if hiddenCount > 0 { footer += ", \(hiddenCount) hidden: run with --all to show them" }
        print("\n" + dim(footer))
    }
    if let hint = personalVoiceHint() { print(dim(hint)) }
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
        fail("""
        voice not found: \(id)
        run `siri-say --list` to see the installed identifiers,
        or `siri-say --manage-voices` to download more
        """)
    }
    return v
}

/// The best installed voice for a language code such as `it` or `en-GB`: Siri
/// first, then enhanced, then the rest, in the `--list` group order. Within the
/// best group, voices from the language's main region win (`fr` means fr-FR, not
/// fr-CA), and among those the voice set in System Settings for the language.
func voiceForLanguage(_ code: String) -> String {
    let candidates = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language.lowercased().hasPrefix(code.lowercased()) }
        // Speaking in the user's own voice takes an explicit --voice.
        .filter { !isPersonal($0) }
        // The identifier breaks ties, putting `compact` before `super-compact`.
        .sorted { ($0.language, $0.name, $0.identifier) < ($1.language, $1.name, $1.identifier) }
    guard let bestGroup = VoiceGroup.allCases.first(where: { group in
        candidates.contains { VoiceGroup($0) == group }
    }) else {
        fail("""
        no voice installed for \(code)
        run `siri-say --manage-voices` to download one
        """)
    }
    // The likely region from Unicode CLDR: `fr` -> FR, `en` -> US, `pt` -> BR.
    let mainRegion = Locale(identifier: Locale.Language(identifier: code).maximalIdentifier)
        .region?.identifier
    let bestVoices = candidates.filter { VoiceGroup($0) == bestGroup }
    let mainRegionVoices = bestVoices.filter {
        Locale(identifier: $0.language).region?.identifier == mainRegion
    }
    // macOS answers `fr` with a fr-CA voice, so its pick only counts in the main region.
    let settingsVoice = AVSpeechSynthesisVoice(language: code)?.identifier
    let preferred = mainRegionVoices.first { $0.identifier == settingsVoice }
        ?? mainRegionVoices.first
        ?? bestVoices.first { $0.identifier == settingsVoice }
        ?? bestVoices[0]
    return preferred.identifier
}

/// Open System Settings on Spoken Content, where voices are downloaded: macOS
/// has no API to download one, so the user picks it there.
func manageVoices() -> Never {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent"]
    do {
        try open.run()
        open.waitUntilExit()
    } catch {
        fail("could not open System Settings: \(error.localizedDescription)")
    }
    guard open.terminationStatus == 0 else { fail("could not open System Settings") }
    print("""
    opened System Settings > Accessibility > Spoken Content.
    to download a voice: click ⓘ next to System voice, pick a language, click
    Voice, then the download icon next to the voice you want.
    once it is downloaded, find its identifier with `siri-say --list`.
    """)
    exit(0)
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
    // The end of the utterance is the delegate's didFinish, as in play(). A
    // zero-length buffer is not: the neural voices synthesise long text in
    // segments and send one between them, so stopping there cut the file at
    // the first segment (about 10 seconds).
    let watcher = PlaybackWatcher()
    synth.delegate = watcher
    var file: AVAudioFile?
    var frames: AVAudioFramePosition = 0
    var finished = false
    var writeError: Error?
    var sawEmpty = false          // a zero-length buffer arrived ...
    var lastBuffer = Date()       // ... and nothing since then

    synth.write(u) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        lastBuffer = Date()
        if pcm.frameLength == 0 { sawEmpty = true; return }
        sawEmpty = false
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
    // Fallback for systems that send no didFinish for write(): an empty buffer
    // followed by 2 seconds without audio is taken as the end.
    pump(while: { !finished && !watcher.done && !(sawEmpty && Date().timeIntervalSince(lastBuffer) > 2) },
         timeout: 600)

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
    // `--all` and the language prefix can come in either order.
    let listArgs = args.dropFirst()
    let languagePrefixes = listArgs.filter { $0 != "--all" }
    if languagePrefixes.count > 1 || languagePrefixes.contains(where: { $0.hasPrefix("-") }) { usage() }
    listVoices(prefix: languagePrefixes.first, includeHidden: listArgs.contains("--all"))
    exit(0)
}

if args.first == "--manage-voices" { manageVoices() }

if args.first == "--allow-personal-voice" { allowPersonalVoice() }

var voiceID: String?   // nil = the system voice
var languageCode: String?   // set by --lang, resolved to voiceID after parsing
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
    case "--lang":
        if args.isEmpty { usage() }
        languageCode = args.removeFirst()
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
if let languageCode {
    if voiceID != nil { fail("--voice and --lang are mutually exclusive") }
    voiceID = voiceForLanguage(languageCode)
}

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
