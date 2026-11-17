#!/bin/sh
# Frondesk desk — sets up a person's own computer (macOS first; Linux for tests) so they can text their
# own Claude Code session through the Frondesk number, and keeps that session running.
#
#   curl -fsSL https://kit.ytx.app/desk | sh -s -- <invite>     first install (invite from Frondesk admin)
#   ~/Frondesk/bin/frondesk install                     resume / redo unfinished steps (finished ones are skipped)
#   ~/Frondesk/bin/frondesk doctor | run | keep | uninstall | redo <step>
#   ~/Frondesk/bin/frondesk contact "<message>"         message straight to the Frondesk developers (also: setup page)
#   ~/Frondesk/bin/frondesk help                         remote help on demand: installs + opens RustDesk, tells Frondesk
#
# Steps (each: check → do → verify, done-marker in ~/Frondesk/.state, failures reported to Frondesk):
#   claim · node · claude · token (his own long-lived Claude key) ·
#   channel (Frondesk number ⇄ session) · fastlink · google · permissions · keeper · power · selftest
# Body is in main() so `curl | sh` parses everything before anything reads the terminal.

main() {
  set -u
  FD_URL="https://kit.ytx.app"
  ROOT="${FRONDESK_HOME:-$HOME/Frondesk}"
  BIN="$ROOT/bin"; ST="$ROOT/.state"; LOG="$ROOT/install.log"
  OS=$(uname -s)
  # rustdesk server (svm, self-hosted; ~/code/rustdesk-server) — public values
  RD_HOST=147.224.175.113; RD_KEY='n6QGuB6uEHzRL2GuQOTKuGCmXCiNrcw5usPc636+VHI='; RD_VER=1.5.3
  FASTLINK_STORE=https://chromewebstore.google.com/detail/eiifomohibgelcdhadklpmdnoblpalde
  CHAN_FLAG=plugin:whatsapp@claude-whatsapp
  DESK_PROMPT="You are this person's own always-on assistant on his computer (Frondesk desk). He is usually away from the computer and talks to you by text: WhatsApp or SMS to the Frondesk number, arriving as <channel source=\"plugin:whatsapp:whatsapp\"> messages. He also texts himself in his Mac's Messages app (<channel source=\"plugin:imessage:imessage\">). He never sees this terminal. ALWAYS answer every channel message by calling the reply tool of the channel it came from, with its chat_id - a plain text answer is lost. For longer work, reply 'on it' first, then reply with the result."
  export PATH="$ROOT/node/bin:$HOME/.local/bin:$PATH"

  cmd=${1:-install}
  case "$cmd" in
    fdinv_*) bootstrap "$cmd" ;;   # piped first run: curl … | sh -s -- <invite>
    install) need_tty; install_all ;;
    redo) [ -n "${2:-}" ] || die "usage: frondesk redo <step>"; rm -f "$ST/$2"; need_tty; install_all ;;
    run) run_desk ;;
    keep) keep ;;
    doctor) doctor ;;
    help) remote_help ;;
    contact) shift; contact_dev "$*" ;;
    uninstall) need_tty; uninstall ;;
    *) die "unknown command: $cmd (install | redo <step> | run | keep | doctor | uninstall)" ;;
  esac
}

STEPS="claim node claude token channel connectors messages fastlink google permissions keeper power selftest"

