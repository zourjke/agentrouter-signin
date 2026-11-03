#!/usr/bin/env bash
# AgentRouter 多账号签到面板（GitHub OAuth 登录即签到 + Telegram 推送）
# 依赖：bash / curl / jq / python3（仅用于 TOTP）
# 用法：./agentrouter.sh            进入面板
#       ./agentrouter.sh --cron     无交互跑一轮（定时任务用）
#       ./agentrouter.sh --checkin  同 --cron
set -o pipefail

AR_VERSION="1.0"
AR_HOME="${AR_HOME:-$HOME/.agentrouter}"
CONF="$AR_HOME/config.json"
ACCOUNTS="$AR_HOME/accounts.json"
STATE="$AR_HOME/state.json"
LOGDIR="$AR_HOME/logs"
JARDIR="$AR_HOME/jars"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'
C_D=$'\033[2m'; C_BOLD=$'\033[1m'; C_N=$'\033[0m'

# ---------------------------------------------------------------- 初始化
ar_init() {
  mkdir -p "$AR_HOME" "$LOGDIR" "$JARDIR"
  chmod 700 "$AR_HOME" 2>/dev/null
  if [ ! -f "$CONF" ]; then
    cat > "$CONF" <<'EOF'
{
  "site": "https://agentrouter.org",
  "github": "https://github.com",
  "client_id": "Ov23lidtiR4LeVZvVRNL",
  "quota_divisor": 500000,
  "expect_reward": 25,
  "currency": "$",
  "site_proxy": "http://127.0.0.1:7890",
  "github_proxy": "",
  "clash_api": "http://127.0.0.1:9999",
  "clash_secret": "",
  "clash_group": "🚀 手动切换",
  "tg": { "token": "", "chat_id": "", "enabled": true }
}
EOF
    chmod 600 "$CONF"
  fi
  [ -f "$ACCOUNTS" ] || echo '[]' > "$ACCOUNTS"
  [ -f "$STATE" ] || echo '{}' > "$STATE"
  chmod 600 "$ACCOUNTS" "$STATE" 2>/dev/null
}

cfg() { jq -r "$1" "$CONF" 2>/dev/null; }
SITE=$(cfg .site); GH=$(cfg .github); CID=$(cfg .client_id)
DIV=$(cfg .quota_divisor); CUR=$(cfg .currency); EXPECT=$(cfg .expect_reward)
SITE_PROXY=$(cfg .site_proxy); GH_PROXY=$(cfg .github_proxy)

AR_DEBUG="${AR_DEBUG:-0}"
dbg() {
  [ "$AR_DEBUG" = "1" ] || return 0
  printf '%s [DBG] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOGDIR/debug.log" >&2
}

log() {
  local d; d=$(date '+%Y-%m-%d')
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOGDIR/$d.log"
}
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✔%s %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '%s!%s %s\n' "$C_Y" "$C_N" "$*"; }
err()  { printf '%s✘%s %s\n' "$C_R" "$C_N" "$*"; }
hr()   { printf '%s\n' "────────────────────────────────────────────────────────"; }

# ---------------------------------------------------------------- HTTP
# ar_curl <jar> [curl args...]   站点/默认走 site_proxy
ar_curl() {
  local jar="$1"; shift
  local p=()
  [ -n "$SITE_PROXY" ] && p=(-x "$SITE_PROXY")
  curl -sS --connect-timeout 8 --max-time 25 "${p[@]}" \
       -b "$jar" -c "$jar" -A "$UA" \
       -H 'Accept: text/html,application/json;q=0.9,*/*;q=0.8' \
       -H 'Accept-Language: zh-CN,zh;q=0.9' "$@"
}

GH_MODE=""
# gh_curl <jar> <mode:auto|direct|proxy> [curl args...]
gh_curl() {
  local jar="$1" mode="${2:-auto}"; shift 2
  local p=()
  case "$mode" in
    proxy)  p=(-x "${GH_PROXY:-$SITE_PROXY}") ;;
    direct) p=(--noproxy '*') ;;
    *)      if [ -n "$GH_MODE" ]; then
              if [ "$GH_MODE" = "proxy" ]; then p=(-x "${GH_PROXY:-$SITE_PROXY}"); else p=(--noproxy '*'); fi
            elif [ -n "$GH_PROXY" ]; then p=(-x "$GH_PROXY"); else p=(--noproxy '*'); fi ;;
  esac
  curl -sS --connect-timeout 8 --max-time 25 "${p[@]}" \
       -b "$jar" -c "$jar" -A "$UA" \
       -H 'Accept: text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8' \
       -H 'Accept-Language: zh-CN,zh;q=0.9' "$@"
}

# 先直连再代理（GitHub 线路经常两边轮着坏）
gh_try() {
  local jar="$1"; shift
  local out
  out=$(gh_curl "$jar" direct "$@" 2>/dev/null) && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  out=$(gh_curl "$jar" proxy "$@" 2>/dev/null) && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  return 1
}

jar_path() { echo "$JARDIR/$1.jar"; }
jar_reset() { : > "$1"; }

# cookie 字符串 -> Netscape jar
cookie_to_jar() { # <jarfile> <domain> <secure:0|1> <"a=b; c=d">
  local f="$1" dom="$2" sec="$3" str="$4"
  { echo "# Netscape HTTP Cookie File"; echo "$dom	FALSE	/	$([ "$sec" = 1 ] && echo TRUE || echo FALSE)	0	_	_"; } > "$f"
  printf '%s' "$str" | tr ';' '\n' | while IFS= read -r kv; do
    kv=$(printf '%s' "$kv" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$kv" ] && continue
    local k="${kv%%=*}" v="${kv#*=}"
    [ -z "$k" ] && continue
    printf '%s\tFALSE\t/\t%s\t0\t%s\t%s\n' "$dom" "$([ "$sec" = 1 ] && echo TRUE || echo FALSE)" "$k" "$v" >> "$f"
  done
  chmod 600 "$f"
}

# jar -> cookie 字符串
jar_to_cookie() { # <jarfile> <domain> [name...]
  local f="$1" dom="$2"; shift 2
  awk -v d="$dom" -v names="$*" '
    BEGIN { n = split(names, arr, " ") }
    /^#/ && !/^#HttpOnly_/ { next }
    {
      line = $0
      sub(/^#HttpOnly_/, "", line)
      c = split(line, f, "\t")
      if (c < 7) next
      if (f[1] != d && f[1] != "." d) next
      if (n > 0) { hit = 0; for (i = 1; i <= n; i++) if (f[6] == arr[i]) hit = 1; if (!hit) next }
      printf "%s=%s; ", f[6], f[7]
    }' "$f" | sed 's/; $//'
}

# ---------------------------------------------------------------- TOTP
totp() { # <base32 secret>
  python3 - "$1" <<'PY'
import base64, hashlib, hmac, struct, sys, time
s = sys.argv[1].replace(" ", "").replace("-", "").upper()
s += "=" * ((8 - len(s) % 8) % 8)
key = base64.b32decode(s)
c = int(time.time()) // 30
d = hmac.new(key, struct.pack(">Q", c), hashlib.sha1).digest()
o = d[-1] & 0x0F
print("%06d" % ((struct.unpack(">I", d[o:o+4])[0] & 0x7FFFFFFF) % 1000000))
PY
}

# ---------------------------------------------------------------- GitHub 登录
# 返回 ok | 2fa | device | badpass | error
gh_login() { # <jar> <user> <pass>
  local jar="$1" u="$2" p="$3" tok loc code
  code=$(gh_curl "$jar" direct -o /dev/null -w '%{http_code}' "$GH/login" 2>/dev/null)
  GH_MODE="direct"
  if [ "$code" != "200" ]; then
    code=$(gh_curl "$jar" proxy -o /dev/null -w '%{http_code}' "$GH/login" 2>/dev/null)
    GH_MODE="proxy"
  fi
  [ "$code" != "200" ] && { echo "error:http$code"; return; }
  if [ "$code" != "200" ]; then
    : # 直接用当前出口，不切节点
    code=$(gh_curl "$jar" auto -o /dev/null -w '%{http_code}' "$GH/login" 2>/dev/null)
    [ "$code" != "200" ] && { echo "error:http$code"; return; }
  fi
  tok=$(gh_curl "$jar" auto "$GH/login" 2>/dev/null | grep -oP 'name="authenticity_token" value="\K[^"]+' | head -1)
  [ -z "$tok" ] && { echo "error:nologintoken"; return; }
  loc=$(gh_curl "$jar" auto -o /tmp/ar_gh_login.html -w '%{redirect_url}' \
        -X POST "$GH/session" \
        --data-urlencode "authenticity_token=$tok" \
        --data-urlencode "login=$u" --data-urlencode "password=$p" \
        --data "webauthn-unsupported=true" --data "commit=Sign in" 2>/dev/null)
  case "$loc" in
    *two-factor*)      echo 2fa ;;
    *verified-device*) echo device ;;
    "")
      if grep -q "Incorrect username or password" /tmp/ar_gh_login.html 2>/dev/null; then
        echo badpass
      elif grep -qi "whoa there\|rate limit\|too many" /tmp/ar_gh_login.html 2>/dev/null; then
        echo ratelimit
      else
        echo blocked
      fi ;;
    *)                 echo ok ;;
  esac
}

