#!/usr/bin/env bash
# mc-wrapper.sh — Production Minecraft wrapper + FIFO + Discord + JSON spots + full commands + backup + countdown

set -euo pipefail
IFS=$'\n\t'
VERSION="1.0.2"

### ─── ARGS & USAGE ───────────────────────────────────────────────────────────
usage(){
  cat <<EOF
Usage: $0 [options]
  -c|--config FILE       (default: ./wrapper.conf)
  -n|--nogui             force nogui
  -g|--gui               force GUI
  -w|--without-commands  disable chat commands
  -v|--version           print version
  -h|--help              this message
EOF
}
CONFIG_FILE=./wrapper.conf; FORCE_GUI=false; WITHOUT_COMMANDS=false
while [[ $# -gt 0 ]]; do
  case $1 in
    -c|--config)           CONFIG_FILE="$2"; shift 2 ;;
    -n|--nogui)            FORCE_GUI=false; shift ;;
    -g|--gui)              FORCE_GUI=true;  shift ;;
    -w|--without-commands) WITHOUT_COMMANDS=true; shift ;;
    -v|--version)          echo "$VERSION"; exit 0 ;;
    -h|--help)             usage; exit 0 ;;
    *)                     echo "Unknown: $1"; usage; exit 1 ;;
  esac
done

### ─── COLORS & LOG ───────────────────────────────────────────────────────────
BLUE='\e[34m'; GREEN='\e[32m'; YELLOW='\e[33m'; RED='\e[31m'; RESET='\e[0m'
log(){ printf "${BLUE}[%s]${RESET} %s\n" "$(date +'%F %T')" "$*"; }

### ─── DEFAULTS & CONFIG ──────────────────────────────────────────────────────
DEFAULT_JAR="server.jar";       DEFAULT_XMX="5G"; DEFAULT_XMS="3G"
DEFAULT_NOGUI_FLAG="nogui";     DEFAULT_LOGDIR="./logs";      DEFAULT_RESTART_DELAY=10
DEFAULT_DISCORD_WEBHOOK="";     DEFAULT_RCON_ENABLED=false
DEFAULT_PRIV_FILE="./privileged_users.conf"
DEFAULT_METRICS_INTERVAL=5;     DEFAULT_TMUX_SESSION="minecraft"
DEFAULT_WORLD_DIR="./world";    DEFAULT_BACKUP_DIR="./backups"

if [[ ! -f "$CONFIG_FILE" ]]; then
  cat >"$CONFIG_FILE"<<EOF
# mc-wrapper overrides:
# JAR="server.jar"
# XMX="5G"
# XMS="3G"
# NOGUI_FLAG="nogui"
# LOGDIR="./logs"
# RESTART_DELAY=10
# DISCORD_WEBHOOK="https://discordapp.com/api/webhooks/…"
# RCON_ENABLED=false
# PRIV_FILE="./privileged_users.conf"
# METRICS_INTERVAL=5
# TMUX_SESSION="minecraft"
# WORLD_DIR="./world"
# BACKUP_DIR="./backups"
EOF
  log "Created $CONFIG_FILE"
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE" 2>/dev/null || true

JAR="${JAR:-$DEFAULT_JAR}"
XMX="${XMX:-$DEFAULT_XMX}"
XMS="${XMS:-$DEFAULT_XMS}"
if $FORCE_GUI; then NOGUI_FLAG=""; else NOGUI_FLAG="${NOGUI_FLAG:-$DEFAULT_NOGUI_FLAG}"; fi
LOGDIR="${LOGDIR:-$DEFAULT_LOGDIR}"
RESTART_DELAY="${RESTART_DELAY:-$DEFAULT_RESTART_DELAY}"
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-$DEFAULT_DISCORD_WEBHOOK}"
RCON_ENABLED="${RCON_ENABLED:-$DEFAULT_RCON_ENABLED}"
PRIV_FILE="${PRIV_FILE:-$DEFAULT_PRIV_FILE}"
METRICS_INTERVAL="${METRICS_INTERVAL:-$DEFAULT_METRICS_INTERVAL}"
TMUX_SESSION="${TMUX_SESSION:-$DEFAULT_TMUX_SESSION}"
WORLD_DIR="${WORLD_DIR:-$DEFAULT_WORLD_DIR}"
BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"
WITHOUT_COMMANDS=${WITHOUT_COMMANDS:-false}

