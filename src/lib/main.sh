# shellcheck shell=bash
# ── Точка входа: экран приветствия, команды, обслуживание ────────────────────

welcome() {
  cls
  banner "TrustTunnel" "установщик · $SELF_VERSION"
  cat <<EOF
  Свой VPN из двух серверов. Устройства подключаются обычным WireGuard к шлюзу
  в России; российские сайты шлюз открывает сам, остальное отправляет через
  TrustTunnel на сервер за рубежом. Посторонний, открывший сервер в браузере,
  видит обычный сайт.

  ${c_dim}устройства ─WireGuard─▶ шлюз (РФ) ─TrustTunnel─▶ сервер (за рубежом) ─▶ интернет${c_0}

  ${c_b}Порядок установки${c_0}
    1. Сервер за рубежом — нужен домен с A-записью на его IP, свободные порты 80 и 443.
    2. Шлюз в России — понадобится ключ подключения, который покажет сервер.
    Сервер работает и сам по себе: телефоны подключаются к нему приложением TrustTunnel.

  ${c_b}Требования${c_0}
    Rocky Linux 9/10 или Debian 12/13, права root, от 512 МБ RAM (swap добавлю сам).

EOF
}
choose_role() { # → ROLE_CHOICE
  local r=${ROLE_CHOICE:-}
  choose r "Что устанавливаем на этот VPS?" server \
    "server|Сервер TrustTunnel|за рубежом · ставится первым" \
    "gateway|Шлюз|в России · ставится вторым" \
    "exit|Выход|"
  [[ $r == exit ]] && exit 0
  ROLE_CHOICE=$r
}
check_os() {
  os_detect
  local rc=0; os_supported || rc=$?
  case $rc in
    0) ;;
    1) warn "$OS_NAME не проверялась — должна работать, но без гарантий"
       yesno "Продолжить?" y || exit 0 ;;
    *) die "Нужен Rocky Linux 9/10 или Debian 12/13 (обнаружено: $OS_NAME)" ;;
  esac
  [[ -d /run/systemd/system ]] || die "Нужен systemd (контейнеры без systemd не подходят)"
  command -v python3 >/dev/null 2>&1 || run "Установка python3" pkg_install python3 || die "Нужен python3"
  command -v curl >/dev/null 2>&1 || run "Установка curl" pkg_install curl ca-certificates || die "Нужен curl"
}
self_install() { # скрипт копирует себя в /usr/local/sbin/tt — дальше управление командой tt
  [[ ${BASH_SOURCE[0]} -ef $BIN ]] 2>/dev/null && return 0
  [[ -r ${BASH_SOURCE[0]} ]] || return 0
  install -d -m 755 "$(dirname "$BIN")"
  install -m 0755 "${BASH_SOURCE[0]}" "$BIN.new" && mv -f "$BIN.new" "$BIN"
}
cmd_install() {
  check_os
  welcome
  local r act
  r=$(role)
  if [[ -n $r ]]; then
    section "Уже установлено: $([[ $r == server ]] && echo "сервер · $(cf DOMAIN)" || echo "шлюз · $(cf ENDPOINT)")"
    act=${INSTALLED_ACTION:-}
    choose act "" menu \
      "menu|Открыть управление|" \
      "reconf|Изменить настройки|данные и ключи сохранятся" \
      "update|Обновить|tt и программы" \
      "exit|Выход|"
    case $act in
      menu) role_menu; return ;;
      update) maint_update_all; return ;;
      exit) return 0 ;;
    esac
  else
    choose_role; r=$ROLE_CHOICE
  fi
  self_install
  install -d -m 700 "$ETC"; install -d -m 755 "$STATE"
  case $r in
    server) srv_install ;;
    gateway) gw_install ;;
  esac
}
role_menu() {
  case $(role) in
    server) srv_menu ;;
    gateway) gw_menu ;;
    *) cmd_install ;;
  esac
}
need_role() { [[ $(role) == "$1" ]] || die "Команда доступна на $([[ $1 == server ]] && echo сервере || echo шлюзе)"; }
role_apply() { case $(role) in server) srv_apply ;; gateway) gw_apply ;; *) die "tt ещё не установлен: запустите tt install" ;; esac; }

