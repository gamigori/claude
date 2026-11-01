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
//   생각 중이면 턱 괴고 고민, 다 끝나면 기뻐하고, 확인이 필요하면 폴짝폴짝
import AppKit

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
    enum State: Equatable { case idle, thinking, tool(String), done, attention }
    var state: State = .idle
    private var since = Date.distantPast
    private var lastMod: Date?
    private let path = NSHomeDirectory() + "/.squirrel/claude-state"

    func poll() {
        if let mod = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
           mod != lastMod {
            lastMod = mod
            since = mod
            // 첫 줄: 훅 이벤트 이름, 둘째 줄: 도구 이름
            let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").components(separatedBy: "\n")
            let tool = lines.count > 1 ? lines[1] : ""
            switch lines[0] {
            case "UserPromptSubmit", "PostToolUse": state = .thinking
            case "PreToolUse": state = .tool(ClaudeWatch.describe(tool))
            case "Stop": state = .done
            case "Notification": state = .attention
            default: state = .idle
            }
        }
        // 오래된 상태는 정리
        let age = Date().timeIntervalSince(since)
        switch state {
        case .done where age > 3.5, .attention where age > 20: state = .idle
        case .thinking where age > 600, .tool where age > 600: state = .idle
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

// MARK: - 하늘다람쥐

enum Mode { case wall, floor, air, held }

// 멈춰서 앞을 보고 하는 행동
enum Act: Equatable { case none, sing, think(String), done, attention, eat }

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
    var target: CGFloat?        // 쫓아가는 도토리의 x
    var eatTime: CGFloat = 0
    var happyTime: CGFloat = 0
    var meals: [CGFloat] = []   // 최근에 먹은 시각
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
        speed += (targetSpeed - speed) * min(1, dt * 4)
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
            targetSpeed = abs(tx - pos.x) < 6 ? 0 : 95
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
        if rnd(0, 1) < 0.35 {
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
        sleeping = false
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
            say("깜짝!")
            timer = rnd(1, 2)
        } else {
            say(["안녕!", "도토리 줘!", "간지러워!", "뭐야?", "♥", "히히", "날아볼까?"].randomElement()!)
        }
        // 바닥에 있으면 폴짝
        if mode == .floor {
            mode = .air
            surface = nil
            airTime = 0
            vel = CGVector(dx: 0, dy: 420)
        }
    }

    func startEating() {
        target = nil
        eatTime = 2.6
        say("냠냠", 2.4)
    }

    func doneEating() {
        meals = meals.filter { time - $0 < 180 } + [time]
        timer = rnd(1, 2)
        if meals.count >= 3 {
            meals = []
            say("배불러~", 2.5)
            sleeping = true
            timer = 12
        } else {
            say(["맛있다! ♥", "도토리 최고!", "냠냠 ♥"].randomElement()!)
            happyTime = 1.6
        }
    }

    // 쓰다듬어 줬을 때
    func petted() {
        happyTime = 2
        say(sleeping ? "음냐..." : ["헤헤 ♥", "기분 좋아~", "더 해줘!"].randomElement()!)
    }

    // 0: 가만히, 1/2: 걷는 프레임
    var frame: Int {
        if sleeping || act != .none || (mode != .held && mode != .air && speed < 6) { return 0 }
        return Int(gait / .pi) % 2 == 0 ? 1 : 2
    }

    // 가사가 나오는 동안 입을 뻐끔뻐끔, 간주 중엔 입 다물고 흥얼
    var mouthOpen: Bool {
        lyric != nil && (time * 3.5).truncatingRemainder(dividingBy: 1) < 0.55
    }
    // 가끔 눈을 감고 신나게
    var happyEyes: Bool { Int(time / 2.5) % 3 == 2 }

    // 앞모습일 때 들썩이는 높이
    var bob: CGFloat {
        switch act {
        case .sing: return Int(time * 4) % 2 == 0 ? P : 0
        case .done: return Int(time * 5) % 2 == 0 ? P * 3 : 0
        case .attention: return Int(time * 6) % 2 == 0 ? P * 2 : 0
        default: return 0
        }
    }

    // 하는 행동에 맞는 말풍선
    var actText: String? {
        switch act {
        case .sing: return lyric
        case .think(let what): return what + String(repeating: ".", count: Int(time * 2.5) % 3 + 1)
        case .done: return "다 했다!"
        case .attention: return "확인해줘!"
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

enum Pose: Hashable {
    case climb(Int, Bool), side(Int, Bool), front(open: Bool, happy: Bool), think(Int), eat(Int), glide, acorn
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
        case .air: return sq.gliding ? .glide : .side(sq.frame, false)
        case _ where sq.act != .none:
            switch sq.act {
            case .think: return .think(Int(sq.time / 1.6) % 3 == 2 ? 1 : 0)
            case .eat: return .eat(Int(sq.time * 5) % 2)
            case .done: return .front(open: true, happy: true)
            case .attention: return .front(open: Int(sq.time * 4) % 2 == 0, happy: false)
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
        case .front, .think, .eat:
            // 노래 박자에 맞춰 통통, 기쁘면 폴짝
            c.draw(img, in: CGRect(x: W / 2 - 46, y: baseY + sq.bob, width: w, height: h))
            anchor = CGPoint(x: W / 2 - 4, y: baseY + h + 6)
        case .glide:
            let wiggle: CGFloat = sq.mode == .held && Int(sq.time * 8) % 2 == 0 ? P : 0
            c.draw(img, in: CGRect(x: W / 2 - w / 2, y: baseY + wiggle, width: w, height: h))
            anchor = CGPoint(x: W / 2, y: baseY + h + 2)
        case .acorn:
            anchor = .zero
        }
        c.restoreGState()

        if sq.sleeping { drawFloating(c, "z", at: anchor, sizes: 9...17) }
        let side = CGPoint(x: anchor.x + 22, y: anchor.y - 10)
        switch sq.act {
        case .sing: drawFloating(c, "♪", at: side, sizes: 11...17)
        case .think: drawFloating(c, "?", at: side, sizes: 10...16)
        case .attention: drawFloating(c, "!", at: side, sizes: 12...18)
        case .done: drawFloating(c, "♥", at: side, sizes: 10...16)
        default: if sq.happyTime > 0 { drawFloating(c, "♥", at: side, sizes: 10...16) }
        }
        if let text = sq.bubble ?? sq.actText { drawBubble(c, text, at: anchor) }
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

final class AcornView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.clear(bounds)
        c.interpolationQuality = .none
        let img = sprite(.acorn)
        c.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(img.width) * P, height: CGFloat(img.height) * P))
    }
}

