# shellcheck shell=bash
# ── Ядро: пути, настройки, система, загрузки, применение конфигураций ─────────

TT_REPO=fLex0id/trusttunnel-gateway
ETC=/etc/tt
CONF=$ETC/tt.conf
LIB=/usr/local/lib/tt
PY=$LIB/tt.py
BIN=/usr/local/sbin/tt
STATE=/var/lib/tt
BK_DIR=$STATE/backup
export LOG=/var/log/tt.log
TT_DIR=/opt/trusttunnel
TTC_DIR=/opt/trusttunnel_client
SB_BIN=/usr/local/bin/sing-box
TT_PINNED=v1.1.0     # проверенные версии: ставятся, только если GitHub API недоступен
TTC_PINNED=v1.1.11
SB_PINNED=v1.14.4
SOCKS_PORT=1080
TEST_PORT=18080
DECOY_PORT=8008
WG_IF=wg0

# ── настройки: /etc/tt/tt.conf — единственный источник правды ────────────────
declare -gA CFG=()
conf_load() {
  CFG=()
  [[ -r $CONF ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    [[ $k =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    v=${v#\"}; v=${v%\"}
    CFG[$k]=$v
  done <"$CONF"
}
cf() { local v=${CFG[$1]:-}; printf '%s' "${v:-${2:-}}"; }     # cf КЛЮЧ [умолчание]
conf_set() { # conf_set КЛЮЧ ЗНАЧЕНИЕ [КЛЮЧ ЗНАЧЕНИЕ …] — меняет и сразу сохраняет
  while (( $# >= 2 )); do
    [[ $2 == *[\"\$\`\\]* || $2 == *$'\n'* ]] && die "Недопустимые символы в значении $1"
    CFG[$1]=$2; shift 2
  done
  local k tmp
  install -d -m 700 "$ETC"
  tmp=$(mktemp "$ETC/.tt.conf.XXXXXX")
  { echo "# Настройки tt. Меняйте через tt (меню) — после правки вручную выполните: tt apply"
    for k in $(printf '%s\n' "${!CFG[@]}" | sort); do printf '%s="%s"\n' "$k" "${CFG[$k]}"; done
  } >"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$CONF"
}
role() { cf ROLE; }

# ── встроенный Python-модуль ─────────────────────────────────────────────────
py_install() {
  if [[ ! -f $PY ]] || ! grep -qx "# tt-version: $SELF_VERSION" "$PY"; then
    install -d -m 755 "$LIB"
    { py_source; echo "# tt-version: $SELF_VERSION"; } >"$PY.tmp" && chmod 644 "$PY.tmp" && mv -f "$PY.tmp" "$PY"
  fi
}
py() { python3 -I "$PY" "$@"; }

# ── система ──────────────────────────────────────────────────────────────────
os_detect() {
  OS_ID=; OS_VER=; OS_NAME=Linux; PM=
  if [[ -r /etc/os-release ]]; then
    OS_ID=$(. /etc/os-release; echo "${ID:-}"); OS_VER=$(. /etc/os-release; echo "${VERSION_ID%%.*}")
    OS_NAME=$(. /etc/os-release; echo "${PRETTY_NAME:-Linux}")
  fi
  if command -v dnf >/dev/null 2>&1; then PM=dnf; elif command -v apt-get >/dev/null 2>&1; then PM=apt; fi
}
os_supported() { # 0 — проверено; 1 — «должно работать»; 2 — нет
  case $OS_ID:$OS_VER in
    rocky:9|rocky:10|debian:12|debian:13) return 0 ;;
    almalinux:9|almalinux:10|rhel:9|rhel:10|ubuntu:22|ubuntu:24) return 1 ;;
  esac
  [[ -n $PM ]] && return 1
  return 2
}
APT_UPDATED=0
pkg_install() {
  case $PM in
    dnf) dnf -y install "$@" ;;
    apt) if (( APT_UPDATED == 0 )); then apt-get update -y && APT_UPDATED=1; fi
         DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
    *) return 1 ;;
  esac
}
arch() { case $(uname -m) in x86_64|amd64) echo x86_64 ;; aarch64|arm64) echo aarch64 ;; *) return 1 ;; esac; }
mem_mb() { awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo; }
sys_line() {
  printf '%s · %s · RAM %s ГБ · свободно %s ГБ' "$OS_NAME" "$(uname -m)" \
    "$(LC_ALL=C awk '/^MemTotal:/{printf "%.1f", $2/1048576}' /proc/meminfo)" \
    "$(df -Pm / | LC_ALL=C awk 'NR==2{printf "%.1f", $4/1024}')"
}
ensure_swap() { # маленький VPS без swap: менеджер пакетов убивает OOM-killer (код 137)
  local mem swap free f=/swapfile
  mem=$(mem_mb); swap=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
  (( mem < 2000 && swap == 0 )) || return 0
  if [[ -f $f ]] && ! grep -q "^$f " /proc/swaps; then swapon "$f" 2>/dev/null && { ok "Подключён swap $f"; return 0; }; fi
  free=$(df -Pm / | awk 'NR==2{print $4}')
  (( free >= 2048 )) || { warn "RAM $mem МБ без swap и мало места на диске — установка пакетов может прерваться"; return 0; }
  if dd if=/dev/zero of="$f" bs=1M count=1024 status=none && chmod 600 "$f" && mkswap "$f" >/dev/null && swapon "$f"; then
    grep -q "^$f " /etc/fstab || echo "$f none swap defaults 0 0" >>/etc/fstab
    ok "RAM $mem МБ — добавлен swap 1 ГБ, чтобы установке хватило памяти"
  else
    rm -f "$f"; warn "Не удалось создать swap"
  fi
}
public_ip() {
  local ip u
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]') || ip=
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { echo "$ip"; return 0; }
  done
  ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1
}
resolve4() { getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'; }
port_users() { ss -H -l"${1:0:1}"np "sport = :$2" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | sort -u | tr '\n' ' ' | sed 's/ $//'; }

# Файрвол: firewalld или ufw, если включены; иначе правила не нужны
fw_kind() {
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then echo firewalld
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then echo ufw
  else echo none; fi
}
fw_open() { # fw_open 80/tcp 443/tcp …
  local p
  case $(fw_kind) in
    firewalld) for p in "$@"; do firewall-cmd --permanent --add-port="$p" >>"$LOG" 2>&1; done; firewall-cmd --reload >>"$LOG" 2>&1 ;;
    ufw) for p in "$@"; do ufw allow "$p" >>"$LOG" 2>&1; done ;;
  esac
}
fw_close() {
  local p
  case $(fw_kind) in
    firewalld) for p in "$@"; do firewall-cmd --permanent --remove-port="$p" >>"$LOG" 2>&1; done; firewall-cmd --reload >>"$LOG" 2>&1 ;;
    ufw) for p in "$@"; do ufw delete allow "$p" >>"$LOG" 2>&1; done ;;
  esac
  return 0
}