gh_otp() { # <jar> <code> -> ok|fail
  local jar="$1" otp="$2" tok loc
  tok=$(gh_curl "$jar" auto -L "$GH/sessions/two-factor" 2>/dev/null | grep -oP 'name="authenticity_token" value="\K[^"]+' | head -1)
  [ -z "$tok" ] && { echo fail; return; }
  local i
  for i in 1 2 3; do
    loc=$(gh_curl "$jar" auto -o /tmp/ar_otp.html -w '%{redirect_url}' -X POST "$GH/sessions/two-factor" \
          --data-urlencode "authenticity_token=$tok" --data-urlencode "otp=$otp" \
          --data "webauthn-unsupported=true" 2>/dev/null)
    [ -n "$loc" ] && break
    printf '  %s提交超时，重试 %d/3…%s\n' "$C_Y" "$i" "$C_N" >&2
    sleep 1
  done
  [ -n "$loc" ] && echo ok || echo fail
}

gh_verified() { # <jar> <code> 邮箱设备验证
  local jar="$1" c="$2" tok loc
  tok=$(gh_curl "$jar" auto -L "$GH/sessions/verified-device" 2>/dev/null | grep -oP 'name="authenticity_token" value="\K[^"]+' | head -1)
  [ -z "$tok" ] && { echo fail; return; }
  loc=$(gh_curl "$jar" auto -o /dev/null -w '%{redirect_url}' -X POST "$GH/sessions/verified-device" \
        --data-urlencode "authenticity_token=$tok" --data-urlencode "otp=$c" 2>/dev/null)
  [ -n "$loc" ] && echo ok || echo fail
}

gh_alive_code() { # <jar> -> http code
  gh_curl "$1" auto -o /dev/null -w '%{http_code}' "$GH/settings/profile" 2>/dev/null
}

gh_alive() { # <jar> -> 0/1
  local code
  code=$(gh_curl "$1" auto -o /dev/null -w '%{http_code}' "$GH/settings/profile" 2>/dev/null)
  [ "$code" = "200" ]
}

# ---------------------------------------------------------------- 站点 OAuth
site_state() { # <site_jar> -> state
  ar_curl "$1" "$SITE/api/oauth/state?mode=login" 2>/dev/null | jq -r '.data // empty' 2>/dev/null
}

# <gh_jar> <state> -> code
site_get_code() {
  local jar="$1" st="$2" url loc body
  url="$GH/login/oauth/authorize?client_id=$CID&state=$st&scope=user:email&allow_signup=true"
  loc=""
  local try
  for try in 1 2; do
    loc=$(gh_curl "$jar" proxy -o /tmp/ar_auth.html -w '%{redirect_url}' "$url" 2>/dev/null)
    [ -n "$loc" ] && break
    loc=$(gh_curl "$jar" direct -o /tmp/ar_auth.html -w '%{redirect_url}' "$url" 2>/dev/null)
    [ -n "$loc" ] && break
  done

  case "$loc" in
    *"/login"*) return 1 ;;               # 会话失效被踢回登录页
    *code=*)    printf '%s' "${loc#*code=}" | sed 's/&.*//'; return 0 ;;
  esac

  # 200：可能是「已授权」页（带 code 链接），也可能是同意页
  body=$(cat /tmp/ar_auth.html 2>/dev/null)
  local c
  c=$(printf '%s' "$body" | grep -oP 'href="[^"]*?code=\K[0-9a-f]+' | head -1)
  [ -n "$c" ] && { printf '%s' "$c"; return 0; }

  # 同意页：按 form action 提交
  local action tok
  action=$(printf '%s' "$body" | grep -oP '<form[^>]*action="\K[^"]+' | head -1)
  tok=$(printf '%s' "$body" | grep -oP 'name="authenticity_token" value="\K[^"]+' | head -1)
  [ -z "$action" ] && return 1
  [ -z "$tok" ] && return 1
  case "$action" in /*) action="$GH$action" ;; esac
  loc=$(gh_curl "$jar" direct -o /tmp/ar_auth2.html -w '%{redirect_url}' -X POST "$action" \
        --data-urlencode "authenticity_token=$tok" \
        --data-urlencode "client_id=$CID" \
        --data-urlencode "state=$st" \
        --data "scope=user:email" --data "authorize=1" 2>/dev/null)
  [ -z "$loc" ] && loc=$(gh_curl "$jar" proxy -o /tmp/ar_auth2.html -w '%{redirect_url}' -X POST "$action" \
        --data-urlencode "authenticity_token=$tok" \
        --data-urlencode "client_id=$CID" \
        --data-urlencode "state=$st" \
        --data "scope=user:email" --data "authorize=1" 2>/dev/null)
  case "$loc" in
    *code=*) printf '%s' "${loc#*code=}" | sed 's/&.*//'; return 0 ;;
  esac
  c=$(grep -oP 'href="[^"]*?code=\K[0-9a-f]+' /tmp/ar_auth2.html 2>/dev/null | head -1)
  [ -n "$c" ] && { printf '%s' "$c"; return 0; }
  return 1
}

# <site_jar> <code> <state> -> json
site_callback() {
  ar_curl "$1" "$SITE/api/oauth/github?code=$2&state=$3" 2>/dev/null
}

# <site_jar> <uid> [token] -> quota
site_quota() {
  local jar="$1" uid="$2" tok="$3" hdr=()
  [ -n "$tok" ] && hdr=(-H "Authorization: Bearer $tok")
  [ -n "$uid" ] && hdr+=(-H "New-Api-User: $uid")
  ar_curl "$jar" "${hdr[@]}" "$SITE/api/user/self" 2>/dev/null | jq -r '.data.quota // empty' 2>/dev/null
}

