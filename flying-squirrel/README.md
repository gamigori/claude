# 하늘다람쥐 🐿️

바탕화면 위를 돌아다니는 macOS 픽셀 하늘다람쥐 펫. Claude Code와 함께 만들었어요.

![icon](icon.png)

## 할 수 있는 것

- 화면 가장자리를 타고 오르고, 바닥과 창 위를 걸어 다니고, 공중에서는 막을 펴고 활공해요
- 마우스로 잡아서 던질 수 있고, 클릭하면 반응하고, 마우스로 쓰다듬으면 좋아해요
- 가만히 두면 눈을 감고 졸아요
- 위젯·스티커 메모 위에도 올라가요 (바탕화면 모드)
- Spotify / 음악 앱에서 노래가 나오면 가사를 말풍선에 띄우며 따라 불러요 (가사: [LRCLIB](https://lrclib.net))
- 메뉴바에서 도토리를 주면 쫓아가서 냠냠 먹어요
- Claude Code가 생각하거나 작업할 때 같이 고민하고, 끝나면 "다 했다!" 해요

## 설치

```sh
./build.sh
```

`~/Applications/하늘다람쥐.app` 이 만들어져요. 메뉴바 아이콘에서 켜고 끌 수 있어요.

## Claude Code 연동 (선택)

1. `hook.sh` 를 `~/.squirrel/hook.sh` 로 복사
2. `~/.claude/settings.json` 의 `hooks` 에 `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `Notification`, `SessionEnd` 이벤트마다 아래 명령을 추가

```json
{ "type": "command", "command": "/bin/sh \"$HOME/.squirrel/hook.sh\"", "timeout": 5, "async": true }
```

훅은 이벤트 이름과 도구 이름만 `~/.squirrel/claude-state` 에 기록해요.