# ── загрузки с GitHub и проверка подписи ─────────────────────────────────────
fetch() { curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 15 -m 600 -o "$2" "$1"; }
gh_latest() { # репозиторий → последний стабильный тег (бета-версии в «latest» не попадают)
  # Через перенаправление страницы релизов: у API GitHub лимит 60 запросов в час на IP (за общим NAT кончается быстро)
  local v
  v=$(curl -fsS -o /dev/null --retry 2 --max-time 15 -w '%{redirect_url}' "https://github.com/$1/releases/latest" 2>/dev/null)
  v=${v##*/tag/}
  if [[ ! $v =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    v=$(curl -fsS --max-time 15 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  fi
  [[ $v =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "v${v#v}"
  return 0
}
gpg_verify() { # файл… — у каждого рядом файл .sig; ключ AdGuard встроен в tt (сервер ключей не нужен)
  local g f rc=0
  command -v gpg >/dev/null 2>&1 || { echo "gpg не установлен"; return 1; }
  g=$(mktemp -d); chmod 700 "$g"
  gpg_key | GNUPGHOME=$g gpg --batch --quiet --import 2>/dev/null || { rm -rf "${g:?}"; return 1; }
  for f in "$@"; do
    if [[ ! -f $f.sig ]]; then echo "нет подписи для $f"; rc=1; continue; fi
    GNUPGHOME=$g gpg --batch --quiet --verify "$f.sig" "$f" 2>/dev/null || { echo "ПОДПИСЬ НЕ СОВПАЛА: $f"; rc=1; }
  done
  rm -rf "${g:?}"
  return "$rc"
}
# bin_install server|client ВЕРСИЯ — релиз TrustTunnel с GitHub: загрузка, проверка подписи, установка
bin_install() {
  local kind=$1 ver=$2 a repo name dir tmp src f
  a=$(arch) || { echo "процессор $(uname -m) не поддерживается"; return 1; }
  case $kind in
    server) repo=TrustTunnel/TrustTunnel; name=trusttunnel; dir=$TT_DIR; f="trusttunnel_endpoint" ;;
    client) repo=TrustTunnel/TrustTunnelClient; name=trusttunnel_client; dir=$TTC_DIR; f="trusttunnel_client" ;;
  esac
  tmp=$(mktemp -d)
  fetch "https://github.com/$repo/releases/download/$ver/$name-$ver-linux-$a.tar.gz" "$tmp/r.tgz" || { rm -rf "${tmp:?}"; return 1; }
  tar -xzf "$tmp/r.tgz" -C "$tmp" || { rm -rf "${tmp:?}"; return 1; }
  src=$(dirname "$(find "$tmp" -type f -name "$f" | head -1)")
  [[ -x $src/$f ]] || { echo "в архиве нет $f"; rm -rf "${tmp:?}"; return 1; }
  gpg_verify "$src/$f" || { rm -rf "${tmp:?}"; return 1; }
  install -d -m 755 "$dir"
  install -m 0755 "$src/$f" "$dir/$f.new" && mv -f "$dir/$f.new" "$dir/$f"
  [[ -f $src/$f.sig ]] && install -m 0644 "$src/$f.sig" "$dir/$f.sig"
  rm -rf "${tmp:?}"
  if command -v chcon >/dev/null 2>&1 && [[ $(getenforce 2>/dev/null) == Enforcing ]]; then chcon -t bin_t "$dir/$f" || true; fi
  echo "$ver" >"$dir/VERSION"
}
bin_version() { cat "${1}/VERSION" 2>/dev/null || echo "?"; }

# ── применение конфигурации: собрать → сравнить → подменить → перезапустить → проверить → откатить ──
# Роль печатает манифест строк «файл|путь|режим|владелец|действие», где действие:
#   daemon — перечитать юниты; restart:юнит; reload:юнит; nginx — проверка + reload; wg — синхронизация wg0
APPLY_CHANGED=0
apply_manifest() { # каталог-сборки манифест функция-проверки
  local stage=$1 manifest=$2 health=$3 bk line f dst mode own act i=0 rc=0
  local -a changed=() acts=()
  while IFS='|' read -r f dst mode own act; do
    [[ -n $f && -f $stage/$f ]] || continue
    cmp -s "$stage/$f" "$dst" 2>/dev/null && continue
    changed+=("$f|$dst|$mode|$own|$act")
  done <<<"$manifest"
  APPLY_CHANGED=${#changed[@]}
  (( APPLY_CHANGED )) || return 0
  bk=$BK_DIR/$(date +%Y%m%d-%H%M%S)-$$
  install -d -m 700 "$bk"
  for line in "${changed[@]}"; do
    IFS='|' read -r f dst mode own act <<<"$line"
    i=$((i + 1))
    if [[ -e $dst ]]; then cp -a "$dst" "$bk/$i"; else : >"$bk/$i.absent"; fi
    echo "$dst" >"$bk/$i.path"
    install -d "$(dirname "$dst")"
    install -m "$mode" -o "${own%%:*}" -g "${own##*:}" "$stage/$f" "$dst.tt-new" && mv -f "$dst.tt-new" "$dst"
    [[ " ${acts[*]} " == *" $act "* ]] || acts+=("$act")
  done
  command -v restorecon >/dev/null 2>&1 && restorecon -R "$ETC" /etc/systemd/system /etc/nginx /etc/sing-box 2>/dev/null || true
  apply_actions "${acts[@]}" && "$health" || rc=1
  if (( rc )); then
    for ((i = 1; i <= ${#changed[@]}; i++)); do
      dst=$(cat "$bk/$i.path")
      if [[ -e $bk/$i.absent ]]; then rm -f "$dst"; else cp -a "$bk/$i" "$dst"; fi
    done
    apply_actions "${acts[@]}" >>"$LOG" 2>&1 || true
    warn "Новые настройки не заработали — прежние возвращены (копия: $bk)"
  fi
  { ls -1dt "$BK_DIR"/*/ 2>/dev/null | tail -n +11 | xargs -r rm -rf; } || true
  return "$rc"
}
apply_actions() {
  local a u
  [[ " $* " == *" daemon "* ]] && systemctl daemon-reload
  for a in "$@"; do
    case $a in
      daemon|none|"") ;;
      restart:*) u=${a#restart:}; systemctl is-enabled --quiet "$u" 2>/dev/null || systemctl enable "$u" >>"$LOG" 2>&1 || true
                 systemctl restart "$u" >>"$LOG" 2>&1 || return 1 ;;
      reload:*)  u=${a#reload:}; systemctl reload-or-restart "$u" >>"$LOG" 2>&1 || return 1 ;;
      nginx)     nginx -t >>"$LOG" 2>&1 || return 1; systemctl enable nginx >>"$LOG" 2>&1 || true
                 systemctl reload-or-restart nginx >>"$LOG" 2>&1 || return 1 ;;
      wg)        wg_sync || return 1 ;;
      sysctl)    sysctl -q -p /etc/sysctl.d/99-tt.conf >>"$LOG" 2>&1 || true ;;
    esac
  done
}
unit_up() { # unit_up юнит [секунд] — служба активна 3 проверки подряд
  local i n=0
  for ((i = 0; i < ${2:-10}; i++)); do
    sleep 1
    if systemctl is-active --quiet "$1"; then n=$((n + 1)); else n=0; fi
    (( n >= 3 )) && return 0
  done
  return 1
}

# ── Telegram (по желанию) ─────────────────────────────────────────────────────
tg_send() { # текст — через туннель, если он работает, иначе напрямую
  local tok chat
  [[ -r $ETC/telegram.conf ]] || return 0
  tok=$(sed -n 's/^TOKEN=//p' "$ETC/telegram.conf"); chat=$(sed -n 's/^CHAT=//p' "$ETC/telegram.conf")
  [[ -n $tok && -n $chat ]] || return 0
  local px=()
  ss -Hlnt "sport = :$SOCKS_PORT" 2>/dev/null | grep -q . && px=(-x "socks5h://127.0.0.1:$SOCKS_PORT")
  curl -fsS -m 15 "${px[@]}" "https://api.telegram.org/bot$tok/sendMessage" -d chat_id="$chat" \
       --data-urlencode text="$(hostname -s): $1" >/dev/null 2>&1 \
    || curl -fsS -m 15 "https://api.telegram.org/bot$tok/sendMessage" -d chat_id="$chat" \
       --data-urlencode text="$(hostname -s): $1" >/dev/null 2>&1
}
tg_setup() { # вопрос при установке; токен и chat_id → /etc/tt/telegram.conf
  local tok='' chat=''
  section "Уведомления в Telegram" "Сообщат, если туннель перестанет работать и когда он восстановится." \
    "Нужны токен бота (у @BotFather) и ваш chat_id (например, у @userinfobot)."
  yesno "Включить уведомления?" n || { rm -f "$ETC/telegram.conf"; return 0; }
  ask tok "Токен бота" "" '^[0-9]+:[A-Za-z0-9_-]{30,}$' "Токен вида 123456789:AA…"
  ask chat "chat_id" "" '^-?[0-9]{5,}$' "Число, например 123456789"
  install -d -m 700 "$ETC"
  (umask 077; printf 'TOKEN=%s\nCHAT=%s\n' "$tok" "$chat" >"$ETC/telegram.conf")
  if tg_send "Уведомления TrustTunnel подключены ✓"; then ok "Тестовое сообщение отправлено"
  else warn "Тестовое сообщение не дошло — проверьте токен и chat_id (позже: tt notify)"; fi
}

# ── самообновление скрипта ───────────────────────────────────────────────────
self_update() {
  local tmp new
  tmp=$(mktemp -d)
  section "Обновление tt" "Текущая версия: $SELF_VERSION"
  if ! run "Загрузка последней версии" fetch "https://github.com/$TT_REPO/releases/latest/download/tt.sh" "$tmp/tt.sh" \
     || ! fetch "https://github.com/$TT_REPO/releases/latest/download/tt.sh.sha256" "$tmp/tt.sh.sha256"; then
    rm -rf "${tmp:?}"; die "Не удалось скачать обновление"
  fi
  (cd "$tmp" && sha256sum -c --status tt.sh.sha256) || { rm -rf "${tmp:?}"; die "Контрольная сумма не совпала — обновление отменено"; }
  new=$(sed -n 's/^SELF_VERSION=//p' "$tmp/tt.sh" | head -1)
  if [[ $new == "$SELF_VERSION" ]]; then rm -rf "${tmp:?}"; ok "Уже последняя версия ($SELF_VERSION)"; return 0; fi
  install -m 0755 "$tmp/tt.sh" "$BIN.new" && mv -f "$BIN.new" "$BIN"
  rm -rf "${tmp:?}"
  ok "tt обновлён: $SELF_VERSION → $new"
  exec "$BIN" apply
}