mkdir -p "$LOGDIR" "$BACKUP_DIR"

### ─── PRIVILEGES ──────────────────────────────────────────────────────────────
if [[ ! -f "$PRIV_FILE" ]]; then
  echo "user:1" >"$PRIV_FILE"
  log "Created $PRIV_FILE"
fi
declare -A PRIV
while IFS=: read -r u lvl; do PRIV["$u"]=$lvl; done <"$PRIV_FILE"
save_priv(){
  :>"$PRIV_FILE"
  for u in "${!PRIV[@]}"; do
    echo "$u:${PRIV[$u]}" >>"$PRIV_FILE"
  done
}
user_level(){ echo "${PRIV[$1]:-3}"; }

### ─── LOCATIONS JSON ─────────────────────────────────────────────────────────
LOC_JSON=./locations.json
if [[ ! -f "$LOC_JSON" ]]; then
  cat >"$LOC_JSON"<<EOF
{
  "home":  "650 102 1130",
  "spawn": "284 64 784",
  "end":   "1737 -28 1343",
  "nether":"648 97 1130",
  "up":    "~ ~50 ~",
  "mup":   "~ ~150 ~",
  "jail":  "0 -61 0"
}
EOF
  log "Created $LOC_JSON"
fi
declare -A LOC
HAS_JQ=false
if command -v jq &>/dev/null; then
  HAS_JQ=true
  while IFS== read -r k v; do LOC["$k"]="$v"; done < <(
    jq -r 'to_entries|map("\(.key)=\(.value|tostring)")|.[]' "$LOC_JSON"
  )
else
  log "jq missing; using built-in locations"
  LOC=( [home]="650 102 1130" [spawn]="284 64 784" [end]="1737 -28 1343"
        [nether]="648 97 1130" [up]="~ ~50 ~" [mup]="~ ~150 ~" [jail]="0 -61 0" )
fi

### ─── FIFO vs RCON ──────────────────────────────────────────────────────────
USE_FIFO=true
if $RCON_ENABLED && command -v mcrcon &>/dev/null; then
  USE_FIFO=false; log "Using mcrcon (RCON)"
else
  PIPE=server.in; [[ -p $PIPE ]]||mkfifo $PIPE
  exec 3<>$PIPE; exec 4</dev/tty
  trap 'rm -f $PIPE' EXIT
  log "FIFO mode → $PIPE"
fi
rcon_send(){
  if ! $USE_FIFO; then
    mcrcon -H "${RCON_HOST:-127.0.0.1}" -P "${RCON_PORT:-25575}" \
      -p "${RCON_PASS:-changeme}" -c "$*"
  else
    echo "$*" >&3
  fi
}

### ─── DISCORD ────────────────────────────────────────────────────────────────
discord_notify(){
  [[ -z $DISCORD_WEBHOOK ]] && return
  curl -s -H "Content-Type: application/json" \
       -d "{\"content\":\"$1\"}" "$DISCORD_WEBHOOK" \
    || log "Discord notify failed"
}