# ── обслуживание ─────────────────────────────────────────────────────────────
speedtest() {
  local url='https://speed.cloudflare.com/__down?bytes=25000000'
  spd() { curl -s -o /dev/null -m 40 "$@" -w '%{speed_download} %{time_connect}' "$url" 2>/dev/null \
          | LC_ALL=C awk '{ if ($1 > 0) printf "%.0f Мбит/с · соединение %.0f мс", $1*8/1000000, $2*1000; else print "нет ответа" }'; }
  section "Скорость" "Загрузка 25 МБ с speed.cloudflare.com."
  KV_W=16
  if [[ $(role) == gateway ]]; then
    kv "Через туннель" "$(spd -x "socks5h://127.0.0.1:$TEST_PORT")"
    kv "Напрямую" "$(spd)"
    note "Через туннель всегда медленнее: путь длиннее. Разница в разы — повод проверить сервер."
  else
    kv "Сервер" "$(spd)"
  fi
}
doctor() {
  local f u
  f=/root/tt-doctor-$(date +%Y%m%d-%H%M%S).txt
  {
    echo "tt $SELF_VERSION · $(date '+%F %T') · $(sys_line)"
    echo "Роль: $(role)"; echo
    echo "== tt.conf (без личных данных) =="; sed 's/^\(EMAIL\)=.*/\1="***"/' "$CONF" 2>/dev/null; echo
    if [[ $(role) == gateway ]]; then
      echo "== сервер =="; ep_info; echo
      for u in trusttunnel-client sing-box "wg-quick@$WG_IF" tt-watchdog.timer tt-ru.timer; do echo "$u: $(systemctl is-active "$u" 2>/dev/null)"; done
      echo; wg show "$WG_IF" 2>/dev/null | sed 's/\(preshared key\|private key\): .*/\1: ***/; s/\(endpoint\): .*/\1: *** (адрес устройства скрыт)/'
      echo; nft list table ip tt_tproxy 2>/dev/null | head -30; nft list table inet tt_guard 2>/dev/null
      echo; echo "Выход через туннель: $(gw_exit_ip || echo нет)"
      for u in trusttunnel-client sing-box; do echo; echo "== журнал $u =="; journalctl -u "$u" -n 30 --no-pager 2>/dev/null; done
    else
      for u in trusttunnel nginx tt-cert.timer; do echo "$u: $(systemctl is-active "$u" 2>/dev/null)"; done
      echo "Сертификат: $(cert_label), осталось $(cert_days) дн."
      echo "Пользователей: $(creds count)"
      echo; echo "== журнал trusttunnel =="; journalctl -u trusttunnel -n 40 --no-pager 2>/dev/null
    fi
    echo; echo "== $LOG (последние 40 строк) =="; tail -n 40 "$LOG" 2>/dev/null
  } >"$f" 2>&1
  chmod 600 "$f"
  sed -i 's/\(password\|PrivateKey\|PresharedKey\|TOKEN\)\([" =:]*\)[^ ",]*/\1\2***/g' "$f"
  ok "Сводка для разбора проблем: $f"
  note "Пароли, ключи, e-mail и адреса устройств в ней скрыты — файл можно переслать тому, кто поможет."
}
maint_update_all() {
  self_update_check || true
  case $(role) in
    server) srv_update ;;
    gateway) gw_update_client; gw_update_singbox ;;
  esac
}
self_update_check() { [[ ${TT_NO_SELF_UPDATE:-0} == 1 ]] || (self_update); }
notify_setup() { tg_setup; }
maint_menu() {
  local c
  while :; do
    cls; banner "TrustTunnel" "обслуживание · tt $SELF_VERSION"
    note "Само ничего не обновляется — работающая система не сломается неожиданно."
    note "Перед обновлением делается копия, при сбое прежняя версия возвращается."
    MI_W=26
    mhead "Обновления"
    if [[ $(role) == server ]]; then
      mi 1 "TrustTunnel" "$(bin_version "$TT_DIR")"
    else
      mi 1 "Клиент TrustTunnel" "$(bin_version "$TTC_DIR")"; mi 2 "sing-box" "$(sb_version)"
    fi
    mi 3 "Сам tt" "$SELF_VERSION"
    mhead "Проверки"
    mi 4 "Скорость"; mi 5 "Сводка для разбора проблем"; mi 6 "Журнал"
    [[ $(role) == gateway ]] && mi 7 "Уведомления в Telegram" "$([[ -f $ETC/telegram.conf ]] && echo вкл || echo выкл)"
    mhead "Опасно"
    mi 9 "Удалить с этого VPS"
    mi 0 "Назад"
    mpick c
    case $c in
      1) if [[ $(role) == server ]]; then (srv_update); else (gw_update_client); fi ;;
      2) [[ $(role) == gateway ]] && (gw_update_singbox) ;;
      3) (self_update) ;;
      4) speedtest ;;
      5) doctor ;;
      6) tail -n 40 "$LOG" | sed 's/^/  /' ;;
      7) [[ $(role) == gateway ]] && (tg_setup) ;;
      9) if [[ $(role) == server ]]; then srv_uninstall; else gw_uninstall; fi; [[ -x $BIN ]] || exit 0 ;;
      0|"") return 0 ;;
      *) warn "Введите номер пункта"; sleep 1; continue ;;
    esac
    conf_load; pause
  done
}

