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
re(){ if printf '%s' "$3" | grep -q "$2"; then ok "$1"; else no "$1"; printf '    不匹配 %s\n' "$2"; fi; }

setup(){
  WORK=$(mktemp -d)
  export RUNNER_TEMP="$WORK"
  export GITHUB_OUTPUT="$WORK/output"; : > "$GITHUB_OUTPUT"
  export ECHOMIND_GH_BIN="$PWD/tests/shims/gh"
  export ECHOMIND_CURL_BIN="$PWD/tests/shims/curl"
  export ECHOMIND_API_BASE="https://example.invalid"
  export DASHSCOPE_API_KEY="tk-test-value"
  export ECHOMIND_ISSUE_NUMBER="8" ECHOMIND_ISSUE_AUTHOR="octocat" ECHOMIND_ISSUE_TITLE="今天很糟"
  export ECHOMIND_REPO="someowener/somerepo" ECHOMIND_REPO_OWNER="someowener"
  export ECHOMIND_EVENT="labeled" ECHOMIND_LABEL="倾诉" ECHOMIND_LABEL_REQUIRED="倾诉"
  export ECHOMIND_COOLDOWN_MINUTES="10"
  export ECHOMIND_BODY_FILE="$WORK/issue_body.md"
  export ECHOMIND_TURNS_FILE="$WORK/turns.json" ECHOMIND_PAYLOAD_FILE="$WORK/payload.json" ECHOMIND_REPLY_FILE="$WORK/reply.md"
  cp -r "$PWD/tests/fixtures" "$WORK/fixtures"
  export ECHOMIND_FIXTURE_DIR="$WORK/fixtures"
  export ECHOMIND_FIXTURE_ISSUE_LIST="$WORK/fixtures/history_none.json"
  export ECHOMIND_FAKE_HTTP="200" ECHOMIND_FAKE_REPLY="好的，我在听。"
  printf '%s' '正文' > "$ECHOMIND_BODY_FILE"
}
teardown(){ rm -rf "$WORK"; }
outval(){ local v;
  v=$(grep -A1 "^$1<<" "$GITHUB_OUTPUT" | tail -1);
  [ -n "$v" ] || v=$(sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -1);
  printf '%s' "$v"; }
TODAY=$(date -u +%-m月%-d日)

echo "=== 1. 请求的基本结构 ==="
setup
printf '%s' '我今晚睡不着，脑子停不下来' > "$ECHOMIND_BODY_FILE"
bash "$SCRIPT" generate >/dev/null 2>&1 || true
U=$(jq -r '.messages[-1].content' "$ECHOMIND_PAYLOAD_FILE" 2>/dev/null)
eq "无历史时消息为 system + user 两条" "2" "$(jq -r '.messages | length' "$ECHOMIND_PAYLOAD_FILE" 2>/dev/null)"
eq "末轮 user 采用「#编号 标题（日期）」加正文的格式" "#8 今天很糟（${TODAY}）"$'\n\n'"我今晚睡不着，脑子停不下来" "$U"
hasnt "正文里不再出现字面反斜杠 n" '\n' "$U"
eq "模型名沿用默认" "qwen-plus" "$(jq -r '.model' "$ECHOMIND_PAYLOAD_FILE" 2>/dev/null)"
eq "temperature 不变" "0.9" "$(jq -r '.temperature' "$ECHOMIND_PAYLOAD_FILE" 2>/dev/null)"
eq "max_tokens 不变" "2000" "$(jq -r '.max_tokens' "$ECHOMIND_PAYLOAD_FILE" 2>/dev/null)"
eq "system 消息只有一条" "1" "$(jq -r '[.messages[] | select(.role=="system")] | length' "$ECHOMIND_PAYLOAD_FILE" 2>/dev/null)"
SYS=$(jq -r '.messages[0].content' "$ECHOMIND_PAYLOAD_FILE" 2>/dev/null)
has "system 含倾听者人设" "你是一位温暖的倾听者" "$SYS"
has "system 含场景说明" "匿名倾诉空间" "$SYS"
has "system 含不再提问的约束" "不要提问" "$SYS"
teardown

echo "=== 2. 倾诉正文里的命令不被执行 ==="
setup
printf '%s' '我很难受 $(touch '"$WORK"'/pwned) 还有 `id` 反引号' > "$ECHOMIND_BODY_FILE"
bash "$SCRIPT" generate >/dev/null 2>&1 || true
[ ! -e "$WORK/pwned" ] && ok "命令替换未被执行" || no "命令替换被执行（注入面仍在）"
has "正文原样进入 user 消息" '$(touch' "$(jq -r '.messages[-1].content' "$ECHOMIND_PAYLOAD_FILE" 2>/dev/null)"
has "反引号原样进入 user 消息" '`id`' "$(jq -r '.messages[-1].content' "$ECHOMIND_PAYLOAD_FILE" 2>/dev/null)"
teardown

