#!/bin/sh
# 하늘다람쥐 데스크톱 펫용 Claude Code 훅
# 훅 이벤트 이름과 도구 이름만 ~/.squirrel/claude-state 에 남김 (도구 입력 내용은 저장하지 않음)
d=$(cat)
event=$(printf '%s' "$d" | /usr/bin/plutil -extract hook_event_name raw -o - - 2>/dev/null)
tool=$(printf '%s' "$d" | /usr/bin/plutil -extract tool_name raw -o - - 2>/dev/null)
printf '%s\n%s\n' "$event" "$tool" > "$HOME/.squirrel/claude-state.tmp" && mv "$HOME/.squirrel/claude-state.tmp" "$HOME/.squirrel/claude-state"
exit 0