// 하늘에서 떨어지는 도토리
final class Acorn {
    var pos: CGPoint            // 바닥에 닿는 아래 가운데
    var vy: CGFloat = 0
    var landed = false
    let window: NSWindow

    init(at p: CGPoint) {
        pos = p
        let size = NSRect(x: 0, y: 0, width: 36, height: 36)
        window = NSWindow(contentRect: size, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = petLevel()
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = AcornView(frame: size)
        window.orderFrontRegardless()
    }

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
        window.setFrameOrigin(NSPoint(x: pos.x.rounded() - 18, y: pos.y.rounded() - 4))
    }
}

final class Pet {
    let sq = Squirrel()
    let view: PetView
    let window: NSWindow

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
        sq.act = currentAct()
        sq.lyric = sq.act == .sing ? music.currentLine : nil
        sq.update(dt, bounds: screenBounds(for: sq.pos))
        window.setFrameOrigin(NSPoint(x: sq.pos.x.rounded() - W / 2, y: sq.pos.y.rounded() - W / 2))
        view.needsDisplay = true
        // 다람쥐 근처가 아니면 클릭이 뒤 창으로 통과
        let m = NSEvent.mouseLocation
        let center = sq.mode == .floor || sq.mode == .air ? CGPoint(x: sq.pos.x, y: sq.feet + 30) : sq.pos
        let dist = hypot(m.x - center.x, m.y - center.y)
        window.ignoresMouseEvents = !view.dragging && dist > 50

