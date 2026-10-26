#!/usr/bin/env bash
# 回声心语 AI 倾听者：准入判定、历史轮装配、请求生成。
# 编排留在 workflow，逻辑在这里；数据只经环境变量与文件进入，绝不拼进命令行。
set -eu

EXIT_OK=0
EXIT_REJECT=2
EXIT_LLM=3
EXIT_PUBLISH=4
EXIT_CONFIG=5

STAGE="init"
say(){ printf '[%s][%s] %s\n' "$STAGE" "$1" "$2" >&2; }
die(){ local reason="$1" code="${2:-1}"; say error "$reason"; echo "::error::$reason"; exit "$code"; }
on_err(){ local rc=$?; say error "阶段 ${STAGE} 异常终止 (rc=${rc})"; echo "::error::阶段 ${STAGE} 异常终止"; exit "$rc"; }
trap on_err ERR

GH="${ECHOMIND_GH_BIN:-gh}"
CURL="${ECHOMIND_CURL_BIN:-curl}"
WORK="${RUNNER_TEMP:-}"
[ -n "$WORK" ] || WORK="$(mktemp -d)"
mkdir -p "$WORK"

BODY_FILE="${ECHOMIND_BODY_FILE:-$WORK/issue_body.md}"
TURNS_FILE="${ECHOMIND_TURNS_FILE:-$WORK/turns.json}"
META_FILE="${ECHOMIND_META_FILE:-$WORK/history_meta.json}"
REPLY_FILE="${ECHOMIND_REPLY_FILE:-$WORK/reply.md}"
PAYLOAD_FILE="${ECHOMIND_PAYLOAD_FILE:-$WORK/payload.json}"
for _f in "$BODY_FILE" "$TURNS_FILE" "$META_FILE" "$REPLY_FILE" "$PAYLOAD_FILE"; do
  mkdir -p "$(dirname "$_f")" 2>/dev/null || true
done

PROMPT_FILE="${ECHOMIND_PROMPT_FILE:-.github/prompt.md}"
CONTEXT_TEMPLATE="${ECHOMIND_CONTEXT_TEMPLATE:-.github/context.md}"
API_BASE="${ECHOMIND_API_BASE:-https://dashscope.aliyuncs.com/compatible-mode/v1}"
MODEL="${ECHOMIND_MODEL:-qwen-plus}"
TEMPERATURE="${ECHOMIND_TEMPERATURE:-0.9}"
MAX_TOKENS="${ECHOMIND_MAX_TOKENS:-2000}"
TIMEOUT="${ECHOMIND_TIMEOUT:-60}"
MAX_HISTORY="${ECHOMIND_MAX_HISTORY_TURNS:-3}"
MAX_BODY_CHARS="${ECHOMIND_MAX_BODY_CHARS:-1500}"

need(){ [ -n "${!1:-}" ] || die "缺少必需环境变量 $1" "$EXIT_CONFIG"; }

# 写步骤输出：分隔符带随机后缀，避免内容里出现同名单独一行导致截断
write_output(){
  local name="$1" value="$2" delim
  delim="__EOM_${name}_$(date +%s)_${RANDOM}__"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { printf '%s<<%s\n%s\n%s\n' "$name" "$delim" "$value" "$delim"; } >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$name" "$value"
  fi
}

fmt_date(){ local v="${1:-}"; [ -n "$v" ] || { printf '最近'; return 0; }
  date -u -d "$v" +%-m月%-d日 2>/dev/null || printf '最近'; }

days_since(){ local v="${1:-}"; [ -n "$v" ] || { printf '0'; return 0; }
  local then now; then="$(date -u -d "$v" +%s 2>/dev/null || echo 0)"; now="$(date -u +%s)"
  printf '%s' "$(( (now - then) / 86400 ))"; }

visitor_code(){ printf '%s' "${1:-anon}" | cksum | awk '{ printf "%04X", $1 % 65536 }'; }

# 去掉 Issue 表单渲染出的字段标题行，只留下人真正写下的话
clean_body(){
  printf '%s\n' "${1:-}" | sed '/^###[[:space:]]/d' \
    | awk 'NF || seen { if (NF) seen=1; if (seen) print }'
}