# ---------------------------------------------------------------- 账号存储
acc_count() { jq 'length' "$ACCOUNTS" 2>/dev/null || echo 0; }
acc_field() { jq -r ".[$1].$2 // empty" "$ACCOUNTS" 2>/dev/null; }
acc_set()   { # <idx> <key> <value>
  local tmp; tmp=$(mktemp)
  jq --argjson i "$1" --arg k "$2" --arg v "$3" '.[$i][$k]=$v' "$ACCOUNTS" > "$tmp" && mv "$tmp" "$ACCOUNTS"
  chmod 600 "$ACCOUNTS"
}
acc_add() { # <json object>
  local tmp; tmp=$(mktemp)
  jq --argjson o "$1" '. + [$o]' "$ACCOUNTS" > "$tmp" && mv "$tmp" "$ACCOUNTS"
  chmod 600 "$ACCOUNTS"
}
acc_del() {
  local tmp; tmp=$(mktemp)
  jq --argjson i "$1" 'del(.[$i])' "$ACCOUNTS" > "$tmp" && mv "$tmp" "$ACCOUNTS"
  chmod 600 "$ACCOUNTS"
}

# ---------------------------------------------------------------- 余额基线
state_key() { printf '%s' "$1" | tr -d '|' ; }
state_prev() { # <name> -> 上一日余额（用本地日期，别用 jq 的 UTC now）
  jq -r --arg k "$1" --arg t "$(date +%F)" \
     '(.[$k] // {}) | to_entries | sort_by(.key) | map(select(.key < $t)) | last | .value // empty' "$STATE" 2>/dev/null
}
state_put() { # <name> <balance>
  local tmp; tmp=$(mktemp)
  jq --arg k "$1" --arg d "$(date +%F)" --argjson v "$2" \
     '.[$k] = ((.[$k] // {}) + {($d): $v})' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
  chmod 600 "$STATE"
}

# ---------------------------------------------------------------- 金额
fmt_money() { # <value>
  [ -z "$1" ] || [ "$1" = "null" ] && { printf '—'; return; }
  printf '%s%s' "$CUR" "$(awk -v v="$1" 'BEGIN{printf "%.4f", v}')"
}
fmt_delta() { # <value>
  [ -z "$1" ] || [ "$1" = "null" ] && { printf '—'; return; }
  awk -v v="$1" -v c="$CUR" 'BEGIN{printf "%s%s%.4f", c, (v>=0?"+":"-"), (v<0?-v:v)}'
}

# ---------------------------------------------------------------- Telegram
tg_send() { # <text>
  local token chat
  token=$(cfg .tg.token); chat=$(cfg .tg.chat_id)
  [ -z "$token" ] || [ -z "$chat" ] && return 1
  curl -sS --max-time 40 ${SITE_PROXY:+-x "$SITE_PROXY"} \
       -X POST "https://api.telegram.org/bot$token/sendMessage" \
       --data-urlencode "chat_id=$chat" \
       --data-urlencode "parse_mode=HTML" \
       --data-urlencode "disable_web_page_preview=true" \
       --data-urlencode "text=$1" >/dev/null 2>&1
}

tg_probe_chats() { # <token>
  curl -sS --max-time 30 ${SITE_PROXY:+-x "$SITE_PROXY"} \
       "https://api.telegram.org/bot$1/getUpdates" 2>/dev/null
}

# ---------------------------------------------------------------- 签到核心
R_OK=0; R_MSG=""; R_BAL=""; R_PREV=""; R_CHECKED=""; R_UID=""

# <idx> <interactive:0|1>
checkin_account() {
  local idx="$1" inter="${2:-0}"
  local name uid gu gp gs gc tok jar_gh jar_site st code cb quota id checked quota_before
  R_OK=0; R_MSG=""; R_BAL=""; R_PREV=""; R_CHECKED=""; R_UID=""

  name=$(acc_field "$idx" name); [ -z "$name" ] && name="acc$idx"
  uid=$(acc_field "$idx" uid)
  gu=$(acc_field "$idx" github_user)
  gp=$(acc_field "$idx" github_password)
  gs=$(acc_field "$idx" github_totp_secret)
  local go; go=$(acc_field "$idx" github_otp)
  gc=$(acc_field "$idx" github_cookie)
  tok=$(acc_field "$idx" access_token)

  dbg "checkin[$idx] name=$name uid=$uid 有密码=$([ -n "$gp" ] && echo yes || echo no) 有cookie=$([ -n "$gc" ] && echo ${#gc}字 || echo 空) 有otp=$([ -n "$go" ] && echo yes || echo no) 有secret=$([ -n "$gs" ] && echo yes || echo no)"

  jar_gh=$(jar_path "gh_$idx"); jar_site=$(jar_path "site_$idx")
  jar_reset "$jar_gh"; jar_reset "$jar_site"

  [ -n "$gc" ] && cookie_to_jar "$jar_gh" "github.com" 1 "$gc"
  [ -n "$tok" ] && [ -n "$uid" ] && quota_before=$(site_quota "$jar_site" "$uid" "$tok")

  # ① GitHub 会话
  local ac; ac=$(gh_alive_code "$jar_gh")
  dbg "gh_alive_code=$ac"
  if [ "$ac" = "000" ]; then
    R_MSG="GitHub 线路不通（http000，当前出口），本次跳过等下次重试"
    return 1
  fi
  if [ "$ac" = "200" ]; then
    dbg "gh_alive=yes（复用已存 cookie）"
  else
    dbg "gh_alive=no（cookie 缺失或失效，开始登录）"
    if [ -z "$gu" ] || [ -z "$gp" ]; then
      R_MSG="GitHub 会话已失效，且未保存账号密码（请在面板重新添加或更新 Cookie）"
      return 1
    fi
    local st1
    st1=$(gh_login "$jar_gh" "$gu" "$gp")
    dbg "gh_login=$st1"
    case "$st1" in
      2fa)
        local otp=""
        if [ -n "$gs" ]; then otp=$(totp "$gs"); elif [ -n "$go" ]; then otp="$go"; fi
        if [ -z "$otp" ] && [ "$inter" = "1" ]; then
          local try=0
          while :; do
            try=$((try+1))
            printf '\n%s检测到两步验证%s —— 请输入 Authenticator 上的 6 位码（或恢复码），直接回车取消\n' "$C_Y" "$C_N"
            printf '验证码: '
            rd otp || break
            [ -z "$otp" ] && break
            otp=$(printf '%s' "$otp" | tr -d ' \t-')
            if [ "${#otp}" -eq 6 ] || [ "${#otp}" -ge 10 ]; then break; fi
            printf '%s格式不对（应为 6 位数字），再试一次%s\n' "$C_R" "$C_N"
            [ "$try" -ge 3 ] && { otp=""; break; }
          done
        fi
        [ -z "$otp" ] && { R_MSG="账号开启了两步验证，但未配置 TOTP 密钥"; return 1; }
        dbg "验证码来源=$([ -n "$go" ] && echo 预置 || ([ -n "$gs" ] && echo TOTP密钥 || echo 交互)) 长度=${#otp}"
        local r2; r2=$(gh_otp "$jar_gh" "$otp")
        dbg "gh_otp=$r2"
        [ "$r2" != "ok" ] && { R_MSG="两步验证码校验失败"; return 1; }
        [ -n "$go" ] && acc_set "$idx" github_otp "" ;;
      device)
        local dc=""
        if [ "$inter" = "1" ]; then
          printf '%s' "GitHub 要求邮箱设备验证码（已发到你邮箱）: "; read -r dc
        fi
        [ -z "$dc" ] && { R_MSG="需要邮箱设备验证码（GitHub 新设备验证）"; return 1; }
        local r3; r3=$(gh_verified "$jar_gh" "$dc")
        [ "$r3" != "ok" ] && { R_MSG="设备验证码校验失败"; return 1; } ;;
      badpass) R_MSG="GitHub 账号或密码不正确"; return 1 ;;
      ratelimit) R_MSG="GitHub 限流（同 IP 登录太频繁），换节点或等 10 分钟"; return 1 ;;
      blocked) R_MSG="GitHub 静默拒绝登录（多为出口 IP 被风控），换节点再试"; return 1 ;;
      *) R_MSG="GitHub 登录失败（$st1）"; return 1 ;;
    esac
    local nc; nc=$(jar_to_cookie "$jar_gh" "github.com")
    dbg "导出cookie长度=${#nc} jar有效行=$(grep -vc '^#' "$jar_gh" 2>/dev/null || echo 0)"
    [ -n "$nc" ] && acc_set "$idx" github_cookie "$nc"
    gh_alive "$jar_gh" || { R_MSG="GitHub 登录后仍未取得会话"; return 1; }
  fi

  # ② 站点 state
  st=$(site_state "$jar_site")
  dbg "site_state 长度=${#st}"
  [ -z "$st" ] && { R_MSG="获取站点 OAuth state 失败（网络或代理问题）"; return 1; }

  # ③ 授权拿 code
  code=$(site_get_code "$jar_gh" "$st")
  dbg "oauth_code=${code:-空}"
  if [ -z "$code" ]; then
    R_MSG="GitHub 授权未拿到 code（线路中断或会话失效，可加 --debug 复跑）"
    return 1
  fi

  # ④ 回调换登录态（这一步就是签到）
  cb=$(site_callback "$jar_site" "$code" "$st")
  if [ "$(printf '%s' "$cb" | jq -r '.success // false')" != "true" ]; then
    R_MSG="站点换取登录态失败：$(printf '%s' "$cb" | jq -r '.message // "未知"')"
    return 1
  fi
  id=$(printf '%s' "$cb" | jq -r '.data.id // empty')
  checked=$(printf '%s' "$cb" | jq -r '.data.checked_in // empty')
  R_CHECKED="$checked"
  [ -n "$id" ] && [ "$id" != "$uid" ] && acc_set "$idx" uid "$id"
  R_UID="$id"

  # ⑤ 读余额
  quota=$(site_quota "$jar_site" "$id" "")
  if [ -z "$quota" ]; then
    quota=$(site_quota "$jar_site" "$id" "$tok")
  fi
  if [ -n "$quota" ] && [ "$quota" != "null" ]; then
    R_BAL=$(awk -v q="$quota" -v d="$DIV" 'BEGIN{printf "%.6f", q/d}')
    state_put "$name" "$R_BAL"
    local prev; prev=$(state_prev "$name")
    if [ -n "$prev" ] && [ "$prev" != "$R_BAL" ]; then R_PREV="$prev"; fi
    if [ -n "$quota_before" ]; then
      R_MSG="登录即签到（本次增量 $(awk -v a="$quota" -v b="$quota_before" -v d="$DIV" 'BEGIN{printf "%.4f", (a-b)/d}')）"
    else
      R_MSG="登录即签到"
    fi
  else
    R_MSG="登录成功，但余额读取失败"
  fi
  [ "$checked" = "true" ] && R_MSG="登录即签到，签到已到账"
  R_OK=1
  return 0
}

