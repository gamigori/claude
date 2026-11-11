#!/bin/sh
# 하늘다람쥐 데스크톱 펫용 Claude Code 훅
# ~/.squirrel/claude-state 에 이벤트 이름, 도구 이름, 표시(test) 세 줄만 남김
# 명령 내용 자체는 저장하지 않고, 테스트 명령이었는지만 기록
d=$(cat)
x() { printf '%s' "$d" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }
event=$(x hook_event_name)
tool=$(x tool_name)
flag=""
if [ "$event" = PostToolUse ] && [ "$tool" = Bash ]; then
  if x tool_input.command | grep -Eq '(npm|pnpm|yarn|bun)( run)? test|pytest|jest|vitest|go test|cargo test|swift test|xcodebuild.* test|rspec|mocha|phpunit|make test|gradle.* test|mvn.* test'; then
    flag=test
  fi
fi
printf '%s\n%s\n%s\n' "$event" "$tool" "$flag" > "$HOME/.squirrel/claude-state.tmp" && mv "$HOME/.squirrel/claude-state.tmp" "$HOME/.squirrel/claude-state"
exit 0