say() { printf '\033[1m%s\033[0m\n' "$*" >&2; }
note() { printf '   %s\n' "$*" >&2; [ -n "${CUR:-}" ] && { GUIDE="${GUIDE:+$GUIDE
}$*"; progress; }; return 0; }
die() { printf 'frondesk: %s\n' "$*" >&2; exit 1; }
need_tty() { [ -r /dev/tty ] || die "needs an interactive terminal"; }
# page_ask <kind buttons|text|phone> <label> [option...]: the question appears on the setup page with buttons /
# an input; the answer comes back through Frondesk (GET /desk/answer). The Terminal only shows that we wait.
ASKN=0
page_ask() {
  kind=$1 label=$2; shift 2
  ASKN=$((ASKN + 1)); ASK_ID="${CUR:-x}-$ASKN"; ASK_KIND=$kind; ASK_LABEL=$label; ASK_OPTS=""
  for o in "$@"; do ASK_OPTS="$ASK_OPTS${ASK_OPTS:+,}\"$(jesc "$o")\""; done
  MODE=you; progress
  printf '   ➜ on the setup page: %s\n' "$label" >&2
  while :; do
    REPLY=$(curl -fsS -m 15 -H @"$(key_hdr)" "$FD_URL/desk/answer?id=$ASK_ID" 2>/dev/null) && [ -n "$REPLY" ] && break
    sleep 2
  done
  REPLY=$(printf '%s' "$REPLY" | tr -d '\r\n')
  printf '     → %s\n' "$REPLY" >&2
  ASK_ID=""; ASK_VALUE=""; MODE=auto; IMAGES=""; URLV=""; progress
}
pause() { page_ask buttons "${1:-Click Done when finished.}" "${2:-Done}"; }
# you <text>: a YOU-do instruction (orange on the page) without a question
you() { MODE=you; note "$*"; }
is_mac() { [ "$OS" = Darwin ]; }
logrun() { printf '\n$ %s\n' "$*" >>"$LOG"; "$@" >>"$LOG" 2>&1; }
key_hdr() { printf '%s' "$ROOT/.desk.hdr"; }

# report <step> <status> [msg] → owner's phone (rate-capped server side). Never fails the caller.
report() {
  [ -f "$ROOT/.desk.hdr" ] || return 0
  curl -fsS -m 15 -o /dev/null -X POST -H @"$(key_hdr)" --data-urlencode "step=$1" --data-urlencode "status=$2" \
    --data-urlencode "msg=${3:-}" "$FD_URL/desk/report" 2>/dev/null || true
}

# live wizard page (/desk/setup/<view>): every step's state + what to do now. Never fails the caller.
jesc() { printf '%s' "$1" | tr '\t\r' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{ printf "%s%s", (NR > 1 ? "\\n" : ""), $0 }'; }
progress() {
  [ -f "$ROOT/.desk.hdr" ] || return 0
  j='{"steps":['; sep=""
  for x in $STEPS; do
    if [ "$x" = "${CUR:-}" ]; then stt=${CUR_STATE:-current}; elif [ -f "$ST/$x" ]; then stt=done; elif [ -f "$ST/$x.skipped" ]; then stt=skipped; else stt=todo; fi
    j="$j$sep{\"id\":\"$x\",\"title\":\"$(jesc "$(step_title "$x")")\",\"state\":\"$stt\"}"; sep=,
  done
  imgs=""; for g in ${IMAGES:-}; do imgs="$imgs${imgs:+,}\"$g\""; done
  ask=null; [ -n "${ASK_ID:-}" ] && ask="{\"id\":\"$ASK_ID\",\"kind\":\"$ASK_KIND\",\"label\":\"$(jesc "$ASK_LABEL")\",\"options\":[$ASK_OPTS],\"value\":\"$(jesc "${ASK_VALUE:-}")\",\"placeholder\":\"$(jesc "${ASK_PH:-}")\"}"
  j="$j],\"now\":{\"title\":\"$(jesc "${NOW_TITLE:-}")\",\"help\":\"$(jesc "${GUIDE:-}")\",\"mode\":\"${MODE:-auto}\",\"images\":[$imgs],\"url\":\"$(jesc "${URLV:-}")\",\"ask\":$ask}}"
  printf '%s' "$j" | curl -fsS -m 8 -o /dev/null -X POST -H @"$(key_hdr)" -H 'content-type: application/json' --data-binary @- "$FD_URL/desk/progress" 2>/dev/null || true
}

bundle() { curl -fsS -m 120 -H @"$(key_hdr)" -o "$2" "$FD_URL/desk/bundle/$1"; }

# piped first run: save this script as ~/Frondesk/bin/frondesk, claim the invite, continue from the file
bootstrap() {
  need_tty
  mkdir -p "$BIN" "$ST" && chmod 700 "$ROOT"
  # FRONDESK_ENGINE: this script's signed copy inside /Applications/Frondesk.app (Mac .pkg) — nothing fetched
  if [ -n "${FRONDESK_ENGINE:-}" ]; then cp "$FRONDESK_ENGINE" "$BIN/frondesk.part"; else curl -fsSL "$FD_URL/desk" -o "$BIN/frondesk.part"; fi \
    && chmod 755 "$BIN/frondesk.part" && mv "$BIN/frondesk.part" "$BIN/frondesk" || die "could not install the Frondesk engine"
  if [ ! -f "$ST/claim" ]; then
    out=$(curl -sS -m 30 -X POST --data-urlencode "invite=$1" --data-urlencode "host=$(uname -n)" \
      --data-urlencode "user=$(id -un)" --data-urlencode "os=$(os_desc)" -w '\n%{http_code}' "$FD_URL/desk/claim") || die "cannot reach Frondesk"
    [ "$(printf '%s\n' "$out" | tail -1)" = 200 ] || die "$(printf '%s\n' "$out" | sed -n 1p)"
    (umask 077
      printf '%s\n' "$out" | sed -n 1p > "$ROOT/.desk.key"
      printf 'Authorization: Bearer %s\n' "$(cat "$ROOT/.desk.key")" > "$ROOT/.desk.hdr"
      printf '%s\n' "$out" | sed -n 2p > "$ROOT/.phone"
      printf '%s\n' "$out" | sed -n 3p > "$ROOT/.name"
      printf '%s\n' "$out" | sed -n 4p > "$ROOT/.setup_url")
    touch "$ST/claim"
  fi
  exec "$BIN/frondesk" install
}

install_all() {
  [ -f "$ST/claim" ] || die "not set up yet: run the install line with your invite"
  touch "$LOG"; chmod 600 "$LOG"
  say "Frondesk desk for $(cat "$ROOT/.name") — $(os_desc)"
  note "Log: $LOG. Safe to stop and rerun ($BIN/frondesk install): finished steps are skipped."
  if [ ! -f "$ST/.page_opened" ] && [ -s "$ROOT/.setup_url" ]; then
    open_url "$(cat "$ROOT/.setup_url")"; touch "$ST/.page_opened"
    note "Follow the setup page that just opened in your browser. Leave this Terminal window open (move it aside)."
    note "Setup page: $(cat "$ROOT/.setup_url")"
  fi
  SN=0; total=$(echo $STEPS | wc -w | tr -d ' ')
  for STEP in $STEPS; do
    SN=$((SN + 1))
    while :; do
      if [ -f "$ST/$STEP" ]; then printf '   ✓ %s/%s %s\n' "$SN" "$total" "$STEP" >&2; break; fi
      CUR=$STEP; CUR_STATE=current; GUIDE=""; MODE=auto; IMAGES=""; URLV=""; NOW_TITLE=$(step_title "$STEP")
      say "── Step $SN of $total: $NOW_TITLE"
      progress
      if "step_$STEP"; then touch "$ST/$STEP"; rm -f "$ST/$STEP.skipped"; printf '   ✓ %s done\n' "$STEP" >&2; CUR=""; break; fi
      tailmsg=$(tail -n 6 "$LOG" 2>/dev/null | cut -c1-120)
      report "$STEP" FAIL "$tailmsg"
      CUR_STATE=failed; IMAGES=""; URLV=""; GUIDE="This step did not work. Frondesk has been told and can help."
      say "✗ $STEP failed (Frondesk has been told)."
      page_ask buttons "This step did not work. Try again, or skip it for now (Frondesk can finish it later)?" "Try again" "Skip for now"
      CUR_STATE=current
      case "$REPLY" in Skip*) touch "$ST/$STEP.skipped"; printf '   skipped %s — rerun later: %s install\n' "$STEP" "$BIN/frondesk" >&2; CUR=""; break ;; esac
    done
  done
  CUR=""; GUIDE=""
  left=""; for s in $STEPS; do [ -f "$ST/$s" ] || left="$left $s"; done
  if [ -z "$left" ]; then NOW_TITLE="Your computer is ready"; GUIDE="Text the Frondesk number from $(cat "$ROOT/.phone") — your computer answers."
  else NOW_TITLE="Almost done"; GUIDE="Still to do:$left. Frondesk will help you finish."; fi
  say "$NOW_TITLE. $GUIDE"; progress
  report install "$([ -z "$left" ] && echo COMPLETE || echo "INCOMPLETE:$left")" "$(doctor 2>&1 | tail -n 15)"
}

step_title() {
  case "$1" in
    claim) echo "Connect to Frondesk" ;;
    node) echo "Helper runtime" ;; claude) echo "Install Claude Code" ;; token) echo "Connect your Claude account" ;; messages) echo "Your Mac's Messages (texts to yourself)" ;;
    channel) echo "Link your phone number (text your computer)" ;; connectors) echo "Your existing connectors (from the Claude app)" ;; fastlink) echo "FastLink for Chrome" ;;
    google) echo "Gmail (Frondesk Gmail)" ;; permissions) echo "Mac permissions (all at once, so nothing asks later)" ;;
    keeper) echo "Keep it running" ;; power) echo "Stay awake while plugged in" ;; selftest) echo "Final check" ;; *) echo "$1" ;;
  esac
}