# ---------------------------------------------------------------- 卡片
build_card() { # 用全局 CARD_* 累加
  :
}

run_all() { # <interactive:0|1>
  local n i name okc total prev bal line body html="" okn=0 tot=0
  n=$(acc_count)
  if [ "$n" = "0" ]; then err "还没有账号，先在面板里添加"; return 1; fi
  html=$'📋 <b>每日签到通知</b>\n'
  for ((i=0; i<n; i++)); do
    name=$(acc_field "$i" name)
    tot=$((tot+1))
    printf '%s→ %s%s\n' "$C_D" "$name" "$C_N"
    if checkin_account "$i" "$1"; then
      okn=$((okn+1))
      bal=$(fmt_money "$R_BAL")
      if [ -n "$R_PREV" ]; then
        local d; d=$(awk -v a="$R_BAL" -v b="$R_PREV" 'BEGIN{printf "%.6f", a-b}')
        line=$(fmt_delta "$d")
      else
        line="—"
      fi
      ok "$name  余额 $bal  较昨日 $line"
      html="$html
🌐 <b>Agent Router</b>
👤 $(printf '%s' "$name" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
余额：$bal
较昨日：$line
"
      log "OK $name quota=$R_BAL prev=$R_PREV checked=$R_CHECKED"
    else
      err "$name  $R_MSG"
      html="$html
🌐 <b>Agent Router</b>
👤 $name
❌ 失败：$R_MSG
"
      log "FAIL $name $R_MSG"
    fi
  done
  local status
  if [ "$okn" = "$tot" ]; then status="✅ 全部成功（$okn/$tot）"
  elif [ "$okn" = "0" ]; then status="❌ 全部失败（0/$tot）"
  else status="⚠️ 部分失败（$okn/$tot）"; fi
  html=$(printf '%s' "$html" | sed "1a\\
状态：$status
")
  html="$html
时间：$(date '+%F %T')"
  printf '%s\n' "$html" > "$AR_HOME/last_card.txt"
  if [ "$(cfg .tg.enabled)" = "true" ] && [ -n "$(cfg .tg.token)" ] && [ -n "$(cfg .tg.chat_id)" ]; then
    if tg_send "$html"; then ok "已推送 Telegram"; else warn "Telegram 推送失败"; fi
  else
    warn "未配置 Telegram，仅本地输出"
  fi
  hr
  printf '%s\n' "$html"
  [ "$okn" = "$tot" ]
}

# 从真实终端读一行（面板里 read 会被管道/EOF 抢走）
rd() { # <varname> [silent]
  local __v=""
  if [ -c /dev/tty ]; then
    if [ -n "${2:-}" ]; then read -r -s __v < /dev/tty || return 1; else read -r __v < /dev/tty || return 1; fi
  else
    if [ -n "${2:-}" ]; then read -r -s __v || return 1; else read -r __v || return 1; fi
  fi
  printf -v "$1" '%s' "$__v"
}

# ---------------------------------------------------------------- 面板：添加账号
ask_secret() { # <prompt> -> 变量 REPLY
  local p="$1"
  printf '%s' "$p"; rd REPLY 1; printf '\n'
}

add_account_password() {
  hr; say "${C_BOLD}添加账号 · GitHub 账号密码登录${C_N}"; hr
  local name gu gp gs
  printf '备注名（如 zourjke / 主号）: '; read -r name
  [ -z "$name" ] && { err "备注名不能为空"; return 1; }
  printf 'GitHub 用户名或邮箱: '; read -r gu
  [ -z "$gu" ] && { err "用户名不能为空"; return 1; }
  ask_secret "GitHub 密码（输入不回显）: "; gp="$REPLY"
  [ -z "$gp" ] && { err "密码不能为空"; return 1; }
  printf 'TOTP 密钥 base32（可留空；留空则登录时手动输 6 位码）: '; read -r gs

  say ""; say "正在登录 GitHub 并检测两步验证…"
  local jar; jar=$(jar_path "tmp_add"); jar_reset "$jar"
  local st; st=$(gh_login "$jar" "$gu" "$gp")
  case "$st" in
    ok)     ok "检测结果：该账号${C_G}未开启两步验证${C_N}" ;;
    2fa)    warn "检测结果：该账号${C_Y}已开启两步验证${C_N}"
            local otp=""
            if [ -n "$gs" ]; then otp=$(totp "$gs"); say "已用 TOTP 密钥自动生成验证码 $otp";
            else printf '请输入当前 6 位验证码: '; read -r otp; fi
            [ -z "$otp" ] && { err "没有验证码，放弃"; return 1; }
            [ "$(gh_otp "$jar" "$otp")" != "ok" ] && { err "验证码校验失败"; return 1; }
            ok "两步验证通过" ;;
    device) warn "检测结果：需要邮箱设备验证（GitHub 发了一封邮件）"
            printf '请输入邮件里的验证码: '; read -r otp
            [ "$(gh_verified "$jar" "$otp")" != "ok" ] && { err "设备验证失败"; return 1; }
            ok "设备验证通过" ;;
    badpass) err "账号或密码不正确"; return 1 ;;
    *)       err "登录失败：$st"; return 1 ;;
  esac

  gh_alive "$jar" || { err "登录后仍未取得会话"; return 1; }
  local ck; ck=$(jar_to_cookie "$jar" "github.com")
  acc_add "$(jq -nc --arg n "$name" --arg u "$gu" --arg p "$gp" --arg s "$gs" --arg c "$ck" \
     '{name:$n, github_user:$u, github_password:$p, github_totp_secret:$s, github_cookie:$c, uid:""}')"
  ok "账号已保存（密码仅存本机 $ACCOUNTS，权限 600）"

  say ""; say "立刻跑一次签到验证…"
  local idx; idx=$(( $(acc_count) - 1 ))
  if checkin_account "$idx" 1; then
    ok "签到成功  余额 $(fmt_money "$R_BAL")  uid=$R_UID"
    log "ADD $name uid=$R_UID bal=$R_BAL"
  else
    err "签到失败：$R_MSG"
  fi
}