### ─── METRICS ────────────────────────────────────────────────────────────────
_last=0; CPU=; RAM=; IO=; NET=
update_metrics(){
  local now; now=$(date +%s)
  (( now - _last < METRICS_INTERVAL )) && return
  _last=$now

  # ─── CPU & RAM ──────────────────────────────────────────────────────────────
  CPU=$( top -b -n2 -d0.5 \
         | awk '/Cpu\(s\)/{print $2 "%"}' \
         | tail -n1 )
  RAM=$( free -m | awk '/^Mem:/{printf "%d%%",$3/$2*100}' )

  # ─── I/O via iostat ─────────────────────────────────────────────────────────
  if command -v iostat &>/dev/null; then
    IO=$( iostat -d 1 1 2>/dev/null \
          | awk '
              # skip the header lines (Linux info & the “Device” header)
              $1=="Linux" || $1=="Device" { next }
              # first non-header line is our real device stats
              NF >= 2 {
                # $2 = tps
                printf "%s:%stps", $1, int($2)
                exit
              }
            ' )
  else
    IO="iostat:N/A"
  fi

  # ─── NET via ifstat ─────────────────────────────────────────────────────────
  if command -v ifstat &>/dev/null; then
    NET=$( ifstat 2>/dev/null \
	   | tail -n +4 \
           | awk '
               # skip header blocks and the lo interface
               NF % 2 == 1 && $1 != "lo" {
               	# fields: $6 = RX Data/Rate, $8 = TX Data/Rate
               	printf "Rx:%s Tx:%s", $6, $8
               	exit
               }
             ' )
  else
    NET="ifstat:N/A"
  fi
}

get_cpu(){ update_metrics; echo "$CPU"; }
get_ram(){ update_metrics; echo "$RAM"; }
get_io(){  update_metrics; echo "$IO";  }
get_net(){ update_metrics; echo "$NET"; }

### ─── UPTIME & HEAP ─────────────────────────────────────────────────────────
START_TS=$(date +%s)
get_uptime(){
  local d=$(( $(date +%s)-START_TS ))
  printf "%02d:%02d:%02d" $((d/3600)) $(((d%3600)/60)) $((d%60))
}
get_heap(){
  if [[ -z ${SERVER_PID-} ]] || ! kill -0 "$SERVER_PID" &>/dev/null || ! command -v jstat &>/dev/null; then
    echo "N/A (needs jstat & valid PID)"
  else
    local u; u=$(jstat -gcutil "$SERVER_PID" | tail -n1)
    read -r S0 S1 E O M CCS YGC YGCT FGC FGCT GCT <<<"$u"
    printf "Eden:%.2f%% Old:%.2f%% Meta:%.2f%% (Xmx=%s)" "$E" "$O" "$M" "$XMX"
  fi
}

### ─── SHUTDOWN COUNTDOWN ─────────────────────────────────────────────────────
SHUTDOWN=false
shutdown_sequence(){
  if ! $SHUTDOWN; then
    SHUTDOWN=true
    for i in 5 4 3 2 1; do
      rcon_send "say Server shutting down in $i…"
      sleep 1
    done
    rcon_send save-all
    sleep 2
    rcon_send stop
    discord_notify "❌ Server down at $(date +'%F %T')"
    log "✔ Server stopped cleanly"
    exit 0
  fi
}
trap 'shutdown_sequence' SIGINT SIGTERM SIGHUP

### ─── BACKUP ─────────────────────────────────────────────────────────────────
do_backup(){
  rcon_send save-off; rcon_send save-all; sleep 2
  ts=$(date +'%Y%m%d-%H%M%S')
  dest="$BACKUP_DIR/world-$ts"; mkdir -p "$dest"
  cp -r "$WORLD_DIR"/. "$dest"/
  rcon_send save-on
  rcon_send "say Backup saved to $dest"
  discord_notify "💾 Backup saved: $dest"
}

### ─── SEED & ADDSPOT VARS ────────────────────────────────────────────────────
SEED_REQ=""; SPOT_REQ=""; SPOT_NAME=""

### ─── PROCESS_OUTPUT ─────────────────────────────────────────────────────────
process_output(){
  while IFS= read -r line; do
    # daily log rotation
    newd=$(date +%Y%m%d)
    if [[ $newd != "$CURRENT_LOG_DATE" ]]; then
      CURRENT_LOG_DATE=$newd
      WRAP_LOG="$LOGDIR/server-$newd.log"
      CHAT_LOG="$LOGDIR/chat-$newd.log"
      log "Rotated logs → $newd"
      discord_notify "🔄 Logs rotated → $newd"
    fi

    # echo & log
    echo -e "${GREEN}[Server]${RESET} $line"
    printf "[%s] %s\n" "$(date +'%F %T')" "$line" >>"$WRAP_LOG"

    # ─ JOIN
    if [[ $line =~ INFO\]:\ ([^[:space:]]+)\ joined\ the\ game ]]; then
      p=${BASH_REMATCH[1]}; ts=$(date +'%F %T')
      echo "[$ts] $p joined" >>"$CHAT_LOG"
      rcon_send "say Welcome, $p!"
      rcon_send "msg $p Enjoy the game! Say help server"
      discord_notify "🟢 $p joined at $ts"
      continue
    fi

    # ─ LEAVE
    if [[ $line =~ INFO\]:\ ([^[:space:]]+)\ left\ the\ game ]]; then
      p=${BASH_REMATCH[1]}; ts=$(date +'%F %T')
      echo "[$ts] $p left" >>"$CHAT_LOG"
      discord_notify "🔴 $p left at $ts"
      continue
    fi

    # ─── ADVANCEMENTS / CHALLENGES / GOALS ──────────────────────────────────────
    if [[ $line =~ INFO\]\:\ ([^[:space:]]+)\ has\ (earned\ the\ advancement|made\ the\ advancement|completed\ the\ challenge|reached\ the\ goal)\:?\ \[([^\]]+)\] ]]; then
      p=${BASH_REMATCH[1]}         # player name
      ach=${BASH_REMATCH[3]}       # captured advancement/challenge/goal text
      discord_notify "🏆 $p got $ach"
      continue
    fi

    # ─ SEED FEEDBACK
    if [[ $line =~ Seed:\ \[?(-?[0-9]+)\]? ]] && [[ -n $SEED_REQ ]]; then
      s=${BASH_REMATCH[1]}
      rcon_send "say World seed is $s (by $SEED_REQ)"
      SEED_REQ=""
      continue
    fi

    # ─ ADDSPOT COORDS
    if [[ -n $SPOT_REQ && $line =~ has\ the\ following\ entity\ data:\ \[([-0-9\.]+)d,\ ([0-9\.]+)d,\ ([-0-9\.]+)d\] ]]; then
      coords="${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"
      if $HAS_JQ; then
        tmp=$(mktemp)
        jq --arg k "$SPOT_NAME" --arg v "$coords" '. + {($k):$v}' "$LOC_JSON" >"$tmp" && mv "$tmp" "$LOC_JSON"
      else
        sed -i -e "\#^}#s#^}#  \"$SPOT_NAME\": \"$coords\",\\n}#" "$LOC_JSON"
      fi
      LOC["$SPOT_NAME"]="$coords"
      rcon_send "say Added spot '$SPOT_NAME': $coords"
      discord_notify "📍 $SPOT_REQ added $SPOT_NAME"
      SPOT_REQ=""; SPOT_NAME=""
      continue
    fi

    # ─ CHAT PARSE
    if [[ $line =~ INFO\]\:\ \<([^>]+)\>\ (.*)$ ]]; then
      user=${BASH_REMATCH[1]}; msg=${BASH_REMATCH[2]}
      raw=$(printf '%s' "$msg" | tr '[:upper:]' '[:lower:]' \
            | sed 's/[^a-z0-9_ ~]//g' | xargs)
      printf "[%s] <%s> %s\n" "$(date +'%H:%M:%S')" "$user" "$msg" >>"$CHAT_LOG"

      prefix=false
      if [[ $raw == server\ * ]]; then prefix=true; cmd=${raw#server }; else cmd=$raw; fi
      lvl=$(user_level "$user")

      # ─ HELP <cmd> ← includes gamemode now
      if [[ $cmd == help\ * ]]; then
        sub=${cmd#help }
        case "$sub" in
          tp)         rcon_send "say Usage: server tp <location|player|x y z>" ;;
          weather)    rcon_send "say Usage: server weather [clear|rain|thunder]" ;;
          seed)       rcon_send "say Usage: server seed" ;;
          save)       rcon_send "say Usage: server save" ;;
          give)       rcon_send "say Usage: server give me <item> | server give <player> <item>" ;;
          addspot)    rcon_send "say Usage: server addspot <name>" ;;
          backup)     rcon_send "say Usage: server backup" ;;
          gamemode)   rcon_send "say Usage: server gamemode <creative|spectator|survival> [player]" ;;
          stop)       rcon_send "say Usage: server stop" ;;
          *)          rcon_send "say No help for '$sub'" ;;
        esac
        continue
      fi

      # ─ HELP
      if [[ $cmd == help ]]; then
        if (( lvl==1 )); then
          rcon_send "say [L1] Full control:"
          rcon_send "say   ban, unban, ban-ip, unban-ip, op, deop, kick,"
          rcon_send "say   addpriv, removepriv, backup, creative, spectator, survival, stop"
          rcon_send "say + all level-2 commands"
        elif (( lvl==2 )); then
          rcon_send "say [L2] Commands:"
          rcon_send "say   day, night, weather <state>, tp <loc>, uptime,"
          rcon_send "say   cpu, ram, io, net, heap, save, seed,"
          rcon_send "say   broadcast <msg>, dispatch <cmd>, addspot <name>, gamemode"
        else
          rcon_send "say [L3] Fun commands:"
          rcon_send "say   ping, hi, joke, dance, time, quote,"
          rcon_send "say   riddle, fortune, coinflip, dice, draw, haiku, story"
        fi
        continue
      fi

      # ─ FUN (L3+)
      case "$cmd" in
        ping)     rcon_send "say pong, $user!" ;;
        hi|hey)   rcon_send "say Hello, $user!" ;;
        joke)     rcon_send "say Why don't skeletons fight? They have no guts." ;;
        dance)    rcon_send "say *dances* 💃" ;;
        time)     rcon_send "say Time: $(date +'%T')" ;;
        quote)    rcon_send "say \"Be yourself; everyone else is taken.\" - Wilde" ;;
        riddle)   rcon_send "say What has keys but opens no locks? A piano." ;;
        fortune)  rcon_send "say You will have a pleasant surprise." ;;
        coinflip) rcon_send "say $((RANDOM%2==0?Heads:Tails))" ;;
        dice)     rcon_send "say 🎲 $((RANDOM%6+1))!" ;;
        draw)     rcon_send $'say O\n/|\\\n/ \\' ;;
        haiku)    rcon_send "say Lines of code cascade across a world of blocks." ;;
        story)    rcon_send "say Once upon a block... The end." ;;
      esac

      # ─ LEVEL 2 (needs prefix)
      if (( lvl<=2 )); then
        case "$cmd" in
          day|time\ day|time\ set\ day)       rcon_send "time set day" ;;
          night|time\ night|time\ set\ night) rcon_send "time set night" ;;
          weather\ *) if $prefix; then
                         st=${cmd#weather }
                         if [[ $st =~ ^(clear|rain|thunder)$ ]]; then
                           rcon_send "weather $st"
                         else
                           rcon_send "say Usage: server weather [clear|rain|thunder]"
                         fi
                       fi ;;
          tp\ *)
            if $prefix; then
              IFS=' ' read -r -a args <<<"${cmd#tp }"
              if (( ${#args[@]} == 3 )) && [[ "${args[0]}" =~ ^[-0-9~] ]]; then
                x="${args[0]}" y="${args[1]}" z="${args[2]}"
                rcon_send "say Teleporting $user to $x $y $z"
                rcon_send "tp $user $x $y $z"
              elif (( ${#args[@]} == 1 )); then
               token="${args[0]}"
               # 1) named location?
               if [[ -n "${LOC[$token]:-}" ]]; then
                 coords="${LOC[$token]}"
                 rcon_send "say Teleporting $user to '$token' ($coords)"
                 rcon_send "tp $user $coords"
               else
                 # 2) assume it's another player
                 rcon_send "say Teleporting $user to player '$token'"
                 rcon_send "tp $user $token"
               fi
              else
                rcon_send "say Usage: server tp <location|x y z>"
              fi
            fi
            ;;
          uptime)      rcon_send "say Uptime: $(get_uptime)" ;;
          cpu)         rcon_send "say CPU: $(get_cpu)" ;;
          ram)         rcon_send "say RAM: $(get_ram)" ;;
          io)          rcon_send "say I/O: $(get_io)" ;;
          net)         rcon_send "say NET: $(get_net)" ;;
          heap)        rcon_send "say Heap: $(get_heap)" ;;
          save)        if $prefix; then rcon_send save-all; fi ;;
          seed)        if $prefix; then SEED_REQ="$user"; rcon_send "seed"; fi ;;
          broadcast\ *)
            msg="${cmd#broadcast }"
            rcon_send "say [B] $msg"
            discord_notify "📢 Broadcast: $msg"
            ;;
          dispatch\ *) rcon_send "${cmd#dispatch }" ;;
          addspot\ *)  if $prefix; then
                          SPOT_REQ="$user"; SPOT_NAME="${cmd#addspot }"
                          rcon_send "data get entity $user Pos"
                        fi
                        ;;
          gamemode\ *) if $prefix; then
                          rest=${cmd#gamemode }
                          read -r -a parts <<<"$rest"
                          mode=${parts[0]}
                          if (( ${#parts[@]}==1 )); then
                            rcon_send "gamemode $mode $user"
                          else
                            rcon_send "gamemode $mode ${parts[1]}"
                          fi
                        fi ;;
          creative)    if $prefix; then rcon_send "gamemode creative $user"; fi ;;
          spectator)   if $prefix; then rcon_send "gamemode spectator $user"; fi ;;
          survival)    if $prefix; then rcon_send "gamemode survival $user"; fi ;;
        esac
      fi

      # ─ LEVEL 1 ONLY (needs prefix)
      if (( lvl==1 )); then
        case "$cmd" in
          ban\ *)       tgt=${cmd#ban }         ; rcon_send "ban $tgt";      discord_notify "⛔ $tgt banned" ;;
          unban\ *)     tgt=${cmd#unban }       ; rcon_send "pardon $tgt";   discord_notify "✅ $tgt unbanned" ;;
          ban-ip\ *)    ip=${cmd#ban-ip }       ; rcon_send "ban-ip $ip";     discord_notify "⛔ IP $ip banned" ;;
          unban-ip\ *)  ip=${cmd#unban-ip }     ; rcon_send "pardon-ip $ip";  discord_notify "✅ IP $ip unbanned" ;;
          op\ *)        tgt=${cmd#op }          ; rcon_send "op $tgt";        discord_notify "🔨 $tgt opped" ;;
          deop\ *)      tgt=${cmd#deop }        ; rcon_send "deop $tgt";      discord_notify "🔨 $tgt de-opped" ;;
          kick\ *)      tgt=${cmd#kick }        ; rcon_send "kick $tgt";      discord_notify "👢 $tgt kicked" ;;
          backup)       if $prefix; then do_backup; fi ;;
          give\ me\ *)  if $prefix; then
                            item=${cmd#give me }
                            case "$item" in
                              tools) for t in sword shovel pickaxe axe hoe; do
                                         rcon_send "give $user minecraft:netherite_$t"
                                       done ;;
                              food)  rcon_send "give $user minecraft:cooked_beef 64" ;;
                              armor) for r in helmet chestplate leggings boots; do
                                         rcon_send "give $user minecraft:netherite_$r"
                                       done ;;
                              *)     rcon_send "give $user minecraft:$item" ;;
                            esac
                            rcon_send "say Gave $item to $user"
                          fi ;;
          give\ *)      if $prefix; then
                            rest=${cmd#give }; tgt=${rest%% *}; itm=${rest#* }
                            rcon_send "give $tgt minecraft:$itm"
                            rcon_send "say Gave $itm to $tgt"
                          fi ;;
          addpriv\ *)   if $prefix; then
                            if [[ $cmd =~ ^addpriv[[:space:]]+([^[:space:]]+)([[:space:]]+([1-3]))?$ ]]; then
                              newu=${BASH_REMATCH[1]}
                              newl=${BASH_REMATCH[3]:-2}
                              PRIV["$newu"]=$newl; save_priv
                              rcon_send "say Added priv: $newu → level $newl"
                            else
                              rcon_send "say Usage: server addpriv <user> [1-3]"
                            fi
                          fi ;;
          removepriv\ *)if $prefix; then
                            if [[ $cmd =~ ^removepriv[[:space:]]+([^[:space:]]+) ]]; then
                              remu=${BASH_REMATCH[1]}
                              unset PRIV["$remu"]; save_priv
                              rcon_send "say Removed priv: $remu"
                            else
                              rcon_send "say Usage: server removepriv <user>"
                            fi
                          fi ;;
          stop)         if $prefix; then shutdown_sequence; fi ;;
        esac
      fi

    fi
  done
}
export -f process_output