os_desc() {
  if is_mac; then printf 'macOS %s %s' "$(sw_vers -productVersion 2>/dev/null)" "$(uname -m)"
  else printf '%s %s' "$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-Linux}")" "$(uname -m)"; fi
}

step_claim() { [ -f "$ROOT/.desk.key" ]; }

# ── remote help, ONLY on request (not an install step): RustDesk pointed at our own server; ID + password to
# Frondesk. Started by "Get Remote Help.command" in ~/Frondesk, or by the desk when he texts that he needs help.
# message to the developers: one channel with the desk's reports (desk_events → boss), name/desk attached
contact_dev() {
  [ -n "$1" ] || { open "$(cat "$ROOT/.setup_url")#contact"; return 0; }
  if curl -fsS -m 20 -o /dev/null -X POST -H @"$(key_hdr)" --data-urlencode "step=contact" --data-urlencode "status=message" \
       --data-urlencode "msg=$1" "$FD_URL/desk/report"; then echo "Sent to the Frondesk developers."
  else echo "Could not send right now — try again in a minute, or use the setup page."; return 1; fi
}

remote_help() {
  need_tty; touch "$LOG"
  say "Frondesk remote help"
  if step_remote; then say "Remote help is ready. Frondesk has been told and will connect when you are ready."
  else say "Remote help could not be set up — Frondesk has been told."; report remote-help FAIL "$(tail -n 6 "$LOG" | cut -c1-120)"; fi
  printf 'Press Enter to close. ' >/dev/tty; read -r _ </dev/tty || true
}
step_remote() {
  is_mac || { note "RustDesk set-up is macOS only here; skipped"; return 0; }
  app=/Applications/RustDesk.app
  if [ ! -x "$app/Contents/MacOS/RustDesk" ]; then
    arch=$(uname -m); [ "$arch" = arm64 ] && arch=aarch64
    dmg="$ROOT/tmp/rustdesk.dmg"; mkdir -p "$ROOT/tmp"
    note "Downloading RustDesk (lets Frondesk help you remotely, only when you allow it)…"
    logrun curl -fL -o "$dmg" "https://github.com/rustdesk/rustdesk/releases/download/$RD_VER/rustdesk-$RD_VER-$arch.dmg" || return 1
    mnt=$(hdiutil attach -nobrowse -readonly "$dmg" 2>>"$LOG" | awk -F'\t' '/\/Volumes\//{print $NF; exit}')
    [ -n "$mnt" ] || return 1
    rm -rf "$app"; logrun ditto "$mnt/RustDesk.app" "$app"; rc=$?
    hdiutil detach "$mnt" >/dev/null 2>&1; rm -f "$dmg"
    [ $rc = 0 ] && [ -x "$app/Contents/MacOS/RustDesk" ] || return 1
  fi
  cfg="$HOME/Library/Preferences/com.carriez.RustDesk"; mkdir -p "$cfg"
  if ! grep -q "$RD_HOST" "$cfg/RustDesk2.toml" 2>/dev/null; then
    printf "rendezvous_server = '%s:21116'\nnat_type = 1\nserial = 0\n\n[options]\ncustom-rendezvous-server = '%s'\nrelay-server = '%s'\napi-server = ''\nkey = '%s'\n" \
      "$RD_HOST" "$RD_HOST" "$RD_HOST" "$RD_KEY" > "$cfg/RustDesk2.toml"
  fi
  open "$app"   # by path: a fresh copy isn't registered with Launch Services yet (11-16 test)
  IMAGES="rustdesk-ready"
  you "RustDesk opened. If it shows 'Install' or 'Start service' on the left, click it and enter your Mac password. If macOS asks to allow RustDesk anything, click Allow."
  if [ -n "${CUR:-}" ]; then pause "Click Done when RustDesk shows a green 'Ready' at the bottom (like the picture)."
  else printf '   Press Enter when RustDesk shows a green Ready at the bottom. ' >/dev/tty; read -r _ </dev/tty || true; fi
  id=$("$app/Contents/MacOS/RustDesk" --get-id 2>>"$LOG" | tr -dc '0-9' | head -c 12)
  [ -n "$id" ] || { note "could not read the RustDesk ID"; return 1; }
  pw=$(LC_ALL=C tr -dc 'a-hj-km-np-z2-9' </dev/urandom | head -c 12)
  you "A macOS window asks for your Mac password (to set the remote-help password). Type it and click OK."
  out=$(admin_run "'$app/Contents/MacOS/RustDesk' --password '$pw'" 2>&1); rc=$?
  printf 'rustdesk --password: rc=%s %s\n' "$rc" "$out" >>"$LOG"; MODE=auto
  case "$rc:$out" in
    0:*rror*|0:*"No such file"*|[1-9]*)
      report remote-access "ID $id, password NOT set" "RustDesk ID $id — permanent password failed: $(printf '%s' "$out" | head -c 120)"
      note "Remote help: ID $id is ready; the permanent password could not be set yet (Frondesk was told)." ;;
    *) report remote-access "ID $id" "RustDesk ID $id password $pw (server $RD_HOST)"
      note "Remote help ready (ID $id). Frondesk has the access details." ;;
  esac
}

# admin_run <shell command>: as root via macOS's own password dialog (no Terminal typing); Linux: sudo
admin_run() {
  if is_mac; then osascript - "$1" <<'OSA'
on run argv
  do shell script (item 1 of argv) with administrator privileges
end run
OSA
  else sudo sh -c "$1"; fi
}