list_accounts() {
  hr; say "${C_BOLD}账号列表${C_N}"; hr
  local n i name gu uid ck pw tok
  n=$(acc_count)
  if [ "$n" = "0" ]; then warn "暂无账号"; return; fi
  printf '%-3s %-14s %-12s %-8s %s\n' "#" "备注" "GitHub" "uid" "凭据"
  for ((i=0; i<n; i++)); do
    name=$(acc_field "$i" name); gu=$(acc_field "$i" github_user)
    uid=$(acc_field "$i" uid); ck=$(acc_field "$i" github_cookie); tok=$(acc_field "$i" access_token)
    local cred=""
    [ -n "$ck" ] && cred="${cred}cookie "
    [ -n "$gu" ] && cred="${cred}密码 "
    [ -n "$tok" ] && cred="${cred}token "
    printf '%-3s %-14s %-12s %-8s %s\n' "$i" "$name" "${gu:--}" "${uid:--}" "${cred:-无}"
  done
  say ""
  say "${C_D}提示：'密码' 表示已存 GitHub 账号密码，cookie 失效时可自动重登（有 TOTP 密钥则完全免人工）${C_N}"
}

detect_account() {
  hr; say "${C_BOLD}检测账号状态${C_N}"; hr
  local n i
  n=$(acc_count); [ "$n" = "0" ] && { warn "暂无账号"; return; }
  for ((i=0; i<n; i++)); do
    local name gu gs jar st
    name=$(acc_field "$i" name); gu=$(acc_field "$i" github_user); gs=$(acc_field "$i" github_totp_secret)
    jar=$(jar_path "det_$i"); jar_reset "$jar"
    local ck; ck=$(acc_field "$i" github_cookie)
    [ -n "$ck" ] && cookie_to_jar "$jar" "github.com" 1 "$ck"
    if gh_alive "$jar"; then
      printf '  %-14s %s会话有效%s' "$name" "$C_G" "$C_N"
      [ -n "$gs" ] && printf ' · 已配 TOTP 密钥' || printf ' · 无 TOTP 密钥'
      [ -n "$gu" ] && printf ' · 可自动重登' || printf ' · %s无密码，失效后需重新导入%s' "$C_Y" "$C_N"
      printf '\n'
    else
      printf '  %-14s %s会话失效%s' "$name" "$C_R" "$C_N"
      if [ -n "$gu" ]; then printf ' · 有账号密码，签到时会自动重登'; else printf ' · %s无密码，需重新导入 Cookie%s' "$C_R" "$C_N"; fi
      printf '\n'
    fi
  done
}

del_account() {
  list_accounts
  local n i; n=$(acc_count); [ "$n" = "0" ] && return
  printf '要删除的序号: '; read -r i
  [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -lt "$n" ] || { err "序号不对"; return; }
  local name; name=$(acc_field "$i" name)
  printf '确认删除 %s ? (y/N): ' "$name"; read -r c
  [ "$c" = "y" ] || { say "已取消"; return; }
  acc_del "$i"; ok "已删除 $name"
}

# ---------------------------------------------------------------- 面板：Telegram
menu_tg() {
  while :; do
    clear 2>/dev/null
    hr; say "${C_BOLD}Telegram 推送设置${C_N}"; hr
    printf '当前 token: %s\n' "$( [ -n "$(cfg .tg.token)" ] && echo "已配置" || echo "${C_Y}未配置${C_N}" )"
    printf '当前 chat : %s\n' "$(cfg .tg.chat_id)"
    say ""
    say " 1) 录入 / 更换 bot token（自动查找 chat_id）"
    say " 2) 发送测试消息"
    say " 3) 开关推送"
    say " 0) 返回"
    printf '选择: '; read -r c
    case "$c" in
      1) tg_setup ;;
      2) if [ -z "$(cfg .tg.token)" ]; then err "先录入 token"; continue; fi
         if tg_send "📋 <b>Agent Router 签到助手</b>
✅ 推送通道测试成功
时间：$(date '+%F %T')"; then ok "已发送，去 TG 看"; else err "发送失败，检查 token/chat_id/网络"; fi ;;
      3) local v; v=$(cfg .tg.enabled)
         if [ "$v" = "true" ]; then jq '.tg.enabled=false' "$CONF" > /tmp/ar_c && mv /tmp/ar_c "$CONF"; warn "已关闭推送"
         else jq '.tg.enabled=true' "$CONF" > /tmp/ar_c && mv /tmp/ar_c "$CONF"; ok "已开启推送"; fi ;;
      0) return ;;
    esac
    printf '\n回车继续…'; read -r _
  done
}

tg_setup() {
  hr; say "先在 TG 里给这个 bot 发一条消息（群的话把它拉进群再发一条）"; hr
  printf 'bot token（形如 123456789:AA...）: '; read -r tk
  [ -z "$tk" ] && return
  say "正在查询会话…"
  local res; res=$(tg_probe_chats "$tk")
  if [ "$(printf '%s' "$res" | jq -r '.ok // false')" != "true" ]; then
    err "token 无效或网络不通：$(printf '%s' "$res" | jq -r '.description // "无响应"')"
    return
  fi
  local cnt; cnt=$(printf '%s' "$res" | jq '[.result[] | .message.chat // .channel_post.chat // empty] | length')
  if [ "$cnt" = "0" ]; then err "没查到会话，先给 bot 发一条消息再试"; return; fi
  say "找到以下会话："
  printf '%s' "$res" | jq -r '[.result[] | (.message.chat // .channel_post.chat // empty)] | unique_by(.id) | to_entries[] | "  \(.key)) \(.value.id)  \(.value.title // .value.username // .value.first_name // "")"'
  printf '选择序号（回车=第一个）: '; read -r sel
  [ -z "$sel" ] && sel=0
  local chat
  chat=$(printf '%s' "$res" | jq -r --argjson s "$sel" '[.result[] | (.message.chat // .channel_post.chat // empty)] | unique_by(.id) | .[$s].id // empty')
  [ -z "$chat" ] && { err "选择无效"; return; }
  local tmp; tmp=$(mktemp)
  jq --arg t "$tk" --arg c "$chat" '.tg.token=$t | .tg.chat_id=$c | .tg.enabled=true' "$CONF" > "$tmp" && mv "$tmp" "$CONF"
  chmod 600 "$CONF"
  ok "已保存 token 和 chat_id=$chat"
  tg_send "📋 <b>Agent Router 签到助手</b>
✅ 已绑定此会话，之后每天签到结果会推到这里" && ok "已发送绑定确认消息"
}

