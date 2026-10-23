#!/usr/bin/env bash
# 回声心语 autoreply.sh 行为回归。期望值全部手工推导，不用被测代码计算。
set -uo pipefail
cd "$(dirname "$0")/.."
SCRIPT=".github/autoreply.sh"
PASS=0 FAIL=0

ok(){ printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1"; printf '    期望 %q\n    实际 %q\n' "$2" "$3"; fi; }
has(){ case "$3" in *"$2"*) ok "$1";; *) no "$1"; printf '    未包含 %q\n' "$2";; esac; }
hasnt(){ case "$3" in *"$2"*) no "$1";; *) ok "$1";; esac; }

setup(){
  WORK=$(mktemp -d)
  export RUNNER_TEMP="$WORK"
  export GITHUB_OUTPUT="$WORK/output"; : > "$GITHUB_OUTPUT"
  export ECHOMIND_GH_BIN="$PWD/tests/shims/gh"
  export ECHOMIND_CURL_BIN="$PWD/tests/shims/curl"
  export ECHOMIND_API_BASE="https://example.invalid"
  export DASHSCOPE_API_KEY="fake-test-key"
  export ECHOMIND_ISSUE_NUMBER="8" ECHOMIND_ISSUE_AUTHOR="octocat" ECHOMIND_ISSUE_TITLE="今天很糟"
  export ECHOMIND_BODY_FILE="$WORK/issue_body.md"
  export ECHOMIND_CONTEXT_FILE="$WORK/context.md" ECHOMIND_REPLY_FILE="$WORK/reply.md" ECHOMIND_PAYLOAD_FILE="$WORK/payload.json"
  export ECHOMIND_FIXTURE_DIR="$PWD/tests/fixtures"
  export ECHOMIND_FIXTURE_ISSUE_LIST="$PWD/tests/fixtures/issue_list_empty.json"
  export ECHOMIND_FAKE_HTTP="200" ECHOMIND_FAKE_REPLY="好的，我在听。"
}
teardown(){ rm -rf "$WORK"; }
outval(){ local v;
  v=$(grep -A1 "^$1<<" "$GITHUB_OUTPUT" | tail -1);
  [ -n "$v" ] || v=$(sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -1);
  printf '%s' "$v"; }
SEP1='\n\n以下是一些相关的历史倾诉记录，供你参考：'
SEP2='\n'

echo "=== 1. generate 的请求消息与调用参数 ==="
setup
printf '%s' '我今晚睡不着，脑子停不下来' > "$ECHOMIND_BODY_FILE"
bash "$SCRIPT" generate >/dev/null 2>&1 || true
P="$ECHOMIND_PAYLOAD_FILE"
eq "user 内容等于标题与正文的既有拼接格式" '标题：今天很糟\n\n内容：我今晚睡不着，脑子停不下来' "$(jq -r '.messages[1].content' "$P" 2>/dev/null)"
eq "system 等于提示词文件原文" "$(cat .github/prompt.md)" "$(jq -r '.messages[0].content' "$P" 2>/dev/null)"
eq "模型名沿用既有默认" "qwen-plus" "$(jq -r '.model' "$P" 2>/dev/null)"
eq "temperature 不变" "0.9" "$(jq -r '.temperature' "$P" 2>/dev/null)"
eq "max_tokens 不变" "2000" "$(jq -r '.max_tokens' "$P" 2>/dev/null)"
eq "无上下文时消息条数为 2" "2" "$(jq -r '.messages | length' "$P" 2>/dev/null)"
teardown

echo "=== 2. generate 把历史上下文拼进 system ==="
setup
printf '%s' '正文' > "$ECHOMIND_BODY_FILE"
printf '%s' '那次我几乎想放弃了。' > "$WORK/ctx.md"
export ECHOMIND_CONTEXT_FILE="$WORK/ctx.md"
export ECHOMIND_PAYLOAD_FILE="$ECHOMIND_PAYLOAD_FILE"
bash "$SCRIPT" generate >/dev/null 2>&1 || true
SYS=$(jq -r '.messages[0].content' "$ECHOMIND_PAYLOAD_FILE" 2>/dev/null)
EXP="$(cat .github/prompt.md)${SEP1}${SEP2}那次我几乎想放弃了。"
eq "历史按既有格式接在提示词之后" "$EXP" "$SYS"
hasnt "倾诉正文不泄漏进 system" "标题：" "$SYS"
teardown

echo "=== 3. 倾诉正文里的命令不被执行 ==="
setup
printf '%s' '我很难受 $(touch '"$WORK"'/pwned) 还有 `id` 反引号' > "$ECHOMIND_BODY_FILE"
bash "$SCRIPT" generate >/dev/null 2>&1 || true
[ ! -e "$WORK/pwned" ] && ok "命令替换未被执行" || no "命令替换被执行（注入面仍在）"
has "正文原样进入 user 消息" '$(touch' "$(jq -r '.messages[1].content' "$ECHOMIND_PAYLOAD_FILE" 2>/dev/null)"
has "反引号原样进入 user 消息" '`id`' "$(jq -r '.messages[1].content' "$ECHOMIND_PAYLOAD_FILE" 2>/dev/null)"
teardown

echo "=== 4. 多行回复与 EOF 行的输出契约 ==="
setup
printf '%s' '正文' > "$ECHOMIND_BODY_FILE"
export ECHOMIND_FAKE_REPLY=$'我在听\nEOF\n你不是一个人'
bash "$SCRIPT" generate >/dev/null 2>&1 || true
eq "回复文件完整保留三行" $'我在听\nEOF\n你不是一个人' "$(cat "$ECHOMIND_REPLY_FILE" 2>/dev/null)"
has "GITHUB_OUTPUT 未被内容里的 EOF 行截断" "你不是一个人" "$(cat "$GITHUB_OUTPUT")"
eq "成功标记为 true" "true" "$(outval success)"
teardown

echo "=== 5. 退出码语义 ==="
setup
printf '%s' '正文' > "$ECHOMIND_BODY_FILE"
bash "$SCRIPT" generate >/dev/null 2>&1; eq "正常回复退出 0" "0" "$?"
ECHOMIND_FAKE_HTTP=500 bash "$SCRIPT" generate >/dev/null 2>&1; eq "上游非 200 退出 3" "3" "$?"
ECHOMIND_FAKE_REPLY="" bash "$SCRIPT" generate >/dev/null 2>&1; eq "200 但空回复退出 3" "3" "$?"
DASHSCOPE_API_KEY="" bash "$SCRIPT" generate >/dev/null 2>&1; eq "缺少 API Key 退出 5" "5" "$?"
bash "$SCRIPT" nosuchcmd >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "未知子命令非零退出" || no "未知子命令被静默接受"
teardown

echo "=== 6. context 装配 ==="
setup
printf '%s' '正文里引用了 [引用:#3] 这一条' > "$ECHOMIND_BODY_FILE"
bash "$SCRIPT" context >/dev/null 2>&1 || true
eq "closed 列表为空时不装配历史" "false" "$(outval has_history)"
eq "命中手动引用时标记为 true" "true" "$(outval has_refs)"
CTX=$(cat "$ECHOMIND_CONTEXT_FILE" 2>/dev/null)
has "引用块含编号与标题" "#3: 第三次尝试" "$CTX"
has "引用块含该条正文" "那次我几乎想放弃了。" "$CTX"
teardown

echo
echo "通过 $PASS 项，失败 $FAIL 项"
[ "$FAIL" -eq 0 ]