# ── Node 22 (portable, no admin) — runs the channel plugin and the FastLink helper ──
step_node() {
  if [ -x "$ROOT/node/bin/node" ] && [ "$("$ROOT/node/bin/node" -p 'process.versions.node.split(".")[0]')" -ge 22 ]; then return 0; fi
  case "$OS-$(uname -m)" in
    Darwin-arm64) p=darwin-arm64 ;; Darwin-x86_64) p=darwin-x64 ;;
    Linux-x86_64) p=linux-x64 ;; Linux-aarch64) p=linux-arm64 ;; *) note "unsupported $OS $(uname -m)"; return 1 ;;
  esac
  base=https://nodejs.org/dist/latest-v22.x
  sums=$(curl -fsSL "$base/SHASUMS256.txt") || return 1
  line=$(printf '%s\n' "$sums" | grep " node-v22[.0-9]*-$p.tar.gz\$" | head -1)
  file=${line##* }; sum=${line%% *}
  [ -n "$file" ] || return 1
  mkdir -p "$ROOT/tmp"
  note "downloading $file"
  logrun curl -fL -o "$ROOT/tmp/$file" "$base/$file" || return 1
  [ "$(sha256 "$ROOT/tmp/$file")" = "$sum" ] || { note "checksum mismatch"; return 1; }
  rm -rf "$ROOT/node" "$ROOT/tmp/node-x"; mkdir -p "$ROOT/tmp/node-x"
  tar -xzf "$ROOT/tmp/$file" -C "$ROOT/tmp/node-x" && mv "$ROOT/tmp/node-x/"node-v* "$ROOT/node" && rm -rf "$ROOT/tmp/$file" "$ROOT/tmp/node-x"
  "$ROOT/node/bin/node" -v >>"$LOG" 2>&1
}
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# ── Claude Code: Anthropic's official installer (stable channel, auto-updates) ──
step_claude() {
  if ! command -v claude >/dev/null 2>&1; then
    note "Installing Claude Code (official installer)…"
    # without our portable Node on PATH, or the installer picks npm and installs into ~/Frondesk/node (11-16)
    curl -fsSL https://claude.ai/install.sh | env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash >>"$LOG" 2>&1 || return 1
  fi
  logrun claude --version
}

# ── his own long-lived Claude key (claude setup-token), kept in the macOS Keychain (Linux: 0600 file) ──
step_token() {
  tok=$(get_token)
  if [ -n "$tok" ] && token_ok "$tok"; then note "Your Claude key is already saved ✓"; else
    URLV=""; you "A browser page opens: sign in to YOUR Claude account (the one you use for Claude / Cowork) and click Authorize. If the page shows a code instead, copy it and paste it into the Terminal window."
    log="$ROOT/tmp/st.$$"; mkdir -p "$ROOT/tmp"; (umask 077; : > "$log")
    size=$(stty size </dev/tty 2>/dev/null); stty cols 400 </dev/tty 2>/dev/null   # the key on one line
    if is_mac; then script -q "$log" claude setup-token </dev/tty >/dev/tty 2>&1; else script -qfc "claude setup-token" "$log" </dev/tty >/dev/tty 2>&1; fi
    [ -n "$size" ] && stty rows "${size% *}" cols "${size#* }" </dev/tty 2>/dev/null
    MODE=auto
    tok=$(tr -d '\r' < "$log" | grep -o 'sk-ant-oat01-[A-Za-z0-9_-]*' | awk 'length > 60' | tail -1)
    rm -f "$log"
    [ -n "$tok" ] || { note "No key came back from Claude."; return 1; }
    token_ok "$tok" || { note "The key did not work."; return 1; }
    save_token "$tok" || return 1
    note "Claude key saved ✓ (valid for one year)"
  fi
  mkdir -p "$ROOT/work"
  node -e '
    const fs=require("fs"),f=process.env.HOME+"/.claude.json";let c={};try{c=JSON.parse(fs.readFileSync(f,"utf8"))}catch{}
    c.hasCompletedOnboarding=true;c.projects=c.projects||{};const p=process.argv[1];
    c.projects[p]={...(c.projects[p]||{}),hasTrustDialogAccepted:true};fs.writeFileSync(f,JSON.stringify(c,null,2))' "$ROOT/work"
  write_desk_md
}
get_token() {
  if is_mac; then security find-generic-password -a "$(id -un)" -s frondesk-claude-token -w 2>/dev/null
  else cat "$ROOT/.claude-token" 2>/dev/null; fi
}
save_token() {
  if is_mac; then security add-generic-password -U -a "$(id -un)" -s frondesk-claude-token -w "$1" >/dev/null 2>>"$LOG"
  else (umask 077 && printf '%s' "$1" > "$ROOT/.claude-token"); fi
}
token_ok() { (cd "$ROOT" && CLAUDE_CODE_OAUTH_TOKEN="$1" claude -p "Reply with exactly: FRONDESK-OK" 2>>"$LOG" | grep -q FRONDESK-OK); }
with_token() { CLAUDE_CODE_OAUTH_TOKEN="$(get_token)" "$@"; }

write_desk_md() {
  [ -f "$ROOT/work/CLAUDE.md" ] && return 0
  cat > "$ROOT/work/CLAUDE.md" <<EOF
# Frondesk desk — $(cat "$ROOT/.name")

This is $(cat "$ROOT/.name")'s own computer and Claude account. He mostly talks to you by text:
WhatsApp or SMS to the Frondesk number (channel "whatsapp"), or a text to himself in Messages
(channel "imessage"). Answer each message with the reply tool of the channel it came from. Keep texts
short and plain.

- Gmail: the "gmail*" MCP servers (Frondesk Gmail; one per Google account). Browser tasks: FastLink.
- Remote help: if he asks for help from Frondesk, open "~/Frondesk/Get Remote Help.command" (open it with the
  `open` command); it installs RustDesk and tells Frondesk. He must be at the computer to allow it.
- Never send passwords, codes or keys by text.
- Command-line tools already logged in on this computer (gh, git, gcloud…): see LOGINS.md here.
- If he says "message the developer: …" (or wants to reach the people who built Frondesk), send it with
  `~/Frondesk/bin/frondesk contact "<his message>"` and tell him it was sent.

## His Cowork and Claude Desktop work (READ-ONLY — never change, move or delete anything there)
His earlier work with Claude Cowork / the Claude app lives on this computer; when he asks about earlier work,
a document, or "what we did in Cowork", look here first:
- ~/Library/Application Support/Claude/local-agent-mode-sessions/<account>/<org>/
  - local_<session>.json — one Cowork session (title, dates, settings)
  - local_<session>/audit.jsonl — that session's full transcript
  - local_<session>/outputs/ and uploads/ — files it produced / he gave it
  - agent/memory/ — Cowork's memory about him
- ~/Library/Application Support/Claude/claude-code-sessions/ — Claude app "Code" sessions
To work on something from there, COPY it into ~/Frondesk/work/<topic>/ first and work on the copy.
EOF
}