# ---------------------------------------------------------------- 面板：定时任务
menu_schedule() {
  while :; do
    clear 2>/dev/null
    hr; say "${C_BOLD}定时任务${C_N}"; hr
    if command -v systemctl >/dev/null 2>&1; then
      printf 'systemd: %s\n' "$(systemctl is-active agentrouter-signin.timer 2>/dev/null || echo inactive)"
      systemctl list-timers agentrouter-signin.timer --no-pager 2>/dev/null | sed -n 2p
    fi
    say ""
    say " 1) 安装/更新 systemd 定时（默认每天 08:25）"
    say " 2) 立即停用"
    say " 3) 卸载"
    say " 4) 用 crontab 安装（无 systemd 时）"
    say " 0) 返回"
    printf '选择: '; read -r c
    case "$c" in
      1) install_timer ;;
      2) systemctl disable --now agentrouter-signin.timer 2>/dev/null && ok "已停用" ;;
      3) systemctl disable --now agentrouter-signin.timer 2>/dev/null
         rm -f /etc/systemd/system/agentrouter-signin.timer /etc/systemd/system/agentrouter-signin.service
         systemctl daemon-reload; ok "已卸载" ;;
      4) install_cron ;;
      0) return ;;
    esac
    printf '\n回车继续…'; read -r _
  done
}

install_timer() {
  printf '每天几点跑（HH:MM，回车=08:25）: '; read -r t
  [ -z "$t" ] && t="08:25"
  [[ "$t" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || { err "时间格式不对"; return; }
  local hh="${BASH_REMATCH[1]}" mm="${BASH_REMATCH[2]}"
  local self; self=$(readlink -f "$0")
  cat > /etc/systemd/system/agentrouter-signin.service <<EOF
[Unit]
Description=AgentRouter daily signin (GitHub OAuth) + Telegram notify
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=AR_HOME=$AR_HOME
ExecStart=/bin/bash $self --cron
TimeoutStartSec=1800
Nice=10
EOF
  cat > /etc/systemd/system/agentrouter-signin.timer <<EOF
[Unit]
Description=AgentRouter daily signin timer

[Timer]
OnCalendar=*-*-* $hh:$mm:00
Persistent=true
RandomizedDelaySec=600
Unit=agentrouter-signin.service

[Install]
WantedBy=timers.target
EOF
  cat > /etc/systemd/system/agentrouter-signin-rearm.service <<UNIT
[Unit]
Description=Re-arm AgentRouter daily signin timer

[Service]
Type=oneshot
Environment=AR_HOME=$AR_HOME
ExecStart=/bin/bash $self --rearm
UNIT
  cat > /etc/systemd/system/agentrouter-signin-rearm.timer <<UNIT
[Unit]
Description=Re-arm AgentRouter signin timer at 00:05

[Timer]
OnCalendar=*-*-* 00:05:00
Persistent=true
Unit=agentrouter-signin-rearm.service

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  if systemctl enable --now agentrouter-signin.timer agentrouter-signin-rearm.timer >/dev/null 2>&1; then
    ok "已安装：每天 $hh:$mm 自动签到（成功即停，次日 00:05 重新武装）"
    systemctl list-timers 'agentrouter-signin*' --no-pager | sed -n 2,3p
  else
    err "安装失败，检查是否有 root 权限"
  fi
}

install_cron() {
  local self; self=$(readlink -f "$0")
  ( crontab -l 2>/dev/null | grep -v 'agentrouter.sh --cron'; \
    echo "25 8 * * * AR_HOME=$AR_HOME /bin/bash $self --cron >/dev/null 2>&1" ) | crontab -
  ok "已写入 crontab（每天 08:25）"; crontab -l | tail -2
}

menu_logs() {
  hr; say "${C_BOLD}最近日志${C_N}"; hr
  local f="$LOGDIR/$(date +%F).log"
  [ -f "$f" ] && tail -40 "$f" || warn "今天还没有日志"
  say ""
  if [ -f "$AR_HOME/last_card.txt" ]; then say "${C_D}最近一次卡片：${C_N}"; cat "$AR_HOME/last_card.txt"; fi
}

menu_settings() {
  while :; do
    clear 2>/dev/null
    hr; say "${C_BOLD}站点与网络${C_N}"; hr
    printf '站点        : %s\n' "$SITE"
    printf 'Client ID   : %s\n' "$CID"
    printf '站点代理    : %s\n' "${SITE_PROXY:-直连}"
    printf 'GitHub 代理 : %s\n' "${GH_PROXY:-直连（失败自动切站点代理）}"
    printf '额度换算    : 1 美元 = %s quota\n' "$DIV"
    say ""
    say " 1) 改站点代理   2) 改 GitHub 代理   3) 改站点地址"
    say " 4) 改额度换算   0) 返回"
    printf '选择: '; read -r c
    local tmp; tmp=$(mktemp)
    case "$c" in
      1) printf '站点代理（留空=直连）: '; read -r v
         jq --arg v "$v" '.site_proxy=$v' "$CONF" > "$tmp" && mv "$tmp" "$CONF"; SITE_PROXY="$v"; ok "已更新" ;;
      2) printf 'GitHub 代理（留空=直连）: '; read -r v
         jq --arg v "$v" '.github_proxy=$v' "$CONF" > "$tmp" && mv "$tmp" "$CONF"; GH_PROXY="$v"; ok "已更新" ;;
      3) printf '站点地址: '; read -r v
         jq --arg v "$v" '.site=$v' "$CONF" > "$tmp" && mv "$tmp" "$CONF"; SITE="$v"; ok "已更新" ;;
      4) printf '1 美元 = 多少 quota（默认 500000）: '; read -r v
         jq --argjson v "${v:-500000}" '.quota_divisor=$v' "$CONF" > "$tmp" && mv "$tmp" "$CONF"; DIV="$v"; ok "已更新" ;;
      0) return ;;
    esac
    printf '\n回车继续…'; read -r _
  done
}



# ---------------------------------------------------------------- Clash 节点自动切换
clash_url() { printf '%s' "$(cfg .clash_api)"; }
clash_sec() { printf '%s' "$(cfg .clash_secret)"; }
clash_grp() { printf '%s' "$(cfg .clash_group)"; }

clash_nodes() {
  local api sec grp
  api=$(clash_url); sec=$(clash_sec); grp=$(clash_grp)
  [ -z "$api" ] && return 1
  curl -sS -m 8 -H "Authorization: Bearer $sec" "$api/proxies" 2>/dev/null \
    | jq -r --arg g "$grp" '.proxies[$g].all[]? // empty' 2>/dev/null
}

clash_now() {
  local api sec grp
  api=$(clash_url); sec=$(clash_sec); grp=$(clash_grp)
  [ -z "$api" ] && return 1
  curl -sS -m 8 -H "Authorization: Bearer $sec" "$api/proxies" 2>/dev/null \
    | jq -r --arg g "$grp" '.proxies[$g].now // empty' 2>/dev/null
}

clash_switch() { # <node>
  local api sec grp enc
  api=$(clash_url); sec=$(clash_sec); grp=$(clash_grp)
  [ -z "$api" ] && return 1
  enc=$(jq -rn --arg s "$grp" '$s|@uri')
  curl -sS -m 8 -X PUT -H "Authorization: Bearer $sec" -H 'Content-Type: application/json' \
       -d "$(jq -nc --arg n "$1" '{name:$n}')" "$api/proxies/$enc" >/dev/null 2>&1
}