        // 마우스로 살살 문지르면 쓰다듬기
        if dist < 45 && !view.dragging {
            rub += hypot(m.x - lastMouse.x, m.y - lastMouse.y)
        } else {
            rub = max(0, rub - dt * 300)
        }
        lastMouse = m
        if rub > 700 { rub = 0; sq.petted() }
    }

    private var rub: CGFloat = 0
    private var lastMouse = CGPoint.zero

    // 우선순위: 먹기 > 도토리 쫓기 > Claude 반응 > 노래
    func currentAct() -> Act {
        if sq.eatTime > 0 { return .eat }
        guard sq.mode == .floor || sq.mode == .wall, sq.target == nil else { return .none }
        if claudeReact {
            switch claude.state {
            case .thinking: return .think("흠")
            case .tool(let what): return .think(what)
            case .done: return .done
            case .attention: return .attention
            case .idle: break
            }
        }
        return singAlong && music.playing ? .sing : .none
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var pets: [Pet] = []
    var statusItem: NSStatusItem!
    var toggleItem: NSMenuItem!
    var shown = true
    var last = CACurrentMediaTime()
    var windowRefresh: CGFloat = 0
    var musicPoll: CGFloat = 0
    var acorns: [Acorn] = []
    var eatenItem: NSMenuItem!
    var eaten = UserDefaults.standard.integer(forKey: "acornsEaten") {
        didSet {
            UserDefaults.standard.set(eaten, forKey: "acornsEaten")
            eatenItem.title = "지금까지 먹은 도토리: \(eaten)개"
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐿️"
        let menu = NSMenu()
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
        menu.addItem(.separator())
        menu.addItem(withTitle: "도토리 주기", action: #selector(giveAcorn), keyEquivalent: "a").target = self
        eatenItem = menu.addItem(withTitle: "지금까지 먹은 도토리: \(eaten)개", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "다람쥐 한 마리 더", action: #selector(addPet), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "한 마리 보내기", action: #selector(removePet), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        addPet()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [unowned self] _ in
            let now = CACurrentMediaTime()
            let dt = CGFloat(min(now - last, 0.05))
            last = now
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
            acorns.forEach { $0.tick(dt) }
            feed()
            pets.forEach { $0.tick(dt, restack: restack) }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    // 바탕화면 층 <-> 모든 창 위
    @objc func toggleDesktop(_ item: NSMenuItem) {
        onDesktop.toggle()
        item.state = onDesktop ? .on : .off
        refreshWindows()
        for w in pets.map(\.window) + acorns.map(\.window) {
            w.level = petLevel()
            if shown { w.orderFrontRegardless() }
        }
    }

    @objc func toggleClaude(_ item: NSMenuItem) {
        claudeReact.toggle()
        item.state = claudeReact ? .on : .off
    }

    // 다람쥐 근처 하늘에서 도토리 하나
    @objc func giveAcorn() {
        if !shown { toggle() }
        guard let pet = pets.randomElement() else { return }
        let b = screenBounds(for: pet.sq.pos)
        let x = min(max(pet.sq.pos.x + rnd(-260, 260), b.minX + 90), b.maxX - 90)
        acorns.append(Acorn(at: CGPoint(x: x, y: b.maxY - 40)))
    }

    // 다람쥐마다 가장 가까운 도토리를 쫓고, 닿으면 먹음
    func feed() {
        for pet in pets {
            let sq = pet.sq
            guard sq.eatTime <= 0, sq.mode != .held,
                  let i = acorns.indices.min(by: { abs(acorns[$0].pos.x - sq.pos.x) < abs(acorns[$1].pos.x - sq.pos.x) })
            else { sq.target = nil; continue }
            if sq.target == nil { sq.say("도토리다!") }
            sq.target = acorns[i].pos.x
            if acorns[i].landed, sq.mode == .floor, sq.surface == nil, abs(acorns[i].pos.x - sq.pos.x) < 10 {
                acorns.remove(at: i).window.orderOut(nil)
                sq.startEating()
                eaten += 1
            }
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
        for a in acorns { shown ? a.window.orderFrontRegardless() : a.window.orderOut(nil) }
    }

    @objc func addPet() {
        if !shown { toggle() }
        // 화면 위쪽에서 활강하며 등장
        let b = NSScreen.screens[0].visibleFrame
        pets.append(Pet(at: CGPoint(x: rnd(b.minX + 150, b.maxX - 150), y: b.maxY - 120)))
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
    ]
    for (name, set) in poses {
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