# ── text channel: Frondesk number ⇄ this session (deskhub channel plugin + Frondesk transport) ──
step_channel() {
  mkdir -p "$ROOT/lib" "$ROOT/channel" "$ROOT/tmp"
  bundle plugin.tgz "$ROOT/tmp/plugin.tgz" && bundle frondesk-transport.mjs "$ROOT/lib/frondesk-transport.mjs" || return 1
  rm -rf "$ROOT/lib/claude-whatsapp" && tar -xzf "$ROOT/tmp/plugin.tgz" -C "$ROOT/lib" && rm -f "$ROOT/tmp/plugin.tgz" || return 1
  logrun claude plugin marketplace add "$ROOT/lib/claude-whatsapp" || logrun claude plugin marketplace update claude-whatsapp || return 1
  logrun claude plugin install whatsapp@claude-whatsapp || return 1
  # the plugin installs its own deps (deskhub start.mjs --install-deps, locked + once-only) now, not on the
  # desk's first start (Claude's 30 s connect timeout); Claude may load the source or the cache copy: do both
  note "Installing the text-message link (one minute)…"
  for d in "$ROOT/lib/claude-whatsapp/plugin" "$HOME"/.claude/plugins/cache/claude-whatsapp/whatsapp/*; do
    [ -f "$d/start.mjs" ] || continue
    (cd "$d" && logrun node start.mjs --install-deps) || return 1
  done
  ASK_VALUE=$(cat "$ROOT/.phone"); ASK_PH="+1 773 555 1234"
  page_ask phone "Your mobile number (the phone you will text from, with country code):" "Save number"
  ASK_PH=""; printf '%s\n' "$REPLY" > "$ROOT/.phone"
  phone=$(tr -dc '0-9' < "$ROOT/.phone")
  note "From $REPLY you can WhatsApp or text the Frondesk number to reach this computer."
  printf '{\n  "selfPhone": "%s",\n  "allowFrom": ["%s"],\n  "prefix": ""\n}\n' "$phone" "$phone" > "$ROOT/channel/config.json"
  chmod 700 "$ROOT/channel"; chmod 600 "$ROOT/channel/config.json"
}

# ── his existing local connectors (Claude app MCP servers + extensions) → the desk's Claude config ──
# scripts/desk/connectors.mjs; best effort, never fails the install
step_connectors() {
  bundle connectors.mjs "$ROOT/lib/connectors.mjs" || { note "Could not check for existing connectors — not needed to continue."; return 0; }
  out=$(cd "$ROOT/work" 2>/dev/null || cd "$ROOT"; CLAUDE_EXE="$(command -v claude)" node "$ROOT/lib/connectors.mjs" 2>>"$LOG" | tail -1)
  printf 'connectors: %s\n' "$out" >>"$LOG"
  names=$(printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const r=JSON.parse(s);console.log(r.imported.map(x=>x.name).join(", ")+"\t"+r.skipped.map(x=>x.name+" ("+x.why+")").join("; ")+"\t"+(r.logins||[]).map(x=>x.tool+": "+x.status).join("; "))}catch{console.log("\t\t")}})')
  lgn=${names##*"$(printf '\t')"}; names=${names%"$(printf '\t')"*}
  imp=${names%%"$(printf '\t')"*}; skp=${names#*"$(printf '\t')"}
  if [ -n "$imp" ]; then note "Using your connectors: $imp"; else note "No connectors from the Claude app to bring over."; fi
  [ -n "$skp" ] && note "Not brought over: $skp"
  if [ -n "$lgn" ]; then
    note "Logins on this computer: $lgn"
    { printf '# Command-line logins on this computer (checked at setup)\n\nIf he needs GitHub and gh is not logged in here, walk him through `gh auth login --web` once (he approves in the browser). Logins he made inside Cowork may exist only in Cowork'"'"'s sandbox, not here.\n\n'
      printf '%s\n' "$lgn" | tr ';' '\n' | sed 's/^ */- /'; } > "$ROOT/work/LOGINS.md"
  fi
  return 0
}

# ── his Mac's own Messages (iMessage + SMS forwarded from his iPhone): Anthropic's iMessage channel plugin ──
step_messages() {
  is_mac || { note "macOS only; skipped"; return 0; }
  if [ ! -x "$HOME/.bun/bin/bun" ]; then
    note "Installing bun (runs the Messages plugin)…"
    curl -fsSL https://bun.sh/install | bash >>"$LOG" 2>&1 || return 1
  fi
  logrun claude plugin marketplace add anthropics/claude-plugins-official || true
  logrun claude plugin install imessage@claude-plugins-official \
    || { logrun claude plugin marketplace update claude-plugins-official; logrun claude plugin install imessage@claude-plugins-official; } || return 1
  open -a Messages
  you "Messages opened on this Mac. Make sure it is signed in with your Apple Account (same as your iPhone). For SMS: on your iPhone, Settings → Apps → Messages → Text Message Forwarding → turn ON this Mac."
  pause "Click Done when Messages shows your conversations."
  note "To reach your computer from Messages: send a text to yourself (your own name in Messages)."
}