gh_reachable() { # <timeout>
  local t="${1:-10}" code
  code=$(curl -sS -o /dev/null -w '%{http_code}' -m "$t" ${SITE_PROXY:+-x "$SITE_PROXY"} \
         --noproxy "" https://github.com/login 2>/dev/null)
  [ "$code" = "200" ]
}

# 自动挑一个能通 GitHub 的节点（最多试 N 个）
gh_autofix() { # <max_nodes>
  local max="${1:-8}" now n i=0
  [ -z "$(clash_url)" ] && { warn "未配置 Clash 控制器，跳过自动切节点"; return 1; }
  now=$(clash_now)
  if gh_reachable 8; then printf '  %s\n' "当前节点可用：$now"; return 0; fi
  warn "当前节点不通（$now），开始扫描…"
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    i=$((i+1)); [ "$i" -gt "$max" ] && break
    clash_switch "$n"
    if gh_reachable 8; then
      ok "已切换到：$n"
      GH_MODE="proxy"
      return 0
    fi
    printf '  %s✘%s %s\n' "$C_R" "$C_N" "$n"
  done < <(clash_nodes)
  err "扫了 $max 个节点都不通"
  return 1
}

doctor() {
  hr; say "${C_BOLD}环境体检${C_N}"; hr
  local b
  for b in curl jq python3; do
    command -v "$b" >/dev/null 2>&1 && ok "$b 就绪" || err "$b 缺失"
  done
  say ""
  say "站点 $SITE"
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' -m 15 ${SITE_PROXY:+-x "$SITE_PROXY"} "$SITE/api/status" 2>/dev/null)
  [ "$code" = "200" ] && ok "站点可达（200）" || err "站点不可达（$code）"
  say ""
  say "GitHub $GH"
  if gh_reachable 12; then ok "GitHub 可达（200）"
  else
    err "GitHub 不可达（当前出口）"
    say "${C_D}如需换节点，手动跑：$0 --fix-node${C_N}"
  fi
  say ""
  say "Clash 控制器 $(clash_url)"
  [ -n "$(clash_url)" ] && printf '  当前节点：%s\n' "$(clash_now)"
  say ""
  list_accounts
}

# ---------------------------------------------------------------- 新手向导
wiz_line() { printf '%s\n' "${C_D}────────────────────────────────────────────────────────${C_N}"; }
wiz_step() { printf '\n%s[%s/6] %s%s\n' "$C_B" "$1" "$2" "$C_N"; }
wiz_ask()  { printf '%s' "$1"; read -r WIZ_ANS; }

# 站点连通性：0=通 1=不通
wiz_try_site() { # <proxy or empty>
  local px="$1" code
  code=$(curl -sS --connect-timeout 8 --max-time 20 ${px:+-x "$px"} \
         -o /dev/null -w '%{http_code}' "$SITE/api/status" 2>/dev/null)
  [ "$code" = "200" ]
}

wiz_try_gh() { # <proxy or empty>
  local px="$1" code
  if [ -n "$px" ]; then
    code=$(curl -sS --connect-timeout 8 --max-time 20 -x "$px" -o /dev/null -w '%{http_code}' "$GH/login" 2>/dev/null)
  else
    code=$(curl -sS --connect-timeout 8 --max-time 20 --noproxy '*' -o /dev/null -w '%{http_code}' "$GH/login" 2>/dev/null)
  fi
  [ "$code" = "200" ]
}

wiz_set() { # <jq-filter> <value> <global-name>
  local tmp; tmp=$(mktemp)
  jq --arg v "$2" "$1" "$CONF" > "$tmp" && mv "$tmp" "$CONF"
  chmod 600 "$CONF"
  printf -v "$3" '%s' "$2"
}

wizard() {
  clear 2>/dev/null
  printf '%s\n' "${C_BOLD}"
  cat <<'BANNER'
   ╔══════════════════════════════════════════════╗
   ║   AgentRouter 签到助手 · 新手向导            ║
   ║   6 步配完，之后每天自动签到并推送到 TG      ║
   ╚══════════════════════════════════════════════╝
BANNER
  printf '%s\n' "${C_N}"
  say "${C_D}任意一步直接回车 = 用方括号里的默认值${C_N}"

  # ---- 0. 环境自检
  wiz_step 1 "环境自检"
  local miss=0 b
  for b in curl jq python3; do
    if command -v "$b" >/dev/null 2>&1; then printf '  %s✔%s %s\n' "$C_G" "$C_N" "$b"
    else printf '  %s✘%s %s 缺失\n' "$C_R" "$C_N" "$b"; miss=1; fi
  done
  if [ "$miss" = "1" ]; then
    err "缺少依赖，先装：apt-get install -y curl jq python3"
    return 1
  fi
  printf '  配置目录 %s\n' "$AR_HOME"

  # ---- 1. 站点
  wiz_step 2 "站点地址"
  wiz_ask "  站点 [$SITE]: "; [ -n "$WIZ_ANS" ] && wiz_set '.site=$v' "$WIZ_ANS" SITE
  say "  → $SITE"

  # ---- 2. 网络
  wiz_step 3 "网络与代理"
  say "  正在测试站点连通性…"
  local site_px=""
  if wiz_try_site ""; then
    ok "直连可达"
  else
    local cand
    for cand in "$SITE_PROXY" "http://127.0.0.1:7890" "http://127.0.0.1:1080" "http://127.0.0.1:7891"; do
      [ -z "$cand" ] && continue
      if wiz_try_site "$cand"; then ok "走代理 $cand 可达"; site_px="$cand"; break; fi
    done
    [ -z "$site_px" ] && warn "直连和常见代理都不通，稍后可在「站点与网络设置」里改"
  fi
  wiz_ask "  站点代理 [$site_px]: "
  if [ -n "$WIZ_ANS" ]; then site_px="$WIZ_ANS"
  elif [ -z "$site_px" ]; then site_px="$SITE_PROXY"; fi   # 探测不到就保留原配置，别清空
  wiz_set '.site_proxy=$v' "$site_px" SITE_PROXY

  say "  正在测试 GitHub 连通性…"
  local gh_px=""
  if wiz_try_gh ""; then
    ok "GitHub 直连可达"
  elif wiz_try_gh "$SITE_PROXY"; then
    ok "GitHub 走 $SITE_PROXY 可达"; gh_px="$SITE_PROXY"
  else
    warn "GitHub 直连/代理都不通，登录会失败"
  fi
  wiz_ask "  GitHub 代理（留空=直连，失败会自动切站点代理）[$gh_px]: "
  if [ -n "$WIZ_ANS" ]; then gh_px="$WIZ_ANS"
  elif [ -z "$gh_px" ]; then gh_px="$GH_PROXY"; fi
  wiz_set '.github_proxy=$v' "$gh_px" GH_PROXY

  # ---- 3. 账号
  wiz_step 4 "添加账号"
  if [ "$(acc_count)" != "0" ]; then
    say "  已有 $(acc_count) 个账号，跳过添加"
    list_accounts
  else
    wiz_ask "  现在添加账号？(Y/n): "
    case "${WIZ_ANS:-y}" in
      n|N) warn "  已跳过，之后从主菜单第 1 项添加" ;;
      *)   add_account_password ;;
    esac
  fi

  # ---- 4. Telegram
  wiz_step 5 "Telegram 推送"
  if [ -n "$(cfg .tg.token)" ]; then
    say "  已配置 chat_id=$(cfg .tg.chat_id)"
  else
    say "  想每天在 TG 收到签到卡片吗？需要 @BotFather 的 bot token。"
    wiz_ask "  现在配置？(Y/n): "
    case "${WIZ_ANS:-y}" in
      n|N) say "  跳过，之后从主菜单第 5 项配置" ;;
      *)   tg_setup ;;
    esac
  fi

  # ---- 5. 定时
  wiz_step 6 "定时任务"
  if command -v systemctl >/dev/null 2>&1; then
    wiz_ask "  安装 systemd 定时，每天 08:25 自动签到？(Y/n): "
    case "${WIZ_ANS:-y}" in
      n|N) say "  跳过，之后从主菜单第 6 项安装" ;;
      *)   install_timer_default ;;
    esac
  else
    warn "  没有 systemd，跳过（可用 crontab，见主菜单第 6 项）"
  fi

  # ---- 收尾
  if [ "$(acc_count)" != "0" ]; then
    wiz_ask "  现在试跑一次签到？(Y/n): "
    case "${WIZ_ANS:-y}" in
      n|N) : ;;
      *)   run_all 1 ;;
    esac
  fi
  date '+%F %T' > "$AR_HOME/.wizard_done"
  wiz_line
  ok "配置完成。以后直接运行：$0"
  say "  ${C_D}随时可重跑向导：$0 --wizard${C_N}"
  printf '\n回车进入主面板…'; read -r _
}