echo "=== 3. 回复输出契约 ==="
setup
export ECHOMIND_FAKE_REPLY=$'我在听\nEOF\n你不是一个人'
bash "$SCRIPT" generate >/dev/null 2>&1 || true
eq "回复文件完整保留三行" $'我在听\nEOF\n你不是一个人' "$(cat "$ECHOMIND_TURNS_FILE.reply" 2>/dev/null || cat "$WORK/reply.md" 2>/dev/null)"
has "GITHUB_OUTPUT 未被内容里的 EOF 行截断" "你不是一个人" "$(cat "$GITHUB_OUTPUT")"
eq "成功标记为 true" "true" "$(outval success)"
teardown

echo "=== 4. 退出码语义 ==="
setup
bash "$SCRIPT" generate >/dev/null 2>&1; eq "正常回复退出 0" "0" "$?"
ECHOMIND_FAKE_HTTP=500 bash "$SCRIPT" generate >/dev/null 2>&1; eq "上游非 200 退出 3" "3" "$?"
ECHOMIND_FAKE_REPLY="" bash "$SCRIPT" generate >/dev/null 2>&1; eq "200 但空回复退出 3" "3" "$?"
DASHSCOPE_API_KEY="" bash "$SCRIPT" generate >/dev/null 2>&1; eq "缺少 API Key 退出 5" "5" "$?"
bash "$SCRIPT" nosuchcmd >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "未知子命令非零退出" || no "未知子命令被静默接受"
teardown

echo "=== 5. 准入判定 ==="
setup
echo '[{"login":"other"}]' > "$ECHOMIND_FIXTURE_DIR/stargazers.json"
bash "$SCRIPT" admit >/dev/null 2>&1; eq "确证未 star 时退出 2" "2" "$?"
eq "拒绝原因为 no_star" "no_star" "$(outval reject_reason)"
echo '[{"login":"octocat"}]' > "$ECHOMIND_FIXTURE_DIR/stargazers.json"
bash "$SCRIPT" admit >/dev/null 2>&1; eq "已 star 时放行" "0" "$?"
eq "放行标记写入输出" "proceed" "$(outval admit)"
ECHOMIND_LABEL="bug" bash "$SCRIPT" admit >/dev/null 2>&1; eq "标签不符时拒绝" "2" "$?"
ECHOMIND_EVENT="opened" ECHOMIND_LABEL="" bash "$SCRIPT" admit >/dev/null 2>&1; eq "opened 事件不查标签" "0" "$?"
echo '[{"body":"回复","user":{"login":"github-actions[bot]"}}]' > "$ECHOMIND_FIXTURE_DIR/comments_8.json"
bash "$SCRIPT" admit >/dev/null 2>&1; eq "本条已被回复过时不重复回复" "2" "$?"
eq "拒绝原因为 answered" "answered" "$(outval reject_reason)"
rm -f "$ECHOMIND_FIXTURE_DIR/stargazers.json"
echo '[]' > "$ECHOMIND_FIXTURE_DIR/comments_8.json"
bash "$SCRIPT" admit >/dev/null 2>&1; eq "star 查询失败时保守放行" "0" "$?"
recent=$(date -u -d '-2 minutes' +%Y-%m-%dT%H:%M:%SZ)
printf '%s\n' '[{"number":7,"title":"上一条","createdAt":"'"$recent"'"}]' > "$ECHOMIND_FIXTURE_ISSUE_LIST"
printf '%s\n' '[{"body":"回复","user":{"login":"github-actions[bot]"},"created_at":"'"$recent"'"}]' > "$ECHOMIND_FIXTURE_DIR/comments_7.json"
bash "$SCRIPT" admit >/dev/null 2>&1; eq "同作者两分钟前刚被回复时进入冷却" "2" "$?"
eq "拒绝原因为 cooldown" "cooldown" "$(outval reject_reason)"
teardown

echo "=== 6. 历史轮装配 ==="
setup
export ECHOMIND_FIXTURE_ISSUE_LIST="$ECHOMIND_FIXTURE_DIR/history_two.json"
bash "$SCRIPT" context >/dev/null 2>&1 || true
eq "两条历史装配出三轮对话" "3" "$(jq -r 'length' "$ECHOMIND_TURNS_FILE" 2>/dev/null)"
eq "轮次角色顺序为 user assistant user" '["user","assistant","user"]' "$(jq -rc '[.[].role]' "$ECHOMIND_TURNS_FILE" 2>/dev/null)"
has "较早一条按时间正序在前" "#3 第三次尝试" "$(jq -r '.[0].content' "$ECHOMIND_TURNS_FILE" 2>/dev/null)"
eq "assistant 轮取的是倾听者当时的真实回复" "那次辛苦了，我一直记着。" "$(jq -r '.[1].content' "$ECHOMIND_TURNS_FILE" 2>/dev/null)"
has "历史轮含日期标记" "10月20日" "$(jq -r '.[2].content' "$ECHOMIND_TURNS_FILE" 2>/dev/null)"
hasnt "没有 bot 回复的历史不伪造 assistant 轮" "谢谢" "$(jq -r '.[].content' "$ECHOMIND_TURNS_FILE" 2>/dev/null)"
teardown