# ── FastLink: his Chrome(s) + this computer, paired to his own FastLink account ──
step_fastlink() {
  mkdir -p "$ROOT/fastlink" "$ROOT/tmp"
  bundle fastlink.tgz "$ROOT/tmp/fastlink.tgz" && tar -xzf "$ROOT/tmp/fastlink.tgz" -C "$ROOT/fastlink" && rm -f "$ROOT/tmp/fastlink.tgz" || return 1
  helper="$ROOT/fastlink/server/index.js"
  name=$(fl_name)
  if is_mac && [ ! -d "/Applications/Google Chrome.app" ]; then
    URLV=https://www.google.com/chrome/; open_url "$URLV"
    you "FastLink works in Google Chrome, which is not on this Mac. Download and install Chrome from the page that opened."
    pause "Click Done when Chrome is installed."
  fi
  URLV=$FASTLINK_STORE; open_url "$FASTLINK_STORE" Chrome; IMAGES="chrome-store chrome-add-extension"
  you "FastLink lets your Claude use your Chrome. In Chrome: click 'Add to Chrome', then 'Add extension'."
  pause "Click Done when Chrome says FastLink was added."
  IMAGES="fastlink-welcome"; URLV=""
  you "On the FastLink page that opened in Chrome: click 'Sign in & connect' (your Google account), then name this browser: ${name}-chrome"
  pause "Click Done when FastLink says this browser is connected."
  if ! node "$helper" machines >/dev/null 2>&1; then
    URLV=https://relay.ytx.app/pair/new; open_url "$URLV" Chrome
    you "One more FastLink code, for this computer: the page that opened shows a code (same Google account)."
    page_ask text "Type the code from that page:" "Connect"
    [ -n "$REPLY" ] || return 1
    logrun node "$helper" pair "$REPLY" --name "$name" || return 1
  fi
  claude mcp remove -s user fastlink >/dev/null 2>&1 || true
  logrun claude mcp add -s user fastlink -- "$ROOT/node/bin/node" "$helper" || return 1
  st=$(cd "$ROOT/fastlink/server" && node --input-type=module -e '
    const { connect } = await import("./call.js"); const fl = await connect({ client: "frondesk-install" });
    const r = await fl.call("fast_status", {}); console.log(JSON.stringify(r.result ?? r).slice(0, 400)); process.exit(0)' 2>>"$LOG")
  printf 'fast_status: %s\n' "$st" >>"$LOG"
  case "$st" in *'"connected":true'*) note "FastLink browser online ✓" ;;
    *) note "FastLink paired; your Chrome shows up whenever it is open." ;; esac
}
fl_name() { n=$(cat "$ROOT/.name" 2>/dev/null | tr 'A-Z ' 'a-z-' | tr -dc 'a-z0-9_-' | cut -c1-20); printf '%s' "${n:-desk}"; }
open_url() {
  if is_mac; then
    if [ "${2:-}" = Chrome ] && [ -d "/Applications/Google Chrome.app" ]; then open -a "Google Chrome" "$1"; else open "$1"; fi
  else xdg-open "$1" >/dev/null 2>&1 || note "open this link: $1"; fi
}

# ── Gmail: Frondesk Gmail (frontdesk gauth broker / Gmail MCP); one key per Google account, delivered via the relay ──
step_google() {
  URLV=https://frondesk.ai/signup; open_url "$URLV" Chrome
  you "Connect your Gmail to Frondesk: on the page that opened, sign up with Google and allow Gmail. If Google says 'Google hasn't verified this app', click Advanced → Continue. For another Gmail account, do it again with that account."
  pause "Click Done when every Gmail account you want is connected."
  report gmail "waiting for keys" "Desk ready for Gmail MCP key(s): sh scripts/desk/admin.sh secret <desk id> gmail[-label] <keyfile>"
  MODE=auto; URLV=""
  note "Frondesk is connecting your Gmail to this computer — this can take a few minutes."
  got=0; i=0
  while [ $i -lt 90 ]; do
    sec=$(curl -fsS -m 15 -H @"$(key_hdr)" "$FD_URL/desk/secrets" 2>/dev/null) || sec=""
    if [ -n "$sec" ]; then
      while IFS="$(printf '\t')" read -r n v; do
        case "$n" in gmail*) ;; *) continue ;; esac
        claude mcp remove -s user "$n" >/dev/null 2>&1 || true
        claude mcp add --scope user --transport http "$n" https://api.frondesk.ai/mcp --header "Authorization: Bearer $v" >>"$LOG" 2>&1 \
          && { got=$((got + 1)); note "✓ Gmail connected ($n)"; }
      done <<SECRETS
$sec
SECRETS
      sec=""
    fi
    [ $got -gt 0 ] && return 0
    sleep 10; i=$((i + 1))
  done
  note "Gmail is not connected yet. Frondesk will finish it with you."; return 1
}

