# shellcheck shell=bash
# ── Единый интерфейс: сообщения, шаги, вопросы, меню, карточки ─────────────────
# Общий для tt-endpoint.sh (ttctl) и tt-gateway.sh (ttgwctl).

# UTF-8 нужен для рамок и ровных колонок с кириллицей
[[ $(locale charmap 2>/dev/null) == UTF-8 ]] || export LC_ALL=C.UTF-8 2>/dev/null || true

if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
  c_acc=$'\e[38;5;39m'; c_ok=$'\e[38;5;42m'; c_warn=$'\e[38;5;214m'; c_err=$'\e[38;5;203m'
  c_dim=$'\e[38;5;245m'; c_b=$'\e[1m'; c_0=$'\e[0m'
else
  c_acc=; c_ok=; c_warn=; c_err=; c_dim=; c_b=; c_0=
fi
UI_TTY=0; [[ -t 0 && -t 1 ]] && UI_TTY=1
LOG=${LOG:-/dev/null}

ok()   { printf '  %s✓%s %s\n' "$c_ok" "$c_0" "$*"; }
log()  { ok "$@"; }
note() { printf '  %s%s%s\n' "$c_dim" "$*" "$c_0"; }
warn() { printf '  %s!%s %s\n' "$c_warn" "$c_0" "$*" >&2; }
err()  { printf '  %s✗%s %s\n' "$c_err" "$c_0" "$*" >&2; }
die()  { printf '\n' >&2; err "$*"; printf '\n' >&2; exit 1; }