setup
export ECHOMIND_FIXTURE_ISSUE_LIST="$ECHOMIND_FIXTURE_DIR/history_self.json"
bash "$SCRIPT" context >/dev/null 2>&1 || true
eq "不把当前这条自己算进历史" "0" "$(jq -r 'length' "$ECHOMIND_TURNS_FILE" 2>/dev/null)"
teardown

setup
printf '%s' '想谈谈 [引用:#9] 那位陌生人的事' > "$ECHOMIND_BODY_FILE"
bash "$SCRIPT" context >/dev/null 2>&1 || true
eq "跨作者引用被忽略" "0" "$(jq -r 'length' "$ECHOMIND_TURNS_FILE" 2>/dev/null)"
re "忽略时留下可见警告" "跳过" "$(bash "$SCRIPT" context 2>&1 || true)"
teardown

setup
printf '%s' '想起 [引用:#5] 那次' > "$ECHOMIND_BODY_FILE"
bash "$SCRIPT" context >/dev/null 2>&1 || true
eq "同作者的手动引用会被装配" "1" "$(jq -r 'length' "$ECHOMIND_TURNS_FILE" 2>/dev/null)"
has "引用轮带编号与标题" "#5 作为发起者的自述" "$(jq -r '.[0].content' "$ECHOMIND_TURNS_FILE" 2>/dev/null)"
teardown

setup
export ECHOMIND_FIXTURE_ISSUE_LIST="$ECHOMIND_FIXTURE_DIR/history_two.json"
printf '%s' '再谈 [引用:#3]' > "$ECHOMIND_BODY_FILE"
bash "$SCRIPT" context >/dev/null 2>&1 || true
eq "自动历史与手动引用同条时去重" "3" "$(jq -r 'length' "$ECHOMIND_TURNS_FILE" 2>/dev/null)"
eq "两个编号各出现一次" "2" "$(jq -r '[.[] | select(.role=="user")] | length' "$ECHOMIND_TURNS_FILE" 2>/dev/null)"
eq "被引用的编号没有被重复装配" "1" "$(jq -r '[.[] | select(.content | startswith("#3 "))] | length' "$ECHOMIND_TURNS_FILE" 2>/dev/null)"
teardown

setup
printf '%s' '[引用:#11]' > "$ECHOMIND_BODY_FILE"
bash "$SCRIPT" context >/dev/null 2>&1 || true
T=$(jq -r '.[0].content // ""' "$ECHOMIND_TURNS_FILE" 2>/dev/null)
hasnt "模板的字段标题行被清洗" "###" "$T"
has "真正写下的内容被保留" "同学说我矫情" "$T"
teardown

setup
printf '%s' '[引用:#12]' > "$ECHOMIND_BODY_FILE"
bash "$SCRIPT" context >/dev/null 2>&1 || true
eq "超长历史按字符数截断" "true" "$(jq -r '[(.[0].content | length) < 1600] | first' "$ECHOMIND_TURNS_FILE" 2>/dev/null)"
has "截断处有省略标记" "…" "$(jq -r '.[0].content' "$ECHOMIND_TURNS_FILE" 2>/dev/null)"
teardown

echo "=== 7. 多轮请求的最终形态 ==="
setup
export ECHOMIND_FIXTURE_ISSUE_LIST="$ECHOMIND_FIXTURE_DIR/history_two.json"
bash "$SCRIPT" context >/dev/null 2>&1 || true
bash "$SCRIPT" generate >/dev/null 2>&1 || true
eq "角色序列为 system 之后历史轮再本次" '["system","user","assistant","user","user"]' "$(jq -rc '[.messages[].role]' "$ECHOMIND_PAYLOAD_FILE" 2>/dev/null)"
has "末轮是本次倾诉" "#8 今天很糟" "$(jq -r '.messages[-1].content' "$ECHOMIND_PAYLOAD_FILE" 2>/dev/null)"
SYS=$(jq -r '.messages[0].content' "$ECHOMIND_PAYLOAD_FILE" 2>/dev/null)
re "场景层写出来访次数" "第 3 次" "$SYS"
hasnt "系统提示不泄漏 GitHub 账号名" "octocat" "$SYS"
teardown

echo "=== 8. 提示词渲染 ==="
setup
printf '%s' '来客 {{visitor_label}} / {{visit_note}} / {{relationship_note}} / 未知 {{bogus_var}}' > "$WORK/tpl.md"
export ECHOMIND_CONTEXT_TEMPLATE="$WORK/tpl.md"
R=$(bash "$SCRIPT" render 2>/dev/null)
hasnt "已知变量被替换" "{{visitor_label}}" "$R"
has "代号形式注入" "来客 " "$R"
has "未知变量原样保留不吞掉" "{{bogus_var}}" "$R"
export ECHOMIND_REPO_OWNER="octocat"
R2=$(bash "$SCRIPT" render 2>/dev/null)
has "站长本人来访时给出关系说明" "搭建" "$R2"
teardown

echo
echo "通过 $PASS 项，失败 $FAIL 项"
[ "$FAIL" -eq 0 ]