# ── macOS permissions, all up front, for the terminal app that runs the desk ──
# Tested 11-16 (macOS 26.5): Accessibility / Full Disk Access lists don't show Terminal until it is added with "+";
# an Automation dialog left unanswered for 120 s becomes a permanent Deny (then fixed in Privacy → Automation).
step_permissions() {
  is_mac || { note "macOS only; skipped"; return 0; }
  term_app > "$ROOT/.term"
  t=$(cat "$ROOT/.term")
  note "Claude runs inside $t, so $t gets the permissions — all now, so nothing asks while you are away."
  missing=""
  perm_pane "Full Disk Access" Privacy_AllFiles probe_fda || missing="$missing fda"
  for a in "System Events" Finder Messages Mail Calendar Contacts Reminders Notes "Google Chrome"; do
    [ "$a" = "Google Chrome" ] && [ ! -d "/Applications/Google Chrome.app" ] && continue
    perm_app "$a" || missing="$missing auto:$a"
  done
  perm_pane "Accessibility" Privacy_Accessibility probe_ax || missing="$missing accessibility"
  if ! probe_sr; then
    IMAGES="screen-recording"; you "macOS asks: '$t would like to record this computer's screen' → click 'Open System Settings', then switch $t ON."
    screencapture -x "$ROOT/tmp/p.png" >/dev/null 2>&1; rm -f "$ROOT/tmp/p.png"
    IMAGES="screen-recording privacy-pane"
    pause "Click Done when $t is switched ON under Screen Recording (if macOS offers 'Quit & Reopen', click 'Later')."
    probe_sr || missing="$missing screen-recording"
  fi
  IMAGES=""
  [ -z "$missing" ] && { note "All permissions granted ✓"; return 0; }
  note "Still missing:$missing"; report permissions partial "missing:$missing"
  page_ask buttons "Some permissions are still off ($missing). Try them again, or continue (Frondesk can fix it later)?" "Try again" "Continue"
  case "$REPLY" in Continue) return 0 ;; esac; return 1
}
term_app() { case "${TERM_PROGRAM:-}" in iTerm.app) echo iTerm ;; *) echo Terminal ;; esac; }
pane() { open "x-apple.systempreferences:com.apple.preference.security?$1" 2>/dev/null; }
probe_fda() { head -c 1 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" >/dev/null 2>&1; }
probe_ax() { [ "$(osascript -l JavaScript -e 'ObjC.import("ApplicationServices"); $.AXIsProcessTrusted()' 2>/dev/null)" = true ]; }
probe_sr() { screencapture -x "$ROOT/tmp/p.png" >/dev/null 2>&1; r=$?; rm -f "$ROOT/tmp/p.png"; [ $r = 0 ]; }
# a real Apple Event per app (a bare "get name" never asks — 11-16 finding); -1743 = denied
ae_probe() {
  case "$1" in
    "System Events") aes='tell application "System Events" to count processes' ;;
    Messages) aes='tell application "Messages" to count chats' ;;
    Mail) aes='tell application "Mail" to count accounts' ;;
    Calendar) aes='tell application "Calendar" to count calendars' ;;
    Contacts) aes='tell application "Contacts" to count people' ;;
    Reminders) aes='tell application "Reminders" to count lists' ;;
    Notes) aes='tell application "Notes" to count notes' ;;
    *) aes="tell application \"$1\" to count windows" ;;
  esac
  out=$(osascript -e "$aes" 2>&1); case "$out" in *-1743*|*"Not authorized"*) return 1 ;; esac; return 0
}
perm_app() {
  you "macOS asks: '$t wants access to control $1' → click OK (within 2 minutes)."
  ae_probe "$1" && { MODE=auto; note "✓ control of $1"; return 0; }
  pane Privacy_Automation; IMAGES=""
  you "Not allowed yet. In the window that opened: Automation → $t → switch ON '$1'."
  pause "Click Done when '$1' is switched ON under $t."
  ae_probe "$1" && { MODE=auto; note "✓ control of $1"; return 0; }
  MODE=auto; note "✗ control of $1 not granted"; return 1
}
# perm_pane <label> <pane> <probe>: macOS has no dialog for these — add Terminal with "+" in the pane
perm_pane() {
  label=$1 pn=$2 pr=$3
  "$pr" && { note "✓ $label"; return 0; }
  i=0
  while [ $i -lt 2 ]; do
    pane "$pn"; IMAGES="privacy-pane privacy-password pick-terminal"
    you "In the window that opened ($label): click '+' under the list, type your Mac password, pick Applications → Utilities → $t, click Open, and make sure $t is switched ON."
    pause "Click Done when $t is switched ON under $label."
    IMAGES=""; "$pr" && { MODE=auto; note "✓ $label"; return 0; }
    i=$((i + 1))
  done
  MODE=auto; note "✗ $label not granted"; return 1
}

