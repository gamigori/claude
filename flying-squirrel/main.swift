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
// - 밤(23시~6시)엔 둥지에서 자고, 그때 컴퓨터 하고 있으면 잔소리. 아침엔 기지개
// - 마우스를 휙휙 흔들면 쫓아와서 덮침, 휴지통에 뭘 버리면 뒤적이러 감
// - 배터리가 부족하면 기운 없음, 비나 눈이 오면 우산
// - 여러 마리면 술래잡기, 도토리 쟁탈전, 노래할 땐 화음
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

enum WinKind { case app, widget, sticky }
struct Win { let id: Int; let frame: CGRect; let kind: WinKind }

// 앞에 있는 창부터 순서대로
var windows: [Win] = []

// true면 바탕화면 층에서만 놀고, 앱 창 대신 위젯과 스티커 메모 위에 올라감
var onDesktop = true
var singAlong = true

let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
let widgetLevel = iconLevel + 2

// 바탕화면 모드: 파일 아이콘과 위젯보다 위, 앱 창보다는 아래
func petLevel() -> NSWindow.Level {
    onDesktop ? NSWindow.Level(widgetLevel + 1) : .floating
}

func isPlatform(_ w: Win) -> Bool { !onDesktop || w.kind != .app }

func refreshWindows() {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return }
    let primaryTop = NSScreen.screens[0].frame.maxY
    let me = Int(ProcessInfo.processInfo.processIdentifier)
    windows = list.compactMap { (d: [String: Any]) -> Win? in
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
            if surface != nil { return fall() }
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
        let sleepy = tired ? 0.7 : 0.35 - (lively - 0.5) * 0.3
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
            if world.night { sleeping = true; timer = rnd(20, 40); return }
            nested = false
            greetTime = 3.5
        }
        sleeping = false
        if tired && rnd(0, 1) < 0.25 {
            say(world.lowBattery ? "배터리가… 부족해…" : "배고파… 힘없어…", 2.2)
        } else if needs.hungry && rnd(0, 1) < 0.2 {
            say(["배고파…", "도토리 줘~", "꼬르륵…"].randomElement()!, 2)
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
        mode = .air
        surface = nil
        airTime = 0
        vel = CGVector(dx: dir * speed, dy: 0)
        sleeping = false
    }

    func grab(at p: CGPoint) {
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
            say("깜짝!")
            timer = rnd(1, 2)
        } else {
            say(["안녕!", "도토리 줘!", "간지러워!", "뭐야?", "♥", "히히", "날아볼까?"].randomElement()!)
        }
        // 바닥에 있으면 폴짝
        if mode == .floor { hop(CGVector(dx: 0, dy: 420)) }
    }

    func hop(_ v: CGVector) {
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
        say(sleeping ? "음냐..." : ["헤헤 ♥", "기분 좋아~", "더 해줘!"].randomElement()!)
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
    "R": (252, 236, 220),   // 우산 줄무늬
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

func image(_ g: Grid) -> CGImage {
    let h = g.count, w = g[0].count
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            if let (r, gg, b) = palette[g[y][x]] {
                px[i] = r; px[i + 1] = gg; px[i + 2] = b; px[i + 3] = 255
            } else {
                px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0
            }
        }
    }
    return ctx.makeImage()!
}

func finish(_ g: Grid, sleep: Bool) -> CGImage {
    var g = g
    if sleep { closeEyes(&g) }
    return image(outlined(pad(g, t: 1, l: 1, r: 1, b: 1)))
}

