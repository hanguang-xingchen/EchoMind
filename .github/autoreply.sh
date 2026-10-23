#!/usr/bin/env bash
# 回声心语 AI 倾听者：上下文装配与回复生成。
# 编排留在 workflow，逻辑在这里；数据只从环境变量与文件进入，绝不拼进命令行。
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
CONTEXT_FILE="${ECHOMIND_CONTEXT_FILE:-$WORK/context.md}"
REPLY_FILE="${ECHOMIND_REPLY_FILE:-$WORK/reply.md}"
PAYLOAD_FILE="${ECHOMIND_PAYLOAD_FILE:-$WORK/payload.json}"
PROMPT_FILE="${ECHOMIND_PROMPT_FILE:-.github/prompt.md}"
API_BASE="${ECHOMIND_API_BASE:-https://dashscope.aliyuncs.com/compatible-mode/v1}"
MODEL="${ECHOMIND_MODEL:-qwen-plus}"
TEMPERATURE="${ECHOMIND_TEMPERATURE:-0.9}"
MAX_TOKENS="${ECHOMIND_MAX_TOKENS:-2000}"
TIMEOUT="${ECHOMIND_TIMEOUT:-60}"

for _f in "$BODY_FILE" "$CONTEXT_FILE" "$REPLY_FILE" "$PAYLOAD_FILE"; do mkdir -p "$(dirname "$_f")" 2>/dev/null || true; done

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

# ── 装配历史上下文（沿用既有行为，本轮不改语义）─────────────────
cmd_context(){
  STAGE="context"
  need ECHOMIND_ISSUE_AUTHOR
  : > "$CONTEXT_FILE"
  local author="${ECHOMIND_ISSUE_AUTHOR}"
  local history num title body has_history="false"
  history="$("$GH" issue list --state closed --limit 10 --json number,title,body,user \
      --jq ".[] | select(.user.login == \"${author}\")" 2>/dev/null | head -1 || true)"
  if [ -n "$history" ]; then
    has_history="true"
    num="$(printf '%s' "$history" | jq -r '.number' 2>/dev/null || echo '')"
    title="$(printf '%s' "$history" | jq -r '.title' 2>/dev/null || echo '')"
    body="$(printf '%s' "$history" | jq -r '.body' 2>/dev/null || echo '')"
    { printf '\n--- 这位用户之前也倾诉过（#%s: %s） ---\n%s\n' "$num" "$title" "$body"; } >> "$CONTEXT_FILE"
  fi
  write_output has_history "$has_history"

  local has_refs="false" refs ref_title ref_body
  [ -f "$BODY_FILE" ] || die "找不到 Issue 正文文件 $BODY_FILE" "$EXIT_CONFIG"
  refs="$(grep -oP '\[引用:#\d+\]' "$BODY_FILE" | grep -oP '\d+' || true)"
  for num in $refs; do
    has_refs="true"
    ref_title="$("$GH" issue view "$num" --json title --jq '.title' 2>/dev/null || echo '未知标题')"
    ref_body="$("$GH" issue view "$num" --json body --jq '.body' 2>/dev/null || echo '无法获取内容')"
    { printf '\n--- 引用的历史倾诉（#%s: %s） ---\n%s\n' "$num" "$ref_title" "$ref_body"; } >> "$CONTEXT_FILE"
  done
  write_output has_refs "$has_refs"
  say info "上下文装配完成：历史=${has_history} 引用条数=$(printf '%s' "$refs" | wc -w | tr -d ' ')"
}

# ── 构造请求并调用模型 ────────────────────────────────────────
cmd_generate(){
  STAGE="generate"
  need DASHSCOPE_API_KEY
  need ECHOMIND_ISSUE_TITLE
  [ -f "$BODY_FILE" ] || die "找不到 Issue 正文文件 $BODY_FILE" "$EXIT_CONFIG"
  [ -f "$PROMPT_FILE" ] || die "找不到提示词文件 $PROMPT_FILE" "$EXIT_CONFIG"

  local prompt issue_body user_msg context full_prompt
  prompt="$(cat "$PROMPT_FILE")"
  issue_body="$(cat "$BODY_FILE")"
  user_msg="标题：${ECHOMIND_ISSUE_TITLE}\n\n内容：${issue_body}"
  context=""
  [ -f "$CONTEXT_FILE" ] && context="$(cat "$CONTEXT_FILE")"
  full_prompt="$prompt"
  [ -n "$context" ] && full_prompt="${prompt}\n\n以下是一些相关的历史倾诉记录，供你参考：\n${context}"

  jq -n --arg prompt "$full_prompt" --arg user_msg "$user_msg" \
        --arg model "$MODEL" --argjson temperature "$TEMPERATURE" --argjson max_tokens "$MAX_TOKENS" \
        '{model:$model, temperature:$temperature, max_tokens:$max_tokens,
          messages:[{role:"system",content:$prompt},{role:"user",content:$user_msg}]}' \
        > "$PAYLOAD_FILE"

  if [ "${ECHOMIND_DRY_RUN:-0}" = "1" ]; then
    say info "dry-run：请求体已写入 $PAYLOAD_FILE，正文长度 $(wc -c < "$PAYLOAD_FILE" | tr -d ' ') 字节"
    cat "$PAYLOAD_FILE" >&2
  fi

  local response http_code body reply
  response="$("$CURL" -s -w '\n%{http_code}' --max-time "$TIMEOUT" \
      "${API_BASE}/chat/completions" \
      -H "Authorization: Bearer ${DASHSCOPE_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "@${PAYLOAD_FILE}" || true)"
  http_code="$(printf '%s' "$response" | tail -1)"
  body="$(printf '%s' "$response" | sed '$d')"
  write_output http_code "$http_code"

  if [ "$http_code" != "200" ]; then
    write_output success "false"
    die "模型调用失败，HTTP ${http_code}：$(printf '%s' "$body" | head -c 300)" "$EXIT_LLM"
  fi
  reply="$(printf '%s' "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null || echo '')"
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
  context)  cmd_context ;;
  generate) cmd_generate ;;
  *) die "用法: autoreply.sh <context|generate>" "$EXIT_CONFIG" ;;
esac