# ── keeper: starts the desk at login and restarts it if it stops (macOS LaunchAgent) ──
step_keeper() {
  is_mac || { note "macOS only (Linux: run '$BIN/frondesk run' yourself); skipped"; return 0; }
  write_command
  la="$HOME/Library/LaunchAgents/ai.frondesk.keeper.plist"; mkdir -p "$HOME/Library/LaunchAgents" "$ROOT/logs"
  cat > "$la" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>ai.frondesk.keeper</string>
  <key>ProgramArguments</key><array><string>$BIN/frondesk</string><string>keep</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>60</integer>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$ROOT/logs/keeper.log</string>
  <key>StandardErrorPath</key><string>$ROOT/logs/keeper.log</string>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)/ai.frondesk.keeper" >/dev/null 2>&1 || true
  logrun launchctl bootstrap "gui/$(id -u)" "$la" || return 1
  note "the desk opens in its own $(cat "$ROOT/.term" 2>/dev/null || echo Terminal) window in a few seconds — leave it open (it reopens itself if closed)."
  i=0; while [ $i -lt 30 ]; do desk_alive && return 0; sleep 2; i=$((i + 1)); done
  note "desk window did not start"; return 1
}
write_command() {
  printf '#!/bin/sh\nexec "%s" run\n' "$BIN/frondesk" > "$BIN/Frondesk.command"; chmod 755 "$BIN/Frondesk.command"
  printf '#!/bin/sh\nexec "%s" help\n' "$BIN/frondesk" > "$ROOT/Get Remote Help.command"; chmod 755 "$ROOT/Get Remote Help.command"
  printf '#!/bin/sh\nexec "%s" contact\n' "$BIN/frondesk" > "$ROOT/Contact the Developer.command"; chmod 755 "$ROOT/Contact the Developer.command"
}
desk_alive() { p=$(cat "$ROOT/run/desk.pid" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

# frondesk keep (LaunchAgent, every 60 s): open the desk window unless it runs
keep() {
  desk_alive && exit 0
  [ -f "$ROOT/.paused" ] && exit 0
  printf '%s keeper: desk not running, opening it\n' "$(date '+%F %T')"
  app=$(cat "$ROOT/.term" 2>/dev/null || echo Terminal)
  open -a "$app" "$BIN/Frondesk.command"
}

# frondesk run: the desk itself — Claude Code with the Frondesk channel, restarted if it exits
run_desk() {
  mkdir -p "$ROOT/run" "$ROOT/logs"
  if desk_alive; then echo "The Frondesk desk is already running in another window."; sleep 5; exit 0; fi
  echo $$ > "$ROOT/run/desk.pid"
  write_exp
  trap 'rm -f "$ROOT/run/desk.pid"' EXIT
  is_mac && { caffeinate -i -w $$ & }
  printf '\033]0;Frondesk — leave this window open\007'
  fast=0
  while :; do
    t0=$(date +%s)
    # resume the desk's conversation only once a real desk session has existed (claude -p runs don't count)
    cont=""; [ -f "$ROOT/run/has-session" ] && cont=--continue
    chans=""; tools=mcp__plugin_whatsapp_whatsapp__reply
    [ -f "$ST/messages" ] && is_mac && { chans="--channels plugin:imessage@claude-plugins-official"; tools="$tools,mcp__plugin_imessage_imessage__reply"; }
    (cd "$ROOT/work" && \
      CLAUDE_CODE_OAUTH_TOKEN="$(get_token)" PATH="$HOME/.bun/bin:$PATH" DISABLE_AUTOUPDATER=1 \
      WHATSAPP_CHANNEL=1 WHATSAPP_STATE_DIR="$ROOT/channel" WHATSAPP_TRANSPORT="$ROOT/lib/frondesk-transport.mjs" \
      FRONDESK_URL="$FD_URL" FRONDESK_KEY_FILE="$ROOT/.desk.key" \
      expect -f "$BIN/desk.exp" claude $cont $chans --dangerously-load-development-channels "$CHAN_FLAG" \
        --allowedTools "$tools" --append-system-prompt "$DESK_PROMPT")
    ran=$(( $(date +%s) - t0 ))
    [ $ran -ge 60 ] && touch "$ROOT/run/has-session"
    # a --continue that finds nothing exits at once: drop the marker so the next start is fresh
    [ $ran -lt 30 ] && [ -n "$cont" ] && rm -f "$ROOT/run/has-session"
    [ $ran -lt 30 ] && fast=$((fast + 1)) || fast=0
    if [ $fast -ge 5 ]; then
      report desk crashloop "claude exits within 30 s, 5 times in a row; pausing 5 min"; echo "Claude keeps exiting; retrying in 5 minutes."; sleep 300; fast=0
    else echo "Claude stopped; restarting in 5 s (close this window to stop it for a minute)."; sleep 5; fi
  done
}

# expect wrapper: real pty for claude, window size follows ours, and it answers the one
# "development channel" confirmation (default option 1) so restarts need nobody at the keyboard.
write_exp() {
  cat > "$BIN/desk.exp" <<'EOF2'
log_user 1
set timeout -1
set rows 40; set cols 120; catch { set rows [stty rows]; set cols [stty columns] }
eval spawn -noecho $argv
catch { stty rows $rows columns $cols < $spawn_out(slave,name) }
trap { catch { set r [stty rows]; set c [stty columns]; stty rows $r columns $c < $spawn_out(slave,name) } } WINCH
# the TUI draws spaces as cursor moves, so match words with anything (escapes) between them; answer once
set answered 0
interact {
  -o -nobuffer -re {Loading.{0,24}development.{0,24}channels} {
    if {!$answered} { set answered 1; after 700; send -i $spawn_id "\r" }
  }
}
catch wait
EOF2
}

doctor() {
  printf 'frondesk doctor — %s, %s\n' "$(cat "$ROOT/.name" 2>/dev/null)" "$(os_desc)"
  for s in $STEPS; do [ -f "$ST/$s" ] && printf '  ✓ %s\n' "$s" || printf '  ✗ %s\n' "$s"; done
  printf '  claude: %s\n' "$(claude --version 2>/dev/null || echo missing)"
  printf '  claude key: %s\n' "$(t=$(get_token) && [ -n "$t" ] && token_ok "$t" && echo works || echo MISSING/BROKEN)"
  printf '  desk running: %s\n' "$(desk_alive && echo yes || echo NO)"
  printf '  channel log: %s\n' "$(tail -n 1 "$ROOT/channel/channel.log" 2>/dev/null | cut -c1-100)"
  is_mac && printf '  keeper: %s\n' "$(launchctl print "gui/$(id -u)/ai.frondesk.keeper" >/dev/null 2>&1 && echo loaded || echo NOT loaded)"
  is_mac && printf '  remote help: %s\n' "$([ -d /Applications/RustDesk.app ] && echo RustDesk || echo NONE)"
}

# ── power: stay awake on the charger, come back after a power cut ──
step_power() {
  is_mac || { note "macOS only; skipped"; return 0; }
  note "So texts reach your computer while you're away: no sleep while plugged in, restart after a power cut. A closed laptop on battery still sleeps — leave it plugged in."
  you "A macOS window asks for your Mac password. Type it and click OK."
  admin_run "pmset -c sleep 0 disksleep 0 womp 1 powernap 1; pmset -a autorestart 1" >>"$LOG" 2>&1 || return 1
  MODE=auto
}

# ── selftest: Claude answers with his login; the desk is connected to Frondesk ──
step_selftest() {
  out=$(cd "$ROOT/work" && with_token claude -p "Reply with exactly: FRONDESK-OK" 2>>"$LOG") || true
  case "$out" in *FRONDESK-OK*) note "✓ Claude answers" ;; *) note "✗ Claude did not answer: $out"; return 1 ;; esac
  if is_mac; then
    grep -q "WhatsApp open" "$ROOT/channel/channel.log" 2>/dev/null && note "✓ desk connected to Frondesk" \
      || { note "✗ desk not connected to Frondesk yet (see $ROOT/channel/channel.log)"; return 1; }
  fi
  note "Now text 'hi' to the Frondesk number from $(cat "$ROOT/.phone") (WhatsApp or SMS), or text yourself in Messages — the answer comes from this computer."
}

uninstall() {
  printf '   Remove Frondesk from this computer (desk, channel, FastLink pairing, keeper, Claude key)? (y/N) ' >/dev/tty; IFS= read -r REPLY </dev/tty || REPLY=""
  case "$REPLY" in y*|Y*) ;; *) exit 0 ;; esac
  if is_mac; then launchctl bootout "gui/$(id -u)/ai.frondesk.keeper" >/dev/null 2>&1; rm -f "$HOME/Library/LaunchAgents/ai.frondesk.keeper.plist"; fi
  p=$(cat "$ROOT/run/desk.pid" 2>/dev/null) && kill "$p" 2>/dev/null
  [ -f "$ROOT/fastlink/server/index.js" ] && node "$ROOT/fastlink/server/index.js" unpair >/dev/null 2>&1
  claude mcp remove -s user fastlink >/dev/null 2>&1
  claude plugin uninstall whatsapp@claude-whatsapp >/dev/null 2>&1
  claude plugin marketplace remove claude-whatsapp >/dev/null 2>&1
  is_mac && security delete-generic-password -a "$(id -un)" -s frondesk-claude-token >/dev/null 2>&1
  claude plugin uninstall imessage@claude-plugins-official >/dev/null 2>&1
  for n in $(claude mcp list 2>/dev/null | grep -o '^gmail[a-z0-9_-]*'); do claude mcp remove -s user "$n" >/dev/null 2>&1; done
  rm -rf "$ROOT"
  say "Removed. Kept: Claude Code and your login, RustDesk (/Applications/RustDesk.app) — drag it to the Trash if unwanted."
}

main "$@"