truncate_body(){
  local limit="$MAX_BODY_CHARS"
  printf '%s' "${1:-}" | jq -R -s -r --argjson n "$limit" \
    'rtrimstr("\n") | if (length > $n) then .[0:$n] + "…" else . end'
}

# ── 准入判定：决定这条 Issue 要不要占用一次模型调用 ─────────────
cmd_admit() {
  STAGE="admit"
  need ECHOMIND_EVENT
  need ECHOMIND_REPO
  need ECHOMIND_ISSUE_NUMBER
  need ECHOMIND_ISSUE_AUTHOR

  local repo="${ECHOMIND_REPO}" author="${ECHOMIND_ISSUE_AUTHOR}" number="${ECHOMIND_ISSUE_NUMBER}"
  local event="${ECHOMIND_EVENT}" label="${ECHOMIND_LABEL:-}"
  local required="${ECHOMIND_LABEL_REQUIRED:-倾诉}"
  local api="repos/${repo}"

  reject() {
    write_output admit "reject"
    write_output reject_reason "$1"
    say info "准入拒绝：$1"
    exit "$EXIT_REJECT"
  }

  if [ "$event" = "labeled" ] && [ "$label" != "$required" ]; then
    reject label
  fi

  # 已回复判定
  local replied
  replied="$("$GH" api "${api}/issues/${number}/comments" \
      --jq '[.[] | select(.user.login == "github-actions[bot]")] | length' 2>/dev/null || echo 0)"
  if [ "${replied:-0}" -gt 0 ]; then
    reject answered
  fi

  # 已取消 Star 判定：按自觉机制处理，避免 owner / stargazer 语义导致误拒
  say info "已取消 Star 判定，按自觉机制继续"
  echo "::notice::已取消 Star 判定，按自觉机制处理"

  # 冷却期判定
  local cooldown="${ECHOMIND_COOLDOWN_MINUTES:-10}"
  if [ "$cooldown" != "0" ]; then
    local cutoff others num hit
    cutoff="$(date -u -d "-${cooldown} minutes" +%Y-%m-%dT%H:%M:%SZ)"
    others="$("$GH" issue list --repo "$repo" --state all --limit 10 --author "$author" --json number 2>/dev/null || true)"
    for num in $(printf '%s' "${others:-[]}" | jq -r '.[].number' 2>/dev/null | grep -v "^${number}$" || true); do
      hit="$("$GH" api "${api}/issues/${num}/comments" \
          --jq "[.[] | select(.user.login == \"github-actions[bot]\" and .created_at >= \"${cutoff}\")] | length" 2>/dev/null || echo 0)"
      if [ "${hit:-0}" -gt 0 ]; then
        reject cooldown
      fi
    done
  fi

  write_output admit "proceed"
  say info "准入通过"
}

# ── 装配历史轮：同一倾诉者的 user/assistant 真实对话 ────────────
cmd_context(){
  STAGE="context"
  need ECHOMIND_REPO
  need ECHOMIND_ISSUE_AUTHOR
  need ECHOMIND_ISSUE_NUMBER

  local repo="${ECHOMIND_REPO}" author="${ECHOMIND_ISSUE_AUTHOR}" number="${ECHOMIND_ISSUE_NUMBER}"
  local required="${ECHOMIND_LABEL_REQUIRED:-倾诉}"
  local auto nums="" refs owner n body_text
  local items="[]" turns="[]" last_created="" user_turns=0

  auto="$("$GH" issue list --repo "$repo" --state all --limit 20 --label "$required" \
      --author "$author" --json number,title,createdAt 2>/dev/null || true)"
  while IFS= read -r n; do
    [ -n "$n" ] && [ "$n" != "$number" ] && nums="${nums}${n}"$'\n'
  done < <(printf '%s' "${auto:-[]}" | jq -r '.[].number' 2>/dev/null || true)

  body_text=""
  [ -f "$BODY_FILE" ] && body_text="$(cat "$BODY_FILE")"
  refs="$(printf '%s' "$body_text" | grep -oP '\\[引用:#\\d+\\]' | grep -oP '\\d+' | sort -u || true)"
  for n in $refs; do
    [ "$n" = "$number" ] && continue
    owner="$("$GH" issue view "$n" --json author --jq '.author.login' 2>/dev/null || echo '')"
    if [ -z "$owner" ]; then
      say warn "引用 #${n} 读取失败，跳过"
      continue
    fi
    if [ "$owner" != "$author" ]; then
      say warn "引用 #${n} 属于其他倾诉者，已跳过"
      echo "::notice::已忽略对 #${n} 的引用（不属于同一倾诉者）"
      continue
    fi
    nums="${nums}${n}"$'\n'
  done

  for n in $(printf '%s' "$nums" | sed '/^$/d' | sort -un); do
    local detail
    detail="$("$GH" issue view "$n" --json number,title,body,createdAt,author 2>/dev/null || true)"
    if [ -z "$detail" ]; then
      say warn "#${n} 详情读取失败，跳过"
      continue
    fi
    items="$(printf '%s' "$items" | jq --argjson d "$detail" '. + [$d]')"
  done
  items="$(printf '%s' "$items" | jq -c "sort_by(.createdAt) | .[-${MAX_HISTORY}:]")"

  local obj title body created reply clean
  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    n="$(printf '%s' "$obj" | jq -r '.number')"
    title="$(printf '%s' "$obj" | jq -r '.title // ""')"
    created="$(printf '%s' "$obj" | jq -r '.createdAt // ""')"
    body="$(printf '%s' "$obj" | jq -r '.body // ""')"
    clean="$(truncate_body "$(clean_body "$body")")"
    user_turn="#${n} ${title}（$(fmt_date "$created")）"$'\n\n'"${clean}"
    turns="$(printf '%s' "$turns" | jq --arg c "$user_turn" '. + [{role:"user",content:$c}]')"
    user_turns=$((user_turns + 1))
    [ -n "$created" ] && last_created="$created"
    reply="$("$GH" api "repos/${repo}/issues/${n}/comments" \
        --jq '[.[] | select(.user.login == "github-actions[bot]")] | last | .body // empty' 2>/dev/null || true)"
    if [ -n "$reply" ]; then
      turns="$(printf '%s' "$turns" | jq --arg c "$reply" '. + [{role:"assistant",content:$c}]')"
    fi
  done < <(printf '%s' "$items" | jq -c '.[]')

  printf '%s' "$turns" | jq . > "$TURNS_FILE"
  printf '{"user_turns":%s,"last_created":"%s"}' "$user_turns" "${last_created:-}" > "$META_FILE"
  write_output history_turns "$user_turns"
  if [ "$user_turns" -gt 0 ]; then write_output has_history "true"; else write_output has_history "false"; fi
  say info "历史装配完成：本人轮次 ${user_turns} 条"
}

# ── 渲染场景层（白名单变量），与稳定人设合成单条 system ──────────
render_system(){
  local author="${ECHOMIND_ISSUE_AUTHOR:-anon}" owner="${ECHOMIND_REPO_OWNER:-}"
  local uturns=0 last="" visit_note="" relation="" label_code
  if [ -f "$META_FILE" ]; then
    uturns="$(jq -r '.user_turns // 0' "$META_FILE" 2>/dev/null || echo 0)"
    last="$(jq -r '.last_created // ""' "$META_FILE" 2>/dev/null || echo '')"
  fi
  if [ "${uturns:-0}" -gt 0 ]; then
    visit_note="这是 TA 第 $((uturns + 1)) 次来了，距上一次大约 $(days_since "$last") 天。"
  else
    visit_note="这是 TA 第一次在这里开口。"
  fi
  if [ -n "$owner" ] && [ "$author" = "$owner" ]; then
    relation="TA 是这个空间搭建的人，此刻也只是来歇一口气的。"
  fi
  label_code="来客 $(visitor_code "$author")"

  local tpl out
  [ -f "$CONTEXT_TEMPLATE" ] || die "找不到场景模板 $CONTEXT_TEMPLATE" "$EXIT_CONFIG"
  tpl="$(cat "$CONTEXT_TEMPLATE")"
  out="${tpl//\{\{visitor_label\}\}/$label_code}"
  out="${out//\{\{visit_note\}\}/$visit_note}"
  out="${out//\{\{relationship_note\}\}/$relation}"
  local leftover
  leftover="$(printf '%s' "$out" | grep -oE '\\{\\{[a-z_]+\\}\\}' | sort -u | tr '\n' ' ' || true)"
  [ -n "$leftover" ] && say warn "场景模板含未登记的变量，已原样保留：$leftover"

  local persona
  [ -f "$PROMPT_FILE" ] || die "找不到提示词文件 $PROMPT_FILE" "$EXIT_CONFIG"
  persona="$(cat "$PROMPT_FILE")"
  printf '%s\n\n%s' "$out" "$persona"
}

cmd_render(){
  STAGE="render"
  render_system
}

# ── 构造请求并调用模型 ────────────────────────────────────────
cmd_generate(){
  STAGE="generate"
  need DASHSCOPE_API_KEY
  need ECHOMIND_ISSUE_TITLE
  need ECHOMIND_ISSUE_NUMBER
  [ -f "$BODY_FILE" ] || die "找不到 Issue 正文文件 $BODY_FILE" "$EXIT_CONFIG"

  local system turns current body_clean payload
  system="$(render_system)"
  turns="[]"
  [ -f "$TURNS_FILE" ] && turns="$(cat "$TURNS_FILE")"
  body_clean="$(truncate_body "$(clean_body "$(cat "$BODY_FILE")")")"
  current="#${ECHOMIND_ISSUE_NUMBER} ${ECHOMIND_ISSUE_TITLE}（$(fmt_date "$(date -u +%Y-%m-%dT%H:%M:%SZ)")）"$'\n\n'"${body_clean}"

  payload="$(jq -n --arg sys "$system" --argjson turns "$turns" --arg cur "$current" \
      --arg model "$MODEL" --argjson temperature "$TEMPERATURE" --argjson max_tokens "$MAX_TOKENS" \
      '{model:$model, temperature:$temperature, max_tokens:$max_tokens,
        messages: ([{role:"system",content:$sys}] + $turns + [{role:"user",content:$cur}])}')"
  printf '%s' "$payload" > "$PAYLOAD_FILE"

  if [ "${ECHOMIND_DRY_RUN:-0}" = "1" ]; then
    say info "dry-run：请求体已写入 $PAYLOAD_FILE，共 $(jq -r '.messages | length' "$PAYLOAD_FILE") 条消息"
    cat "$PAYLOAD_FILE" >&2
  fi

  local response http_code resp_body reply
  response="$("$CURL" -s -w '\n%{http_code}' --max-time "$TIMEOUT" \
      "${API_BASE}/chat/completions" \
      -H "Authorization: Bearer ${DASHSCOPE_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "@${PAYLOAD_FILE}" || true)"
  http_code="$(printf '%s' "$response" | tail -1)"
  resp_body="$(printf '%s' "$response" | sed '$d')"
  write_output http_code "$http_code"

  if [ "$http_code" != "200" ]; then
    write_output success "false"
    die "模型调用失败，HTTP ${http_code}：$(printf '%s' "$resp_body" | head -c 300)" "$EXIT_LLM"
  fi
  reply="$(printf '%s' "$resp_body" | jq -r '.choices[0].message.content // empty' 2>/dev/null || echo '')"
  if [ -z "$reply" ]; then
    write_output success "false"
    die "模型返回 200 但没有内容" "$EXIT_LLM"
  fi
  printf '%s' "$reply" > "$REPLY_FILE"
  write_output reply "$reply"
  write_output success "true"
  say info "生成成功，回复 $(wc -c < "$REPLY_FILE" | tr -d ' ') 字节写入 $REPLY_FILE"
}

STAGE="dispatch"
case "${1:-}" in
  admit)    cmd_admit ;;
  context)  cmd_context ;;
  render)   cmd_render ;;
  generate) cmd_generate ;;
  *) die "用法: autoreply.sh <admit|context|render|generate>" "$EXIT_CONFIG" ;;
esac