### ─── INTERACTIVE FORWARDING ────────────────────────────────────────────────
# read player commands from tmux pane's tty (fd 4) → rcon_send
exec 4</dev/tty
if [ -t 0 ]; then
  while IFS= read -r -u 4 c; do
    [[ -z $c ]] && continue
    rcon_send "$c"
  done &
fi

### ─── MAIN LAUNCH LOOP ───────────────────────────────────────────────────────
while true; do
  CURRENT_LOG_DATE=$(date +%Y%m%d)
  WRAP_LOG="$LOGDIR/server-$CURRENT_LOG_DATE.log"
  CHAT_LOG="$LOGDIR/chat-$CURRENT_LOG_DATE.log"

  log "▶ Starting server…"
  discord_notify "✅ Server up at $(date +'%F %T')"

  OUT_FIFO="/tmp/mc-out-$$.fifo"; mkfifo "$OUT_FIFO"
  if $USE_FIFO; then
    java -Xmx"$XMX" -Xms"$XMS" -jar "$JAR" $NOGUI_FLAG <"$PIPE" >"$OUT_FIFO" 2>&1 &
  else
    java -Xmx"$XMX" -Xms"$XMS" -jar "$JAR" $NOGUI_FLAG < /dev/null >"$OUT_FIFO" 2>&1 &
  fi
  SERVER_PID=$!

  (
    trap '' SIGINT SIGTERM
    tee -a "$WRAP_LOG" <"$OUT_FIFO" | process_output
  ) &
  PIPELINE_PID=$!

  # wait for the Java server to exit
  wait "$SERVER_PID"

  # tear down pipeline & clean up
  kill -TERM $PIPELINE_PID 2>/dev/null || true
  wait $PIPELINE_PID 2>/dev/null || true
  rm "$OUT_FIFO"

  # discord_notify "❌ Server down at $(date +'%F %T')"
  if $SHUTDOWN; then
    # we already exited from shutdown_sequence(), but just in case:
    log "✔ Server stopped cleanly"
    exit 0
  fi

  log "⚠️  Crashed; restarting in $RESTART_DELAY s…"
  sleep "$RESTART_DELAY"
done