func climbSprite(frame: Int, sleep: Bool) -> CGImage {
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

func sideSprite(frame: Int, sleep: Bool) -> CGImage {
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

func frontSprite(open: Bool, happy: Bool) -> CGImage {
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
func thinkSprite(frame: Int) -> CGImage {
    var g: Grid = frontBody.map(Array.init)
    for (x, y) in [(12, 10), (13, 10), (12, 11), (13, 11)] { g[y][x] = "w" }
    for (x, y) in [(12, 8), (13, 8), (12, 9), (13, 9)] { g[y][x] = "f" }
    for (x, y) in [(9, 8), (10, 8)] { g[y][x] = "o" }
    if frame == 1 { for x in 4...17 where g[4][x] == "k" { g[4][x] = "g" } }
    return finish(g, sleep: false)
}

// 도토리를 두 손으로 들고 오물오물 (볼이 빵빵)
func eatSprite(frame: Int) -> CGImage {
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
func waveSprite(frame: Int) -> CGImage {
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
func startleSprite() -> CGImage {
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
}

var spriteCache: [Pose: CGImage] = [:]
func sprite(_ pose: Pose) -> CGImage {
    if let s = spriteCache[pose] { return s }
    let s: CGImage
    switch pose {
    case .climb(let f, let sleep): s = climbSprite(frame: f, sleep: sleep)
    case .side(let f, let sleep): s = sideSprite(frame: f, sleep: sleep)
    case .front(let open, let happy): s = frontSprite(open: open, happy: happy)
    case .think(let f): s = thinkSprite(frame: f)
    case .eat(let f): s = eatSprite(frame: f)
    case .glide: s = finish(glideBody.map(Array.init), sleep: false)
    case .acorn: s = finish(acornBody.map(Array.init), sleep: false)
    case .wave(let f): s = waveSprite(frame: f)
    case .startle: s = startleSprite()
    case .nest: s = finish(nestBody.map(Array.init), sleep: false)
    case .mound: s = finish(moundBody.map(Array.init), sleep: false)
    case .umbrella: s = finish(umbrellaBody.map(Array.init), sleep: false)
    }
    spriteCache[pose] = s
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
        let img = sprite(pose)
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

// 바탕화면에 놓이는 작은 그림 (도토리, 흙더미, 둥지). pos는 바닥에 닿는 아래 가운데
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

    init(at p: CGPoint) { super.init(.acorn, at: p) }

    func tick(_ dt: CGFloat) {
        if !landed {
            vy -= gravity * dt
            pos.y += vy * dt
            let ground = screenBounds(for: pos).minY
            if pos.y <= ground {
                pos.y = ground
                if -vy > 300 { vy = -vy * 0.35 } else { landed = true; vy = 0 }
            }
        }
        place()
    }
}

// 다람쥐가 가려는 곳
enum Goal: Equatable { case acorn(ObjectIdentifier), mouse, approach, tag, flee, stash(CGFloat), trash, nest }
// 도착해서 하는 일
enum Chore { case bury, unbury(CGFloat), trash }

final class Pet {
    let sq = Squirrel()
    let view: PetView
    let window: NSWindow
    var index = 0
    var goal: Goal?
    var chore: Chore?
    var claimed: ObjectIdentifier?  // "내꺼야!" 하고 외친 도토리
    var chaseTime: CGFloat = 0
    private var chaseCool: CGFloat = 0
    private var calm: CGFloat = 0
    private var mouseSpeed: CGFloat = 0
    private var nag: CGFloat = 20
    private var lastFlip = Date.distantPast

    init(at p: CGPoint) {
        sq.pos = p
        sq.dir = Bool.random() ? 1 : -1
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
        sq.lively = needs.mood
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
        watchMouse(m, moved: moved, dt)
        lastMouse = m
    }

    private var rub: CGFloat = 0
    private var lastMouse = CGPoint.zero

    // 마우스를 휙휙 흔들면 쫓아가서 덮침
    private func watchMouse(_ m: CGPoint, moved: CGFloat, _ dt: CGFloat) {
        mouseSpeed += (moved / max(dt, 0.001) - mouseSpeed) * min(1, dt * 8)
        if chaseTime > 0 {
            chaseTime -= dt
            calm = mouseSpeed < 150 ? calm + dt : 0
            if calm > 1.5 { chaseTime = 0; sq.say("어디 갔지?") }
            if chaseTime <= 0 { chaseCool = 8 }
        } else {
            chaseCool -= dt
            let free = sq.act == .none || sq.act == .sing || sq.act == .harmony
            if chaseCool <= 0, mouseSpeed > 2000, free, sq.mode == .floor, sq.target == nil, !sq.nested,
               abs(m.x - sq.pos.x) < 600, m.y < sq.pos.y + 500 {
                chaseTime = 5
                calm = 0
                sq.say("잡을 거야!", 1.2)
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

    func endChase() { chaseTime = 0; chaseCool = 8 }

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
        if singAlong && music.playing { return index == 0 ? .sing : .harmony }
        return .none
    }
}

func bar(_ v: CGFloat) -> String {
    let n = Int((min(max(v, 0), 1) * 5).rounded())
    return String(repeating: "■", count: n) + String(repeating: "□", count: 5 - n)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var pets: [Pet] = []
    var statusItem: NSStatusItem!
    var toggleItem: NSMenuItem!
    var statusLine: NSMenuItem!
    var stashItem: NSMenuItem!
    var shown = true
    var last = CACurrentMediaTime()
    var windowRefresh: CGFloat = 0
    var musicPoll: CGFloat = 0
    var acorns: [Acorn] = []
    var mounds: [Prop] = []
    var nest: Prop!
    var play: (chaser: Pet, runner: Pet, time: CGFloat)?
    var playCheck: CGFloat = 20
    var eatenItem: NSMenuItem!
    var eaten = UserDefaults.standard.integer(forKey: "acornsEaten") {
        didSet {
            UserDefaults.standard.set(eaten, forKey: "acornsEaten")
            eatenItem.title = "지금까지 먹은 도토리: \(eaten)개"
        }
    }

    // 둥지는 주 화면 왼쪽 아래
    var nestPos: CGPoint {
        let b = NSScreen.screens[0].visibleFrame
        return CGPoint(x: b.minX + 140, y: b.minY)
    }

    var props: [NSWindow] { acorns.map(\.window) + mounds.map(\.window) + [nest.window] }

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
        eatenItem = menu.addItem(withTitle: "지금까지 먹은 도토리: \(eaten)개", action: nil, keyEquivalent: "")
        stashItem = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "다람쥐 한 마리 더", action: #selector(addPet), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "한 마리 보내기", action: #selector(removePet), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        nest = Prop(.nest, at: nestPos, show: false)
        mounds = needs.stash.map { Prop(.mound, at: CGPoint(x: $0, y: groundY(at: $0))) }
        addPet()
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
                pets.randomElement()?.sq.say(news, 2.5)
            }
            acorns.forEach { $0.tick(dt) }
            plan()
            updatePlay(dt)
            for (i, p) in pets.enumerated() {
                p.index = i
                p.tick(dt, restack: restack)
            }
            updateNest(restack: restack)
        }
        RunLoop.main.add(t, forMode: .common)
    }

    func applicationWillTerminate(_ n: Notification) { needs.save() }

    // 메뉴를 열 때 컨디션 표시
    func menuWillOpen(_ menu: NSMenu) {
        statusLine.title = "배고픔 \(bar(needs.hunger))   기분 \(bar(needs.mood))"
        stashItem.title = "묻어둔 도토리: \(needs.stash.count)개"
    }

    // 바탕화면 층 <-> 모든 창 위
    @objc func toggleDesktop(_ item: NSMenuItem) {
        onDesktop.toggle()
        item.state = onDesktop ? .on : .off
        refreshWindows()
        for w in pets.map(\.window) + props {
            w.level = petLevel()
            if shown && (w !== nest.window || w.isVisible) { w.orderFrontRegardless() }
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
        let b = screenBounds(for: pet.sq.pos)
        let x = min(max(pet.sq.pos.x + rnd(-260, 260), b.minX + 90), b.maxX - 90)
        acorns.append(Acorn(at: CGPoint(x: x, y: b.maxY - 40)))
    }

    // 다람쥐마다 지금 어디로 갈지 정하고, 도착하면 할 일을 시작
    func plan() {
        let m = NSEvent.mouseLocation
        for (i, pet) in pets.enumerated() {
            let sq = pet.sq
            if sq.finished {
                sq.finished = false
                finishChore(pet)
            }
            guard sq.eatTime <= 0, sq.workTime <= 0, sq.mode != .held else {
                sq.target = nil
                pet.goal = nil
                continue
            }
            let b = screenBounds(for: sq.pos)
            var goal: Goal?
            var x: CGFloat = 0, rush: CGFloat = 95
            if let a = acorns.min(by: { abs($0.pos.x - sq.pos.x) < abs($1.pos.x - sq.pos.x) }) {
                goal = .acorn(ObjectIdentifier(a)); x = a.pos.x
            } else if pet.chaseTime > 0 {
                goal = .mouse; x = m.x; rush = 170
            } else if claudeReact, claude.state == .attention, sq.mode == .floor, !sq.nested, abs(m.x - sq.pos.x) > 140 {
                // Claude가 허락을 기다리면 마우스 쪽으로 다가가서 손 흔들기
                goal = .approach; x = m.x; rush = 110
            } else if let p = play, p.chaser === pet {
                goal = .tag; x = p.runner.sq.pos.x; rush = 150
            } else if let p = play, p.runner === pet {
                goal = .flee; x = sq.pos.x + (sq.pos.x >= p.chaser.sq.pos.x ? 200 : -200); rush = 120
            } else if needs.hungry, let s = needs.stash.min(by: { abs($0 - sq.pos.x) < abs($1 - sq.pos.x) }) {
                goal = .stash(s); x = s; rush = 80
            } else if world.trashed && i == 0 {
                // 휴지통은 보통 Dock 오른쪽 끝
                goal = .trash; x = b.maxX - 120; rush = 110
            } else if world.night && !sq.nested {
                goal = .nest; x = nestPos.x + [0, -26, 26, -13, 13][i % 5]; rush = 60
            }
            x = min(max(x, b.minX + 80), b.maxX - 80)
            if goal != nil, goal != .nest { sq.nested = false }

            if goal != pet.goal {
                pet.goal = goal
                switch goal {
                case .acorn?: sq.say("도토리다!")
                case .approach?: sq.say("불렀어?")
                case .stash?: sq.say("숨겨둔 도토리 먹어야지~", 2)
                case .trash?: sq.say("방금 뭐 버렸어?", 2)
                case .nest?: sq.say("졸려… 둥지 가야지", 2)
                default: break
                }
            }
            sq.target = goal == nil ? nil : x
            sq.rush = rush
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
                if needs.full {
                    // 배부르면 나중을 위해 묻어둠
                    pet.chore = .bury
                    sq.startWork(1.8, "나중에 먹어야지~")
                } else {
                    sq.startEating()
                    eaten += 1
                }
            case .mouse:
                if dx < 40 && m.y < sq.feet + 160 {
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
            case .nest:
                if dx < 8 {
                    pet.goal = nil
                    sq.target = nil
                    sq.nested = true
                    sq.sleeping = true
                    sq.targetSpeed = 0
                    sq.timer = rnd(20, 40)
                }
            case .approach, .flee:
                break
            }
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

    // 두 마리 이상이면 가끔 술래잡기
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
        guard needs.mood > 0.35, !world.night, rnd(0, 1) < 0.5 else { return }
        let free = pets.filter {
            $0.sq.mode == .floor && $0.sq.surface == nil && $0.sq.act == .none && $0.sq.target == nil
                && !$0.sq.sleeping && !$0.sq.nested
        }.shuffled()
        guard free.count >= 2 else { return }
        play = (free[0], free[1], 6)
        free[0].sq.say("술래잡기 하자!", 1.6)
        free[1].sq.say("잡아봐라~", 1.6)
    }

    // 둥지는 밤에만, 다람쥐보다 앞에 둬서 다리를 가림
    func updateNest(restack: Bool) {
        let want = world.night || pets.contains { $0.sq.nested }
        if want != nest.window.isVisible {
            if want { nest.window.orderFrontRegardless() } else { nest.window.orderOut(nil) }
        } else if want && restack {
            nest.window.orderFrontRegardless()
        }
    }

    @objc func toggleSing(_ item: NSMenuItem) {
        singAlong.toggle()
        item.state = singAlong ? .on : .off
    }

    @objc func toggle() {
        shown.toggle()
        toggleItem.title = shown ? "다람쥐 숨기기" : "다람쥐 보이기"
        statusItem.button?.appearsDisabled = !shown
        for p in pets { shown ? p.window.orderFrontRegardless() : p.window.orderOut(nil) }
        for w in props where !(shown && w === nest.window) { shown ? w.orderFrontRegardless() : w.orderOut(nil) }
    }

    @objc func addPet() {
        if !shown { toggle() }
        // 화면 위쪽에서 활강하며 등장
        let b = NSScreen.screens[0].visibleFrame
        let pet = Pet(at: CGPoint(x: rnd(b.minX + 150, b.maxX - 150), y: b.maxY - 120))
        // 그날 처음 아침에 켜면 기지개
        if pets.isEmpty && world.morning {
            let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
            if UserDefaults.standard.integer(forKey: "greetDay") != day {
                UserDefaults.standard.set(day, forKey: "greetDay")
                pet.sq.greetTime = 6
            }
        }
        pets.append(pet)
    }

    @objc func removePet() {
        pets.popLast()?.window.orderOut(nil)
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
    for (name, pose) in [("nest", Pose.nest), ("mound", Pose.mound)] {
        let rep = NSBitmapImageRep(cgImage: sprite(pose))
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
    for (name, set) in poses {
        world.weather = .clear
        let s = Squirrel(); set(s)
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
