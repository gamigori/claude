// 하늘다람쥐 데스크톱 펫 (픽셀 아트)
// - 벽: 유리창에 붙은 것처럼 얼굴과 배를 보이며 상하좌우로 기어다님
// - 바닥(Dock 위), 위젯, 스티커 메모 위: 옆모습으로 종종종 걸어다님
//   (바탕화면 모드를 끄면 모든 앱 창 위에도 올라감)
// - 잡으면 날개막을 쫙 펴고, 던지면 날아가다가 활강해서 내려옴
//   세게 던져서 화면 옆에 부딪히면 벽에 철퍽 붙음
// - 클릭하면 폴짝 뛰면서 말풍선, 가만히 두면 가끔 졸기
// - Spotify / 음악 앱에서 노래가 나오면 앞을 보고 앉아서 가사를 따라 부름
//   (가사는 lrclib.net 에서 받아옴)
// - 메뉴에서 도토리를 주면 달려가서 냠냠, 많이 먹으면 배불러서 졸음
// - 마우스로 쓰다듬으면 좋아함
// - Claude Code 훅이 ~/.squirrel/claude-state 에 남기는 상태를 보고
//   생각 중이면 턱 괴고 고민, 오래 걸리면 도토리 까먹으며 기다리고, 다 끝나면 기뻐하고,
//   허락이 필요하면 마우스 쪽으로 와서 손 흔들고, 에러면 털이 쭈뼛, 테스트 통과면 공중제비
// - 배고픔/기분: 배고프면 시무룩, 기분 좋으면 높이 뛰어 활강. 배부를 때 받은 도토리는 묻어뒀다가 나중에 꺼내 먹음
// - 밤(23시~6시)엔 집에 들어가 자고, 아침엔 기지개
// - 다람쥐 근처에서 마우스를 흔들면 쫓아와서 덮침 (메뉴의 '마우스 잡기 놀이'로도 시작), 휴지통에 뭘 버리면 뒤적이러 감
// - 배터리가 부족하면 기운 없음, 비나 눈이 오면 우산
// - 여러 마리면 술래잡기, 도토리 쟁탈전, 노래할 땐 화음
// - 다람쥐마다 이름과 성격(장난꾸러기/먹보/잠꾸러기/겁쟁이/노래쟁이)이 있고, 성격에 맞는 머리 장식을 함
// - 바탕화면에 다람쥐 집: 모양, 지붕 색, 장식을 고르고 끌어서 옮김. 밤엔 들어가서 자고 낮에도 가끔 들름
// - 맵 꾸미기: 발판, 사료통, 트램펄린, 방석, 화분, 가로등을 바탕화면에 놓고 옮김
//   놓을 때 다람쥐 점프 궤적을 잔상으로 보여줘서 뛰어갈 수 있는지 미리 알 수 있음 (실제 점프도 같은 계산)
//   다람쥐는 발판을 건너건너 길을 찾아가고, 사료통엔 도토리가 쌓여서 배고프면 와서 먹음
import AppKit
import IOKit.ps

let W: CGFloat = 240
let P: CGFloat = 4              // 픽셀 하나의 크기 (pt)
let gravity: CGFloat = 1800
let glideFall: CGFloat = 130    // 활강할 때 떨어지는 속도

func rnd(_ a: CGFloat, _ b: CGFloat) -> CGFloat { .random(in: a...b) }

func screenBounds(for p: CGPoint) -> CGRect {
    (NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.screens[0]).visibleFrame
}

let up: CGFloat = .pi / 2, down: CGFloat = -.pi / 2

// MARK: - 다른 앱 창, 위젯, 스티커 메모 (다람쥐가 올라탈 수 있는 곳)

enum WinKind { case app, widget, sticky, custom }
struct Win { let id: Int; let frame: CGRect; let kind: WinKind }

// 앞에 있는 창부터 순서대로
var windows: [Win] = []

// true면 바탕화면 층에서만 놀고, 앱 창 대신 위젯과 스티커 메모 위에 올라감
var onDesktop = true
// 맵 꾸미기에서 놓은 발판 (창처럼 올라탈 수 있음, id는 음수)
var customWins: [Win] = []
// 맵 꾸미기 중이면 전부 앱 창 위로 올라옴
var editing = false
var singAlong = true

let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
let widgetLevel = iconLevel + 2

// 바탕화면 모드: 파일 아이콘과 위젯보다 위, 앱 창보다는 아래
func petLevel() -> NSWindow.Level {
    onDesktop && !editing ? NSWindow.Level(widgetLevel + 1) : .floating
}

func isPlatform(_ w: Win) -> Bool { w.kind == .custom || !onDesktop || w.kind != .app }

// 발판에서 발판으로 뛰는 포물선. 다람쥐의 실제 점프와 맵 꾸미기의 잔상 미리보기가 같이 씀
// (위로는 155pt쯤, 옆으로는 체공 시간 동안 초속 330pt까지)
func jumpArc(from a: CGPoint, to b: CGPoint) -> (v: CGVector, T: CGFloat)? {
    let h = b.y - a.y
    let vy = (2 * gravity * (max(h, 0) + 36)).squareRoot()
    guard vy <= 830 else { return nil }
    let T = (vy + (vy * vy - 2 * gravity * h).squareRoot()) / gravity
    let vx = (b.x - a.x) / T
    guard abs(vx) <= 330 else { return nil }
    return (CGVector(dx: vx, dy: vy), T)
}

// 진행 중인 점프
struct Jump {
    let from: CGPoint       // 발 디딘 곳
    let v: CGVector
    let T: CGFloat
    let surface: Int?       // 내려앉을 발판 (바닥이면 nil)
    var t: CGFloat = 0

    func point(_ t: CGFloat) -> CGPoint {
        CGPoint(x: from.x + v.dx * t, y: from.y + v.dy * t - gravity * t * t / 2)
    }
}