install_timer_default() {
  local self; self=$(readlink -f "$0")
  cat > /etc/systemd/system/agentrouter-signin.service <<EOF
[Unit]
Description=AgentRouter daily signin (GitHub OAuth) + Telegram notify
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=AR_HOME=$AR_HOME
ExecStart=/bin/bash $self --cron
TimeoutStartSec=1800
Nice=10
EOF
  cat > /etc/systemd/system/agentrouter-signin.timer <<EOF
[Unit]
Description=AgentRouter daily signin timer

[Timer]
OnCalendar=*-*-* 08:25:00
Persistent=true
RandomizedDelaySec=600
Unit=agentrouter-signin.service

[Install]
WantedBy=timers.target
EOF
  if systemctl daemon-reload && systemctl enable --now agentrouter-signin.timer >/dev/null 2>&1; then
    ok "已安装：每天 08:25 自动签到"
    systemctl list-timers agentrouter-signin.timer --no-pager 2>/dev/null | sed -n 2p
  else
    err "安装失败（需要 root）"
  fi
}

# 需要时在菜单层先要验证码（这里的 read 一定能用）
prompt_otp_if_needed() {
  local n i ck need=0
  n=$(acc_count); [ "$n" = "0" ] && return 0
  for ((i=0;i<n;i++)); do
    ck=$(acc_field "$i" github_cookie)
    if [ -z "$ck" ] && [ -n "$(acc_field "$i" github_password)" ]; then need=1; fi
  done
  [ "$need" = "0" ] && return 0
  say ""
  warn "有账号还没有 GitHub 会话，本次会走一次登录（需要两步验证码）"
  printf '现在输入 6 位码（直接回车=跑到那一步再问）: '
  local code=""; read -r code
  if [ -n "$code" ]; then
    for ((i=0;i<n;i++)); do
      ck=$(acc_field "$i" github_cookie)
      [ -z "$ck" ] && acc_set "$i" github_otp "$code"
    done
    ok "已注入验证码（有效期 30 秒，马上开始）"
  fi
}

# ---------------------------------------------------------------- 主面板
menu_main() {
  while :; do
    clear 2>/dev/null
    local n; n=$(acc_count)
    printf '%s\n' "${C_BOLD}┌──────────────────────────────────────────────┐${C_N}"
    printf '%s\n' "${C_BOLD}│  AgentRouter 签到面板  v$AR_VERSION                 │${C_N}"
    printf '%s\n' "${C_BOLD}└──────────────────────────────────────────────┘${C_N}"
    printf '  站点 %s\n' "$SITE"
    printf '  账号 %s 个   Telegram %s\n' "$n" "$( [ -n "$(cfg .tg.token)" ] && echo "${C_G}已配置${C_N}" || echo "${C_Y}未配置${C_N}" )"
    say ""
    say "  1) 添加账号（GitHub 账号密码，自动检测两步验证）"
    say "  2) 账号列表 / 状态检测"
    say "  3) 立即签到（全部账号）"
    say "  4) 单个账号签到"
    say "  5) Telegram 推送设置"
    say "  6) 定时任务"
    say "  7) 站点与网络设置"
    say "  8) 新手向导（重走一遍配置流程）"
    say "  T) 环境体检（站点/GitHub/节点）"
    say "  L) 查看日志        D) 删除账号"
    say "  0) 退出"
    printf '\n选择: '; read -r c
    case "$c" in
      1) add_account_password ;;
      2) list_accounts; say ""; detect_account ;;
      3) prompt_otp_if_needed; run_all 1 ;;
      4) prompt_otp_if_needed; list_accounts; printf '序号: '; read -r i
         [[ "$i" =~ ^[0-9]+$ ]] || { err "序号不对"; continue; }
         if checkin_account "$i" 1; then ok "余额 $(fmt_money "$R_BAL")  $(fmt_delta "")"; else err "$R_MSG"; fi ;;
      5) menu_tg ;;
      6) menu_schedule ;;
      7) menu_settings ;;
      8|w|W) wizard ;;
      t|T) doctor ;;
      l|L) menu_logs ;;
      d|D) del_account ;;
      0) exit 0 ;;
    esac
    printf '\n回车继续…'; read -r _
  done
}

# ---------------------------------------------------------------- 入口
main() {
  ar_init
  case "${1:-}" in
    --cron|--checkin)
      local rc=0 done="$AR_HOME/.done_$(date +%F)"
      if [ -f "$done" ] && [ "${2:-}" != "--force" ]; then
        log "今日已签到，跳过"; exit 0
      fi
      if run_all 0; then
        date '+%F %T' > "$done"
        if systemctl stop agentrouter-signin.timer 2>/dev/null; then
          log "签到成功，已停止今日重试（次日 00:05 自动重新武装）"
        fi
        exit 0
      else
        exit 2
      fi ;;
    --list)   list_accounts; exit 0 ;;
    --detect) detect_account; exit 0 ;;
    -h|--help)
      cat <<EOF
AgentRouter 签到面板 v$AR_VERSION
  ./agentrouter.sh            进入面板
  ./agentrouter.sh --cron     无交互跑一轮（定时任务）
  ./agentrouter.sh --list     列出账号
  ./agentrouter.sh --detect   检测账号状态
  ./agentrouter.sh --wizard   重跑新手向导
  ./agentrouter.sh --otp 123456  带验证码跑一轮（免交互，适合脚本/远程调用）
  ./agentrouter.sh --shortcut ck   安装快捷命令（之后直接敲 ck 打开面板）
  ./agentrouter.sh --debug    打印调试日志（也可 AR_DEBUG=1 环境变量）
  ./agentrouter.sh --doctor   体检（依赖/站点/GitHub/节点）
  ./agentrouter.sh --fix-node 自动切到能通 GitHub 的节点
配置目录：$AR_HOME
EOF
      exit 0 ;;
    "") if [ ! -f "$AR_HOME/.wizard_done" ]; then
          wizard
        fi
        menu_main ;;
    --wizard) wizard; menu_main ;;
    --otp)
      local code="${2:-}"
      [ -z "$code" ] && { err "用法: $0 --otp 123456"; exit 1; }
      local n i; n=$(acc_count)
      for ((i=0;i<n;i++)); do acc_set "$i" github_otp "$code"; done
      say "已注入验证码，开始签到…"
      run_all 0 && exit 0 || exit 2 ;;
    --rearm)
      find "$AR_HOME" -name ".done_*" -mtime +7 -delete 2>/dev/null
      systemctl start agentrouter-signin.timer 2>/dev/null && say "已重新武装今日定时"
      exit 0 ;;
    --shortcut)
      local n="${2:-ck}"
      local self; self=$(readlink -f "$0")
      chmod +x "$self"
      if ln -sf "$self" "/usr/local/bin/$n" 2>/dev/null; then
        ok "已创建快捷命令：$n  （直接敲 $n 即可打开面板）"
      else
        err "创建失败，检查 /usr/local/bin 权限"
      fi
      exit 0 ;;
    --debug) AR_DEBUG=1; shift; main "$@" ;;
    --doctor) doctor; exit 0 ;;
    --fix-node) gh_autofix 12; exit $? ;;
    *) err "未知参数 $1"; exit 1 ;;
  esac
}

main "$@"