trim() { local s=$*; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }
pad()  { local s=$1 w=$2; printf '%s%*s' "$s" $(( w > ${#s} ? w - ${#s} : 0 )) ''; }   # ширина в символах
rule() { printf '  %s%s%s\n' "$c_dim" "──────────────────────────────────────────────────────" "$c_0"; }
cls()  { [[ $UI_TTY == 1 ]] && printf '\e[H\e[2J' || true; }

banner() { # banner "Продукт" "роль"
  printf '\n  %s◆%s %s%s%s  %s%s%s\n' "$c_acc" "$c_0" "$c_b" "$1" "$c_0" "$c_dim" "${2:-}" "$c_0"
  rule
}

# Шаги установки: steps N, затем step "Название" → «3/7  Название»
UI_STEP=0; UI_STEPS=0
steps() { UI_STEPS=$1; UI_STEP=0; }
step() {
  UI_STEP=$((UI_STEP + 1))
  printf '\n  %s%d/%d%s  %s%s%s\n' "$c_dim" "$UI_STEP" "$UI_STEPS" "$c_0" "$c_b" "$*" "$c_0"
  printf '\n=== %s %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null || true
}
section() { printf '\n  %s%s%s\n' "$c_b$c_acc" "$1" "$c_0"; shift; local l; for l in "$@"; do note "$l"; done; }

ui_dur() { local s=$1; if (( s >= 60 )); then printf '%d мин %d с' $((s / 60)) $((s % 60)); else printf '%d с' "$s"; fi; }

# run "Что делаем" команда… — вывод команды уходит в журнал $LOG, на экране спиннер и итог
run() {
  local msg=$1 t0=$SECONDS rc=0 pid i=0 fr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  shift
  printf -- '--- %s: %s\n' "$(date +%T)" "$msg" >>"$LOG" 2>/dev/null || true
  if [[ $UI_TTY == 1 ]]; then
    ( "$@" ) >>"$LOG" 2>&1 </dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s%s%s %s' "$c_acc" "${fr:i++%10:1}" "$c_0" "$msg"
      sleep 0.1
    done
    wait "$pid" || rc=$?
    printf '\r\e[K'
  else
    ( "$@" ) >>"$LOG" 2>&1 </dev/null || rc=$?
  fi
  if (( rc == 0 )); then
    if (( SECONDS - t0 >= 3 )); then
      printf '  %s✓%s %s  %s%s%s\n' "$c_ok" "$c_0" "$msg" "$c_dim" "$(ui_dur $((SECONDS - t0)))" "$c_0"
    else
      printf '  %s✓%s %s\n' "$c_ok" "$c_0" "$msg"
    fi
  else
    err "$msg"
    if [[ -f $LOG ]]; then
      tail -n 12 "$LOG" | sed "s/^/      $c_dim/; s/\$/$c_0/" >&2
      note "  полный журнал: $LOG" >&2
    fi
  fi
  return "$rc"
}

# Подсказки вопросов. Escape-последовательности обёрнуты в \001…\002, чтобы readline верно считал ширину.
ui_prompt() { # текст [умолчание] → готовая строка для read -p
  local q=$1 d=${2:-} p
  p="  "$'\001'"$c_b"$'\002'"$q"$'\001'"$c_0"$'\002'
  [[ -n $d ]] && p+=" "$'\001'"$c_dim"$'\002'"[$d]"$'\001'"$c_0"$'\002'
  p+=" "$'\001'"$c_acc"$'\002'"›"$'\001'"$c_0"$'\002'" "
  printf '%s' "$p"
}

# ask ПЕРЕМЕННАЯ "Вопрос" [умолчание] [regex] [текст ошибки] [функция-проверка]
# Значение, заранее заданное в окружении, принимается без вопроса (если корректно).
# Все локальные переменные — с префиксом _u: функции пишут в переменную вызывающего по имени,
# и совпадение имён (например, «k» у вызывающего и у choose) иначе ломало бы ответ.
ask() {
  local _uv=$1 _uq=$2 _ud=${3:-} _ure=${4:-} _um=${5:-Неверный формат} _uf=${6:-} _ua _up=${!1:-}
  if [[ -n $_up ]]; then
    _up=$(trim "$_up")
    if [[ -z $_ure || $_up =~ $_ure ]] && { [[ -z $_uf ]] || "$_uf" "$_up"; }; then printf -v "$_uv" '%s' "$_up"; return 0; fi
    warn "Заданное значение $_uv=«$_up» не подходит"
  fi
  if [[ ! -t 0 ]]; then
    if [[ -n $_ud ]] && [[ -z $_ure || $_ud =~ $_ure ]]; then printf -v "$_uv" '%s' "$_ud"; return 0; fi
    die "Нет ответа на вопрос «$_uq» (запуск без терминала)"
  fi
  while :; do
    IFS= read -r -e -p "$(ui_prompt "$_uq" "$_ud")" _ua || die "Ввод прерван"
    _ua=$(trim "$_ua"); _ua=${_ua:-$_ud}
    if [[ -z $_ure || $_ua =~ $_ure ]] && { [[ -z $_uf ]] || "$_uf" "$_ua"; }; then printf -v "$_uv" '%s' "$_ua"; return 0; fi
    warn "$_um"
  done
}

# ask_secret ПЕРЕМЕННАЯ "Вопрос" — ввод скрыт, пустое значение не принимается
ask_secret() {
  local _uv=$1 _uq=$2 _ua
  [[ -n ${!1:-} ]] && return 0
  [[ -t 0 ]] || die "Нет ответа на вопрос «$_uq» (запуск без терминала)"
  while :; do
    IFS= read -r -s -p "$(ui_prompt "$_uq")" _ua || die "Ввод прерван"
    echo
    [[ -n $_ua ]] && { printf -v "$_uv" '%s' "$_ua"; return 0; }
    warn "Пустое значение не подходит"
  done
}

# yesno "Вопрос" y|n   (0 = да). ASSUME_YES=1 или запуск без терминала — ответ по умолчанию.
yesno() {
  local _uq=$1 _ud=${2:-n} _ua _uh
  [[ $_ud == y ]] && _uh='Y/n' || _uh='y/N'
  if [[ ${ASSUME_YES:-0} == 1 || ! -t 0 ]]; then [[ $_ud == y ]]; return; fi
  while :; do
    IFS= read -r -p "$(ui_prompt "$_uq" "$_uh")" _ua || die "Ввод прерван"
    _ua=${_ua,,}; _ua=${_ua:-$_ud}
    case $_ua in
      y|yes|д|да) return 0 ;;
      n|no|н|нет) return 1 ;;
      *) warn "Ответьте y (да) или n (нет)" ;;
    esac
  done
}

# choose ПЕРЕМЕННАЯ "Заголовок" "ключ-по-умолчанию" "ключ|Название|пояснение" …
# Заранее заданное (в окружении) значение-ключ принимается без вопроса.
choose() {
  local _uv=$1 _ut=$2 _ud=$3 _ui _uk _un _ux _uc=0 _uw=0 _udn=1 _ua _upre=${!1:-}
  shift 3
  local -a _ukeys=()
  for _ui in "$@"; do IFS='|' read -r _uk _un _ux <<<"$_ui"; _ukeys+=("$_uk"); (( ${#_un} > _uw )) && _uw=${#_un}; done
  if [[ -n $_upre ]]; then
    for _uk in "${_ukeys[@]}"; do [[ $_uk == "$_upre" ]] && return 0; done
    warn "Заданное значение $_uv=«$_upre» не подходит"
  fi
  if [[ ! -t 0 ]]; then printf -v "$_uv" '%s' "$_ud"; return 0; fi
  [[ -n $_ut ]] && printf '  %s%s%s\n' "$c_b" "$_ut" "$c_0"
  for _ui in "$@"; do
    IFS='|' read -r _uk _un _ux <<<"$_ui"
    _uc=$((_uc + 1)); [[ $_uk == "$_ud" ]] && _udn=$_uc
    printf '    %s%2d%s  %s  %s%s%s\n' "$c_acc" "$_uc" "$c_0" "$(pad "$_un" "$_uw")" "$c_dim" "$_ux" "$c_0"
  done
  while :; do
    IFS= read -r -p "$(ui_prompt "Выбор" "$_udn")" _ua || die "Ввод прерван"
    _ua=$(trim "$_ua"); _ua=${_ua:-$_udn}
    if [[ $_ua =~ ^[0-9]+$ ]] && (( _ua >= 1 && _ua <= ${#_ukeys[@]} )); then
      printf -v "$_uv" '%s' "${_ukeys[_ua - 1]}"
      return 0
    fi
    warn "Введите число от 1 до ${#_ukeys[@]}"
  done
}

# Карточки: card "Заголовок"; kv "ключ" "значение"; card_end
card()     { printf '\n  %s┌─%s %s%s%s\n' "$c_dim" "$c_0" "$c_b" "$1" "$c_0"; }
kv()       { printf '  %s│%s %s%s%s %s\n' "$c_dim" "$c_0" "$c_dim" "$(pad "$1" "${KV_W:-17}")" "$c_0" "$2"; }
card_line(){ printf '  %s│%s %s\n' "$c_dim" "$c_0" "$*"; }
card_end() { printf '  %s└──────────────────────────────────────────────────────%s\n' "$c_dim" "$c_0"; }

# Меню: mhead "Группа"; mi N "Пункт" ["значение справа"]; mpick ПЕРЕМЕННАЯ
mhead() { printf '\n  %s%s%s\n' "$c_dim" "$1" "$c_0"; }
mi()    { printf '    %s%2s%s  %s%s%s%s\n' "$c_acc" "$1" "$c_0" "$(pad "$2" "${MI_W:-30}")" "$c_dim" "${3:-}" "$c_0"; }
mpick() { local a; echo; IFS= read -r -p "$(ui_prompt "Выбор")" a || a=0; printf -v "$1" '%s' "$(trim "$a")"; }
pause() { [[ -t 0 ]] || return 0; echo; read -r -s -n 1 -p "  ${c_dim}Любая клавиша — назад${c_0}" _ || true; echo; }

dot_state() { # dot_state служба → цветной «● работает» / «● остановлена»
  if systemctl is-active --quiet "$1" 2>/dev/null; then printf '%s●%s работает' "$c_ok" "$c_0"
  else printf '%s●%s остановлена' "$c_err" "$c_0"; fi
}

# pick_from ПЕРЕМЕННАЯ "Вопрос" элемент… — выбор из списка по номеру или имени (один элемент — по Enter)
pick_from() {
  local _pv=$1 _pq=$2 _pa _pi=0 _px
  shift 2
  (( $# )) || { warn "Список пуст"; return 1; }
  echo
  for _px in "$@"; do _pi=$((_pi + 1)); printf '    %s%2d%s  %s\n' "$c_acc" "$_pi" "$c_0" "$_px"; done
  IFS= read -r -p "$(ui_prompt "$_pq" "$( (( $# == 1 )) && echo 1)")" _pa || return 1
  _pa=$(trim "$_pa"); [[ -z $_pa && $# == 1 ]] && _pa=1
  [[ -n $_pa ]] || return 1
  if [[ $_pa =~ ^[0-9]+$ ]] && (( _pa >= 1 && _pa <= $# )); then _pa=${!_pa}; fi
  for _px in "$@"; do [[ $_px == "$_pa" ]] && { printf -v "$_pv" '%s' "$_pa"; return 0; }; done
  warn "«$_pa» нет в списке"; return 1
}