func refreshWindows() {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return }
    let primaryTop = NSScreen.screens[0].frame.maxY
    let me = Int(ProcessInfo.processInfo.processIdentifier)
    windows = customWins + list.compactMap { (d: [String: Any]) -> Win? in
        guard let layer = d[kCGWindowLayer as String] as? Int, layer == 0 || layer == widgetLevel,
              let pid = d[kCGWindowOwnerPID as String] as? Int, pid != me,
              ((d[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
              let id = d[kCGWindowNumber as String] as? Int,
              let bd = d[kCGWindowBounds as String],
              let r = CGRect(dictionaryRepresentation: bd as! CFDictionary),
              r.width > 120, r.height > 60 else { return nil }
        let sticky = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier == "com.apple.Stickies"
        let kind: WinKind = layer == widgetLevel ? .widget : sticky ? .sticky : .app
        // CG 좌표(위가 0)를 Cocoa 좌표(아래가 0)로
        return Win(id: id, frame: CGRect(x: r.minX, y: primaryTop - r.maxY, width: r.width, height: r.height), kind: kind)
    }
}

// 창 윗변의 x 지점이 다른 창에 가려지지 않았는지
func topVisible(_ w: Win, x: CGFloat) -> Bool {
    let p = CGPoint(x: x, y: w.frame.maxY + 2)
    for o in windows {
        if o.id == w.id { return true }
        if o.frame.contains(p) { return false }
    }
    return false
}

// MARK: - 지금 재생 중인 노래와 가사

final class NowPlaying {
    var playing = false
    var lyrics: [(time: Double, text: String)] = []
    private var position: Double = 0
    private var polledAt = CACurrentMediaTime()
    private var trackKey = ""
    private var busy = false
    private let queue = DispatchQueue(label: "now-playing")

    var elapsed: Double { position + (CACurrentMediaTime() - polledAt) }

    // 지금 불러야 할 가사 한 줄 (간주 중이면 nil)
    var currentLine: String? {
        let t = elapsed + 0.15
        guard let line = lyrics.last(where: { $0.time <= t }), !line.text.isEmpty else { return nil }
        return line.text
    }

    func poll() {
        guard !busy else { return }
        busy = true
        queue.async {
            let info = NowPlaying.query()
            DispatchQueue.main.async {
                self.apply(info)
                self.busy = false
            }
        }
    }

    // [제목, 아티스트, 앨범, 길이(초), 재생 위치(초)]
    private static func query() -> [String]? {
        let players = [("com.spotify.client", "Spotify", "(duration of current track) / 1000"),
                       ("com.apple.Music", "Music", "duration of current track")]
        for (bundle, name, duration) in players
        where !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
            let src = """
            tell application "\(name)"
                if player state is playing then
                    return (name of current track) & linefeed & (artist of current track) & linefeed & ¬
                        (album of current track) & linefeed & (\(duration)) & linefeed & player position
                end if
            end tell
            return ""
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", src]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { continue }
            p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let lines = text.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
            if lines.count >= 5 { return lines }
        }
        return nil
    }

    private func apply(_ info: [String]?) {
        guard let info = info else { playing = false; return }
        let num = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        playing = true
        position = num(info[4])
        polledAt = CACurrentMediaTime()
        let key = info[0] + "\n" + info[1]
        if key != trackKey {
            trackKey = key
            lyrics = []
            fetchLyrics(title: info[0], artist: info[1], album: info[2], duration: num(info[3]), key: key)
        }
    }

    private func fetchLyrics(title: String, artist: String, album: String, duration: Double, key: String) {
        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [URLQueryItem(name: "track_name", value: title),
                            URLQueryItem(name: "artist_name", value: artist),
                            URLQueryItem(name: "album_name", value: album),
                            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))]
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [URLQueryItem(name: "track_name", value: title),
                             URLQueryItem(name: "artist_name", value: artist)]

        func request(_ c: URLComponents, _ done: @escaping (Any?) -> Void) {
            var r = URLRequest(url: c.url!)
            r.setValue("DesktopFlyingSquirrel/1.0", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: r) { data, _, _ in
                done(data.flatMap { try? JSONSerialization.jsonObject(with: $0) })
            }.resume()
        }
        func use(_ synced: String?) {
            guard let synced = synced else { return }
            let parsed = NowPlaying.parseLRC(synced)
            DispatchQueue.main.async { if self.trackKey == key { self.lyrics = parsed } }
        }

        // 제목/아티스트/앨범/길이가 딱 맞는 걸 먼저 찾고, 없으면 검색 결과 중 싱크 가사가 있는 것
        request(exact) { json in
            if let s = (json as? [String: Any])?["syncedLyrics"] as? String { return use(s) }
            request(search) { json in
                let hit = (json as? [[String: Any]])?.first { $0["syncedLyrics"] is String }
                use(hit?["syncedLyrics"] as? String)
            }
        }
    }

    // "[01:23.45] 가사" 형식
    static func parseLRC(_ s: String) -> [(time: Double, text: String)] {
        var out: [(time: Double, text: String)] = []
        for raw in s.components(separatedBy: .newlines) {
            var line = Substring(raw)
            var times: [Double] = []
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let tag = line[line.index(after: line.startIndex)..<close].split(separator: ":")
                if tag.count == 2, let m = Double(tag[0]), let sec = Double(tag[1]) { times.append(m * 60 + sec) }
                line = line[line.index(after: close)...]
            }
            let text = line.trimmingCharacters(in: .whitespaces)
            for t in times { out.append((t, text)) }
        }
        return out.sorted { $0.time < $1.time }
    }
}

let music = NowPlaying()

// MARK: - Claude Code 상태 (훅이 남긴 파일을 읽음)

final class ClaudeWatch {
    enum State: Equatable { case idle, thinking, tool(String), done, attention, error, cheer }
    var state: State = .idle
    private(set) var since = Date.distantPast
    private var busySince: Date?
    private var lastMod: Date?
    private let path = NSHomeDirectory() + "/.squirrel/claude-state"

    // 한 번의 요청을 1분 넘게 붙잡고 있으면 몇 분째인지
    var busyMinutes: Int? {
        guard let b = busySince else { return nil }
        let t = Date().timeIntervalSince(b)
        return t > 60 ? Int(t / 60) : nil
    }

    func poll() {
        if let mod = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
           mod != lastMod {
            lastMod = mod
            since = mod
            // 첫 줄: 훅 이벤트 이름, 둘째 줄: 도구 이름, 셋째 줄: 테스트 명령이었으면 test
            let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").components(separatedBy: "\n")
            let tool = lines.count > 1 ? lines[1] : ""
            let flag = lines.count > 2 ? lines[2] : ""
            switch lines[0] {
            case "UserPromptSubmit": state = .thinking; busySince = mod
            case "PostToolUse": state = flag == "test" ? .cheer : .thinking
            case "PostToolUseFailure": state = .error
            case "PreToolUse": state = .tool(ClaudeWatch.describe(tool))
            case "Stop": state = .done
            case "Notification", "PermissionRequest": state = .attention
            default: state = .idle
            }
            switch state {
            case .idle, .done: busySince = nil
            default: if busySince == nil { busySince = mod }
            }
        }
        // 오래된 상태는 정리
        let age = Date().timeIntervalSince(since)
        switch state {
        case .done where age > 3.5, .attention where age > 20: state = .idle
        case .error where age > 2.5, .cheer where age > 3: state = .thinking
        case .thinking where age > 600, .tool where age > 600: state = .idle; busySince = nil
        default: break
        }
    }

    static func describe(_ tool: String) -> String {
        switch tool {
        case "Read", "NotebookRead": return "읽는 중"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "고치는 중"
        case "Bash": return "명령 실행 중"
        case "Grep", "Glob", "LS": return "찾는 중"
        case "WebFetch", "WebSearch": return "검색 중"
        case "Task", "Agent": return "도우미 부르는 중"
        default: return "작업 중"
        }
    }
}

let claude = ClaudeWatch()
var claudeReact = true

// MARK: - 컨디션: 배고픔, 기분, 묻어둔 도토리 (여러 마리가 같이 씀)

final class Needs {
    var hunger: CGFloat         // 0 배부름 ~ 1 배고픔 (1시간 반이면 꽉 참)
    var mood: CGFloat           // 0 시무룩 ~ 1 신남
    var stash: [CGFloat]        // 묻어둔 도토리의 x
    private var saveIn: CGFloat = 10
    private let d = UserDefaults.standard

    init() {
        hunger = d.object(forKey: "hunger") == nil ? 0.4 : CGFloat(d.double(forKey: "hunger"))
        mood = d.object(forKey: "mood") == nil ? 0.6 : CGFloat(d.double(forKey: "mood"))
        stash = (d.array(forKey: "stash") as? [Double] ?? []).map { CGFloat($0) }
        // 꺼져 있던 동안에도 배는 고파짐
        if d.object(forKey: "needsSaved") != nil {
            let away = CGFloat(Date().timeIntervalSince1970 - d.double(forKey: "needsSaved"))
            hunger = min(1, hunger + max(0, away) / 5400)
        }
    }

    var full: Bool { hunger < 0.12 }
    var hungry: Bool { hunger > 0.65 }

    func tick(_ dt: CGFloat) {
        hunger = min(1, hunger + dt / 5400)
        // 배고프면 기분이 처지고, 아니면 천천히 보통으로 돌아옴
        let rest = 0.6 - hunger * 0.5
        mood += (rest - mood) * min(1, dt / 900)
        saveIn -= dt
        if saveIn <= 0 { save() }
    }

    func ate() { hunger = max(0, hunger - 0.3); cheer(0.15) }
    func cheer(_ v: CGFloat) { mood = min(1, mood + v) }

    func save() {
        saveIn = 10
        d.set(Double(hunger), forKey: "hunger")
        d.set(Double(mood), forKey: "mood")
        d.set(stash.map(Double.init), forKey: "stash")
        d.set(Date().timeIntervalSince1970, forKey: "needsSaved")
    }
}

let needs = Needs()

// MARK: - 바깥 세상: 시간, 배터리, 날씨, 휴지통

var weatherReact = true

final class World {
    enum Weather { case clear, rain, snow }
    var battery: Int?           // 배터리가 없는 맥이면 nil
    var charging = false
    var weather = Weather.clear
    var trashed = false         // 방금 휴지통에 뭔가 버림 (다람쥐가 구경 가면 false)
    var news: String?           // 다람쥐 한 마리가 말해줄 소식
    private var trashCount: Int?
    private var trashBusy = false, trashDenied = false
    private var batteryPoll: CGFloat = 0, weatherPoll: CGFloat = 3, trashPoll: CGFloat = 2

    var hour: Int { Calendar.current.component(.hour, from: Date()) }
    var night: Bool { hour >= 23 || hour < 6 }
    var morning: Bool { hour >= 6 && hour < 11 }
    var lowBattery: Bool { !charging && (battery ?? 100) <= 20 }

    func tick(_ dt: CGFloat) {
        batteryPoll -= dt; weatherPoll -= dt; trashPoll -= dt
        if batteryPoll <= 0 { batteryPoll = 20; pollBattery() }
        if weatherPoll <= 0 { weatherPoll = 1800; pollWeather() }
        if trashPoll <= 0 { trashPoll = 3; pollTrash() }
    }

    func pollBattery() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        guard let ps = list.first,
              let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
              let level = desc[kIOPSCurrentCapacityKey] as? Int else { battery = nil; return }
        let plugged = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        if battery != nil {
            if plugged && !charging { news = "충전이다! ⚡" }
            if !plugged && level <= 20 && (battery! > 20 || charging) { news = "배터리가 부족해… 🪫" }
        }
        battery = level
        charging = plugged
    }

    // wttr.in 이 IP로 대충 위치를 잡아서 지금 날씨를 알려줌
    func pollWeather() {
        guard weatherReact else { weather = .clear; return }
        var r = URLRequest(url: URL(string: "https://wttr.in/?format=j1")!)
        r.setValue("DesktopFlyingSquirrel/1.0", forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 15
        URLSession.shared.dataTask(with: r) { data, _, _ in
            guard let data = data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cur = (j["current_condition"] as? [[String: Any]])?.first,
                  let code = Int(cur["weatherCode"] as? String ?? "") else { return }
            let w: Weather = World.snowCodes.contains(code) ? .snow : World.rainCodes.contains(code) ? .rain : .clear
            DispatchQueue.main.async {
                guard weatherReact else { return }
                if w != self.weather && w != .clear { self.news = w == .rain ? "비 온다~ ☔" : "눈이다! ❄" }
                self.weather = w
            }
        }.resume()
    }

    static let rainCodes: Set<Int> = [176, 200, 263, 266, 281, 284, 293, 296, 299, 302, 305, 308, 311, 314,
                                      353, 356, 359, 386, 389]
    static let snowCodes: Set<Int> = [179, 182, 185, 227, 230, 317, 320, 323, 326, 329, 332, 335, 338, 350,
                                      362, 365, 368, 371, 374, 377, 392, 395]

    // 휴지통 폴더는 직접 못 읽어서 Finder에게 개수를 물어봄 (처음 한 번 권한을 물어봄)
    func pollTrash() {
        guard !trashBusy, !trashDenied else { return }
        trashBusy = true
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"Finder\" to count items of trash"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            var n: Int?
            if (try? p.run()) != nil {
                p.waitUntilExit()
                n = Int(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
            DispatchQueue.main.async {
                self.trashBusy = false
                guard let n = n else { self.trashDenied = true; return }
                if let old = self.trashCount, n > old { self.trashed = true }
                self.trashCount = n
            }
        }
    }
}

let world = World()

// MARK: - 하늘다람쥐

enum Mode { case wall, floor, air, held }

// 다람쥐마다 다른 성격. 성격에 맞는 머리 장식을 하고, 말투와 하는 짓이 달라짐
enum Personality: String, CaseIterable {
    case playful, glutton, sleepy, shy, singer

    var title: String {
        switch self {
        case .playful: return "장난꾸러기"
        case .glutton: return "먹보"
        case .sleepy: return "잠꾸러기"
        case .shy: return "겁쟁이"
        case .singer: return "노래쟁이"
        }
    }

    var emoji: String {
        switch self {
        case .playful: return "🧢"
        case .glutton: return "🌰"
        case .sleepy: return "💤"
        case .shy: return "🎀"
        case .singer: return "🌼"
        }
    }

    var accessory: Accessory {
        switch self {
        case .playful: return .cap
        case .glutton: return .acornHat
        case .sleepy: return .nightcap
        case .shy: return .ribbon
        case .singer: return .flower
        }
    }

    // 클릭했을 때 하는 말
    var pokeLines: [String] {
        switch self {
        case .playful: return ["놀자!", "나 잡아봐라~", "히히", "날아볼까?", "심심해!"]
        case .glutton: return ["도토리 줘!", "배고파~", "간식 시간?", "도토리 냄새!", "하나만 더…"]
        case .sleepy: return ["하암…", "졸려…", "5분만…", "음냐…", "왜 깨워…"]
        case .shy: return ["히익!", "까, 깜짝이야…", "///", "아, 안녕…", "부끄러워…"]
        case .singer: return ["라라라~ ♪", "노래 틀어줘!", "도레미~", "♪♪", "같이 부를래?"]
        }
    }

    // 가만히 있다가 하는 혼잣말
    var idleLines: [String] {
        switch self {
        case .playful: return ["심심해~", "뭐 하고 놀지?", "마우스 흔들어줘!"]
        case .glutton: return ["도토리 먹고 싶다…", "간식 없나?", "꼬르륵"]
        case .sleepy: return ["하암…", "졸려…", "낮잠 잘까…"]
        case .shy: return ["…", "(두리번)", "조, 조용하다…"]
        case .singer: return ["♪ 흥얼흥얼~", "♪ 라라라~", "노래 듣고 싶다~"]
        }
    }

    // 자러 가는 시각과 일어나는 시각
    var bed: (sleep: Int, wake: Int) { self == .sleepy ? (21, 8) : (23, 6) }
}

// 멈춰서 하는 행동
enum Act: Equatable {
    case none, sing, harmony, think(String), wait(Int), done, cheer, attention, startle, eat, dig, greet
}

final class Squirrel {
    var pos = CGPoint.zero      // 창 중심 (화면 좌표)
    var vel = CGVector.zero
    var heading: CGFloat = up   // 벽에서는 상하좌우 네 방향만
    var mode: Mode = .air
    var surface: Int?           // 올라탄 창 id, nil이면 화면 바닥
    var dir: CGFloat = 1        // 옆모습일 때 바라보는 방향
    var gait: CGFloat = 0
    var speed: CGFloat = 0
    var targetSpeed: CGFloat = 0
    var timer: CGFloat = 1
    var airTime: CGFloat = 0
    var sleeping = false
    var act: Act = .none
    var lyric: String?
    var target: CGFloat?        // 가려는 곳의 x (도토리, 둥지, 마우스 등)
    var rush: CGFloat = 95      // 거기로 가는 속도
    var eatTime: CGFloat = 0
    var workTime: CGFloat = 0   // 땅 파기, 뒤적이기 남은 시간
    var finished = false        // 일이 막 끝남
    var happyTime: CGFloat = 0
    var flipTime: CGFloat = 0   // 공중제비 남은 시간
    var greetTime: CGFloat = 0
    var nested = false          // 둥지에서 자는 중
    var tired = false           // 배터리가 없거나 너무 배고파서 기운 없음
    var lively: CGFloat = 0.5   // 기분
    var jump: Jump?             // 발판으로 뛰는 중
    var keepSurface = false     // 목적지가 발판 위에 있어서 뛰어내리지 않고 걸어감
    var personality = Personality.playful
    var name = ""
    // 지금이 이 다람쥐가 잘 시간인지
    var bedtime: Bool {
        let h = world.hour, b = personality.bed
        return h >= b.sleep || h < b.wake
    }
    var bubble: String?
    var bubbleTime: CGFloat = 0
    var time: CGFloat = 0

    // 옆모습일 때 발바닥 높이
    var feet: CGFloat {
        get { pos.y - W / 2 + 8 }
        set { pos.y = newValue + W / 2 - 8 }
    }

    // 던진 직후엔 데굴데굴, 조금 지나면 날개막을 펴고 활강
    var gliding: Bool { mode == .air && airTime > 0.35 }

    func say(_ s: String, _ t: CGFloat = 1.6) { bubble = s; bubbleTime = t }

    func update(_ dt: CGFloat, bounds b: CGRect) {
        time += dt
        if bubbleTime > 0 { bubbleTime -= dt } else { bubble = nil }
        if happyTime > 0 { happyTime -= dt }
        if eatTime > 0 {
            eatTime -= dt
            if eatTime <= 0 { doneEating() }
        }
        if workTime > 0 {
            workTime -= dt
            if workTime <= 0 { finished = true }
        }
        if flipTime > 0 { flipTime -= dt }
        if greetTime > 0 { greetTime -= dt }
        speed += (targetSpeed * (tired ? 0.5 : 1) - speed) * min(1, dt * 4)
        if act != .none { sleeping = false; speed = 0 }

        switch mode {
        case .held:
            gait += dt * 16
        case .air:
            updateAir(dt, b)
        case .wall:
            // 도토리가 보이면 벽에서 뛰어내림
            if target != nil, act == .none { return fall() }
            if act == .none {
                timer -= dt
                if timer <= 0 { pickWall() }
            }
            pos.x += cos(heading) * speed * dt
            pos.y += sin(heading) * speed * dt
            let m: CGFloat = 70
            if pos.x < b.minX + m { pos.x = b.minX + m; heading = 0 }
            if pos.x > b.maxX - m { pos.x = b.maxX - m; heading = .pi }
            if pos.y > b.maxY - m { pos.y = b.maxY - m; heading = down }
            if pos.y < b.minY + 60 && sin(heading) < -0.5 { land(on: nil, ground: b.minY) }
            gait += speed * dt * 0.25
        case .floor:
            updateFloor(dt, b)
        }
    }

    func updateAir(_ dt: CGFloat, _ b: CGRect) {
        airTime += dt
        if var j = jump {
            // 계산해 둔 포물선을 그대로 따라가서 정확히 내려앉음
            j.t += dt
            gait += dt * 14
            if abs(j.v.dx) > 20 { dir = j.v.dx > 0 ? 1 : -1 }
            let p = j.point(min(j.t, j.T))
            pos.x = p.x
            feet = p.y
            if j.t >= j.T {
                jump = nil
                land(on: j.surface, ground: p.y)
            } else {
                jump = j
            }
            return
        }
        vel.dy -= gravity * dt
        if gliding {
            // 날개막 덕분에 천천히 떨어지면서 옆으로 미끄러짐
            if vel.dy < -glideFall { vel.dy += (-glideFall - vel.dy) * min(1, dt * 5) }
            if let tx = target {
                // 도토리 쪽으로 방향을 잡으며 활강
                dir = tx > pos.x ? 1 : -1
                vel.dx += (dir * 220 - vel.dx) * min(1, dt * 2)
            } else {
                if abs(vel.dx) < 90 { vel.dx += dir * 200 * dt }
                vel.dx *= 1 - min(1, dt * 0.6)
            }
        }
        let oldFeet = feet
        pos.x += vel.dx * dt
        pos.y += vel.dy * dt
        gait += dt * 14
        if abs(vel.dx) > 20 { dir = vel.dx > 0 ? 1 : -1 }

        // 화면 옆: 세게 부딪히면 벽에 붙고 아니면 튕김
        let m: CGFloat = 70
        if pos.x < b.minX + m || pos.x > b.maxX - m {
            pos.x = min(max(pos.x, b.minX + m), b.maxX - m)
            if abs(vel.dx) > 700 {
                mode = .wall
                heading = vel.dy > 0 ? up : down
                targetSpeed = 0; speed = 0; timer = 1
                say("철퍽!")
                return
            }
            vel.dx = -vel.dx * 0.5
            dir = -dir
        }
        if feet + 60 > b.maxY { feet = b.maxY - 60; vel.dy = -abs(vel.dy) * 0.5 }

        guard vel.dy < 0 else { return }
        var ground = b.minY
        var hit: Win?
        // 도토리를 쫓을 땐 위젯이나 메모에 걸리지 않고 바닥까지
        for w in windows where target == nil && isPlatform(w) && w.frame.minX < pos.x && pos.x < w.frame.maxX
            && oldFeet >= w.frame.maxY && feet <= w.frame.maxY && w.frame.maxY > ground
            && topVisible(w, x: pos.x) {
            ground = w.frame.maxY; hit = w
        }
        guard feet <= ground else { return }
        feet = ground
        if -vel.dy > 320 {
            vel.dy = -vel.dy * 0.45     // 통통
            vel.dx *= 0.7
            airTime = 0
        } else {
            land(on: hit?.id, ground: ground)
        }
    }

    func updateFloor(_ dt: CGFloat, _ b: CGRect) {
        if let tx = target, act == .none {
            // 도토리를 향해 종종종 (위젯이나 메모 위면 뛰어내림)
            if surface != nil && !keepSurface { return fall() }
            sleeping = false
            dir = tx > pos.x ? 1 : -1
            targetSpeed = abs(tx - pos.x) < 6 ? 0 : rush
        } else if act == .none {
            timer -= dt
            if timer <= 0 { pickFloor() }
            guard mode == .floor else { return }
        }
        if !sleeping { pos.x += dir * speed * dt }
        gait += speed * dt * 0.25

        if let id = surface {
            // 창이 사라지거나 가려지면 떨어짐, 창이 움직이면 같이 따라감
            guard let w = windows.first(where: { $0.id == id }), isPlatform(w), topVisible(w, x: pos.x)
            else { return fall() }
            if pos.x < w.frame.minX + 6 || pos.x > w.frame.maxX - 6 {
                if Bool.random() {
                    pos.x = min(max(pos.x, w.frame.minX + 6), w.frame.maxX - 6)
                    dir = -dir
                } else {
                    return fall()
                }
            }
            feet = w.frame.maxY
        } else {
            feet = b.minY
        }
        if pos.x < b.minX + 80 { pos.x = b.minX + 80; dir = 1 }
        if pos.x > b.maxX - 80 { pos.x = b.maxX - 80; dir = -1 }
    }

    // 쉬는 중이면 가끔 졸기
    func rest() {
        targetSpeed = 0
        // 기운 없으면 자주, 신나 있으면 덜 졺
        let sleepy = (tired ? 0.7 : 0.35 - (lively - 0.5) * 0.3) + (personality == .sleepy ? 0.3 : 0)
        if rnd(0, 1) < sleepy {
            sleeping = true; timer = rnd(6, 14)
        } else {
            timer = rnd(1, 3)
        }
    }

    func pickWall() {
        sleeping = false
        let r = rnd(0, 1)
        if r < 0.25 {
            rest()
        } else if r < 0.85 {
            targetSpeed = rnd(30, 55); timer = rnd(1.5, 4)
            heading += [0, up, down].randomElement()!
        } else {
            targetSpeed = 50; heading = down; timer = 10
        }
    }

    func pickFloor() {
        if nested {
            // 밤새 둥지에서 자고, 아침이 되면 기지개
            if bedtime { sleeping = true; timer = rnd(20, 40); return }
            nested = false
            greetTime = 3.5
        }
        sleeping = false
        if tired && rnd(0, 1) < 0.25 {
            say(world.lowBattery ? "배터리가… 부족해…" : "배고파… 힘없어…", 2.2)
        } else if needs.hungry && rnd(0, 1) < 0.2 {
            say(["배고파…", "도토리 줘~", "꼬르륵…"].randomElement()!, 2)
        } else if rnd(0, 1) < 0.1 {
            say(personality.idleLines.randomElement()!, 2)
        }
        // 기분 좋으면 가끔 높이 뛰어올라 활강
        if lively > 0.7 && !tired && surface == nil && rnd(0, 1) < 0.12 {
            say("야호~!", 1.2)
            return hop(CGVector(dx: dir * 160, dy: 760))
        }
        let r = rnd(0, 1)
        if r < 0.25 {
            rest()
        } else if r < 0.82 {
            targetSpeed = rnd(25, 50); timer = rnd(2, 5)
            if rnd(0, 1) < 0.35 { dir = -dir }
        } else if surface != nil {
            targetSpeed = rnd(25, 50); timer = rnd(2, 5)
        } else {
            // 벽으로 올라가기
            mode = .wall
            heading = up
            pos.y = feet + 75
            surface = nil
            targetSpeed = 45; timer = 3
        }
    }

    func land(on id: Int?, ground: CGFloat) {
        mode = .floor
        surface = id
        feet = ground
        vel = .zero
        sleeping = false
        timer = rnd(1, 3); targetSpeed = rnd(25, 45)
    }

    func fall() {
        jump = nil
        mode = .air
        surface = nil
        airTime = 0
        vel = CGVector(dx: dir * speed, dy: 0)
        sleeping = false
    }

    func grab(at p: CGPoint) {
        jump = nil
        mode = .held
        heading = up
        sleeping = false
        targetSpeed = 0
        pos = p
    }

    func release(at p: CGPoint, vel v: CGVector) {
        mode = .air
        surface = nil
        airTime = 0
        vel = v
        pos = CGPoint(x: p.x, y: p.y + W / 2 - 28)
        if abs(v.dx) > 20 { dir = v.dx > 0 ? 1 : -1 }
        if hypot(v.dx, v.dy) > 900 { say("슝~!", 1) }
    }

    func poke() {
        if sleeping {
            sleeping = false
            nested = false
            say(personality == .sleepy ? "5분만 더…" : "깜짝!")
            timer = rnd(1, 2)
        } else if rnd(0, 1) < 0.2 {
            say("나는 \(name)! \(personality.title)야", 2.2)
        } else {
            say(personality.pokeLines.randomElement()!)
        }
        // 바닥에 있으면 폴짝 (겁쟁이는 옆으로 도망)
        if mode == .floor {
            let away: CGFloat = personality == .shy ? (Bool.random() ? 220 : -220) : 0
            hop(CGVector(dx: away, dy: 420))
        }
    }

    // 발판으로 폴짝
    func leap(_ j: Jump) {
        mode = .air
        surface = nil
        airTime = 0
        sleeping = false
        jump = j
    }

    func hop(_ v: CGVector) {
        jump = nil
        mode = .air
        surface = nil
        airTime = 0
        sleeping = false
        vel = v
    }

    // 테스트 통과! 제자리에서 공중제비
    func flip() {
        guard mode == .floor else { return }
        hop(CGVector(dx: 0, dy: 640))
        flipTime = 0.7
        happyTime = 2.5
    }

    // 마우스 커서를 덮침
    func pounce(toward x: CGFloat) {
        dir = x > pos.x ? 1 : -1
        hop(CGVector(dx: dir * 260, dy: 560))
        say("잡았다!", 1.4)
        happyTime = 2
        needs.cheer(0.05)
    }

    func startEating() {
        target = nil
        eatTime = 2.6
        say("냠냠", 2.4)
    }

    func doneEating() {
        needs.ate()
        timer = rnd(1, 2)
        if needs.full {
            say("배불러~", 2.5)
            sleeping = true
            timer = 12
        } else {
            say(["맛있다! ♥", "도토리 최고!", "냠냠 ♥"].randomElement()!)
            happyTime = 1.6
        }
    }

    // 땅 파기, 뒤적이기
    func startWork(_ t: CGFloat, _ s: String) {
        target = nil
        sleeping = false
        workTime = t
        finished = false
        say(s, t)
    }

    // 쓰다듬어 줬을 때
    func petted() {
        happyTime = 2
        needs.cheer(0.1)
        let lines = personality == .shy ? ["부, 부끄러워… ///", "헤헤…", "…좋아"] : ["헤헤 ♥", "기분 좋아~", "더 해줘!"]
        say(sleeping ? "음냐..." : lines.randomElement()!)
    }

    // 0: 가만히, 1/2: 걷는 프레임
    var frame: Int {
        if sleeping || act != .none || (mode != .held && mode != .air && speed < 6) { return 0 }
        return Int(gait / .pi) % 2 == 0 ? 1 : 2
    }

    // 가사가 나오는 동안 입을 뻐끔뻐끔, 간주 중엔 입 다물고 흥얼
    // 화음 넣는 다람쥐는 반 박자 엇갈려서
    var mouthOpen: Bool {
        let beat = time * 3.5 + (act == .harmony ? 0.5 : 0)
        return lyric != nil && beat.truncatingRemainder(dividingBy: 1) < 0.55
    }
    // 가끔 눈을 감고 신나게
    var happyEyes: Bool { Int(time / 2.5) % 3 == 2 }

    // 앞모습일 때 들썩이는 높이
    var bob: CGFloat {
        switch act {
        case .sing: return Int(time * 4) % 2 == 0 ? P : 0
        case .harmony: return Int(time * 4) % 2 == 1 ? P : 0
        case .done, .cheer, .greet: return Int(time * 5) % 2 == 0 ? P * 3 : 0
        case .attention: return Int(time * 6) % 2 == 0 ? P * 2 : 0
        default: return 0
        }
    }

    // 하는 행동에 맞는 말풍선
    var actText: String? {
        switch act {
        case .sing, .harmony: return lyric
        case .think(let what): return what + String(repeating: ".", count: Int(time * 2.5) % 3 + 1)
        case .wait(let m): return "아직 하는 중… (\(m)분째)"
        case .done: return "다 했다!"
        case .cheer: return "테스트 통과!"
        case .startle: return "으악! 에러다!"
        case .attention: return "확인해줘!"
        case .greet: return world.morning ? "으아암~ 좋은 아침!" : "으아암~ 잘 잤다!"
        default: return nil
        }
    }
}

// MARK: - 픽셀 스프라이트

typealias Grid = [[Character]]

let palette: [Character: (UInt8, UInt8, UInt8)] = [
    "g": (200, 184, 166),   // 털
    "d": (150, 130, 114),   // 진한 털 (귀, 꼬리 테두리, 날개막 가장자리)
    "e": (172, 152, 136),   // 날개막
    "w": (252, 248, 240),   // 배
    "k": (34, 28, 28),      // 눈
    "h": (255, 255, 255),   // 눈 반짝
    "p": (255, 164, 176),   // 볼터치
    "n": (222, 120, 132),   // 코
    "m": (176, 66, 80),     // 벌린 입
    "f": (236, 206, 196),   // 발
    "q": (206, 176, 166),   // 먼 쪽 발
    "o": (78, 58, 50),      // 외곽선
    "a": (130, 84, 48),     // 도토리 모자
    "b": (214, 150, 86),    // 도토리
    "l": (246, 200, 146),   // 도토리 반짝
    "t": (150, 100, 60),    // 둥지 나뭇가지
    "y": (214, 176, 108),   // 둥지 지푸라기
    "u": (156, 118, 84),    // 흙
    "v": (120, 88, 62),     // 진한 흙
    "r": (236, 108, 108),   // 우산
    "R": (252, 236, 220),   // 우산 줄무늬, 모자 챙
    "c": (120, 150, 220),   // 잠옷 모자
    "C": (90, 116, 186),    // 잠옷 모자 그늘
    "j": (250, 208, 90),    // 노란 꽃, 불빛, 문고리
    "L": (112, 172, 92),    // 풀, 잎
    "K": (80, 136, 70),     // 진한 풀
    "W": (196, 146, 98),    // 통나무
    "V": (156, 110, 72),    // 진한 통나무
    "D": (116, 78, 52),     // 문
    "G": (176, 218, 240),   // 유리창 (밤에 누가 있으면 노랗게)
    "S": (244, 232, 208),   // 버섯 기둥, 점
    "s": (222, 204, 176),   // 버섯 기둥 그늘
    "P": (204, 112, 72),    // 화분
]

// 둥지 (밤에만 나타남, 다람쥐 다리를 가림)
let nestBody = [
    "t..y..t...y..t...y..t..y...t..y.",
    "yttyty.tttyy.tyttyt.yyttyt.tytyt",
    "tyttyttytyyttytytyyttyttytyttyyt",
    ".tytttyytyttyttyttytyyttytttyyt.",
    "..ttyttytyyttyttytytyttyttytyt..",
    "....ttttyyttttyyttttyyttttyy....",
]

// 도토리를 묻어둔 흙더미
let moundBody = [
    "....aa.....",
    "..uuaauuu..",
    ".uuvuuuvuu.",
    "uuuuuvuuuuu",
]

// 비 오는 날 쓰는 우산
let umbrellaBody = [
    "........o........",
    "......rrRrr......",
    "....rrrrRrrrr....",
    "..rrrrrRRRrrrrr..",
    ".rrrrrrRRRrrrrrr.",
    "rrrrrrRRRRRrrrrrr",
    "r.r.r.r.o.r.r.r.r",
    "........o........",
    "........o........",
    "........o........",
    "......o.o........",
    ".......o.........",
]

let acornBody = [
    "...a...",
    ".aaaaa.",
    "aaaaaaa",
    ".bbbbb.",
    ".blbbb.",
    "..bbb..",
    "...b...",
]

// 앞모습 (노래 부를 때). 두 손을 가슴에 모으고 있음
let frontBody = [
    "......gg......gg......",
    ".....gddg....gddg.....",
    ".....gggggggggggg.....",
    "....gggggggggggggg..dd",
    "....ggkkggggggkkgg.dgg",
    "....gkhkkggggkhkkg.ggg",
    "....gkkkkgnngkkkkg.dgg",
    "....gpkkgwwwwgkkpg.ggg",
    ".....ggwwwwwwwwgg..gdg",
    "....gggwwwwwwwwggg.ggg",
    "...ggwwwffwwffwwwgggdg",
    "...gwwwwffwwffwwwwggg.",
    "...ggwwwwwwwwwwwwggg..",
    "....ggwwwwwwwwwwgg....",
    ".....gggggggggggg.....",
    ".....ffgg....ggff.....",
]

// 옆모습, 머리가 오른쪽. 마지막 두 줄은 다리 자리
let sideBody = [
    ".gg...........gg..gg....",
    "gdgg.........gddggddg...",
    "gdggg.......gggggggggg..",
    "ggdgg......gggggggggggg.",
    ".gdgg......ggggggkkkggg.",
    ".ggdg....ggggggggkhkgggn",
    "..gdgg.ggggggggggkkkggg.",
    "...ggggggggggggggggpggw.",
    "....gggggwwwwwwwwggggww.",
    "....ddgwwwwwwwwwwwwggg..",
    ".....ddddwwwwwwwwwdd....",
    "......ddddddddddddd.....",
    "........................",
    "........................",
]

// 벽 탈 때: 유리창에 붙은 것처럼 얼굴과 배가 보임, 머리가 위쪽. 팔다리는 코드로 붙임
let climbBody = [
    "......gg......gg......",
    ".....gddg....gddg.....",
    ".....gggggggggggg.....",
    "....gggggggggggggg....",
    "....ggkkggggggkkgg....",
    "....gkhkkggggkhkkg....",
    "....gkkkkgnngkkkkg....",
    "....gpkkgwwwwgkkpg....",
    ".....ggwwwwwwwwgg.....",
    "....gggwwwwwwwwggg....",
    "...ggwwwwwwwwwwwwgg...",
    "..dgwwwwwwwwwwwwwwgd..",
    "..dgwwwwwwwwwwwwwwgd..",
    "...ggwwwwwwwwwwwwgg...",
    "....gggwwwwwwwwggg....",
    ".....gggggggggggg.....",
    ".......dggggggd.......",
    "......dggggggggd......",
    "......dggggggggd......",
    "......dggggggggd......",
    ".......dggggggd.......",
    "........dddddd........",
]
let limbUp = ["f.f.", ".ff.", "..ff"]
let limbOut = ["f...", ".fff", "f..."]
let limbDown = ["..ff", ".ff.", "f.f."]

// 날개막을 쫙 편 모습 (활강, 잡혔을 때)
let glideBody = [
    ".........gg......gg.........",
    "........gddg....gddg........",
    "........gggggggggggg........",
    ".......ggkkggggggkkgg.......",
    ".......gkhkkggggkhkkg.......",
    "f......gkkkkgnngkkkkg......f",
    "fdddd...gpggwwwwggpg...ddddf",
    ".deeeddgggwwwwwwwwgggddeeed.",
    ".deeeeeggwwwwwwwwwwggeeeeed.",
    ".deeeeeggwwwwwwwwwwggeeeeed.",
    ".deeeeeggwwwwwwwwwwggeeeeed.",
    ".deeeeeggwwwwwwwwwwggeeeeed.",
    ".deeeeedggwwwwwwwwggdeeeeed.",
    ".deeeeeedgggwwwwgggdeeeeeed.",
    "fddddddddggggggggggddddddddf",
    "f.........gggggggg.........f",
    "...........dggggd...........",
    "..........dggggggd..........",
    "..........dggggggd..........",
    "...........dggggd...........",
    "............dddd............",
]

func pad(_ g: Grid, t: Int, l: Int, r: Int, b: Int) -> Grid {
    let w = (g.map(\.count).max() ?? 0) + l + r
    let empty = [Character](repeating: ".", count: w)
    let rows = g.map { (row: [Character]) -> [Character] in
        [Character](repeating: ".", count: l) + row + [Character](repeating: ".", count: w - l - row.count)
    }
    return Array(repeating: empty, count: t) + rows + Array(repeating: empty, count: b)
}

// 빈 칸에만 찍음 (먼저 찍은 게 위에 보임)
func stamp(_ g: inout Grid, _ s: [String], x: Int, y: Int, mirror: Bool = false) {
    for (dy, row) in s.enumerated() {
        let cs = Array(row)
        for (dx, ch) in cs.enumerated() where ch != "." {
            let px = mirror ? x + cs.count - 1 - dx : x + dx, py = y + dy
            if py >= 0, py < g.count, px >= 0, px < g[py].count, g[py][px] == "." { g[py][px] = ch }
        }
    }
}

// 눈 감기: 눈 하나하나를 지우고 그 자리 아래쪽에 졸린 ‿ 모양을 그림
func closeEyes(_ g: inout Grid) {
    let src = g
    let isEye = { (x: Int, y: Int) in src[y][x] == "k" || src[y][x] == "h" }
    let cols = src[0].indices.filter { x in src.indices.contains { isEye(x, $0) } }
    // 붙어 있는 열끼리 눈 하나
    var eyes: [[Int]] = []
    for x in cols {
        if let last = eyes.last?.last, last == x - 1 { eyes[eyes.count - 1].append(x) } else { eyes.append([x]) }
    }
    for eye in eyes {
        let bottom = eye.flatMap { x in g.indices.filter { isEye(x, $0) } }.max()!
        for x in eye { for y in g.indices where isEye(x, y) { g[y][x] = "g" } }
        for x in eye {
            // 작은 눈은 그냥 한 줄, 큰 눈은 양 끝을 올려서 ‿
            let edge = eye.count >= 4 && (x == eye.first || x == eye.last)
            g[edge ? bottom - 1 : bottom][x] = "k"
        }
    }
}

// 1픽셀 외곽선
func outlined(_ g: Grid) -> Grid {
    var o = g
    for y in g.indices {
        for x in g[y].indices where g[y][x] == "." {
            let around: [(Int, Int)] = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            let n = around.contains { (nx: Int, ny: Int) -> Bool in
                guard ny >= 0, ny < g.count, nx >= 0, nx < g[ny].count else { return false }
                return g[ny][nx] != "."
            }
            if n { o[y][x] = "o" }
        }
    }
    return o
}

// extra: 집 지붕 색처럼 그때그때 바뀌는 색
func image(_ g: Grid, _ extra: [Character: (UInt8, UInt8, UInt8)] = [:]) -> CGImage {
    let h = g.count, w = g[0].count
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            if let (r, gg, b) = extra[g[y][x]] ?? palette[g[y][x]] {
                px[i] = r; px[i + 1] = gg; px[i + 2] = b; px[i + 3] = 255
            } else {
                px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0
            }
        }
    }
    return ctx.makeImage()!
}

func finish(_ g: Grid, sleep: Bool) -> Grid {
    var g = g
    if sleep { closeEyes(&g) }
    return g
}

func climbSprite(frame: Int, sleep: Bool) -> Grid {
    var g: Grid = climbBody.map(Array.init)
    // [왼팔, 오른팔, 왼다리, 오른다리]: 0 가만히, 1/2 대각선끼리 번갈아 뻗으며 기어오름
    let reach: [[Bool]] = [[true, true, false, false], [true, false, false, true], [false, true, true, false]]
    for (i, r) in reach[frame].enumerated() {
        let arm = i < 2, right = i % 2 == 1
        let (s, y): ([String], Int) = arm ? (r ? (limbUp, 7) : (limbOut, 8)) : (r ? (limbOut, 13) : (limbDown, 14))
        stamp(&g, s, x: right ? 18 : 0, y: y, mirror: right)
    }
    return finish(g, sleep: sleep)
}

func sideSprite(frame: Int, sleep: Bool) -> Grid {
    var g: Grid = sideBody.map(Array.init)
    // 다리: 기준 x, 앞(1)/가운데(0)/뒤(-1)
    func leg(_ x: Int, _ s: Int, _ ch: Character) {
        let pts: [(Int, Int)]
        if s == 0 { pts = [(x, 12), (x, 13), (x + 1, 13)] }
        else if s > 0 { pts = [(x + 1, 12), (x + 2, 13), (x + 3, 13)] }
        else { pts = [(x - 1, 12), (x - 2, 13), (x - 1, 13)] }
        for (px, py) in pts where g[py][px] == "." { g[py][px] = ch }
    }
    let s: [Int] = [[0, 0], [1, -1], [-1, 1]][frame]
    leg(17, s[0], "f"); leg(8, s[1], "f")      // 가까운 다리
    leg(15, -s[0], "q"); leg(7, -s[1], "q")    // 먼 쪽 다리
    return finish(g, sleep: sleep)
}

func frontSprite(open: Bool, happy: Bool) -> Grid {
    var g: Grid = frontBody.map(Array.init)
    // 다문 입은 ω, 벌린 입은 코 밑에 한 칸 띄워서 동그랗게
    let mouth: [(Int, Int)] = open ? [(10, 8), (11, 8), (10, 9), (11, 9)] : [(9, 7), (10, 8), (11, 8), (12, 7)]
    for (x, y) in mouth { g[y][x] = open ? "m" : "o" }
    if happy {
        // 눈을 감고 ^^ 웃음
        for y in 4...7 { for x in 4...17 where g[y][x] == "k" || g[y][x] == "h" { g[y][x] = "g" } }
        for (x, y) in [(5, 6), (6, 5), (7, 5), (8, 6), (13, 6), (14, 5), (15, 5), (16, 6)] { g[y][x] = "k" }
    }
    return finish(g, sleep: false)
}

// 턱 괴고 고민 (frame 1은 눈을 가늘게)
func thinkSprite(frame: Int) -> Grid {
    var g: Grid = frontBody.map(Array.init)
    for (x, y) in [(12, 10), (13, 10), (12, 11), (13, 11)] { g[y][x] = "w" }
    for (x, y) in [(12, 8), (13, 8), (12, 9), (13, 9)] { g[y][x] = "f" }
    for (x, y) in [(9, 8), (10, 8)] { g[y][x] = "o" }
    if frame == 1 { for x in 4...17 where g[4][x] == "k" { g[4][x] = "g" } }
    return finish(g, sleep: false)
}

// 도토리를 두 손으로 들고 오물오물 (볼이 빵빵)
func eatSprite(frame: Int) -> Grid {
    var g: Grid = frontBody.map(Array.init)
    for (x, y) in [(8, 10), (9, 10), (12, 10), (13, 10), (8, 11), (9, 11), (12, 11), (13, 11)] { g[y][x] = "w" }
    for y in 6...8 { g[y][3] = "g" }
    let lift = frame == 1 ? 1 : 0
    for (x, y) in [(10, 8), (11, 8)] { g[y - lift][x] = "a" }
    for (x, y) in [(10, 9), (11, 9), (10, 10), (11, 10)] { g[y - lift][x] = "b" }
    for (x, y) in [(9, 9), (12, 9), (9, 10), (12, 10)] { g[y - lift][x] = "f" }
    if frame == 1 {
        for y in 4...7 { for x in 4...17 where g[y][x] == "k" || g[y][x] == "h" { g[y][x] = "g" } }
        for (x, y) in [(5, 6), (6, 5), (7, 5), (8, 6), (13, 6), (14, 5), (15, 5), (16, 6)] { g[y][x] = "k" }
    }
    return finish(g, sleep: false)
}

// 한 손을 번쩍 들고 흔들기 (Claude가 불러요)
func waveSprite(frame: Int) -> Grid {
    var g: Grid = frontBody.map(Array.init)
    for (x, y) in [(8, 10), (9, 10), (8, 11), (9, 11)] { g[y][x] = "w" }
    for (x, y) in [(10, 8), (11, 8), (10, 9), (11, 9)] { g[y][x] = "m" }
    let arm: [(Int, Int)] = frame == 0 ? [(3, 9), (3, 8), (2, 7), (2, 6)] : [(3, 9), (2, 8), (1, 7)]
    let paw: [(Int, Int)] = frame == 0 ? [(1, 4), (2, 4), (1, 5), (2, 5)] : [(0, 5), (1, 5), (0, 6), (1, 6)]
    for (x, y) in arm { g[y][x] = "g" }
    for (x, y) in paw { g[y][x] = "f" }
    return finish(g, sleep: false)
}

// 깜짝 놀라서 털이 쭈뼛, 눈이 동그래짐 (에러!)
func startleSprite() -> Grid {
    var g: Grid = frontBody.map(Array.init)
    // 동그란 눈: 흰자 가운데 작은 눈동자
    for y in 4...7 { for x in 4...17 where g[y][x] == "k" || g[y][x] == "h" { g[y][x] = "h" } }
    for (x, y) in [(6, 6), (7, 6), (14, 6), (15, 6), (6, 5), (14, 5)] { g[y][x] = "k" }
    for (x, y) in [(10, 8), (11, 8), (10, 9), (11, 9)] { g[y][x] = "m" }
    // 테두리 털을 한 칸씩 삐죽삐죽
    let src = g
    for y in stride(from: 3, to: src.count - 1, by: 2) {
        if let l = src[y].firstIndex(where: { $0 != "." }), l > 0 { g[y][l - 1] = "g" }
        if let r = src[y].lastIndex(where: { $0 != "." }), r < src[y].count - 1 { g[y][r + 1] = "g" }
    }
    for x in [7, 10, 11, 14] where g[1][x] == "." { g[1][x] = "g" }
    return finish(g, sleep: false)
}

enum Pose: Hashable {
    case climb(Int, Bool), side(Int, Bool), front(open: Bool, happy: Bool), think(Int), eat(Int), glide, acorn
    case wave(Int), startle, nest, mound, umbrella
    case obj(ObjKind, Int)
}

// 성격에 맞는 머리 장식
enum Accessory: String, CaseIterable {
    case cap, acornHat, nightcap, ribbon, flower

    var art: [String] {
        switch self {
        case .cap: return ["....rrrr......", "...rrrrrr.....", "..rrrRrrrr....", "..rrrrrrrrRRRR"]
        case .acornHat: return [".....a.....", "...aaaaa...", "..aaaaaaa..", ".aaaaaaaaa.", "aaaaaaaaaaa"]
        case .nightcap: return ["...........hh", "......ccc..hh", "....cccccCc..", "..cccccCccc..",
                                ".cccccccc....", "hhhhhhhhhh..."]
        case .ribbon: return ["ppp...ppp", "pppp.pppp", "ppppnpppp", "pppp.pppp", "ppp...ppp"]
        case .flower: return ["..j..", ".jjj.", "jjajj", ".jjjL", "..jL."]
        }
    }
}

// 머리 꼭대기 (장식의 가운데 x, 장식 아랫줄이 놓일 행)
func headTop(_ pose: Pose) -> (x: Int, y: Int)? {
    switch pose {
    case .climb, .front, .think, .eat, .wave, .startle: return (11, 1)
    case .side: return (17, 1)
    case .glide: return (14, 1)
    default: return nil
    }
}

// 장식이 들어갈 만큼 위를 늘리고, 빈 칸에만 찍어서 귀는 장식 앞에 보이게
func wear(_ g: Grid, _ acc: Accessory, at head: (x: Int, y: Int)) -> Grid {
    let art = acc.art
    let h = art.count
    var out = pad(g, t: h, l: 0, r: 0, b: 0)
    let left = head.x - (art.map(\.count).max() ?? 0) / 2
    stamp(&out, art, x: left, y: head.y + 1)
    return out
}

struct SpriteKey: Hashable { let pose: Pose; let acc: Accessory? }

var spriteCache: [SpriteKey: CGImage] = [:]
func sprite(_ pose: Pose, _ acc: Accessory? = nil) -> CGImage {
    let key = SpriteKey(pose: pose, acc: acc)
    if let s = spriteCache[key] { return s }
    var g: Grid
    switch pose {
    case .climb(let f, let sleep): g = climbSprite(frame: f, sleep: sleep)
    case .side(let f, let sleep): g = sideSprite(frame: f, sleep: sleep)
    case .front(let open, let happy): g = frontSprite(open: open, happy: happy)
    case .think(let f): g = thinkSprite(frame: f)
    case .eat(let f): g = eatSprite(frame: f)
    case .glide: g = glideBody.map(Array.init)
    case .acorn: g = acornBody.map(Array.init)
    case .wave(let f): g = waveSprite(frame: f)
    case .startle: g = startleSprite()
    case .nest: g = nestBody.map(Array.init)
    case .mound: g = moundBody.map(Array.init)
    case .umbrella: g = umbrellaBody.map(Array.init)
    case .obj(let k, let n): g = k.art(n).map(Array.init)
    }
    if let acc = acc, let head = headTop(pose) { g = wear(g, acc, at: head) }
    let s = image(outlined(pad(g, t: 1, l: 1, r: 1, b: 1)))
    spriteCache[key] = s
    return s
}

let inkColor = CGColor(red: 78 / 255, green: 58 / 255, blue: 50 / 255, alpha: 1)
let inkNS = NSColor(cgColor: inkColor)!

final class PetView: NSView {
    let sq: Squirrel
    var scale: CGFloat = 1
    var background: NSColor?
    var dragging = false
    private var moved = false
    private var lastDrag: (CGPoint, TimeInterval)?
    private var dragVel = CGVector.zero

    init(frame: NSRect, squirrel: Squirrel) {
        self.sq = squirrel
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        dragging = true; moved = false
        lastDrag = nil; dragVel = .zero
    }

    override func mouseDragged(with e: NSEvent) {
        let p = NSEvent.mouseLocation
        if let (lp, lt) = lastDrag, e.timestamp > lt {
            let dt = CGFloat(e.timestamp - lt)
            let v = CGVector(dx: (p.x - lp.x) / dt, dy: (p.y - lp.y) / dt)
            dragVel = CGVector(dx: dragVel.dx * 0.5 + v.dx * 0.5, dy: dragVel.dy * 0.5 + v.dy * 0.5)
        }
        lastDrag = (p, e.timestamp)
        moved = true
        sq.grab(at: p)
    }

    override func mouseUp(with e: NSEvent) {
        dragging = false
        guard moved else { return sq.poke() }
        // 놓기 직전에 멈춰 있었으면 그냥 떨어뜨림
        var v = dragVel
        if let (_, lt) = lastDrag, e.timestamp - lt > 0.08 { v = .zero }
        let s = hypot(v.dx, v.dy), maxS: CGFloat = 2400
        if s > maxS { v = CGVector(dx: v.dx / s * maxS, dy: v.dy / s * maxS) }
        sq.release(at: NSEvent.mouseLocation, vel: v)
    }

    // 지금 그릴 포즈
    var pose: Pose {
        switch sq.mode {
        case .held: return .glide
        case .air where sq.flipTime > 0: return .front(open: true, happy: true)
        case .air: return sq.gliding ? .glide : .side(sq.frame, false)
        case _ where sq.act != .none:
            switch sq.act {
            case .think: return .think(Int(sq.time / 1.6) % 3 == 2 ? 1 : 0)
            // 오래 걸리면 고민하다가 도토리 까먹다가
            case .wait: return Int(sq.time / 3) % 2 == 0 ? .eat(Int(sq.time * 5) % 2) : .think(0)
            case .eat: return .eat(Int(sq.time * 5) % 2)
            case .dig: return .side(Int(sq.time * 10) % 2 + 1, false)
            case .done, .cheer, .greet: return .front(open: true, happy: true)
            case .attention: return .wave(Int(sq.time * 5) % 2)
            case .startle: return .startle
            default: return .front(open: sq.mouthOpen, happy: sq.happyEyes)
            }
        case .wall: return .climb(sq.frame, sq.sleeping)
        case .floor: return .side(sq.frame, sq.sleeping)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.clear(bounds)
        if let bg = background { c.setFillColor(bg.cgColor); c.fill(bounds) }
        c.scaleBy(x: scale, y: scale)
        c.interpolationQuality = .none
        c.setShouldAntialias(false)

        let pose = self.pose
        let img = sprite(pose, sq.personality.accessory)
        let w = CGFloat(img.width) * P, h = CGFloat(img.height) * P
        // 바닥 위에 서 있으면 발이 y=8, 벽이나 손에 있으면 창 가운데
        let grounded = sq.mode == .floor || sq.mode == .air
        let baseY: CGFloat = grounded ? 4 : (W / 2 - h / 2).rounded()
        func drawBody() -> CGPoint {
            var anchor: CGPoint
            c.saveGState()
            switch pose {
            case .climb:
                // 90도 단위로만 돌려서 픽셀이 깨지지 않게
                let q = (sq.heading / up).rounded()
                c.translateBy(x: W / 2, y: W / 2)
                c.rotate(by: (q - 1) * up)
                c.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                anchor = CGPoint(x: W / 2, y: W / 2 + 52)
            case .side:
                c.translateBy(x: W / 2, y: 0)
                c.scaleBy(x: sq.dir, y: 1)
                c.draw(img, in: CGRect(x: -52, y: baseY, width: w, height: h))
                anchor = CGPoint(x: W / 2 + sq.dir * 28, y: baseY + h + 2)
            case .front where sq.flipTime > 0:
                // 공중제비: 90도씩 한 바퀴
                let q = CGFloat(Int((0.7 - sq.flipTime) / 0.7 * 4) % 4)
                c.translateBy(x: W / 2 - 46 + w / 2, y: baseY + h / 2)
                c.rotate(by: -q * up)
                c.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                anchor = CGPoint(x: W / 2 - 4, y: baseY + h + 6)
            case .front, .think, .eat, .wave, .startle:
                // 노래 박자에 맞춰 통통, 기쁘면 폴짝, 놀라면 부들부들
                let shake: CGFloat = sq.act == .startle ? (Int(sq.time * 30) % 2 == 0 ? P : -P) : 0
                c.draw(img, in: CGRect(x: W / 2 - 46 + shake, y: baseY + sq.bob, width: w, height: h))
                anchor = CGPoint(x: W / 2 - 4, y: baseY + h + 6)
            case .glide:
                let wiggle: CGFloat = sq.mode == .held && Int(sq.time * 8) % 2 == 0 ? P : 0
                c.draw(img, in: CGRect(x: W / 2 - w / 2, y: baseY + wiggle, width: w, height: h))
                anchor = CGPoint(x: W / 2, y: baseY + h + 2)
            default:
                anchor = .zero
            }
            c.restoreGState()
            return anchor
        }
        var anchor = drawBody()

        if sq.act == .dig { drawDirt(c) }
        if showUmbrella {
            // 머리 옆 뒤쪽으로 우산을 들고, 몸을 한 번 더 그려서 손잡이가 머리 뒤로 숨게
            let u = sprite(.umbrella)
            let uw = CGFloat(u.width) * P, uh = CGFloat(u.height) * P
            var cx = anchor.x + 14
            if case .side = pose { cx = anchor.x - sq.dir * 14 }
            c.draw(u, in: CGRect(x: (cx - uw / 2).rounded(), y: anchor.y - 22, width: uw, height: uh))
            _ = drawBody()
            anchor.y += uh - 22
        }

        if sq.sleeping { drawFloating(c, "z", at: anchor, sizes: 9...17) }
        let side = CGPoint(x: anchor.x + 22, y: anchor.y - 10)
        switch sq.act {
        case .sing, .harmony: drawFloating(c, "♪", at: side, sizes: 11...17)
        case .think, .wait: drawFloating(c, "?", at: side, sizes: 10...16)
        case .attention, .startle: drawFloating(c, "!", at: side, sizes: 12...18)
        case .done, .cheer: drawFloating(c, "♥", at: side, sizes: 10...16)
        case .greet: drawFloating(c, "☀", at: side, sizes: 10...16)
        default: if sq.happyTime > 0 { drawFloating(c, "♥", at: side, sizes: 10...16) }
        }
        if let text = sq.bubble ?? sq.actText { drawBubble(c, text, at: anchor) }
    }

    // 비나 눈이 오면 땅 위에서는 우산을 씀
    var showUmbrella: Bool {
        weatherReact && world.weather != .clear && sq.mode == .floor && !sq.nested
    }

    // 땅 팔 때 뒤로 튀는 흙
    func drawDirt(_ c: CGContext) {
        c.setFillColor(CGColor(red: 156 / 255, green: 118 / 255, blue: 84 / 255, alpha: 1))
        for i in 0..<5 {
            let t = (sq.time * 2.2 + CGFloat(i) / 5).truncatingRemainder(dividingBy: 1)
            let x = W / 2 - sq.dir * (10 + t * 46)
            let y = 6 + sin(t * .pi) * 30
            c.fill(CGRect(x: x.rounded(), y: y.rounded(), width: P, height: P))
        }
    }

    // 머리 위로 떠오르는 Zzz, ♪
    func drawFloating(_ c: CGContext, _ s: String, at a: CGPoint, sizes: ClosedRange<CGFloat>) {
        for i in 0..<3 {
            let t = (sq.time * 0.6 + CGFloat(i) / 3).truncatingRemainder(dividingBy: 1)
            let font = NSFont.boldSystemFont(ofSize: sizes.lowerBound + t * (sizes.upperBound - sizes.lowerBound))
            let color = inkNS.withAlphaComponent(1 - t * t)
            let p = CGPoint(x: a.x + 6 + t * 18 + sin(t * 9) * 3, y: a.y - 14 + t * 30)
            (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
        }
    }

    // 픽셀 느낌의 말풍선 (길면 여러 줄)
    func drawBubble(_ c: CGContext, _ text: String, at a: CGPoint) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12),
                                                    .foregroundColor: inkNS, .paragraphStyle: style]
        let maxText = W - 26
        let size = (text as NSString).boundingRect(with: CGSize(width: maxText, height: 200),
                                                   options: .usesLineFragmentOrigin, attributes: attrs).size
        let bw = (size.width + 14).rounded(.up), bh = (size.height + 6).rounded(.up)
        let x = min(max((a.x - bw / 2).rounded(), 2), W - bw - 2)
        let y = min(a.y + 4, W - bh - 2)

        func box(_ inset: CGFloat, _ color: CGColor) {
            c.setFillColor(color)
            c.fill(CGRect(x: x + 2 + inset, y: y + inset, width: bw - 4 - inset * 2, height: bh - inset * 2))
            c.fill(CGRect(x: x + inset, y: y + 2 + inset, width: bw - inset * 2, height: bh - 4 - inset * 2))
        }
        box(0, inkColor)
        box(2, .white)
        let tx = min(max(a.x, x + 8), x + bw - 8)
        c.setFillColor(inkColor)
        c.fill(CGRect(x: tx - 4, y: y - 2, width: 2, height: 2))
        c.fill(CGRect(x: tx + 2, y: y - 2, width: 2, height: 2))
        c.fill(CGRect(x: tx - 2, y: y - 4, width: 4, height: 2))
        c.setFillColor(.white)
        c.fill(CGRect(x: tx - 2, y: y - 2, width: 4, height: 4))
        (text as NSString).draw(in: CGRect(x: x + 7, y: y + 3, width: bw - 14, height: size.height + 1),
                                withAttributes: attrs)
    }
}

// MARK: - 창 / 앱

final class SpriteView: NSView {
    let pose: Pose
    init(_ pose: Pose, size: NSSize) {
        self.pose = pose
        super.init(frame: NSRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.clear(bounds)
        c.interpolationQuality = .none
        let img = sprite(pose)
        c.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(img.width) * P, height: CGFloat(img.height) * P))
    }
}

// 바탕화면에 놓이는 작은 그림 (도토리, 흙더미). pos는 바닥에 닿는 아래 가운데
class Prop {
    var pos: CGPoint
    let window: NSWindow
    let size: NSSize

    init(_ pose: Pose, at p: CGPoint, show: Bool = true) {
        pos = p
        let img = sprite(pose)
        size = NSSize(width: CGFloat(img.width) * P, height: CGFloat(img.height) * P)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = petLevel()
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = SpriteView(pose, size: size)
        place()
        if show { window.orderFrontRegardless() }
    }

    func place() {
        window.setFrameOrigin(NSPoint(x: pos.x.rounded() - size.width / 2, y: pos.y.rounded() - 4))
    }
}

// 화면 바닥 높이 (x가 속한 화면)
func groundY(at x: CGFloat) -> CGFloat {
    let s = NSScreen.screens.first { $0.frame.minX <= x && x < $0.frame.maxX } ?? NSScreen.screens[0]
    return s.visibleFrame.minY
}

// 하늘에서 떨어지는 도토리
final class Acorn: Prop {
    var vy: CGFloat = 0
    var landed = false
    weak var into: MapObj?      // 사료통 위로 떨어지는 도토리
    var absorbed = false

    init(at p: CGPoint) { super.init(.acorn, at: p) }

    func tick(_ dt: CGFloat) {
        if !landed {
            vy -= gravity * dt
            pos.y += vy * dt
            if let f = into, pos.y <= f.frame.maxY - 8 { absorbed = true }
            let ground = screenBounds(for: pos).minY
            if pos.y <= ground {
                pos.y = ground
                if -vy > 300 { vy = -vy * 0.35 } else { landed = true; vy = 0 }
            }
        }
        place()
    }
}

// MARK: - 다람쥐 집 (모양, 지붕 색, 장식을 고를 수 있고 끌어서 옮김)

enum HouseStyle: String, CaseIterable {
    case cabin, mushroom, acorn, nest

    var title: String {
        switch self {
        case .cabin: return "나무 오두막"
        case .mushroom: return "버섯집"
        case .acorn: return "도토리집"
        case .nest: return "둥지"
        }
    }

    // X, Y는 고른 지붕 색으로 칠해짐
    var art: [String] {
        switch self {
        case .cabin: return [
            "..............XX..........VV..",
            "............XXXXXX........VV..",
            "..........XXXXXXXXXX......VV..",
            "........XXXXXXXXXXXXXX....VV..",
            "......XXXXXXXXXXXXXXXXXX..VV..",
            "....XXXXXXXXXXXXXXXXXXXXXXVV..",
            "..XXXXXXXXXXXXXXXXXXXXXXXXXXX.",
            "YYYYYYYYYYYYYYYYYYYYYYYYYYYYYY",
            "...WWWWWWWWWWWWWWWWWWWWWWWW...",
            "...VVVVVVVVVVVVVVVVVVVVVVVV...",
            "...WWWooooooWWWWWWWWWWWWWWW...",
            "...VVVoGGoGoVVVVVVaaaaVVVVV...",
            "...WWWoGGoGoWWWWWaDDDDaWWWW...",
            "...VVVooooooVVVVaDDDDDDaVVV...",
            "...WWWoGGoGoWWWWaDDDDDDaWWW...",
            "...VVVoGGoGoVVVVaDDDDjDaVVV...",
            "...WWWooooooWWWWaDDDDDDaWWW...",
            "...VVVVVVVVVVVVVaDDDDDDaVVV...",
            "...WWWWWWWWWWWWWaDDDDDDaWWW...",
            "..VVVVVVVVVVVVVVaDDDDDDaVVVV..",
        ]
        case .mushroom: return [
            "...........XXXXXXXX...........",
            "........XXXXXXXXXXXXXX........",
            "......XXXXSSXXXXXXXXXXXX......",
            "....XXXXXSSSSXXXXXXXSSXXXX....",
            "...XXXXXXXSSXXXXXXXSSSSXXXX...",
            "..XXXSSXXXXXXXXXXXXXSSXXXXXX..",
            ".XXXSSSSXXXXXXSSXXXXXXXXXSSXX.",
            ".XXXXSSXXXXXXSSSSXXXXXXXSSSSX.",
            "XXXXXXXXXXXXXXSSXXXXXXXXXSSXXX",
            "YYYYYYYYYYYYYYYYYYYYYYYYYYYYYY",
            ".......ssssssssssssssss.......",
            "......SSSSSSSSSSSSSSSSSS......",
            "......SSoooSSSSSSaaaaSSS......",
            "......SSoGoSSSSSaDDDDaSS......",
            "......SSoooSSSSaDDDDDDaS......",
            "......SSSSSSSSSaDDDDjDaS......",
            "......SSSSSSSSSaDDDDDDaS......",
            "......SSSSSSSSSaDDDDDDaS......",
            ".....SSSSSSSSSSaDDDDDDaSS.....",
            "...KLLKLLLKLLLLaDDDDDDaLLKL...",
        ]
        case .acorn: return [
            ".............aa.............",
            ".............aa.............",
            "..........XXXXXXXX..........",
            "........XXYXXYXXYXXX........",
            "......XXYXXYXXYXXYXXXX......",
            "....XXXXXYXXYXXYXXYXXXXX....",
            "...XYXXYXXYXXYXXYXXYXXYXX...",
            "..YYYYYYYYYYYYYYYYYYYYYYYY..",
            "...bbbbbbbbbbbbbbbbbbbbbb...",
            "...blllbbbbbbbbbbbbbbbbbb...",
            "...bllbbbbbbbbbbbbbbbbbbb...",
            "...blbbbooooobbbbbbbbbbbb...",
            "...bbbbboGoGobbbbaaaabbbb...",
            "....bbbbooooobbbaDDDDabb....",
            "....bbbboGoGobbaDDDDDDab....",
            ".....bbbooooobbaDDDDjDa.....",
            "......bbbbbbbbbaDDDDDDa.....",
            ".......bbbbbbbbaDDDDDDa.....",
            "........bbbbbbbaDDDDDDa.....",
        ]
        case .nest: return nestBody
        }
    }

    // 문 가운데, 지붕 꼭대기, 랜턴 자리 (그림 기준 열/행)
    var door: Int { [.cabin: 19, .mushroom: 18, .acorn: 18, .nest: 16][self]! }
    var peak: Int { [.cabin: 14, .mushroom: 14, .acorn: 13, .nest: 3][self]! }
    var lantern: (x: Int, y: Int)? {
        switch self {
        case .cabin: return (13, 11)
        case .mushroom: return (11, 13)
        case .acorn: return (12, 12)
        case .nest: return nil
        }
    }
}

enum Decor: String, CaseIterable {
    case flag, pot, mailbox, lantern, fence

    var title: String {
        switch self {
        case .flag: return "깃발"
        case .pot: return "화분"
        case .mailbox: return "우체통"
        case .lantern: return "랜턴"
        case .fence: return "울타리"
        }
    }

    var art: [String] {
        switch self {
        case .flag: return ["or", "orrr", "orrrr", "orr", "o", "o", "o"]
        case .pot: return ["p.j.p", ".LLL.", "PPPPP", ".PPP.", ".PPP."]
        case .mailbox: return ["rrrr", "rrrr", "rrRr", ".o..", ".o..", ".o.."]
        case .lantern: return ["o", ".oo", "ojjo", "ojjo", ".oo"]
        case .fence: return ["W.W.W", "WWWWW", "W.W.W", "WWWWW", "W.W.W"]
        }
    }
}

let roofColors: [(name: String, rgb: (UInt8, UInt8, UInt8))] = [
    ("빨강", (222, 92, 84)), ("파랑", (92, 140, 214)), ("초록", (98, 170, 98)),
    ("노랑", (236, 186, 72)), ("보라", (160, 112, 200)), ("분홍", (238, 140, 170)),
]

final class HouseView: NSView {
    var image: CGImage?
    var sleepers = 0
    var time: CGFloat = 0
    var chimney = CGPoint.zero
    var onKnock: (() -> Void)?
    var onMoved: (() -> Void)?
    var menuMaker: (() -> NSMenu)?
    var dragging = false
    private var moved = false
    private var grab = CGPoint.zero

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext, let img = image else { return }
        c.clear(bounds)
        c.interpolationQuality = .none
        c.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(img.width) * P, height: CGFloat(img.height) * P))
        // 안에서 자고 있으면 Zzz
        guard sleepers > 0 else { return }
        for i in 0..<3 {
            let t = (time * 0.5 + CGFloat(i) / 3).truncatingRemainder(dividingBy: 1)
            let font = NSFont.boldSystemFont(ofSize: 9 + t * 8)
            let p = CGPoint(x: chimney.x + t * 16 + sin(t * 9) * 3, y: chimney.y + t * 28)
            ("z" as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: inkNS.withAlphaComponent(1 - t * t)])
        }
    }

    // 끌면 옮기고, 그냥 누르면 노크
    override func mouseDown(with e: NSEvent) {
        dragging = true
        moved = false
        let m = NSEvent.mouseLocation, o = window!.frame.origin
        grab = CGPoint(x: m.x - o.x, y: m.y - o.y)
    }

    override func mouseDragged(with e: NSEvent) {
        let m = NSEvent.mouseLocation
        moved = true
        window?.setFrameOrigin(NSPoint(x: m.x - grab.x, y: m.y - grab.y))
    }

    override func mouseUp(with e: NSEvent) {
        dragging = false
        if moved { onMoved?() } else { onKnock?() }
    }

    override func rightMouseDown(with e: NSEvent) {
        if let menu = menuMaker?() { NSMenu.popUpContextMenu(menu, with: e, for: self) }
    }
}

final class House {
    var style: HouseStyle
    var color: Int
    var decor: Set<Decor>
    var shown: Bool
    var x: CGFloat               // 집 그림 가운데의 화면 x
    let window: NSWindow
    let view = HouseView()
    private var imageSize = CGSize.zero
    private var lit = false
    private let d = UserDefaults.standard
    // 그림 양옆과 위에 장식 자리
    private let sideRoom = 12, topRoom = 8

    init() {
        style = HouseStyle(rawValue: d.string(forKey: "houseStyle") ?? "") ?? .cabin
        color = min(max(d.integer(forKey: "houseColor"), 0), roofColors.count - 1)
        if let saved = d.array(forKey: "houseDecor") as? [String] {
            decor = Set(saved.compactMap(Decor.init(rawValue:)))
        } else {
            decor = [.flag, .pot]
        }
        shown = d.object(forKey: "houseShown") == nil ? true : d.bool(forKey: "houseShown")
        let b = NSScreen.screens[0].visibleFrame
        var hx = d.object(forKey: "houseX") == nil ? b.minX + 170 : CGFloat(d.double(forKey: "houseX"))
        // 화면 구성이 바뀌어서 집이 화면 밖이면 다시 데려옴
        if !NSScreen.screens.contains(where: { $0.frame.minX + 60 < hx && hx < $0.frame.maxX - 60 }) { hx = b.minX + 170 }
        x = hx

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = petLevel()
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = view
        view.onMoved = { [unowned self] in
            // 놓은 자리 아래 바닥에 내려앉음
            self.x = self.window.frame.minX + self.imageSize.width / 2
            self.place()
            self.save()
        }
        rebuild()
        if shown { window.orderFrontRegardless() }
    }

    // 문 앞 (다람쥐가 걸어갈 곳)
    var doorX: CGFloat {
        x - imageSize.width / 2 + CGFloat(sideRoom + style.door + 1) * P
    }

    func save() {
        d.set(style.rawValue, forKey: "houseStyle")
        d.set(color, forKey: "houseColor")
        d.set(decor.map(\.rawValue), forKey: "houseDecor")
        d.set(shown, forKey: "houseShown")
        d.set(Double(x), forKey: "houseX")
    }

    func place() {
        window.setFrameOrigin(NSPoint(x: (x - imageSize.width / 2).rounded(), y: groundY(at: x) - 4))
    }

    // 고른 모양, 색, 장식으로 그림을 다시 만듦
    func rebuild() {
        let art = style.art
        let aw = art.map(\.count).max() ?? 0, ah = art.count
        let w = aw + sideRoom * 2, h = ah + topRoom
        var g: Grid = Array(repeating: [Character](repeating: ".", count: w), count: h)
        // 앞에 보여야 하는 것부터 찍음 (stamp는 빈 칸에만 찍힘)
        func put(_ dc: Decor, x: Int, bottom: Int) {
            guard decor.contains(dc) else { return }
            stamp(&g, dc.art, x: x, y: bottom - dc.art.count + 1)
        }
        if let l = style.lantern { put(.lantern, x: sideRoom + l.x, bottom: topRoom + l.y + 4) }
        put(.pot, x: 6, bottom: h - 1)
        put(.mailbox, x: w - 10, bottom: h - 1)
        put(.fence, x: 0, bottom: h - 1)
        put(.fence, x: w - 5, bottom: h - 1)
        // 깃발은 지붕 꼭대기 위에
        let top = art.firstIndex { Array($0)[style.peak] != "." } ?? 0
        put(.flag, x: sideRoom + style.peak, bottom: topRoom + top - 1)
        stamp(&g, art, x: sideRoom, y: topRoom)

        let roof = roofColors[color].rgb
        let dark = (UInt8(Double(roof.0) * 0.75), UInt8(Double(roof.1) * 0.75), UInt8(Double(roof.2) * 0.75))
        var extra: [Character: (UInt8, UInt8, UInt8)] = ["X": roof, "Y": dark]
        if lit { extra["G"] = (255, 216, 122) }
        let img = image(outlined(pad(g, t: 1, l: 1, r: 1, b: 1)), extra)
        imageSize = CGSize(width: CGFloat(img.width) * P, height: CGFloat(img.height) * P)
        view.image = img
        view.chimney = CGPoint(x: imageSize.width / 2 + 30, y: imageSize.height - CGFloat(topRoom) * P)
        // 위쪽은 Zzz 자리
        let size = NSSize(width: imageSize.width, height: imageSize.height + 44)
        window.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        place()
        view.needsDisplay = true
    }

    // 그림이 있는 자리 (마우스가 여기 있을 때만 클릭을 받음)
    var body: CGRect {
        let art = style.art
        let aw = CGFloat(art.map(\.count).max() ?? 0) * P, ah = CGFloat(art.count) * P
        return CGRect(x: x - aw / 2, y: window.frame.minY, width: aw, height: ah)
    }

    func tick(_ dt: CGFloat, sleepers: Int, anyoneHome: Bool) {
        view.time += dt
        if anyoneHome != lit {
            lit = anyoneHome
            rebuild()
        }
        if sleepers != view.sleepers || sleepers > 0 {
            view.sleepers = sleepers
            view.needsDisplay = true
        }
        window.ignoresMouseEvents = !view.dragging && !body.contains(NSEvent.mouseLocation)
    }
}

// MARK: - 맵 꾸미기: 발판과 기능 오브젝트

enum ObjKind: String, CaseIterable {
    case plank, longPlank, feeder, trampoline, cushion, flowerPot, lamp

    var title: String {
        switch self {
        case .plank: return "발판"
        case .longPlank: return "긴 발판"
        case .feeder: return "사료통"
        case .trampoline: return "트램펄린"
        case .cushion: return "방석"
        case .flowerPot: return "화분"
        case .lamp: return "가로등"
        }
    }

    var hint: String {
        switch self {
        case .plank, .longPlank: return "다람쥐가 뛰어 올라가 걸어 다녀요"
        case .feeder: return "도토리가 2분마다 하나씩 쌓이고, 배고프면 와서 먹어요"
        case .trampoline: return "밟으면 높이 튀어 올라 활강해요"
        case .cushion: return "와서 낮잠을 자요"
        case .flowerPot, .lamp: return "꾸미기용 (가로등은 밤에 켜져요)"
        }
    }

    var isPlatform: Bool { self == .plank || self == .longPlank }

    // n: 사료통이면 쌓인 도토리 수, 가로등이면 불 켜짐(1)
    func art(_ n: Int) -> [String] {
        switch self {
        case .plank: return plankArt(24)
        case .longPlank: return plankArt(40)
        case .feeder:
            var g = feederBody.map(Array.init)
            // 아래층부터 도토리가 쌓임
            for (x, y) in feederSlots.prefix(n) {
                g[y - 1][x] = "a"; g[y - 1][x + 1] = "a"
                g[y][x] = "b"; g[y][x + 1] = "l"
            }
            return g.map { String($0) }
        case .trampoline: return ["cccccccccccccccc", "CCCCCCCCCCCCCCCC", ".o............o.", "oo............oo"]
        case .cushion: return ["..pppppppppp..", ".pppppppppppp.", "pppppnppppnppp", ".nnnnnnnnnnnn."]
        case .flowerPot: return [".p...j.", "pjp.jaj", ".pL..jL", "..LLLL.", ".PPPPP.", ".PPPPP.", "..PPP.."]
        case .lamp:
            let light = n == 1 ? "j" : "S"
            return ["ooooo", "o" + String(repeating: light, count: 3) + "o", "o" + String(repeating: light, count: 3) + "o",
                    "ooooo"] + Array(repeating: "..o..", count: 10) + [".ooo."]
        }
    }
}

func plankArt(_ w: Int) -> [String] {
    (0..<3).map { r in String((0..<w).map { x -> Character in r == 2 || (r == 1 && x % 9 == 1) ? "V" : "W" }) }
}

let feederCapacity = 7
let feederBody = [
    "....rrrr....",
    "..rrrrrrrr..",
    "rrrrrrrrrrrr",
    "mmmmmmmmmmmm",
    ".VDDDDDDDDV.",
    ".VDDDDDDDDV.",
    ".VDDDDDDDDV.",
    ".VDDDDDDDDV.",
    ".VWWWWWWWWV.",
    ".VVVVVVVVVV.",
    ".V........V.",
    ".V........V.",
]
let feederSlots = [(2, 7), (4, 7), (6, 7), (8, 7), (3, 5), (5, 5), (7, 5)]

final class ObjView: NSView {
    weak var obj: MapObj?
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext, let obj = obj else { return }
        c.clear(bounds)
        c.interpolationQuality = .none
        let img = sprite(obj.pose)
        c.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(img.width) * P, height: CGFloat(img.height) * P))
    }

    // 맵 꾸미기 중에만: 끌어서 옮기기, 우클릭(또는 지우개)으로 지우기
    private var grab = CGPoint.zero
    override func mouseDown(with e: NSEvent) {
        guard let obj = obj else { return }
        if mapEditor.erasing {
            mapEditor.onErase?(obj)
            return
        }
        let m = NSEvent.mouseLocation
        grab = CGPoint(x: m.x - obj.pos.x, y: m.y - obj.pos.y)
        mapEditor.focus = obj
    }
    override func mouseDragged(with e: NSEvent) {
        guard let obj = obj, mapEditor.focus === obj else { return }
        let m = NSEvent.mouseLocation
        obj.pos = CGPoint(x: (m.x - grab.x).rounded(), y: (m.y - grab.y).rounded())
        obj.place()
    }
    override func mouseUp(with e: NSEvent) {
        guard let obj = obj, mapEditor.focus === obj else { return }
        mapEditor.focus = nil
        obj.pos = snapped(obj.kind, obj.pos)
        obj.place()
        mapEditor.onChange?()
    }
    override func rightMouseDown(with e: NSEvent) {
        if let obj = obj { mapEditor.onErase?(obj) }
    }
}

final class MapObj {
    private static var nextId = -1
    let id: Int
    let kind: ObjKind
    var pos: CGPoint            // 아래 가운데 (발판이면 밑면, 나머지는 놓인 바닥)
    var acorns: Int { didSet { if acorns != oldValue { redraw() } } }
    var lit = false { didSet { if lit != oldValue { redraw() } } }
    let window: NSWindow
    let view = ObjView()

    init(_ kind: ObjKind, at p: CGPoint, acorns: Int = 0) {
        id = MapObj.nextId
        MapObj.nextId -= 1
        self.kind = kind
        pos = p
        self.acorns = acorns
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = !editing
        window.level = petLevel()
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = view
        view.obj = self
        redraw()
    }

    var pose: Pose { .obj(kind, kind == .feeder ? acorns : kind == .lamp ? (lit ? 1 : 0) : 0) }

    // 테두리를 뺀 그림 크기
    var artSize: CGSize {
        let a = kind.art(0)
        return CGSize(width: CGFloat(a.map(\.count).max() ?? 0) * P, height: CGFloat(a.count) * P)
    }

    var frame: CGRect { CGRect(x: pos.x - artSize.width / 2, y: pos.y, width: artSize.width, height: artSize.height) }

    func redraw() {
        let img = sprite(pose)
        let size = NSSize(width: CGFloat(img.width) * P, height: CGFloat(img.height) * P)
        window.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        place()
        view.needsDisplay = true
    }

    func place() {
        window.setFrameOrigin(NSPoint(x: (pos.x - artSize.width / 2 - P).rounded(), y: pos.y - P))
    }
}

// 놓은 오브젝트들 (발판은 customWins로 창 목록에 끼워 넣음)
var mapObjs: [MapObj] = []

// 다람쥐가 서 있을 수 있는 면: 주 화면 바닥(id nil)과 발판들
struct Plat {
    let id: Int?
    let minX: CGFloat, maxX: CGFloat, y: CGFloat
}

func floorPlat() -> Plat {
    let b = NSScreen.screens[0].visibleFrame
    return Plat(id: nil, minX: b.minX + 80, maxX: b.maxX - 80, y: b.minY)
}

func plats(_ extra: [Plat] = []) -> [Plat] {
    [floorPlat()] + mapObjs.filter { $0.kind.isPlatform }.map {
        Plat(id: $0.id, minX: $0.frame.minX, maxX: $0.frame.maxX, y: $0.frame.maxY)
    } + extra
}

// A에서 B로 한 번에 뛸 수 있으면 도약 지점과 점프 (B가 너무 높거나 멀면 nil)
func edge(_ a: Plat, _ b: Plat) -> (take: CGFloat, jump: Jump)? {
    let aL = a.minX + 10, aR = a.maxX - 10, bL = b.minX + 14, bR = b.maxX - 14
    guard aL <= aR, bL <= bR else { return nil }
    let take = min(max((bL + bR) / 2, aL), aR)
    let side: CGFloat = (bL + bR) / 2 >= take ? 40 : -40
    for lx in [min(max(take, bL), bR), min(max(take + side, bL), bR), (bL + bR) / 2] {
        let from = CGPoint(x: take, y: a.y), to = CGPoint(x: lx, y: b.y)
        if let arc = jumpArc(from: from, to: to) {
            return (take, Jump(from: from, v: arc.v, T: arc.T, surface: b.id))
        }
    }
    return nil
}

// a에서 b까지 발판을 건너건너 가는 길의 첫 점프 (못 가면 nil)
func firstHop(from a: Int?, to b: Int?, extra: [Plat] = []) -> (take: CGFloat, jump: Jump)? {
    let ps = plats(extra)
    guard let s = ps.firstIndex(where: { $0.id == a }), let t = ps.firstIndex(where: { $0.id == b }), s != t
    else { return nil }
    var prev: [Int: Int] = [:]
    var queue = [s]
    var seen: Set<Int> = [s]
    while !queue.isEmpty {
        let u = queue.removeFirst()
        if u == t { break }
        for v in ps.indices where !seen.contains(v) && edge(ps[u], ps[v]) != nil {
            seen.insert(v)
            prev[v] = u
            queue.append(v)
        }
    }
    guard seen.contains(t) else { return nil }
    var v = t
    while prev[v] != s { v = prev[v]! }
    return edge(ps[s], ps[v])
}

func reachable(from a: Int?, to b: Int?, extra: [Plat] = []) -> Bool {
    a == b || firstHop(from: a, to: b, extra: extra) != nil
}

// x 아래로 가장 가까운 면 (발판 위면 그 발판, 아니면 바닥)
func surfaceBelow(x: CGFloat, y: CGFloat) -> (y: CGFloat, id: Int?) {
    var best = (y: groundY(at: x), id: Int?.none)
    for p in plats().dropFirst() where p.minX + 4 <= x && x <= p.maxX - 4 && p.y <= y + 6 && p.y > best.y {
        best = (p.y, p.id)
    }
    return best
}

// 오브젝트가 놓인 면
func objPlat(_ o: MapObj) -> Int? {
    if o.kind.isPlatform { return o.id }
    return surfaceBelow(x: o.pos.x, y: o.pos.y).id
}

// 맵 꾸미기에서 놓을 자리: 발판은 마우스 자리 그대로, 나머지는 아래 면에 내려놓음
func snapped(_ k: ObjKind, _ p: CGPoint) -> CGPoint {
    if k.isPlatform {
        return CGPoint(x: p.x.rounded(), y: max(p.y, groundY(at: p.x) + 40).rounded())
    }
    return CGPoint(x: p.x.rounded(), y: surfaceBelow(x: p.x, y: p.y + 4).y)
}

// MARK: - 맵 꾸미기 화면 (팔레트 + 잔상 미리보기)

final class OverlayView: NSView {
    var origin = CGPoint.zero       // 이 뷰 왼쪽 아래의 화면 좌표
    var mouse: CGPoint?             // 스냅샷용으로 직접 줄 수도 있음

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        guard let k = mapEditor.tool else { return }
        mapEditor.onPlace?(k, snapped(k, NSEvent.mouseLocation))
    }
    override func rightMouseDown(with e: NSEvent) { mapEditor.select(nil) }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.clear(bounds)
        c.setFillColor(CGColor(red: 0.2, green: 0.35, blue: 0.5, alpha: 0.06))
        c.fill(bounds)
        c.interpolationQuality = .none
        let m = mouse ?? NSEvent.mouseLocation

        // 지금 보고 있는 면: 끌고 있는 발판, 아니면 놓으려는 발판 유령
        var focus: Plat?
        var label: (CGPoint, Bool)?
        if let o = mapEditor.focus {
            if o.kind.isPlatform {
                focus = Plat(id: o.id, minX: o.frame.minX, maxX: o.frame.maxX, y: o.frame.maxY)
            } else {
                let s = surfaceBelow(x: o.pos.x, y: o.pos.y + 4)
                label = (CGPoint(x: o.pos.x, y: o.frame.maxY + 8), reachable(from: nil, to: s.id))
            }
        } else if let k = mapEditor.tool {
            let p = snapped(k, m)
            let img = sprite(.obj(k, k == .feeder ? 3 : 0))
            let w = CGFloat(img.width) * P, h = CGFloat(img.height) * P
            c.saveGState()
            c.setAlpha(0.55)
            c.draw(img, in: CGRect(x: p.x - origin.x - w / 2, y: p.y - origin.y - P, width: w, height: h))
            c.restoreGState()
            if k.isPlatform {
                let size = CGFloat(k.art(0)[0].count) * P
                focus = Plat(id: 0, minX: p.x - size / 2, maxX: p.x + size / 2, y: p.y + 3 * P)
            } else {
                let s = surfaceBelow(x: p.x, y: p.y + 4)
                label = (CGPoint(x: p.x, y: p.y + h + 4), reachable(from: nil, to: s.id))
            }
        }

        if let f = focus {
            let extra = f.id == 0 ? [f] : []
            // 근처 면들과 서로 뛰어갈 수 있는지 잔상으로 보여줌
            for o in plats() where o.id != f.id {
                let gap = max(o.minX - f.maxX, f.minX - o.maxX, 0)
                guard gap < 420, abs(o.y - f.y) < 420 else { continue }
                // 초록: 여기로 올 수 있는 길, 파랑: 여기서 내려가는 길, 빨강: 여기로 못 옴
                let come = edge(o, f), leave = edge(f, o)
                if let e = come { drawArc(c, e.jump, ok: true) }
                if let e = leave, come == nil || abs(o.y - f.y) > 30 { drawArc(c, e.jump, ok: false) }
                if come == nil {
                    // 못 가는 사이는 빨간 점선
                    let ax = min(max(f.minX + f.maxX, 2 * o.minX), 2 * o.maxX) / 2
                    let bx = min(max(o.minX + o.maxX, 2 * f.minX), 2 * f.maxX) / 2
                    drawMiss(c, CGPoint(x: ax, y: o.y), CGPoint(x: bx, y: f.y))
                }
            }
            label = (CGPoint(x: (f.minX + f.maxX) / 2, y: f.y + 70), reachable(from: nil, to: f.id, extra: extra))
        }
        if let (p, ok) = label {
            let text = ok ? "✓ 다람쥐가 여기까지 올 수 있어요" : "✗ 여기는 못 와요 (너무 높거나 멀어요)"
            drawTag(c, text, at: CGPoint(x: p.x - origin.x, y: p.y - origin.y), ok: ok)
        }
    }

    // 점프 궤적을 따라 다람쥐 잔상
    func drawArc(_ c: CGContext, _ j: Jump, ok: Bool) {
        let color = ok ? CGColor(red: 0.2, green: 0.62, blue: 0.3, alpha: 0.85)
            : CGColor(red: 0.3, green: 0.5, blue: 0.85, alpha: 0.7)
        c.saveGState()
        c.setStrokeColor(color)
        c.setLineWidth(2)
        c.setLineDash(phase: 0, lengths: [5, 4])
        for i in 0...24 {
            let p = j.point(j.T * CGFloat(i) / 24)
            let q = CGPoint(x: p.x - origin.x, y: p.y - origin.y + 14)
            if i == 0 { c.move(to: q) } else { c.addLine(to: q) }
        }
        c.strokePath()
        c.restoreGState()
        let img = sprite(.side(1, false))
        let w = CGFloat(img.width) * P * 0.55, h = CGFloat(img.height) * P * 0.55
        let n = 4
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            let p = j.point(j.T * t)
            c.saveGState()
            c.setAlpha((ok ? 0.12 : 0.06) + (ok ? 0.38 : 0.2) * t)
            c.translateBy(x: p.x - origin.x, y: p.y - origin.y)
            c.scaleBy(x: j.v.dx >= 0 ? 1 : -1, y: 1)
            c.draw(img, in: CGRect(x: -w / 2, y: 0, width: w, height: h))
            c.restoreGState()
        }
    }

    func drawMiss(_ c: CGContext, _ a: CGPoint, _ b: CGPoint) {
        let pa = CGPoint(x: a.x - origin.x, y: a.y - origin.y + 10), pb = CGPoint(x: b.x - origin.x, y: b.y - origin.y + 10)
        c.saveGState()
        c.setStrokeColor(CGColor(red: 0.85, green: 0.25, blue: 0.25, alpha: 0.75))
        c.setLineWidth(2)
        c.setLineDash(phase: 0, lengths: [3, 5])
        c.move(to: pa)
        c.addLine(to: pb)
        c.strokePath()
        c.restoreGState()
        let mid = CGPoint(x: (pa.x + pb.x) / 2 - 5, y: (pa.y + pb.y) / 2 - 8)
        ("✕" as NSString).draw(at: mid, withAttributes: [.font: NSFont.boldSystemFont(ofSize: 13),
                                                          .foregroundColor: NSColor.systemRed])
    }

    func drawTag(_ c: CGContext, _ text: String, at p: CGPoint, ok: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let r = CGRect(x: (p.x - size.width / 2 - 8).rounded(), y: p.y.rounded(), width: size.width + 16, height: size.height + 6)
        c.setFillColor(ok ? CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 0.92) : CGColor(red: 0.8, green: 0.25, blue: 0.25, alpha: 0.92))
        c.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
        c.fillPath()
        (text as NSString).draw(at: CGPoint(x: r.minX + 8, y: r.minY + 3), withAttributes: attrs)
    }
}

final class MapEditor: NSObject {
    var tool: ObjKind?
    var erasing = false
    var focus: MapObj?
    var onPlace: ((ObjKind, CGPoint) -> Void)?
    var onErase: ((MapObj) -> Void)?
    var onChange: (() -> Void)?
    var onDone: (() -> Void)?
    private var panel: NSPanel?
    private var overlay: NSWindow?
    let overlayView = OverlayView()
    private var buttons: [NSButton] = []
    private var hintLabel: NSTextField!

    func show() {
        if panel == nil { build() }
        let f = NSScreen.screens[0].frame
        overlay!.setFrame(f, display: false)
        overlayView.frame = NSRect(origin: .zero, size: f.size)
        overlayView.origin = f.origin
        overlay!.orderFrontRegardless()
        panel!.orderFrontRegardless()
        select(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        overlay?.orderOut(nil)
        tool = nil
        erasing = false
        focus = nil
    }

    func tick() { overlayView.needsDisplay = true }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 210, height: 420),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "맵 꾸미기"
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for (i, k) in ObjKind.allCases.enumerated() {
            let b = NSButton(title: k.title, target: self, action: #selector(pick(_:)))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .rounded
            b.tag = i
            buttons.append(b)
            stack.addArrangedSubview(b)
        }
        let eraser = NSButton(title: "지우개", target: self, action: #selector(pick(_:)))
        eraser.setButtonType(.pushOnPushOff)
        eraser.bezelStyle = .rounded
        eraser.tag = 99
        buttons.append(eraser)
        stack.addArrangedSubview(eraser)
        hintLabel = NSTextField(wrappingLabelWithString: "")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.preferredMaxLayoutWidth = 186
        stack.addArrangedSubview(hintLabel)
        let done = NSButton(title: "다 꾸몄어요", target: self, action: #selector(finish))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        stack.addArrangedSubview(done)
        p.contentView = stack
        let vf = NSScreen.screens[0].visibleFrame
        p.setFrameTopLeftPoint(NSPoint(x: vf.maxX - 240, y: vf.maxY - 40))
        panel = p

        let o = NSWindow(contentRect: NSScreen.screens[0].frame, styleMask: .borderless, backing: .buffered, defer: false)
        o.isOpaque = false
        o.backgroundColor = .clear
        o.hasShadow = false
        o.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        o.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        o.contentView = overlayView
        overlay = o
    }

    @objc func pick(_ b: NSButton) {
        select(b.state == .on ? b.tag : nil)
    }

    // 고른 도구 (99는 지우개, nil이면 옮기기만)
    func select(_ tag: Int?) {
        tool = tag.flatMap { $0 < ObjKind.allCases.count ? ObjKind.allCases[$0] : nil }
        erasing = tag == 99
        for b in buttons { b.state = b.tag == tag ? .on : .off }
        hintLabel?.stringValue = tool.map { "\($0.hint)\n바탕화면을 누르면 놓여요." }
            ?? (erasing ? "지울 오브젝트를 누르세요." :
                "오브젝트를 골라 놓고, 놓은 건 끌어서 옮겨요. 우클릭하면 지워요.\n초록 잔상: 여기로 뛰어올 수 있는 길\n파란 잔상: 여기서 내려가는 길\n빨간 점선: 너무 높거나 멀어서 못 오는 사이")
    }

    @objc func finish() { onDone?() }
}

extension MapEditor: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onDone?()
        return false
    }
}

let mapEditor = MapEditor()

// 다람쥐가 가려는 곳
enum Goal: Equatable {
    case acorn(ObjectIdentifier), mouse, approach, tag, flee, stash(CGFloat), trash, home, visit
    case feeder(Int), obj(Int)
}
// 도착해서 하는 일
enum Chore { case bury, unbury(CGFloat), trash }

final class Pet {
    let sq = Squirrel()
    let view: PetView
    let window: NSWindow
    var index = 0
    var lead = true                 // 노래할 때 가사를 부르는 다람쥐 (나머지는 화음)
    var goal: Goal?
    var chore: Chore?
    var claimed: ObjectIdentifier?  // "내꺼야!" 하고 외친 도토리
    var chaseTime: CGFloat = 0
    var inside = false              // 집 안에 들어가 있음
    var insideTime: CGFloat = 0     // 낮에 잠깐 들른 거면 남은 시간
    var wantsVisit = false
    var visitCheck = rnd(90, 240)
    var objGoal: Int? { didSet { if objGoal != oldValue { objX = nil } } }  // 혼자 놀러 가는 오브젝트
    var objX: CGFloat?              // 발판 위 어디쯤으로 갈지
    var objCheck = rnd(15, 30)
    var navFail: CGFloat = 0        // 못 가는 곳이었으면 잠깐 포기
    var bounceCool: CGFloat = 0
    private var chaseCool: CGFloat = 0
    private var calm: CGFloat = 0
    private var mouseSpeed: CGFloat = 0
    private var nag: CGFloat = 20
    private var lastFlip = Date.distantPast

    init(at p: CGPoint, name: String, personality: Personality) {
        sq.pos = p
        sq.dir = Bool.random() ? 1 : -1
        sq.name = name
        sq.personality = personality
        view = PetView(frame: NSRect(x: 0, y: 0, width: W, height: W), squirrel: sq)
        window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = petLevel()
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = view
        window.orderFrontRegardless()
    }

    func tick(_ dt: CGFloat, restack: Bool) {
        // 스티커 메모 위에 있으면 그 메모 바로 위로 (메모를 가리는 다른 앱 창보다는 아래)
        if onDesktop, let id = sq.surface, windows.first(where: { $0.id == id })?.kind == .sticky {
            if window.level != .normal { window.level = .normal }
            if restack { window.order(.above, relativeTo: id) }
        } else if window.level != petLevel() {
            window.level = petLevel()
            window.orderFrontRegardless()
        }
        sq.tired = world.lowBattery || needs.hunger > 0.85
        sq.lively = min(1, needs.mood + (sq.personality == .playful ? 0.25 : 0))
        sq.act = currentAct()
        switch sq.act {
        case .sing: sq.lyric = music.currentLine
        case .harmony:
            // 가사가 나올 때 옆에서 화음
            let hum = ["♪ 우~ 우우~", "♪ 라~ 라라~", "♪ 음~ 음음~"][Int(sq.time / 4) % 3]
            sq.lyric = music.currentLine == nil ? nil : hum
        default: sq.lyric = nil
        }
        // 테스트가 통과하면 한 번 공중제비
        if sq.act == .cheer, claude.since != lastFlip {
            lastFlip = claude.since
            sq.flip()
        }
        sq.update(dt, bounds: screenBounds(for: sq.pos))
        window.setFrameOrigin(NSPoint(x: sq.pos.x.rounded() - W / 2, y: sq.pos.y.rounded() - W / 2))
        view.needsDisplay = true
        // 다람쥐 근처가 아니면 클릭이 뒤 창으로 통과
        let m = NSEvent.mouseLocation
        let center = sq.mode == .floor || sq.mode == .air ? CGPoint(x: sq.pos.x, y: sq.feet + 30) : sq.pos
        let dist = hypot(m.x - center.x, m.y - center.y)
        window.ignoresMouseEvents = !view.dragging && dist > 50

        // 마우스로 살살 문지르면 쓰다듬기
        let moved = hypot(m.x - lastMouse.x, m.y - lastMouse.y)
        if dist < 45 && !view.dragging {
            rub += moved
        } else {
            rub = max(0, rub - dt * 300)
        }
        if rub > 700 { rub = 0; sq.petted() }
        watchMouse(m, moved: moved, dist: dist, dt)
        lastMouse = m
    }

    private var rub: CGFloat = 0
    private var lastMouse = CGPoint.zero

    // 다람쥐 근처에서 마우스를 좌우로 흔들면 쫓아가서 덮침 (겁쟁이는 도망)
    private func watchMouse(_ m: CGPoint, moved: CGFloat, dist: CGFloat, _ dt: CGFloat) {
        mouseSpeed += (moved / max(dt, 0.001) - mouseSpeed) * min(1, dt * 6)
        if chaseTime > 0 {
            chaseTime -= dt
            calm = mouseSpeed < 120 ? calm + dt : 0
            if calm > 2 {
                chaseTime = 0
                sq.say(sq.personality == .shy ? "휴… 갔나?" : "어디 갔지?")
            }
            if chaseTime <= 0 { chaseCool = 6 }
        } else {
            chaseCool -= dt
            // 장난꾸러기는 조금만 흔들어도 달려듦
            let need: CGFloat = sq.personality == .playful ? 500 : 900
            let free = sq.act == .none || sq.act == .sing || sq.act == .harmony
            if chaseCool <= 0, mouseSpeed > need, dist > 60, dist < 700, free, sq.mode == .floor || sq.mode == .wall,
               sq.target == nil, !sq.nested, !view.dragging {
                startChase()
            }
        }
        // 둥지에서 자는데 아직 컴퓨터를 하고 있으면 잔소리
        if sq.nested && sq.sleeping && moved > 2 {
            nag -= dt
            if nag <= 0 {
                nag = 45
                sq.say(["얼른 자…", "졸려… 너도 자…", "음냐… 내일 해…"].randomElement()!, 2.5)
            }
        }
    }

    func startChase() {
        chaseTime = 6
        calm = 0
        sq.sleeping = false
        sq.say(sq.personality == .shy ? "히익! 무서워!" : "잡을 거야!", 1.2)
    }

    func endChase() { chaseTime = 0; chaseCool = 6 }

    // 우선순위: 먹기 > 일하기 > 어디 가는 중 > Claude 반응 > 아침 인사 > 노래
    func currentAct() -> Act {
        if sq.eatTime > 0 { return .eat }
        if sq.workTime > 0 { return .dig }
        guard sq.mode == .floor || sq.mode == .wall, sq.target == nil, !sq.nested else { return .none }
        if claudeReact {
            switch claude.state {
            case .thinking: return claude.busyMinutes.map { .wait($0) } ?? .think("흠")
            case .tool(let what): return claude.busyMinutes.map { .wait($0) } ?? .think(what)
            case .done: return .done
            case .cheer: return .cheer
            case .error: return .startle
            case .attention: return .attention
            case .idle: break
            }
        }
        if sq.greetTime > 0 { return .greet }
        if singAlong && music.playing { return lead ? .sing : .harmony }
        return .none
    }
}

func bar(_ v: CGFloat) -> String {
    let n = Int((min(max(v, 0), 1) * 5).rounded())
    return String(repeating: "■", count: n) + String(repeating: "□", count: 5 - n)
}

let petNames = ["밤톨", "도토리", "솔방울", "땅콩", "호두", "잣", "개암", "은행"]

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var pets: [Pet] = []
    var statusItem: NSStatusItem!
    var toggleItem: NSMenuItem!
    var statusLine: NSMenuItem!
    var stashItem: NSMenuItem!
    var houseItem: NSMenuItem!
    var editItem: NSMenuItem!
    var feederTick: CGFloat = 120
    var petsHeader: NSMenuItem!
    var shown = true
    var last = CACurrentMediaTime()
    var windowRefresh: CGFloat = 0
    var musicPoll: CGFloat = 0
    var acorns: [Acorn] = []
    var mounds: [Prop] = []
    var house: House!
    var play: (chaser: Pet, runner: Pet, time: CGFloat)?
    var playCheck: CGFloat = 20
    var eatenItem: NSMenuItem!
    var eaten = UserDefaults.standard.integer(forKey: "acornsEaten") {
        didSet {
            UserDefaults.standard.set(eaten, forKey: "acornsEaten")
            eatenItem.title = "지금까지 먹은 도토리: \(eaten)개"
        }
    }

    var props: [NSWindow] { acorns.map(\.window) + mounds.map(\.window) }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐿️"
        let menu = NSMenu()
        menu.delegate = self
        statusLine = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        toggleItem = menu.addItem(withTitle: "다람쥐 숨기기", action: #selector(toggle), keyEquivalent: "h")
        toggleItem.target = self
        let deskItem = menu.addItem(withTitle: "바탕화면에서만 놀기", action: #selector(toggleDesktop(_:)), keyEquivalent: "d")
        deskItem.target = self
        deskItem.state = onDesktop ? .on : .off
        let singItem = menu.addItem(withTitle: "노래 따라 부르기", action: #selector(toggleSing(_:)), keyEquivalent: "s")
        singItem.target = self
        singItem.state = singAlong ? .on : .off
        let claudeItem = menu.addItem(withTitle: "Claude 따라 고민하기", action: #selector(toggleClaude(_:)), keyEquivalent: "c")
        claudeItem.target = self
        claudeItem.state = claudeReact ? .on : .off
        let weatherItem = menu.addItem(withTitle: "날씨 따라 우산 쓰기", action: #selector(toggleWeather(_:)), keyEquivalent: "w")
        weatherItem.target = self
        weatherItem.state = weatherReact ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "도토리 주기", action: #selector(giveAcorn), keyEquivalent: "a").target = self
        menu.addItem(withTitle: "마우스 잡기 놀이", action: #selector(playChase), keyEquivalent: "m").target = self
        eatenItem = menu.addItem(withTitle: "지금까지 먹은 도토리: \(eaten)개", action: nil, keyEquivalent: "")
        stashItem = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        houseItem = menu.addItem(withTitle: "다람쥐 집 꾸미기", action: nil, keyEquivalent: "")
        editItem = menu.addItem(withTitle: "맵 꾸미기 (발판, 사료통…)", action: #selector(toggleEdit), keyEquivalent: "e")
        editItem.target = self
        menu.addItem(.separator())
        petsHeader = menu.addItem(withTitle: "우리 다람쥐들 (성격 바꾸기)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "다람쥐 한 마리 더", action: #selector(addPet), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "한 마리 보내기", action: #selector(removePet), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        // 집을 먼저 만들어서 다람쥐들이 그 앞을 지나다니게
        house = House()
        house.view.menuMaker = { [unowned self] in self.houseMenu() }
        house.view.onKnock = { [unowned self] in self.knock() }
        mounds = needs.stash.map { Prop(.mound, at: CGPoint(x: $0, y: groundY(at: $0))) }
        loadMap()
        mapEditor.onPlace = { [unowned self] k, p in
            let o = MapObj(k, at: p)
            mapObjs.append(o)
            o.window.orderFrontRegardless()
            self.mapChanged()
        }
        mapEditor.onErase = { [unowned self] o in
            mapObjs.removeAll { $0 === o }
            o.window.orderOut(nil)
            self.mapChanged()
        }
        mapEditor.onChange = { [unowned self] in self.mapChanged() }
        mapEditor.onDone = { [unowned self] in if editing { self.toggleEdit() } }
        // 지난번에 있던 다람쥐들이 그대로 돌아옴
        let saved = UserDefaults.standard.array(forKey: "squirrels") as? [[String]] ?? []
        for s in saved where s.count == 2 { spawn(name: s[0], personality: Personality(rawValue: s[1]) ?? .playful) }
        if pets.isEmpty { addPet() }

        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [unowned self] _ in
            let now = CACurrentMediaTime()
            let dt = CGFloat(min(now - last, 0.05))
            last = now
            needs.tick(dt)
            guard shown else { return }
            windowRefresh -= dt
            let restack = windowRefresh <= 0
            if restack {
                refreshWindows()
                windowRefresh = 0.25
            }
            musicPoll -= dt
            if musicPoll <= 0 {
                if singAlong { music.poll() } else { music.playing = false }
                musicPoll = 1
            }
            claude.poll()
            world.tick(dt)
            if let news = world.news {
                world.news = nil
                pets.filter { !$0.inside }.randomElement()?.sq.say(news, 2.5)
            }
            acorns.forEach { $0.tick(dt) }
            for a in acorns where a.absorbed {
                // 사료통 안으로 쏙
                a.window.orderOut(nil)
                if let f = a.into { f.acorns = min(feederCapacity, f.acorns + 1) }
            }
            acorns.removeAll { $0.absorbed }
            tickMap(dt)
            plan(dt)
            updatePlay(dt)
            // 노래쟁이가 있으면 걔가 가사를 부르고, 없으면 첫째가
            let singer = pets.first { $0.sq.personality == .singer && !$0.inside } ?? pets.first { !$0.inside }
            for (i, p) in pets.enumerated() where !p.inside {
                p.index = i
                p.lead = p === singer
                p.tick(dt, restack: restack)
            }
            updateHouse(dt, restack: restack)
        }
        RunLoop.main.add(t, forMode: .common)
    }

    func applicationWillTerminate(_ n: Notification) { needs.save() }

    // 메뉴를 열 때 컨디션, 다람쥐 목록, 집 메뉴를 새로 채움
    func menuWillOpen(_ menu: NSMenu) {
        statusLine.title = "배고픔 \(bar(needs.hunger))   기분 \(bar(needs.mood))"
        stashItem.title = "묻어둔 도토리: \(needs.stash.count)개"
        houseItem.submenu = houseMenu()
        for item in menu.items where item.tag >= 1000 { menu.removeItem(item) }
        let at = menu.index(of: petsHeader) + 1
        for (i, pet) in pets.enumerated() {
            let sq = pet.sq
            let item = NSMenuItem(title: "  \(sq.personality.emoji) \(sq.name) · \(sq.personality.title)", action: nil, keyEquivalent: "")
            item.tag = 1000 + i
            let sub = NSMenu()
            for (j, p) in Personality.allCases.enumerated() {
                let choice = sub.addItem(withTitle: "\(p.emoji) \(p.title)", action: #selector(setPersonality(_:)), keyEquivalent: "")
                choice.target = self
                choice.tag = i * 100 + j
                choice.state = p == sq.personality ? .on : .off
            }
            item.submenu = sub
            menu.insertItem(item, at: at + i)
        }
    }

    @objc func setPersonality(_ item: NSMenuItem) {
        let i = item.tag / 100, p = Personality.allCases[item.tag % 100]
        guard pets.indices.contains(i) else { return }
        pets[i].sq.personality = p
        pets[i].sq.say("이제 나는 \(p.title)!", 2)
        savePets()
    }

    func savePets() {
        UserDefaults.standard.set(pets.map { [$0.sq.name, $0.sq.personality.rawValue] }, forKey: "squirrels")
    }

    // MARK: 집

    func houseMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector?, tag: Int = 0, on: Bool = false) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = on ? .on : .off
        }
        add("집 보이기", #selector(toggleHouse), on: house.shown)
        menu.addItem(.separator())
        add("집 모양", nil)
        for (i, s) in HouseStyle.allCases.enumerated() {
            add("  " + s.title, #selector(setHouseStyle(_:)), tag: i, on: s == house.style)
        }
        menu.addItem(.separator())
        add("지붕 색", nil)
        for (i, c) in roofColors.enumerated() {
            add("  " + c.name, #selector(setHouseColor(_:)), tag: i, on: i == house.color)
        }
        menu.addItem(.separator())
        add("장식", nil)
        for (i, dc) in Decor.allCases.enumerated() {
            add("  " + dc.title, #selector(toggleDecor(_:)), tag: i, on: house.decor.contains(dc))
        }
        menu.addItem(.separator())
        add("집은 끌어서 옮기고, 누르면 똑똑 노크해요", nil)
        return menu
    }

    @objc func toggleHouse() {
        house.shown.toggle()
        if house.shown && shown { house.window.orderFrontRegardless() } else { house.window.orderOut(nil) }
        // 집이 없어지면 안에 있던 다람쥐들은 밖으로
        if !house.shown { for p in pets where p.inside { leaveHome(p, say: "어? 집이 없어졌어!") } }
        house.save()
    }

    @objc func setHouseStyle(_ item: NSMenuItem) {
        house.style = HouseStyle.allCases[item.tag]
        // 둥지는 들어가는 집이 아니라 올라앉는 곳
        for p in pets where p.inside { leaveHome(p, say: "집이 바뀌었네!") }
        for p in pets { p.sq.nested = false }
        house.rebuild()
        house.save()
    }

    @objc func setHouseColor(_ item: NSMenuItem) {
        house.color = item.tag
        house.rebuild()
        house.save()
    }

    @objc func toggleDecor(_ item: NSMenuItem) {
        let dc = Decor.allCases[item.tag]
        if house.decor.contains(dc) { house.decor.remove(dc) } else { house.decor.insert(dc) }
        house.rebuild()
        house.save()
    }

    // 똑똑: 안에 있으면 나오고, 없으면 가까운 다람쥐가 대답
    func knock() {
        if let p = pets.first(where: { $0.inside }) {
            leaveHome(p, say: "누구세요?")
            p.visitCheck = rnd(120, 300)
        } else if let p = pets.min(by: { abs($0.sq.pos.x - house.x) < abs($1.sq.pos.x - house.x) }) {
            p.sq.say(["우리 집 예쁘지?", "지금 아무도 없어~", "똑똑!"].randomElement()!, 2)
        }
    }

    func enterHome(_ pet: Pet, for time: CGFloat) {
        pet.inside = true
        pet.insideTime = time
        pet.wantsVisit = false
        pet.goal = nil
        pet.sq.target = nil
        pet.window.orderOut(nil)
    }

    func leaveHome(_ pet: Pet, say line: String?) {
        guard pet.inside else { return }
        pet.inside = false
        let sq = pet.sq
        sq.pos.x = house.doorX
        sq.land(on: nil, ground: groundY(at: house.doorX))
        sq.dir = Bool.random() ? 1 : -1
        if let line = line { sq.say(line, 2) }
        if shown { pet.window.orderFrontRegardless() }
    }

    func updateHouse(_ dt: CGFloat, restack: Bool) {
        guard house.shown else { return }
        let home = pets.filter { $0.inside }
        house.tick(dt, sleepers: home.filter { $0.insideTime <= 0 }.count, anyoneHome: !home.isEmpty)
        // 둥지는 다람쥐보다 앞에 둬서 다리를 가림
        if house.style == .nest && restack && pets.contains(where: { $0.sq.nested }) {
            house.window.orderFrontRegardless()
        }
    }

    // 바탕화면 층 <-> 모든 창 위
    @objc func toggleDesktop(_ item: NSMenuItem) {
        onDesktop.toggle()
        item.state = onDesktop ? .on : .off
        refreshWindows()
        house.window.level = petLevel()
        if shown && house.shown { house.window.orderFrontRegardless() }
        for w in mapObjs.map(\.window) + pets.filter({ !$0.inside }).map(\.window) + props {
            w.level = petLevel()
            if shown { w.orderFrontRegardless() }
        }
    }

    @objc func toggleClaude(_ item: NSMenuItem) {
        claudeReact.toggle()
        item.state = claudeReact ? .on : .off
    }

    @objc func toggleWeather(_ item: NSMenuItem) {
        weatherReact.toggle()
        item.state = weatherReact ? .on : .off
        world.weather = .clear
        if weatherReact { world.pollWeather() }
    }

    // 다람쥐 근처 하늘에서 도토리 하나
    @objc func giveAcorn() {
        if !shown { toggle() }
        guard let pet = pets.randomElement() else { return }
        // 사료통이 있으면 반쯤은 사료통 안으로 떨어짐
        if let f = mapObjs.filter({ $0.kind == .feeder && $0.acorns < feederCapacity }).randomElement(), rnd(0, 1) < 0.5 {
            let a = Acorn(at: CGPoint(x: f.pos.x, y: screenBounds(for: f.pos).maxY - 40))
            a.into = f
            acorns.append(a)
            return
        }
        let from = pet.inside ? CGPoint(x: house.doorX, y: groundY(at: house.doorX) + 100) : pet.sq.pos
        let b = screenBounds(for: from)
        let x = min(max(from.x + rnd(-260, 260), b.minX + 90), b.maxX - 90)
        acorns.append(Acorn(at: CGPoint(x: x, y: b.maxY - 40)))
    }

    // 메뉴에서 바로 시작하는 마우스 잡기
    @objc func playChase() {
        if !shown { toggle() }
        for p in pets {
            if p.inside { leaveHome(p, say: nil) }
            p.sq.nested = false
            p.startChase()
        }
    }

    // 다람쥐마다 지금 어디로 갈지 정하고, 도착하면 할 일을 시작
    func plan(_ dt: CGFloat) {
        let m = NSEvent.mouseLocation
        for (i, pet) in pets.enumerated() {
            let sq = pet.sq
            if pet.inside {
                // 자러 들어간 거면 일어날 시간까지, 놀러 들어간 거면 잠깐만. 도토리가 떨어지면 뛰쳐나옴
                if !freeAcorns.isEmpty {
                    leaveHome(pet, say: "도토리 소리!")
                } else if pet.insideTime > 0 {
                    pet.insideTime -= dt
                    if pet.insideTime <= 0 { leaveHome(pet, say: "다녀왔어!") }
                } else if !sq.bedtime {
                    leaveHome(pet, say: nil)
                    sq.greetTime = 3.5
                }
                continue
            }
            if sq.finished {
                sq.finished = false
                finishChore(pet)
            }
            guard sq.eatTime <= 0, sq.workTime <= 0, sq.mode != .held else {
                sq.target = nil
                pet.goal = nil
                continue
            }
            // 낮에 가끔 집에 들름
            let idle = sq.mode == .floor && sq.act == .none && !sq.sleeping
            if house.shown && house.style != .nest && !sq.bedtime && !pet.wantsVisit && idle {
                pet.visitCheck -= dt
                if pet.visitCheck <= 0 {
                    pet.visitCheck = rnd(120, 300)
                    pet.wantsVisit = rnd(0, 1) < 0.5
                }
            }

            sq.keepSurface = false
            pet.navFail -= dt
            pet.bounceCool -= dt
            bounce(pet)
            if idle && pet.objGoal == nil && !sq.bedtime {
                pet.objCheck -= dt
                if pet.objCheck <= 0 {
                    pet.objCheck = rnd(15, 35)
                    pet.objGoal = pickObject(for: pet)
                }
            }

            let b = screenBounds(for: sq.pos)
            let shy = sq.personality == .shy
            var goal: Goal?
            var nav: (x: CGFloat, plat: Int?)?
            var x: CGFloat = 0, rush: CGFloat = 95
            if let a = freeAcorns.min(by: { abs($0.pos.x - sq.pos.x) < abs($1.pos.x - sq.pos.x) }) {
                // 먹보는 도토리를 보면 전속력
                goal = .acorn(ObjectIdentifier(a)); x = a.pos.x; rush = sq.personality == .glutton ? 150 : 95
            } else if pet.chaseTime > 0 {
                // 겁쟁이는 마우스한테서 도망
                goal = .mouse; rush = sq.personality == .playful ? 200 : 170
                x = shy ? sq.pos.x + (sq.pos.x >= m.x ? 260 : -260) : m.x
            } else if claudeReact, claude.state == .attention, sq.mode == .floor, !sq.nested, abs(m.x - sq.pos.x) > 140 {
                // Claude가 허락을 기다리면 마우스 쪽으로 다가가서 손 흔들기
                goal = .approach; x = m.x; rush = 110
            } else if let p = play, p.chaser === pet {
                goal = .tag; x = p.runner.sq.pos.x; rush = 150
            } else if let p = play, p.runner === pet {
                goal = .flee; x = sq.pos.x + (sq.pos.x >= p.chaser.sq.pos.x ? 200 : -200); rush = 120
            } else if let f = feeder(for: pet) {
                goal = .feeder(f.id); nav = (f.pos.x, objPlat(f)); rush = sq.personality == .glutton ? 140 : 90
            } else if needs.hungry, let s = needs.stash.min(by: { abs($0 - sq.pos.x) < abs($1 - sq.pos.x) }) {
                goal = .stash(s); x = s; rush = 80
            } else if world.trashed && i == 0 {
                // 휴지통은 보통 Dock 오른쪽 끝
                goal = .trash; x = b.maxX - 120; rush = 110
            } else if house.shown && sq.bedtime && !sq.nested {
                goal = .home; rush = 60
                x = house.style == .nest ? house.x + [0, -26, 26, -13, 13][i % 5] : house.doorX
            } else if house.shown && pet.wantsVisit {
                goal = .visit; x = house.doorX; rush = 70
            } else if let id = pet.objGoal, let o = mapObjs.first(where: { $0.id == id }) {
                goal = .obj(id); rush = 85
                if o.kind.isPlatform && pet.objX == nil { pet.objX = rnd(o.frame.minX + 20, o.frame.maxX - 20) }
                nav = o.kind.isPlatform ? (pet.objX!, o.id) : (o.pos.x, objPlat(o))
            } else {
                pet.objGoal = nil
            }
            // 집은 다른 화면에 있을 수도 있으니 화면 끝에 막히지 않게
            if goal != .home && goal != .visit { x = min(max(x, b.minX + 80), b.maxX - 80) }
            if goal != nil, goal != .home { sq.nested = false }

            if goal != pet.goal {
                pet.goal = goal
                switch goal {
                case .acorn?: sq.say(sq.personality == .glutton ? "도토리!! 내 거!!" : "도토리다!")
                case .approach?: sq.say("불렀어?")
                case .stash?: sq.say("숨겨둔 도토리 먹어야지~", 2)
                case .trash?: sq.say("방금 뭐 버렸어?", 2)
                case .home?: sq.say(house.style == .nest ? "졸려… 둥지 가야지" : "졸려… 집에 가야지", 2)
                case .visit?: sq.say("집에 잠깐 다녀올게~", 2)
                case .feeder?: sq.say("사료통에 밥 먹으러~", 2)
                case .obj(let id)?:
                    switch mapObjs.first(where: { $0.id == id })?.kind {
                    case .trampoline?: sq.say("트램펄린 타야지!", 1.6)
                    case .cushion?: sq.say("방석에서 쉴래~", 1.6)
                    default: sq.say("저기 올라가 볼까?", 1.6)
                    }
                default: break
                }
            }
            sq.rush = rush
            if let n = nav, let g = goal {
                switch navigate(sq, x: n.x, on: n.plat) {
                case .walking: break
                case .arrived: arrive(pet, g)
                case .unreachable:
                    // 맵이 바뀌어서 못 가게 됐으면 포기
                    pet.goal = nil
                    pet.objGoal = nil
                    pet.navFail = 40
                    sq.target = nil
                    sq.say("저기는 못 가겠어…", 1.6)
                }
                continue
            }
            sq.target = goal == nil ? nil : x
            guard let g = goal, sq.mode == .floor, sq.surface == nil else { continue }
            let dx = abs(x - sq.pos.x)

            switch g {
            case .acorn(let id):
                guard let a = acorns.first(where: { ObjectIdentifier($0) == id }) else { break }
                // 같은 도토리를 노리는 다람쥐끼리 마주치면
                if dx < 150, pet.claimed != id,
                   pets.contains(where: { $0 !== pet && $0.goal == g && abs($0.sq.pos.x - sq.pos.x) < 90 }) {
                    pet.claimed = id
                    sq.say("내꺼야!", 1.2)
                }
                guard a.landed, dx < 10 else { break }
                acorns.removeAll { $0 === a }
                a.window.orderOut(nil)
                for o in pets where o !== pet && o.goal == g {
                    o.sq.say("치… 내 도토리…", 1.8)
                    o.goal = nil
                }
                pet.goal = nil
                // 배부르면 나중을 위해 묻어둠 (먹보는 배불러도 먹음)
                if needs.full && sq.personality != .glutton {
                    pet.chore = .bury
                    sq.startWork(1.8, "나중에 먹어야지~")
                } else {
                    sq.startEating()
                    eaten += 1
                }
            case .mouse:
                if !shy && dx < 40 && m.y < sq.feet + 160 {
                    pet.endChase()
                    pet.goal = nil
                    sq.pounce(toward: m.x)
                }
            case .tag:
                if let p = play, abs(p.runner.sq.pos.x - sq.pos.x) < 30 {
                    sq.say("잡았다!", 1.4)
                    p.runner.sq.say("꺅!", 1.2)
                    sq.happyTime = 2
                    p.runner.sq.happyTime = 2
                    needs.cheer(0.1)
                    play = nil
                }
            case .stash(let s):
                if dx < 10 {
                    pet.goal = nil
                    pet.chore = .unbury(s)
                    sq.startWork(1.6, "어디 묻었더라…")
                }
            case .trash:
                if dx < 10 {
                    world.trashed = false
                    pet.goal = nil
                    pet.chore = .trash
                    sq.startWork(2.2, "뒤적뒤적…")
                }
            case .home:
                guard dx < 8 else { break }
                if house.style == .nest {
                    pet.goal = nil
                    sq.target = nil
                    sq.nested = true
                    sq.sleeping = true
                    sq.targetSpeed = 0
                    sq.timer = rnd(20, 40)
                } else {
                    enterHome(pet, for: 0)
                }
            case .visit:
                if dx < 8 { enterHome(pet, for: rnd(15, 40)) }
            case .approach, .flee, .feeder, .obj:
                break
            }
        }
    }

    var freeAcorns: [Acorn] { acorns.filter { $0.into == nil } }

    // MARK: 맵

    enum Nav { case walking, arrived, unreachable }

    // 같은 면이면 걸어가고, 다른 면이면 갈 수 있는 길을 찾아서 폴짝
    func navigate(_ sq: Squirrel, x: CGFloat, on target: Int?) -> Nav {
        guard sq.mode == .floor else {
            if sq.jump == nil { sq.target = x }
            return .walking
        }
        // 앱 창이나 위젯 위면 일단 내려옴
        if let h = sq.surface, h >= 0 {
            sq.target = x
            return .walking
        }
        if sq.surface == target {
            sq.keepSurface = true
            sq.target = x
            return abs(x - sq.pos.x) < 8 ? .arrived : .walking
        }
        guard let hop = firstHop(from: sq.surface, to: target) else { return .unreachable }
        sq.keepSurface = true
        sq.target = hop.take
        if abs(hop.take - sq.pos.x) < 6 {
            sq.target = nil
            sq.leap(hop.jump)
        }
        return .walking
    }

    func arrive(_ pet: Pet, _ g: Goal) {
        let sq = pet.sq
        pet.goal = nil
        sq.target = nil
        switch g {
        case .feeder(let id):
            guard let f = mapObjs.first(where: { $0.id == id }), f.acorns > 0 else { return sq.say("비었네…", 1.4) }
            f.acorns -= 1
            sq.startEating()
            eaten += 1
        case .obj(let id):
            pet.objGoal = nil
            switch mapObjs.first(where: { $0.id == id })?.kind {
            case .cushion?:
                sq.sleeping = true
                sq.targetSpeed = 0
                sq.timer = rnd(15, 30)
                sq.say("푹신하다~", 1.6)
            case .plank?, .longPlank?:
                if rnd(0, 1) < 0.5 { sq.say(["높다~!", "여기 좋다!", "경치 좋네~"].randomElement()!, 1.6) }
            default:
                break
            }
        default:
            break
        }
    }

    // 배고프고 갈 수 있는 사료통에 도토리가 있으면 거기로
    func feeder(for pet: Pet) -> MapObj? {
        let sq = pet.sq
        guard pet.navFail <= 0, needs.hunger > (sq.personality == .glutton ? 0.25 : 0.45) else { return nil }
        let here = (sq.surface ?? 0) < 0 ? sq.surface : nil
        return mapObjs.filter { $0.kind == .feeder && $0.acorns > 0 && reachable(from: here, to: objPlat($0)) }
            .min { abs($0.pos.x - sq.pos.x) < abs($1.pos.x - sq.pos.x) }
    }

    // 심심하면 성격에 맞는 오브젝트로 놀러 감
    func pickObject(for pet: Pet) -> Int? {
        let sq = pet.sq
        guard pet.navFail <= 0 else { return nil }
        let here = (sq.surface ?? 0) < 0 ? sq.surface : nil
        let ok = mapObjs.filter { $0.kind != .feeder && $0.kind != .flowerPot && $0.kind != .lamp }
            .filter { o in o.id != here && reachable(from: here, to: objPlat(o)) }
        let tramps = ok.filter { $0.kind == .trampoline }, cushions = ok.filter { $0.kind == .cushion }
        let planks = ok.filter { $0.kind.isPlatform }
        switch sq.personality {
        case .playful: return (tramps + tramps + planks).randomElement()?.id
        case .sleepy: return (cushions.randomElement() ?? planks.randomElement())?.id
        default: return rnd(0, 1) < 0.6 ? ok.randomElement()?.id : nil
        }
    }

    // 트램펄린을 밟으면 높이 튀어 오름
    func bounce(_ pet: Pet) {
        let sq = pet.sq
        guard sq.mode == .floor, pet.bounceCool <= 0, (sq.surface ?? -1) < 0 || sq.surface == nil else { return }
        for t in mapObjs where t.kind == .trampoline && objPlat(t) == sq.surface && abs(t.pos.x - sq.pos.x) < 18 {
            pet.bounceCool = 1.2
            if case .obj(let id)? = pet.goal, id == t.id { pet.goal = nil; pet.objGoal = nil }
            sq.target = nil
            sq.hop(CGVector(dx: sq.dir * 120, dy: 1150))
            sq.say(["뿅~!", "슝~!", "야호!"].randomElement()!, 1.2)
            needs.cheer(0.02)
            return
        }
    }

    // 사료통 채우기, 가로등 켜기, 맵 꾸미기 화면 다시 그리기
    func tickMap(_ dt: CGFloat) {
        feederTick -= dt
        if feederTick <= 0 {
            feederTick = 120
            for f in mapObjs where f.kind == .feeder && f.acorns < feederCapacity { f.acorns += 1 }
            saveMap()
        }
        for l in mapObjs where l.kind == .lamp { l.lit = world.night }
        if editing { mapEditor.tick() }
    }

    func mapChanged() {
        // 발판이 사라지거나 옮겨지면 그 위의 오브젝트는 아래로 떨어짐
        customWins = mapObjs.filter { $0.kind.isPlatform }.map { Win(id: $0.id, frame: $0.frame, kind: .custom) }
        for o in mapObjs where !o.kind.isPlatform {
            o.pos = snapped(o.kind, o.pos)
            o.place()
        }
        refreshWindows()
        saveMap()
    }

    func saveMap() {
        let rows = mapObjs.map { [$0.kind.rawValue, "\(Double($0.pos.x))", "\(Double($0.pos.y))", "\($0.acorns)"] }
        UserDefaults.standard.set(rows, forKey: "mapObjects")
    }

    func loadMap() {
        let rows = UserDefaults.standard.array(forKey: "mapObjects") as? [[String]] ?? []
        for r in rows where r.count == 4 {
            guard let k = ObjKind(rawValue: r[0]), let x = Double(r[1]), let y = Double(r[2]) else { continue }
            let o = MapObj(k, at: CGPoint(x: x, y: y), acorns: Int(r[3]) ?? 0)
            mapObjs.append(o)
            if shown { o.window.orderFrontRegardless() }
        }
        mapChanged()
    }

    // 맵 꾸미기: 모든 걸 앱 창 위로 올리고 팔레트와 미리보기를 띄움
    @objc func toggleEdit() {
        if !shown { toggle() }
        editing.toggle()
        editItem.state = editing ? .on : .off
        let all = [house.window] + mapObjs.map(\.window) + props + pets.filter { !$0.inside }.map(\.window)
        for w in all {
            w.level = petLevel()
            if w.isVisible || w !== house.window { w.orderFrontRegardless() }
        }
        if !house.shown { house.window.orderOut(nil) }
        for o in mapObjs { o.window.ignoresMouseEvents = !editing }
        if editing {
            mapEditor.show()
        } else {
            mapEditor.hide()
            saveMap()
        }
    }

    func finishChore(_ pet: Pet) {
        let sq = pet.sq
        switch pet.chore {
        case .bury?:
            needs.stash.append(sq.pos.x)
            mounds.append(Prop(.mound, at: CGPoint(x: sq.pos.x, y: groundY(at: sq.pos.x))))
            sq.say("다 묻었다! 🌰", 1.6)
        case .unbury(let s)?:
            if let i = needs.stash.firstIndex(of: s) {
                needs.stash.remove(at: i)
                if let j = mounds.firstIndex(where: { $0.pos.x == s }) { mounds.remove(at: j).window.orderOut(nil) }
                sq.startEating()
                eaten += 1
            } else {
                sq.say("어? 없어졌다…")
            }
        case .trash?:
            sq.say(["이거 버려도 돼?", "쓸만한 거 없네…", "도토리는 없다…"].randomElement()!, 2.2)
        case nil:
            break
        }
        pet.chore = nil
        needs.save()
    }

    // 두 마리 이상이면 가끔 술래잡기 (장난꾸러기가 있으면 더 자주)
    func updatePlay(_ dt: CGFloat) {
        if var p = play {
            p.time -= dt
            let alive = pets.contains { $0 === p.chaser } && pets.contains { $0 === p.runner }
            play = p.time > 0 && alive ? p : nil
            if play == nil && alive { p.chaser.sq.say("헥헥… 못 잡겠다", 1.8) }
            return
        }
        playCheck -= dt
        guard playCheck <= 0 else { return }
        playCheck = rnd(25, 45)
        let eager = pets.contains { $0.sq.personality == .playful }
        guard needs.mood > 0.35, !world.night, rnd(0, 1) < (eager ? 0.8 : 0.5) else { return }
        var free = pets.filter {
            !$0.inside && $0.sq.mode == .floor && $0.sq.surface == nil && $0.sq.act == .none && $0.sq.target == nil
                && !$0.sq.sleeping && !$0.sq.nested
        }.shuffled()
        guard free.count >= 2 else { return }
        // 장난꾸러기가 있으면 걔가 술래
        free = free.filter { $0.sq.personality == .playful } + free.filter { $0.sq.personality != .playful }
        play = (free[0], free[1], 6)
        free[0].sq.say("술래잡기 하자!", 1.6)
        free[1].sq.say("잡아봐라~", 1.6)
    }

    @objc func toggleSing(_ item: NSMenuItem) {
        singAlong.toggle()
        item.state = singAlong ? .on : .off
    }

    @objc func toggle() {
        shown.toggle()
        toggleItem.title = shown ? "다람쥐 숨기기" : "다람쥐 보이기"
        statusItem.button?.appearsDisabled = !shown
        if shown && house.shown { house.window.orderFrontRegardless() } else { house.window.orderOut(nil) }
        for p in pets where !p.inside { shown ? p.window.orderFrontRegardless() : p.window.orderOut(nil) }
        for w in props + mapObjs.map(\.window) { shown ? w.orderFrontRegardless() : w.orderOut(nil) }
        if !shown && editing { toggleEdit() }
    }

    @discardableResult
    func spawn(name: String, personality: Personality) -> Pet {
        // 화면 위쪽에서 활강하며 등장
        let b = NSScreen.screens[0].visibleFrame
        let pet = Pet(at: CGPoint(x: rnd(b.minX + 150, b.maxX - 150), y: b.maxY - 120),
                      name: name, personality: personality)
        // 그날 처음 아침에 켜면 기지개
        if pets.isEmpty && world.morning {
            let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
            if UserDefaults.standard.integer(forKey: "greetDay") != day {
                UserDefaults.standard.set(day, forKey: "greetDay")
                pet.sq.greetTime = 6
            }
        }
        pets.append(pet)
        return pet
    }

    // 아직 없는 성격과 이름으로 새 다람쥐
    @objc func addPet() {
        if !shown { toggle() }
        let used = Set(pets.map(\.sq.personality))
        let personality = Personality.allCases.filter { !used.contains($0) }.randomElement()
            ?? Personality.allCases.randomElement()!
        let name = petNames.first { n in !pets.contains { $0.sq.name == n } } ?? "다람쥐 \(pets.count + 1)"
        let pet = spawn(name: name, personality: personality)
        pet.sq.say("안녕! 나는 \(name), \(personality.title)야", 3)
        savePets()
    }

    @objc func removePet() {
        guard pets.count > 1 else { return }
        pets.popLast()?.window.orderOut(nil)
        savePets()
    }
}

// 그림 확인용: ./Squirrel --snapshot <폴더>
func snapshot(_ dir: String) {
    let poses: [(String, (Squirrel) -> Void)] = [
        ("sing", { $0.mode = .floor; $0.act = .sing; $0.lyric = "♪ 라라라 (가사 자리)"; $0.time = 0.2 }),
        ("think", { $0.mode = .floor; $0.act = .think("읽는 중"); $0.time = 0.5 }),
        ("eat", { $0.mode = .floor; $0.act = .eat; $0.eatTime = 1; $0.time = 0.25; $0.say("냠냠") }),
        ("done", { $0.mode = .floor; $0.act = .done; $0.time = 0.1 }),
        ("side", { $0.mode = .floor; $0.speed = 45; $0.gait = 1; $0.say("도토리 줘!") }),
        ("sleep", { $0.mode = .floor; $0.sleeping = true; $0.time = 0.4 }),
        ("climb", { $0.mode = .wall; $0.speed = 45; $0.gait = 1 }),
        ("climbsleep", { $0.mode = .wall; $0.sleeping = true; $0.time = 0.4 }),
        ("glide", { $0.mode = .air; $0.airTime = 1 }),
        ("wave", { $0.mode = .floor; $0.act = .attention; $0.time = 0.1 }),
        ("startle", { $0.mode = .floor; $0.act = .startle; $0.time = 0.02 }),
        ("wait", { $0.mode = .floor; $0.act = .wait(3); $0.time = 0.1 }),
        ("greet", { $0.mode = .floor; $0.act = .greet; $0.time = 0.1 }),
        ("dig", { $0.mode = .floor; $0.act = .dig; $0.time = 0.3; $0.say("어디 묻었더라…") }),
        ("flip", { $0.mode = .air; $0.flipTime = 0.4 }),
        ("umbrella", { $0.mode = .floor; $0.speed = 45; $0.gait = 1; world.weather = .rain }),
        ("umbrellasing", { $0.mode = .floor; $0.act = .sing; $0.lyric = "♪ 라라라"; world.weather = .rain }),
    ]
    // 집 모양마다 장식을 다 단 모습
    let house = House()
    for (i, style) in HouseStyle.allCases.enumerated() {
        house.style = style
        house.color = i
        house.decor = Set(Decor.allCases)
        house.rebuild()
        let rep = NSBitmapImageRep(cgImage: house.view.image!)
        try? rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "\(dir)/house-\(style.rawValue).png"))
    }
    // 맵 꾸미기 미리보기: 닿는 발판, 너무 높은 발판, 사료통
    let f = floorPlat()
    let base = CGPoint(x: f.minX + 200, y: f.y)
    mapObjs = [MapObj(.plank, at: CGPoint(x: base.x + 120, y: base.y + 110)),
               MapObj(.longPlank, at: CGPoint(x: base.x + 420, y: base.y + 200)),
               MapObj(.trampoline, at: CGPoint(x: base.x + 640, y: base.y))]
    mapObjs.append(MapObj(.feeder, at: CGPoint(x: base.x + 420, y: base.y + 212), acorns: 5))
    customWins = mapObjs.filter { $0.kind.isPlatform }.map { Win(id: $0.id, frame: $0.frame, kind: .custom) }
    for (name, tool, m) in [("map-ok", ObjKind.plank, CGPoint(x: base.x + 260, y: base.y + 230)),
                            ("map-high", ObjKind.plank, CGPoint(x: base.x + 760, y: base.y + 330))] {
        let v = OverlayView(frame: NSRect(x: 0, y: 0, width: 960, height: 520))
        v.origin = CGPoint(x: base.x - 100, y: base.y - 20)
        v.mouse = m
        mapEditor.tool = tool
        let bg = NSImage(size: v.bounds.size)
        bg.lockFocus()
        NSColor(white: 0.93, alpha: 1).setFill()
        v.bounds.fill()
        v.draw(v.bounds)
        for o in mapObjs {
            let img = sprite(o.pose)
            NSGraphicsContext.current!.cgContext.interpolationQuality = .none
            NSGraphicsContext.current!.cgContext.draw(img, in: CGRect(x: o.pos.x - o.artSize.width / 2 - P - v.origin.x,
                y: o.pos.y - P - v.origin.y, width: CGFloat(img.width) * P, height: CGFloat(img.height) * P))
        }
        bg.unlockFocus()
        let rep = NSBitmapImageRep(data: bg.tiffRepresentation!)!
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
    mapEditor.tool = nil
    mapObjs = []
    customWins = []
    for (name, pose) in [("nest", Pose.nest), ("mound", Pose.mound)] {
        let rep = NSBitmapImageRep(cgImage: sprite(pose))
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
    for (name, set) in poses {
        world.weather = .clear
        let s = Squirrel(); set(s)
        s.personality = Personality.allCases[abs(name.hashValue) % Personality.allCases.count]
        let v = PetView(frame: NSRect(x: 0, y: 0, width: W * 2, height: W * 2), squirrel: s)
        v.scale = 2
        v.background = NSColor(white: 0.93, alpha: 1)
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}

// 앱 아이콘용: ./Squirrel --icon <파일.png>
func renderIcon(_ path: String) {
    let n = 1024, ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let box = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.addPath(CGPath(roundedRect: box, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [
        CGColor(red: 0.62, green: 0.82, blue: 0.95, alpha: 1),
        CGColor(red: 0.98, green: 0.90, blue: 0.80, alpha: 1)] as CFArray, locations: nil)!,
        start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    let img = sprite(.front(open: false, happy: true))
    let k = CGFloat(Int(640 / CGFloat(max(img.width, img.height))))
    let w = CGFloat(img.width) * k, h = CGFloat(img.height) * k
    ctx.interpolationQuality = .none
    ctx.draw(img, in: CGRect(x: (1024 - w) / 2, y: 190, width: w, height: h))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--icon") {
    renderIcon(CommandLine.arguments[i + 1])
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
    snapshot(CommandLine.arguments[i + 1])
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