usage() {
  cat <<EOF

  ${c_b}tt${c_0} — TrustTunnel: сервер и шлюз ${c_dim}(без команды — меню)${c_0}

  ${c_dim}Общие${c_0}
    install                  установка (экран приветствия)
    status                   проверка состояния
    apply                    пересобрать и применить настройки (после правки /etc/tt/tt.conf)
    update                   обновить tt и программы
    self-update              обновить только сам tt
    speedtest                скорость
    doctor                   сводка для разбора проблем (без паролей)
    logs [N]                 журнал tt
    uninstall                удалить с этого VPS
EOF
  if [[ $(role) == server ]]; then cat <<EOF

  ${c_dim}Сервер${c_0}
    users                    пользователи и кто подключён
    add ИМЯ [ПАРОЛЬ]         добавить пользователя
    del ИМЯ                  удалить
    passwd ИМЯ [ПАРОЛЬ]      сменить пароль
    link [ИМЯ]               ссылка tt:// и QR-код
    key ИМЯ                  ключ подключения для шлюза
    dns                      DNS для приложений
EOF
  elif [[ $(role) == gateway ]]; then cat <<EOF

  ${c_dim}Шлюз${c_0}
    list                     клиенты WireGuard и кто на связи
    add [ИМЯ] | remove ИМЯ | show ИМЯ
    endpoint [КЛЮЧ|ФАЙЛ]     сменить сервер TrustTunnel
    repin                    заново закрепить IP сервера
    udp auto|tunnel|block    режим UDP через туннель
    ru status|enable|disable|update|add-direct Д|add-proxy Д|del Д|exceptions
    notify                   уведомления в Telegram
EOF
  fi
  echo
}

main() {
  [[ $EUID -eq 0 ]] || { echo "Нужны права root: sudo tt" >&2; exit 1; }
  install -d -m 755 "$(dirname "$LOG")"; touch "$LOG"; chmod 600 "$LOG"
  install -d -m 755 "$STATE"
  py_install
  conf_load
  os_detect
  local cmd=${1:-}
  [[ $# -gt 0 ]] && shift
  case $cmd in   # служебные команды без блокировки (их вызывают systemd и wg-quick)
    rules) gw_rules "${1:-}"; return ;;
    watchdog) [[ $(role) == gateway ]] && watchdog; return 0 ;;
    guard) [[ $(role) == gateway ]] && gw_guard; return ;;
  esac
  exec 9>/run/tt.lock
  if ! flock -n 9; then
    [[ $cmd == ru && ${1:-} == update ]] && { flock 9; } || die "tt уже запущен в другом окне — дождитесь его завершения"
  fi
  case $cmd in
    "") if [[ -n $(role) ]]; then role_menu; else cmd_install; fi ;;
    menu) role_menu ;;
    install) cmd_install ;;
    status) case $(role) in server) srv_status ;; gateway) gw_status ;; *) die "tt ещё не установлен" ;; esac ;;
    apply) run "Применение настроек" role_apply && ok "Настройки применены" ;;
    update) maint_update_all ;;
    self-update) self_update ;;
    speedtest) speedtest ;;
    doctor) doctor ;;
    logs) tail -n "${1:-60}" "$LOG" ;;
    uninstall) case $(role) in server) srv_uninstall ;; gateway) gw_uninstall ;; *) die "Нечего удалять" ;; esac ;;
    help|-h|--help) usage ;;
    version|--version) echo "tt $SELF_VERSION" ;;
    # сервер
    users) need_role server; echo; users_table ;;
    add) if [[ $(role) == server ]]; then u_add "${1:-}" "${2:-}"; else need_role gateway; cl_add "${1:-}"; fi ;;
    del) need_role server; [[ -n ${1:-} ]] || die "Укажите имя: tt del ИМЯ"; u_del "$1" ;;
    passwd) need_role server; [[ -n ${1:-} ]] || die "Укажите имя: tt passwd ИМЯ [ПАРОЛЬ]"; u_pass "$1" "${2:-}" ;;
    link) need_role server; if [[ -n ${1:-} ]]; then show_user "$1"; else for u in $(user_names); do show_user "$u"; done; fi ;;
    key) need_role server; [[ -n ${1:-} ]] || die "Укажите имя: tt key ИМЯ"; creds exists "$1" 2>/dev/null || die "Пользователя «$1» нет"; show_key "$1" ;;
    dns) need_role server; s_dns ;;
    # шлюз
    list) need_role gateway; cl_list ;;
    remove|rm) need_role gateway; cl_remove "${1:-}" ;;
    show) need_role gateway; [[ -n ${1:-} ]] || die "Укажите имя: tt show ИМЯ"; cl_show "$1" ;;
    endpoint) need_role gateway; gw_endpoint "${1:-}" ;;
    repin) need_role gateway; gw_repin ;;
    udp) need_role gateway; gw_udp "${1:-auto}" ;;
    notify) need_role gateway; tg_setup ;;
    ru) need_role gateway
        case ${1:-status} in
          status) ru_status ;; enable) ru_enable ;; disable) ru_disable ;; update) ru_update ;;
          add-direct) ru_exc_add direct "${2:-}" ;; add-proxy) ru_exc_add proxy "${2:-}" ;;
          del) ru_exc_del "${2:-}" ;; exceptions) ru_exc_list ;; *) usage; exit 1 ;;
        esac ;;
    *) usage; exit 1 ;;
  esac
}
