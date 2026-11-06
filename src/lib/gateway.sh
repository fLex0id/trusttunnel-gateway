# shellcheck shell=bash
# ── Роль «шлюз»: WireGuard → TPROXY → sing-box → клиент TrustTunnel ─────────

RULES_DIR=$STATE/rulesets
EXC_D=$ETC/ru-direct.list
EXC_P=$ETC/ru-proxy.list
TPROXY_MARK=1
TPROXY_TABLE=100
RE_DOH_URL='^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/-]*)?$'
RE_IPV4='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

onoff() { [[ ${1:-0} == 1 ]] && echo "да" || echo "нет"; }
ep_host() { py ep host 2>/dev/null || echo "?"; }
ep_info() { py ep info 2>/dev/null || echo "?"; }

# ── DNS ──────────────────────────────────────────────────────────────────────
doh_name() {
  case ${1:-cloudflare} in
    cloudflare) echo "Cloudflare" ;; quad9) echo "Quad9" ;; google) echo "Google" ;; opendns) echo "OpenDNS" ;;
    custom) [[ ${2:-} == https://dns.nextdns.io/* ]] && echo "NextDNS" || echo "${2:-свой}" ;; *) echo "$1" ;;
  esac
}
ru_dns_name() {
  case ${1:-yandex} in
    yandex) echo "Яндекс" ;; yandex-doh) echo "Яндекс DoH" ;; system) echo "DNS хостера" ;;
    cloudflare-doh) echo "Cloudflare DoH" ;; quad9-doh) echo "Quad9 DoH" ;; google-doh) echo "Google DoH" ;;
    opendns-doh) echo "OpenDNS DoH" ;; custom) echo "${2:-свой}" ;; *) echo "$1" ;;
  esac
}
dns_explain_tunnel() {
  section "DNS для зарубежных и заблокированных сайтов" \
    "Через него узнаются адреса всех сайтов, которые идут через TrustTunnel." \
    "Запросы шифруются и уходят через туннель — ни провайдер, ни хостер шлюза их не видят."
}
dns_explain_ru() {
  section "DNS для российских сайтов" \
    "Только для доменов из российских списков (банки, Госуслуги, маркетплейсы…)." \
    "Запросы идут напрямую с этого сервера, чтобы сайты отдавали российские адреса и открывались быстро." \
    "Зарубежные домены сюда не попадают никогда."
}
pick_doh() { # → DOH DOH_URL
  local k='' def=${DOH:-cloudflare} url
  [[ $def == custom && ${DOH_URL:-} == https://dns.nextdns.io/* ]] && def=nextdns
  choose k "" "$def" \
    "cloudflare|Cloudflare|1.1.1.1 · самый быстрый" \
    "quad9|Quad9|9.9.9.9 · блокирует вредоносные сайты" \
    "google|Google|8.8.8.8" \
    "opendns|OpenDNS|208.67.222.222 · Cisco" \
    "nextdns|NextDNS|ваш профиль с фильтрами" \
    "custom|Свой DoH|https://…"
  case $k in
    nextdns) url=; [[ ${DOH_URL:-} == https://dns.nextdns.io/* ]] && url=$DOH_URL; DOH_URL=
             note "Адрес профиля — в настройках NextDNS (my.nextdns.io), вида https://dns.nextdns.io/abc123"
             ask DOH_URL "Адрес профиля NextDNS" "$url" '^https://dns\.nextdns\.io/[A-Za-z0-9]+$' "Нужен адрес вида https://dns.nextdns.io/abc123"
             DOH=custom ;;
    custom) url=${DOH_URL:-}; DOH_URL=; ask DOH_URL "Адрес DoH" "$url" "$RE_DOH_URL" "Нужен адрес вида https://dns.example/dns-query"; DOH=custom ;;
    *) DOH=$k; DOH_URL= ;;
  esac
}
v_ru_custom() { [[ $1 =~ $RE_IPV4 || $1 =~ $RE_DOH_URL ]]; }
pick_ru_dns() { # → RU_DNS RU_DNS_CUSTOM
  local k='' c
  choose k "" "${RU_DNS:-yandex}" \
    "yandex|Яндекс|77.88.8.8 · российский · рекомендуется" \
    "yandex-doh|Яндекс DoH|российский, шифрованный" \
    "system|DNS хостера|настройки этого сервера" \
    "cloudflare-doh|Cloudflare DoH|1.1.1.1 · зарубежный, шифрованный" \
    "quad9-doh|Quad9 DoH|9.9.9.9 · зарубежный, шифрованный" \
    "google-doh|Google DoH|8.8.8.8 · зарубежный, шифрованный" \
    "opendns-doh|OpenDNS DoH|208.67.222.222 · зарубежный, шифрованный" \
    "custom|Свой|IPv4 или https://…"
  RU_DNS=$k; RU_DNS_CUSTOM=
  if [[ $k == custom ]]; then c=$(cf RU_DNS_CUSTOM); ask RU_DNS_CUSTOM "IPv4 или адрес DoH" "$c" "" "Нужен IPv4-адрес или https://…" v_ru_custom; fi
}

# ── сборка конфигурации ──────────────────────────────────────────────────────
gw_units() { # каталог
  local d=$1
  cat >"$d/trusttunnel-client.service" <<EOF
[Unit]
Description=TrustTunnel (клиент шлюза, SOCKS5 127.0.0.1:$SOCKS_PORT)
After=network-online.target
Wants=network-online.target

[Service]
User=ttclient
Group=ttclient
WorkingDirectory=$TTC_DIR
ExecStartPre=+$BIN guard
ExecStart=$TTC_DIR/trusttunnel_client --config $TTC_DIR/trusttunnel_client.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  cat >"$d/sing-box.service" <<EOF
[Unit]
Description=sing-box (шлюз TrustTunnel)
After=network-online.target trusttunnel-client.service
Wants=network-online.target trusttunnel-client.service

[Service]
User=sing-box
Group=sing-box
StateDirectory=sing-box
WorkingDirectory=/var/lib/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStartPre=$SB_BIN check -c /etc/sing-box/config.json
ExecStart=$SB_BIN -D /var/lib/sing-box -c /etc/sing-box/config.json run
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
  printf '[Unit]\nAfter=network-online.target firewalld.service\nWants=network-online.target\n' >"$d/wg-dropin.conf"
  printf '[Unit]\nDescription=TrustTunnel: сторож туннеля\n[Service]\nType=oneshot\nExecStart=%s watchdog\n' "$BIN" >"$d/tt-watchdog.service"
  printf '[Unit]\nDescription=TrustTunnel: проверка туннеля раз в минуту\n[Timer]\nOnBootSec=2min\nOnUnitActiveSec=1min\n[Install]\nWantedBy=timers.target\n' >"$d/tt-watchdog.timer"
  printf '[Unit]\nDescription=TrustTunnel: обновление списков РФ\nAfter=sing-box.service\n[Service]\nType=oneshot\nNice=10\nExecStart=%s ru update\n' "$BIN" >"$d/tt-ru.service"
  printf '[Unit]\nDescription=TrustTunnel: еженедельное обновление списков РФ\n[Timer]\nOnCalendar=weekly\nRandomizedDelaySec=12h\nPersistent=true\n[Install]\nWantedBy=timers.target\n' >"$d/tt-ru.timer"
  {
    echo "net.ipv4.ip_forward = 1"
    echo "net.ipv6.conf.all.forwarding = 0"
    echo "net.core.rmem_max = 7500000"
    echo "net.core.wmem_max = 7500000"
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || modprobe tcp_bbr 2>/dev/null; then
      echo "net.core.default_qdisc = fq"; echo "net.ipv4.tcp_congestion_control = bbr"
    fi
  } >"$d/99-tt.conf"
}
gw_stage() { # каталог → манифест (порядок важен: клиент → sing-box → WireGuard)
  local s=$1
  py render client "$s" && py render singbox "$s" && py render wg "$s" || return 1
  "$SB_BIN" check -c "$s/config.json" >>"$LOG" 2>&1 || { err "sing-box отверг новую конфигурацию (журнал: $LOG)"; return 1; }
  gw_units "$s"
  cat <<EOF
99-tt.conf|/etc/sysctl.d/99-tt.conf|644|root:root|sysctl
trusttunnel-client.service|/etc/systemd/system/trusttunnel-client.service|644|root:root|daemon
sing-box.service|/etc/systemd/system/sing-box.service|644|root:root|daemon
wg-dropin.conf|/etc/systemd/system/wg-quick@$WG_IF.service.d/10-tt.conf|644|root:root|daemon
tt-watchdog.service|/etc/systemd/system/tt-watchdog.service|644|root:root|daemon
tt-watchdog.timer|/etc/systemd/system/tt-watchdog.timer|644|root:root|daemon
tt-ru.service|/etc/systemd/system/tt-ru.service|644|root:root|daemon
tt-ru.timer|/etc/systemd/system/tt-ru.timer|644|root:root|daemon
trusttunnel_client.toml|$TTC_DIR/trusttunnel_client.toml|640|root:ttclient|restart:trusttunnel-client
config.json|/etc/sing-box/config.json|640|root:sing-box|restart:sing-box
wg0.conf|/etc/wireguard/$WG_IF.conf|600|root:root|wg
EOF
}
wg_sync() { # пиры и ключи — без разрыва; смена адреса подсети — перезапуск интерфейса
  systemctl enable "wg-quick@$WG_IF" >>"$LOG" 2>&1 || true
  if ip link show "$WG_IF" >/dev/null 2>&1 && ip -4 addr show "$WG_IF" | grep -q " $(cf WG_BASE 10.11.42).1/24"; then
    wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF") >>"$LOG" 2>&1
  else
    systemctl restart "wg-quick@$WG_IF" >>"$LOG" 2>&1
  fi
}
gw_exit_ip() { curl -fsS -m 15 -x "socks5h://127.0.0.1:$TEST_PORT" https://api.ipify.org 2>/dev/null; }
gw_health() {
  local i ip=''
  unit_up trusttunnel-client 10 || { err "Клиент TrustTunnel не запустился"; journalctl -u trusttunnel-client -n 15 --no-pager >>"$LOG" 2>&1; return 1; }
  unit_up sing-box 8 || { err "sing-box не запустился"; journalctl -u sing-box -n 15 --no-pager >>"$LOG" 2>&1; return 1; }
  for i in 1 2 3 4 5 6; do ip=$(gw_exit_ip) && [[ -n $ip ]] && break; sleep 2; done
  [[ -n $ip ]] || { err "Через туннель нет выхода в интернет (адрес, логин, пароль сервера?)"; journalctl -u trusttunnel-client -n 15 --no-pager >>"$LOG" 2>&1; return 1; }
  GW_EXIT_IP=$ip
  ip link show "$WG_IF" >/dev/null 2>&1 || { err "WireGuard не поднялся"; return 1; }
}
gw_apply() {
  local s m rc=0
  [[ $(cf RU_DIRECT 0) == 1 ]] || true
  s=$(mktemp -d)
  m=$(gw_stage "$s") || { rm -rf "${s:?}"; return 1; }
  apply_manifest "$s" "$m" gw_health || rc=1
  rm -rf "${s:?}"
  if [[ $(cf RU_DIRECT 0) == 1 ]]; then systemctl enable --now tt-ru.timer >>"$LOG" 2>&1; else systemctl disable --now tt-ru.timer >>"$LOG" 2>&1; fi
  return "$rc"
}
gw_set() { # gw_set КЛЮЧ ЗНАЧЕНИЕ … — изменить, применить; при сбое вернуть прежнее
  local -A old=(); local k
  for ((k = 1; k < $#; k += 2)); do old[${!k}]=${CFG[${!k}]:-}; done
  conf_set "$@"
  gw_apply && return 0
  for k in "${!old[@]}"; do conf_set "$k" "${old[$k]}"; done
  gw_apply >>"$LOG" 2>&1 || true
  return 1
}

# ── правила перехвата (PostUp/PostDown интерфейса wg0) ───────────────────────
gw_rules() {
  local base port
  base=$(cf WG_BASE 10.11.42); port=$(cf TPROXY_PORT 14205)
  while ip rule del fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" 2>/dev/null; do :; done
  ip route flush table "$TPROXY_TABLE" 2>/dev/null
  nft delete table ip tt_tproxy 2>/dev/null
  nft delete table ip6 tt_block6 2>/dev/null
  [[ ${1:-} == up ]] || return 0
  ip rule add fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" priority 100 || return 1
  ip route add local 0.0.0.0/0 dev lo table "$TPROXY_TABLE" || return 1
  # Весь трафик устройств — в sing-box; что не перехвачено, наружу не выходит (kill switch). IPv6 — запрещён.
  nft -f - <<NFT || return 1
table ip tt_tproxy {
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    iifname != "$WG_IF" return
    ip daddr $base.0/24 return
    fib daddr type local return
    fib daddr type broadcast return
    fib daddr type multicast return
    tcp dport != 0 meta mark set $TPROXY_MARK tproxy to :$port accept
    udp dport != 0 meta mark set $TPROXY_MARK tproxy to :$port accept
  }
  chain input {
    type filter hook input priority filter; policy accept;
    iifname != "$WG_IF" return
    meta mark $TPROXY_MARK accept
    ip protocol icmp accept
    counter drop
  }
  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname "$WG_IF" counter drop
    oifname "$WG_IF" counter drop
  }
}
table ip6 tt_block6 {
  chain input { type filter hook input priority filter; policy accept; iifname "$WG_IF" counter drop; }
  chain forward { type filter hook forward priority filter; policy accept; iifname "$WG_IF" counter drop; oifname "$WG_IF" counter drop; }
}
NFT
}

# Защита от утечки: при недоступном сервере клиент TrustTunnel в режиме SOCKS выпускает
# соединения напрямую (killswitch на SOCKS не действует — проверено). Поэтому процессу клиента
# (пользователь ttclient) разрешены только адреса сервера; остальное отклоняется сразу.
# Ставится перед каждым запуском клиента (ExecStartPre), поэтому переживает перезагрузку и смену сервера.
gw_guard() {
  local ips='' dns='' a
  if [[ -s $ETC/endpoint.ip && $(cf PIN_MODE pin) == pin ]]; then
    ips=$(sed 's/:[0-9]*$//' "$ETC/endpoint.ip" | grep -E "$RE_IPV4" | paste -sd, -)
  else
    ips=$(getent ahostsv4 "$(ep_host)" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, -)
    dns=$(awk '$1=="nameserver" && $2 ~ /^[0-9.]+$/ {print $2}' /etc/resolv.conf | paste -sd, -)
  fi
  [[ -n $ips ]] || { echo "tt guard: адрес сервера неизвестен — клиенту закрыт весь выход" >&2; ips=127.0.0.1; }
  a="meta skuid ttclient ip daddr { $ips } accept"
  [[ -n $dns ]] && a+=$'
'"    meta skuid ttclient ip daddr { $dns } udp dport 53 accept"$'
'"    meta skuid ttclient ip daddr { $dns } tcp dport 53 accept"
  nft -f - <<NFT
table inet tt_guard
delete table inet tt_guard
table inet tt_guard {
  chain output {
    type filter hook output priority filter; policy accept;
    meta skuid ttclient oif "lo" accept
    $a
    meta skuid ttclient counter reject
  }
}
NFT
}

# ── клиенты WireGuard ────────────────────────────────────────────────────────
client_names() { local f; for f in "$ETC"/peers/*.peer; do [[ -f $f ]] && basename "$f" .peer; done; }
valid_client() { [[ ${1:-} =~ ^[A-Za-z0-9_-]{1,32}$ ]]; }
cl_add() { # имя [тихо]
  local n=${1:-} ip priv pub psk ep
  if [[ -z $n ]]; then ask n "Имя клиента" "" '^[A-Za-z0-9_-]{1,32}$' "Латиница, цифры, _ и - (до 32 символов)"; fi
  valid_client "$n" || die "Имя: латиница, цифры, _ и - (до 32 символов)"
  [[ -f $ETC/peers/$n.peer ]] && die "Клиент $n уже есть"
  ip=$(py next-ip) || return 1
  priv=$(wg genkey); pub=$(wg pubkey <<<"$priv"); psk=$(wg genpsk)
  ep=$(cf ENDPOINT); [[ $ep == *:* && $ep != \[* ]] && ep="[$ep]"
  install -d -m 700 "$ETC/peers" "$ETC/clients"
  (umask 077
   printf 'Address=%s\nPublicKey=%s\nPresharedKey=%s\n' "$ip" "$pub" "$psk" >"$ETC/peers/$n.peer"
   printf '[Interface]\nPrivateKey = %s\nAddress = %s/32\nDNS = %s\n\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nEndpoint = %s:%s\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 25\n' \
     "$priv" "$ip" "$(cf CLIENT_DNS '1.1.1.1, 1.0.0.1')" "$(cat "$ETC/wg.pub")" "$psk" "$ep" "$(cf WG_PORT)" >"$ETC/clients/$n.conf")
  if [[ ${2:-} != quiet ]]; then
    gw_apply >>"$LOG" 2>&1 || { rm -f "$ETC/peers/$n.peer" "$ETC/clients/$n.conf"; die "Не удалось добавить клиента (журнал: $LOG)"; }
  fi
  ok "Клиент $n добавлен: $ip"
  [[ ${2:-} == quiet ]] || cl_show "$n"
}
cl_show() {
  local n=$1 f=$ETC/clients/$1.conf
  [[ -f $f ]] || die "Клиента «$n» нет"
  card "WireGuard · $n"
  KV_W=8 kv "Адрес" "$(awk -F' *= *' '/^Address/{print $2}' "$f")"
  KV_W=8 kv "Шлюз" "$(cf ENDPOINT):$(cf WG_PORT)"
  KV_W=8 kv "Файл" "$f"
  card_end
  echo; sed "s/^/    $c_dim/; s/\$/$c_0/" "$f"
  if command -v qrencode >/dev/null 2>&1; then echo; qrencode -t ansiutf8 -m 2 <"$f" | sed 's/^/  /'
    note "Приложение WireGuard: «+» → «Сканировать QR-код» или импорт файла."
  fi
}
cl_remove() {
  local n=${1:-}
  if [[ -z $n ]]; then
    local -a cs; mapfile -t cs < <(client_names)
    pick_from n "Кого удалить" "${cs[@]}" || return 1
    yesno "Удалить $n? Устройство больше не подключится" n || return 0
  fi
  [[ -f $ETC/peers/$n.peer ]] || die "Клиента «$n» нет"
  mv -f "$ETC/peers/$n.peer" "$STATE/$n.peer.removed"
  if gw_apply >>"$LOG" 2>&1; then rm -f "$ETC/clients/$n.conf" "$STATE/$n.peer.removed"; ok "Клиент $n удалён"
  else mv -f "$STATE/$n.peer.removed" "$ETC/peers/$n.peer"; die "Не удалось удалить клиента (журнал: $LOG)"; fi
}
cl_list() { echo; C_OK="$c_ok" C_DIM="$c_dim" C_0="$c_0" WG_DUMP="$(wg show "$WG_IF" dump 2>/dev/null | tail -n +2)" py clients; }

# ── российские сайты напрямую ────────────────────────────────────────────────
ru_fetch() { # url файл — через туннель, до 5 попыток: единичный сбой соединения не должен срывать загрузку
  local i
  for i in 1 2 3 4 5; do
    curl -fsSL --connect-timeout 20 -m 180 -x "socks5h://127.0.0.1:$TEST_PORT" -o "$2" "$1" 2>>"$LOG" \
      && [[ $(head -c 3 "$2") == SRS ]] && return 0
    echo "$(date '+%F %T') список: попытка $i не удалась ($1)" >>"$LOG"
    (( i < 5 )) && sleep $((i * 3))
  done
  return 1
}
ru_download() { # через туннель; новый список заметно меньше прежнего — не принимается (защита от порчи)
  local kind tag url tmp dst old new fail=0
  RU_CHANGED=0
  install -d -m 755 "$RULES_DIR"
  while read -r kind tag url; do
    dst=$RULES_DIR/$tag.srs; tmp=$(mktemp "$RULES_DIR/.dl.XXXXXX")
    if ru_fetch "$url" "$tmp"; then
      new=$(stat -c %s "$tmp"); old=$(stat -c %s "$dst" 2>/dev/null || echo 0)
      if cmp -s "$tmp" "$dst"; then rm -f "$tmp"; continue; fi
      if (( old > 0 && new * 2 < old )); then
        rm -f "$tmp"; warn "Список $tag уменьшился больше чем вдвое ($old → $new байт) — оставлен прежний"; continue
      fi
      chmod 644 "$tmp"; mv -f "$tmp" "$dst"; RU_CHANGED=1; note "  ↓ $tag"
    else
      rm -f "$tmp"; warn "Не удалось скачать список $tag (5 попыток; подробности: $LOG)"; fail=1
    fi
  done < <(py sets)
  return "$fail"
}
ru_update() {
  [[ $(cf RU_DIRECT 0) == 1 ]] || { note "Режим «российские сайты напрямую» выключен — обновлять нечего"; return 0; }
  ru_download || warn "Часть списков не обновилась — работают прежние"
  if (( RU_CHANGED )); then ok "Списки обновлены (sing-box подхватывает их сам)"; else ok "Списки актуальны"; fi
}
ru_enable() {
  systemctl is-active --quiet sing-box || die "sing-box не запущен: списки скачиваются через туннель"
  note "Загружаю списки через туннель…"
  ru_download || die "Не все списки скачались — режим не включён"
  gw_set RU_DIRECT 1 || die "Режим не включён — прежние настройки возвращены"
  ok "Российские сайты идут напрямую · DNS: $(ru_dns_name "$(cf RU_DNS yandex)" "$(cf RU_DNS_CUSTOM)") · списки обновляются раз в неделю"
}
ru_disable() { gw_set RU_DIRECT 0 && ok "Режим выключен: весь трафик идёт через TrustTunnel (списки и исключения сохранены)"; }
norm_dom() { local d=${1,,}; d=${d#http://}; d=${d#https://}; d=${d%%/*}; d=${d#.}; [[ $d =~ ^[[:alnum:]]([[:alnum:]._-]*[[:alnum:]])?$ ]] && printf '%s' "$d"; }
ru_exc_add() { # direct|proxy [домен]
  local kind=$1 d=${2:-} file other
  [[ -n $d ]] || ask d "Домен (поддомены тоже)" "" "" ""
  d=$(norm_dom "$d") || die "Некорректный домен"
  if [[ $kind == direct ]]; then file=$EXC_D; other=$EXC_P; else file=$EXC_P; other=$EXC_D; fi
  touch "$file" "$other"
  grep -vxF "$d" "$other" >"$other.tmp" || true; mv -f "$other.tmp" "$other"
  grep -qxF "$d" "$file" || echo "$d" >>"$file"
  gw_apply >>"$LOG" 2>&1 || die "Не удалось применить (журнал: $LOG)"
  ok "$d и поддомены: всегда $([[ $kind == direct ]] && echo напрямую || echo 'через туннель')"
}
ru_exc_del() {
  local d=${1:-} f
  [[ -n $d ]] || { ru_exc_list; echo; ask d "Какой домен убрать" "" "" ""; }
  d=$(norm_dom "$d") || die "Некорректный домен"
  for f in "$EXC_D" "$EXC_P"; do [[ -f $f ]] && { grep -vxF "$d" "$f" >"$f.tmp" || true; mv -f "$f.tmp" "$f"; }; done
  gw_apply >>"$LOG" 2>&1 || die "Не удалось применить (журнал: $LOG)"
  ok "$d убран из исключений"
}
ru_exc_list() {
  section "Исключения"
  printf '  %sВсегда напрямую%s\n' "$c_dim" "$c_0"; if [[ -s $EXC_D ]]; then sed 's/^/    /' "$EXC_D"; else note "    —"; fi
  printf '  %sВсегда через туннель%s\n' "$c_dim" "$c_0"; if [[ -s $EXC_P ]]; then sed 's/^/    /' "$EXC_P"; else note "    —"; fi
}
ru_toggle() { # КЛЮЧ
  local k=$1 v
  v=$([[ $(cf "$k" 1) == 1 ]] && echo 0 || echo 1)
  [[ $k == RU_GUARD && $v == 0 ]] && warn "Без защиты заблокированные в РФ сайты на российских адресах пойдут напрямую и могут не открыться"
  conf_set "$k" "$v"
  if [[ $(cf RU_DIRECT 0) == 1 && $v == 1 ]]; then ru_download || { conf_set "$k" 0; die "Нужный список не скачался"; }; fi
  if [[ $(cf RU_DIRECT 0) == 1 ]]; then gw_apply >>"$LOG" 2>&1 || { conf_set "$k" "$((1 - v))"; gw_apply >>"$LOG" 2>&1; die "Не удалось применить"; }; fi
  ok "Готово"
}
ru_status() {
  section "Российские сайты напрямую"; KV_W=23
  if [[ $(cf RU_DIRECT 0) == 1 ]]; then kv "Режим" "${c_ok}●${c_0} включён"; else kv "Режим" "${c_dim}○${c_0} выключен — всё идёт через туннель"; fi
  kv "DNS российских сайтов" "$(ru_dns_name "$(cf RU_DNS yandex)" "$(cf RU_DNS_CUSTOM)") · напрямую"
  kv "Домены .ru .su .рф" "$(onoff "$(cf RU_SUFFIX 1)")"
  kv "IP-адреса России" "$(onoff "$(cf RU_GEOIP 1)")"
  kv "Защита заблокированных" "$(onoff "$(cf RU_GUARD 1)")"
  compgen -G "$RULES_DIR/*.srs" >/dev/null && kv "Списки" "$(find "$RULES_DIR" -maxdepth 1 -name '*.srs' | wc -l) шт., обновлены $(date -r "$(ls -t "$RULES_DIR"/*.srs | head -1)" '+%d.%m %H:%M') · раз в неделю"
  return 0
}

# ── сторож туннеля и Telegram ────────────────────────────────────────────────
tunnel_alive() { # по IP, без DNS: любой HTTP-ответ — туннель работает
  local u c
  for u in https://1.1.1.1/cdn-cgi/trace https://9.9.9.9/; do
    c=$(curl -s -o /dev/null -w '%{http_code}' -m 12 -x "socks5h://127.0.0.1:$SOCKS_PORT" "$u" 2>/dev/null)
    [[ -n $c && $c != 000 ]] && return 0
  done
  return 1
}
watchdog() { # раз в минуту по таймеру: туннель жив? нет — перезапуск клиента и уведомление
  local st=$STATE/watchdog fails=0 since=0 now
  now=$(date +%s)
  [[ -r $st ]] && read -r fails since <"$st"
  if tunnel_alive; then
    if (( fails >= 3 )); then
      tg_send "✅ Туннель снова работает (простой $(( (now - since) / 60 )) мин)"
      echo "$(date '+%F %T') туннель восстановлен" >>"$LOG"
    fi
    echo "0 0" >"$st"; return 0
  fi
  fails=$((fails + 1)); (( since )) || since=$now
  echo "$fails $since" >"$st"
  echo "$(date '+%F %T') сторож: туннель не отвечает (попытка $fails)" >>"$LOG"
  (( fails == 2 || fails % 10 == 0 )) && systemctl restart trusttunnel-client
  (( fails == 3 )) && tg_send "⚠️ Туннель TrustTunnel не работает с $(date -d "@$since" '+%H:%M'). Перезапуск клиента не помог; устройства без интернета."
  return 0
}

# ── сервер TrustTunnel, UDP, обновления ─────────────────────────────────────
v_tt_addr() { local h=${1#https://}; h=${h%%/*}; [[ $h =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]]; }
ep_collect() { # ключ ttgw:… / файл / вручную → endpoint.json; описание → EP_INFO
  local src def='' a
  if [[ -f $ETC/endpoint.json && -z ${TT_KEY:-}${TT_HOST:-} && ${EP_FORCE:-0} != 1 ]]; then
    EP_INFO=$(ep_info)
    yesno "Оставить сервер $EP_INFO?" y && { ok "Сервер: $EP_INFO"; return 0; }
  fi
  while :; do
    src=${TT_KEY:-}
    if [[ -z $src && -z ${TT_HOST:-} ]]; then
      note "Ключ подключения — строка ttgw:…, её показывает сервер (tt → Ключ для шлюза)."
      note "Можно указать путь к файлу экспорта или оставить пустым и ввести адрес, логин и пароль."
      for def in /root/gw.toml ""; do [[ -z $def || -f $def ]] && break; done
      ask src "Ключ подключения" "$def" "" ""
    fi
    if [[ -n $src ]]; then
      EP_INFO=$(py ep import "$src" 2>&1) && { ok "Сервер: $EP_INFO"; return 0; }
      warn "${EP_INFO#Ошибка: }"; TT_KEY=; continue
    fi
    ask TT_HOST "Адрес сервера" "" "" "Домен или IPv4, можно с портом: www.example.com:443" v_tt_addr
    a=${TT_HOST#https://}; a=${a%%/*}
    if [[ $a == *:* ]]; then TT_PORT=${a##*:}; a=${a%:*}; fi
    TT_HOST=$a
    ask TT_USER "Логин" "" '^[^[:space:]]+$' "Логин без пробелов"
    ask_secret TT_PASS "Пароль (не отображается)"
    EP_INFO=$(TT_HOST=$TT_HOST TT_PORT=${TT_PORT:-443} TT_USER=$TT_USER TT_PASS=$TT_PASS TT_PROTO=${TT_PROTO:-http2} py ep set 2>&1) \
      && { ok "Сервер: $EP_INFO"; return 0; }
    warn "${EP_INFO#Ошибка: }"; TT_HOST=; TT_USER=; TT_PASS=
  done
}
gw_endpoint() { # [ключ|файл]
  local bk; bk=$(mktemp -d)
  cp -a "$ETC/endpoint.json" "$ETC/endpoint.ip" "$bk/" 2>/dev/null
  if [[ -n ${1:-} ]]; then EP_INFO=$(py ep import "$1" 2>&1) || { rm -rf "${bk:?}"; die "${EP_INFO#Ошибка: }"; }
  else section "Сервер TrustTunnel" "Сейчас: $(ep_info)"; TT_KEY=; TT_HOST=; EP_FORCE=1 ep_collect; fi
  [[ $(cf PIN_MODE pin) == pin ]] && { py ep pin >>"$LOG" 2>&1 || warn "IP сервера не закреплён — адрес будет определяться через DNS"; }
  if run "Подключение к $EP_INFO" gw_apply; then rm -rf "${bk:?}"; ok "Сервер сменён · выход в интернет: $(gw_exit_ip)"; return 0; fi
  cp -a "$bk"/. "$ETC"/; rm -rf "${bk:?}"; gw_apply >>"$LOG" 2>&1 || true
  die "Новый сервер не отвечает (адрес, логин или пароль?) — оставлен прежний"
}
gw_repin() { py ep pin >>"$LOG" 2>&1 || die "Не удалось узнать IP сервера"; run "Переподключение" gw_apply && ok "IP сервера закреплён заново: $(cat "$ETC/endpoint.ip" | tr '\n' ' ')"; }
udp_works() { py udp-test "$SOCKS_PORT"; }
gw_udp() { # auto|tunnel|block
  local m=${1:-auto}
  if [[ $m == auto ]]; then if udp_works; then m=tunnel; else m=block; fi; fi
  gw_set UDP_MODE "$m" || die "Не удалось применить"
  ok "Режим UDP: $m — $([[ $m == tunnel ]] && echo 'UDP идёт через туннель' || echo 'UDP наружу не выпускается, браузеры переходят на TCP')"
}
sb_install() { # версия → /usr/local/bin/sing-box
  local v=${1#v} a tmp
  case $(uname -m) in x86_64) a=amd64 ;; aarch64) a=arm64 ;; *) echo "процессор не поддерживается"; return 1 ;; esac
  tmp=$(mktemp -d)
  fetch "https://github.com/SagerNet/sing-box/releases/download/v$v/sing-box-$v-linux-$a.tar.gz" "$tmp/sb.tgz" \
    && tar -xzf "$tmp/sb.tgz" -C "$tmp" && install -m 0755 "$tmp"/sing-box-*/sing-box "$SB_BIN.new" && mv -f "$SB_BIN.new" "$SB_BIN" \
    || { rm -rf "${tmp:?}"; return 1; }
  rm -rf "${tmp:?}"
  command -v restorecon >/dev/null 2>&1 && restorecon -F "$SB_BIN"
  return 0
}
sb_version() { "$SB_BIN" version 2>/dev/null | awk 'NR==1{print "v"$3}'; }
# shellcheck disable=SC2120  # необязательный аргумент — версия
gw_update_client() {
  local cur want bk
  cur=$(bin_version "$TTC_DIR"); want=${1:-$(gh_latest TrustTunnel/TrustTunnelClient)}
  section "Клиент TrustTunnel" "Установлен: $cur · последний: ${want:-не удалось узнать}"
  [[ -n $want ]] || return 1; want="v${want#v}"
  [[ $want == "$cur" ]] && { ok "Уже последняя версия"; return 0; }
  bk=$(mktemp -d); cp -a "$TTC_DIR/trusttunnel_client" "$TTC_DIR/VERSION" "$bk/" 2>/dev/null
  run "Загрузка и проверка подписи $want" bin_install client "$want" || { rm -rf "${bk:?}"; warn "Не удалось — оставлена $cur"; return 1; }
  systemctl restart trusttunnel-client >>"$LOG" 2>&1
  if gw_health; then rm -rf "${bk:?}"; conf_set TTC_VERSION "$want"; ok "Клиент обновлён: $cur → $want"; return 0; fi
  cp -a "$bk"/. "$TTC_DIR"/; rm -rf "${bk:?}"; systemctl restart trusttunnel-client >>"$LOG" 2>&1
  warn "Версия $want не заработала — возвращена $cur"; return 1
}
# shellcheck disable=SC2120  # необязательный аргумент — версия
gw_update_singbox() {
  local cur want bk
  cur=$(sb_version); want=${1:-$(gh_latest SagerNet/sing-box)}
  section "sing-box" "Установлен: $cur · последний: ${want:-не удалось узнать}"
  [[ -n $want ]] || return 1; want="v${want#v}"
  [[ $want == "$cur" ]] && { ok "Уже последняя версия"; return 0; }
  bk=$(mktemp); cp -a "$SB_BIN" "$bk"
  run "Загрузка sing-box $want" sb_install "$want" || { rm -f "$bk"; warn "Не удалось — оставлен $cur"; return 1; }
  if "$SB_BIN" check -c /etc/sing-box/config.json >>"$LOG" 2>&1 && systemctl restart sing-box && gw_health; then
    rm -f "$bk"; ok "sing-box обновлён: $cur → $want"; return 0
  fi
  cp -a "$bk" "$SB_BIN"; rm -f "$bk"; systemctl restart sing-box >>"$LOG" 2>&1
  warn "sing-box $want не принял конфигурацию — возвращён $cur"; return 1
}

# ── состояние ────────────────────────────────────────────────────────────────
gw_state() {
  local s bad=()
  for s in "wg-quick@$WG_IF" trusttunnel-client sing-box; do systemctl is-active --quiet "$s" || bad+=("${s%@*}"); done
  if (( ${#bad[@]} == 0 )); then printf '%s●%s работает' "$c_ok" "$c_0"; else printf '%s●%s остановлено: %s' "$c_err" "$c_0" "${bad[*]}"; fi
}
gw_checks() {
  local ip
  chk() { if eval "$2"; then ok "$1"; else err "$1"; fi; }
  chk "WireGuard принимает подключения · $(cf ENDPOINT):$(cf WG_PORT)/udp" 'systemctl is-active --quiet "wg-quick@$WG_IF"'
  chk "Клиент TrustTunnel на связи с сервером" 'systemctl is-active --quiet trusttunnel-client'
  chk "sing-box распределяет трафик" 'systemctl is-active --quiet sing-box'
  chk "Перехват трафика и DNS (nftables) на месте" 'nft list table ip tt_tproxy >/dev/null 2>&1'
  chk "Клиенту TrustTunnel разрешён только адрес сервера (нет утечки при сбое)" 'nft list table inet tt_guard >/dev/null 2>&1'
  ip=$(gw_exit_ip)
  chk "Выход в интернет через туннель: ${ip:-нет ответа}" '[[ -n $ip ]]'
  if [[ $(cf UDP_MODE tunnel) == block ]]; then note "  UDP наружу не выпускается (режим block): браузеры идут по TCP"
  elif py udp-test >/dev/null 2>&1; then ok "UDP проходит через туннель"
  else warn "UDP через туннель не подтверждён (tt → Режим UDP → Проверить)"; fi
  if [[ $(cf RU_DIRECT 0) == 1 ]]; then ok "Российские сайты идут напрямую"; fi
  if systemctl is-active --quiet tt-watchdog.timer; then ok "Сторож туннеля включён$([[ -f $ETC/telegram.conf ]] && echo ' · уведомления в Telegram')"; fi
}
gw_status() {
  section "Шлюз $(cf ENDPOINT)"; KV_W=20
  kv "WireGuard" "$(dot_state "wg-quick@$WG_IF") · $(cf ENDPOINT):$(cf WG_PORT)/udp"
  kv "Клиент TrustTunnel" "$(dot_state trusttunnel-client) · $(bin_version "$TTC_DIR")"
  kv "sing-box" "$(dot_state sing-box) · $(sb_version)"
  kv "Сервер" "$(ep_info)"
  kv "DNS: зарубежные" "$(doh_name "$(cf DOH)" "$(cf DOH_URL)") · через туннель"
  kv "DNS: российские" "$(ru_dns_name "$(cf RU_DNS yandex)" "$(cf RU_DNS_CUSTOM)") · напрямую$([[ $(cf RU_DIRECT 0) == 1 ]] || echo ' (режим выключен)')"
  section "Проверки"; gw_checks
  ru_status
  section "Клиенты"; cl_list
}

# ── удаление ─────────────────────────────────────────────────────────────────
gw_uninstall() {
  local b
  section "Удаление шлюза" "Будут остановлены и удалены WireGuard-сервер, sing-box, клиент TrustTunnel и настройки tt." \
    "Копия настроек и конфигов клиентов останется в /root."
  yesno "Удалить шлюз с этого VPS?" n || return 0
  b=/root/tt-backup-$(date +%Y%m%d-%H%M%S); install -d -m 700 "$b"; cp -a "$ETC" "$b/etc-tt" 2>/dev/null
  systemctl disable --now tt-watchdog.timer tt-ru.timer sing-box trusttunnel-client "wg-quick@$WG_IF" >>"$LOG" 2>&1 || true
  gw_rules down; nft delete table inet tt_guard 2>/dev/null
  rm -f /etc/systemd/system/{trusttunnel-client,sing-box,tt-watchdog,tt-ru}.service /etc/systemd/system/{tt-watchdog,tt-ru}.timer \
        "/etc/systemd/system/wg-quick@$WG_IF.service.d/10-tt.conf" /etc/sysctl.d/99-tt.conf "/etc/wireguard/$WG_IF.conf" "$SB_BIN"
  systemctl daemon-reload
  fw_close "$(cf WG_PORT)/udp"
  [[ $(fw_kind) == firewalld ]] && { firewall-cmd --permanent --zone=trusted --remove-interface="$WG_IF" >>"$LOG" 2>&1; firewall-cmd --reload >>"$LOG" 2>&1; }
  rm -rf "${TTC_DIR:?}" /etc/sing-box /var/lib/sing-box "${ETC:?}" "${STATE:?}" "${LIB:?}"
  ok "Шлюз удалён. Копия настроек: $b"
  rm -f "$BIN"
}

# ── установка ────────────────────────────────────────────────────────────────
v_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
v_tp_port() { v_port "$1" && (( 10#$1 != 10#${WG_PORT:-0} && 10#$1 != TEST_PORT && 10#$1 != SOCKS_PORT )); }
v_base() { local IFS=. x; local -a o; read -ra o <<<"$1"; (( ${#o[@]} == 3 )) || return 1; for x in "${o[@]}"; do [[ $x =~ ^[0-9]{1,3}$ ]] && (( 10#$x <= 255 )) || return 1; done; }
v_clients() { local n seen=" "; for n in $1; do [[ $n =~ ^[A-Za-z0-9_-]{1,32}$ && $seen != *" $n "* ]] || return 1; seen+="$n "; done; [[ $seen != " " ]]; }

gw_questions() {
  local b
  section "Шлюз" "Адрес, по которому устройства подключаются по WireGuard."
  ENDPOINT=${ENDPOINT:-}; ask ENDPOINT "Адрес шлюза" "$(public_ip)" '^[A-Za-z0-9._:-]+$' "IP-адрес или домен без пробелов"
  WG_PORT=${WG_PORT:-}; ask WG_PORT "Порт WireGuard (UDP)" "$(shuf -i 49152-65535 -n 1)" '^[0-9]{1,5}$' "Число от 1 до 65535" v_port
  WG_PORT=$((10#$WG_PORT))

  section "Сервер TrustTunnel" "Через него идёт всё, кроме российских сайтов."
  install -d -m 700 "$ETC"
  ep_collect

  dns_explain_tunnel
  if [[ -n ${DOH:-} ]]; then ok "DNS: $(doh_name "$DOH" "${DOH_URL:-}")"; else DOH=; DOH_URL=; pick_doh; fi

  section "Российские сайты напрямую" \
    "Банки, Госуслуги, маркетплейсы, операторы связи, Яндекс, VK — с этого сервера, без туннеля:" \
    "быстрее и без проверок «вы за рубежом». Заблокированные в РФ — всегда через туннель." \
    "Списки обновляются раз в неделю."
  if [[ -z ${RU_ENABLE:-} ]]; then if yesno "Включить?" y; then RU_ENABLE=1; else RU_ENABLE=0; fi; fi
  RU_DNS=${RU_DNS:-}; RU_DNS_CUSTOM=${RU_DNS_CUSTOM:-}
  if [[ $RU_ENABLE == 1 ]]; then
    dns_explain_ru
    if [[ -n $RU_DNS ]]; then ok "DNS: $(ru_dns_name "$RU_DNS" "$RU_DNS_CUSTOM")"; else pick_ru_dns; fi
  fi

  section "Клиенты" "Имена устройств через пробел — каждому свой конфиг и QR-код. Потом: tt add ИМЯ."
  CLIENTS=${CLIENTS:-}; ask CLIENTS "Клиенты" "phone" '^[A-Za-z0-9_ -]+$' "Латиница, цифры, _ и - (до 32 символов), без повторов" v_clients

  tg_setup

  WG_BASE=${WG_BASE:-10.11.42}; CLIENT_DNS=${CLIENT_DNS:-1.1.1.1, 1.0.0.1}; TPROXY_PORT=${TPROXY_PORT:-14205}
  RU_SUFFIX=${RU_SUFFIX:-1}; RU_GEOIP=${RU_GEOIP:-1}; RU_DNS=${RU_DNS:-yandex}
  PIN_MODE=${PIN_MODE:-pin}; is_ipaddr "$(ep_host)" && PIN_MODE=name
  echo
  if yesno "Дополнительные параметры (подсеть, порты, правила для РФ)?" n; then
    section "Подсеть WireGuard" "Первые три числа; шлюз получит .1, устройства — .2, .3 и далее."
    b=$WG_BASE; WG_BASE=; ask WG_BASE "Подсеть" "$b" '^[0-9]{1,3}(\.[0-9]{1,3}){2}$' "Формат: 10.11.42" v_base
    section "DNS в конфигах устройств" "Формальность: шлюз всё равно перехватывает запросы и решает сам."
    b=$CLIENT_DNS; CLIENT_DNS=; ask CLIENT_DNS "DNS" "$b" '^[0-9a-fA-F:.]+(, ?[0-9a-fA-F:.]+)*$' "IP-адреса через запятую"
    section "Внутренний порт sing-box"
    b=$TPROXY_PORT; TPROXY_PORT=; ask TPROXY_PORT "Порт" "$b" '^[0-9]{1,5}$' "Порт 1–65535, не занятый WireGuard, $SOCKS_PORT и $TEST_PORT" v_tp_port
    TPROXY_PORT=$((10#$TPROXY_PORT))
    if [[ $PIN_MODE == pin ]]; then
      section "Адрес сервера TrustTunnel" "Закрепить IP — шлюз не обращается к DNS за адресом сервера (незаметнее)." "При смене IP сервера: tt repin."
      b=$PIN_MODE; PIN_MODE=; choose PIN_MODE "" "$b" "pin|Закрепить IP|рекомендуется" "name|Спрашивать DNS|через DNS хостера шлюза"
    fi
    if [[ $RU_ENABLE == 1 ]]; then
      section "Правила для российских сайтов"
      if yesno "Считать российскими все домены .ru, .su и .рф?" y; then RU_SUFFIX=1; else RU_SUFFIX=0; fi
      if yesno "Пускать напрямую и всё, что идёт на российские IP-адреса?" y; then RU_GEOIP=1; else RU_GEOIP=0; fi
    fi
  fi
  if ip -4 route show 2>/dev/null | grep -v " dev $WG_IF " | grep -q "^${WG_BASE//./\\.}\."; then
    warn "Подсеть ${WG_BASE}.0/24 уже используется на этом сервере"
    yesno "Продолжить с ней?" n || die "Отменено. Запустите снова и выберите другую подсеть в дополнительных параметрах"
  fi
  if [[ -n $(ss -H -lun "sport = :$WG_PORT" 2>/dev/null) ]] && ! wg show "$WG_IF" listen-port 2>/dev/null | grep -qx "$WG_PORT"; then
    warn "Порт $WG_PORT/udp уже занят"; yesno "Продолжить?" n || die "Отменено — ничего не изменено"
  fi

  card "Проверьте настройки"
  kv "Шлюз" "$ENDPOINT:$WG_PORT/udp · подсеть ${WG_BASE}.0/24"
  kv "Сервер" "$EP_INFO"
  kv "Клиенты" "$CLIENTS"
  if [[ $RU_ENABLE == 1 ]]; then
    kv "Маршруты" "российские сайты — напрямую, остальное — через туннель"
    kv "DNS: зарубежные" "$(doh_name "$DOH" "$DOH_URL") · через туннель"
    kv "DNS: российские" "$(ru_dns_name "$RU_DNS" "$RU_DNS_CUSTOM") · напрямую"
  else
    kv "Маршруты" "весь трафик — через туннель"
    kv "DNS" "$(doh_name "$DOH" "$DOH_URL") · через туннель"
  fi
  kv "Уведомления" "$([[ -f $ETC/telegram.conf ]] && echo "Telegram" || echo "нет")"
  card_end
  echo
  yesno "Начать установку?" y || die "Отменено — ничего не изменено"
}
is_ipaddr() { [[ $1 =~ ^[0-9.]+$ || $1 == *:* ]]; }
gw_pkgs() {
  case $PM in
    dnf) pkg_install epel-release || true
         command -v crb >/dev/null 2>&1 && crb enable || true
         pkg_install wireguard-tools nftables iproute python3 tar gnupg2 curl; pkg_install qrencode || true ;;
    apt) pkg_install wireguard-tools nftables iproute2 python3 tar gnupg curl ca-certificates; pkg_install qrencode || true ;;
  esac
  local m; for m in wg wg-quick nft python3 gpg curl; do command -v "$m" >/dev/null 2>&1 || { echo "нет $m"; return 1; }; done
}
gw_firewall() {
  case $(fw_kind) in
    firewalld) firewall-cmd --permanent --add-port="$WG_PORT/udp" >>"$LOG" 2>&1
               firewall-cmd --permanent --zone=trusted --add-interface="$WG_IF" >>"$LOG" 2>&1
               firewall-cmd --reload >>"$LOG" 2>&1; ok "Файрвол (firewalld): открыт $WG_PORT/udp" ;;
    ufw) ufw allow "$WG_PORT/udp" >>"$LOG" 2>&1; ufw allow in on "$WG_IF" >>"$LOG" 2>&1; ok "Файрвол (ufw): открыт $WG_PORT/udp" ;;
    none) note "Файрвол не включён — защиту от утечек обеспечивают собственные правила nftables шлюза" ;;
  esac
}
gw_install() {
  steps 7
  step "Проверка системы"
  ok "$(sys_line)"
  arch >/dev/null || die "Процессор $(uname -m) не поддерживается: нужен x86_64 или aarch64"
  if [[ -f /etc/tproxy-gw/gw.env || -f /etc/tt-gw/gw.env ]]; then
    warn "На сервере есть другой шлюз (deploy-tproxy.sh или tt-gateway v2) — у них общие wg0 и sing-box"
    yesno "Всё равно продолжить?" n || die "Отменено — ничего не изменено"
  fi
  if [[ -f /etc/wireguard/$WG_IF.conf && $(cf ROLE) != gateway ]]; then
    warn "Интерфейс $WG_IF уже настроен другой программой"
    yesno "Сохранить его копию в /root и установить шлюз вместо него?" n || die "Отменено — ничего не изменено"
    systemctl disable --now "wg-quick@$WG_IF" >>"$LOG" 2>&1 || true
    mv -f "/etc/wireguard/$WG_IF.conf" "/root/$WG_IF.conf.before-tt-$(date +%Y%m%d-%H%M%S)"
  fi
  gw_questions
  conf_set ROLE gateway ENDPOINT "$ENDPOINT" WG_PORT "$WG_PORT" WG_BASE "$WG_BASE" CLIENT_DNS "$CLIENT_DNS" \
    TPROXY_PORT "$TPROXY_PORT" DOH "$DOH" DOH_URL "$DOH_URL" PIN_MODE "$PIN_MODE" UDP_MODE "$(cf UDP_MODE tunnel)" \
    LOG_LEVEL warn RU_DIRECT 0 RU_DNS "$RU_DNS" RU_DNS_CUSTOM "$RU_DNS_CUSTOM" RU_SUFFIX "$RU_SUFFIX" \
    RU_GEOIP "$RU_GEOIP" RU_GUARD 1
  [[ $RU_ENABLE == 1 ]] && UI_STEPS=8

  step "Подготовка системы"
  ensure_swap
  run "Установка пакетов (WireGuard, nftables, python3)" gw_pkgs || die "Пакеты не установились"
  modprobe wireguard 2>/dev/null || die "В ядре нет модуля WireGuard"
  getent group sing-box >/dev/null || groupadd -r sing-box
  id sing-box >/dev/null 2>&1 || useradd -r -g sing-box -d /var/lib/sing-box -s /sbin/nologin -M sing-box
  getent group ttclient >/dev/null || groupadd -r ttclient
  id ttclient >/dev/null 2>&1 || useradd -r -g ttclient -d /nonexistent -s /sbin/nologin -M ttclient
  ok "Системные пользователи sing-box и ttclient"

  step "Программы"
  local v
  if [[ -x $SB_BIN ]]; then ok "sing-box $(sb_version) уже установлен"
  else
    v=${SINGBOX_VERSION:-$(gh_latest SagerNet/sing-box)}; [[ -n $v ]] || { v=$SB_PINNED; warn "GitHub не ответил — ставлю проверенный sing-box $v"; }
    run "Загрузка sing-box ${v}" sb_install "$v" || die "Не удалось установить sing-box"
  fi
  if [[ -x $TTC_DIR/trusttunnel_client && -z ${TTC_VERSION:-} ]]; then ok "Клиент TrustTunnel $(bin_version "$TTC_DIR") уже установлен"
  else
    v=${TTC_VERSION:-$(gh_latest TrustTunnel/TrustTunnelClient)}; [[ -n $v ]] || { v=$TTC_PINNED; warn "GitHub не ответил — ставлю проверенный клиент $v"; }
    run "Загрузка клиента TrustTunnel ${v} и проверка подписи" bin_install client "v${v#v}" || die "Не удалось установить клиент TrustTunnel"
    conf_set TTC_VERSION "v${v#v}"
  fi

  step "Подключение к серверу TrustTunnel"
  if [[ $PIN_MODE == pin ]]; then
    v=$(py ep pin 2>&1) || die "Не удалось узнать IP сервера: ${v#Ошибка: }"
    ok "IP сервера закреплён: $v"
  fi
  if [[ ! -f $ETC/wg.key ]]; then (umask 077; wg genkey >"$ETC/wg.key"); fi
  wg pubkey <"$ETC/wg.key" >"$ETC/wg.pub"
  local n; for n in $CLIENTS; do [[ -f $ETC/peers/$n.peer ]] || cl_add "$n" quiet; done
  run "Запуск туннеля, sing-box и WireGuard" gw_apply || die "Шлюз не запустился. Журнал: $LOG"
  ok "Туннель работает · выход в интернет: $(gw_exit_ip)"
  if [[ $(cf UDP_MODE tunnel) == tunnel ]]; then
    if udp_works; then ok "UDP проходит через туннель"
    else gw_set UDP_MODE block >>"$LOG" 2>&1; warn "UDP через туннель не проходит — режим block: браузеры идут по TCP (проверка: tt udp auto)"; fi
  fi

  step "Защита и сторож"
  gw_firewall
  systemctl enable --now tt-watchdog.timer >>"$LOG" 2>&1 && ok "Сторож проверяет туннель раз в минуту$([[ -f $ETC/telegram.conf ]] && echo ' · уведомления в Telegram')"
  ok "Если туннель упадёт, интернет у устройств пропадёт, а не пойдёт напрямую"

  if [[ $RU_ENABLE == 1 ]]; then
    step "Российские сайты напрямую"
    (ru_enable) || warn "Режим не включён (шлюз работает, всё идёт через туннель). Позже: tt ru enable"
    conf_load
  fi

  step "Проверка"
  gw_checks

  printf '\n  %s✓ Шлюз готов%s\n' "$c_ok$c_b" "$c_0"
  card "Шлюз"
  kv "Устройства" "WireGuard → $ENDPOINT:$WG_PORT/udp"
  kv "Сервер" "$(ep_info)"
  kv "Маршруты" "$([[ $(cf RU_DIRECT 0) == 1 ]] && echo 'российские сайты — напрямую, остальное — через туннель' || echo 'весь трафик — через туннель')"
  kv "Управление" "tt"
  kv "Журнал" "$LOG"
  card_end
  note "Если у хостера есть свой файрвол — откройте в нём $WG_PORT/udp."
  for n in $CLIENTS; do cl_show "$n"; done
  echo
}

# ── меню ─────────────────────────────────────────────────────────────────────
gw_ru_menu() {
  local c
  while :; do
    cls; banner "TrustTunnel" "шлюз · российские сайты напрямую"
    note "Сайты РФ (банки, Госуслуги, маркетплейсы, операторы) идут с этого сервера напрямую,"
    note "всё остальное — через TrustTunnel. Заблокированные в РФ — всегда через туннель."
    MI_W=38
    mhead "Режим"
    if [[ $(cf RU_DIRECT 0) == 1 ]]; then mi 1 "Выключить" "сейчас включён"; else mi 1 "Включить" "сейчас выключен"; fi
    mi 2 "Состояние и списки"
    mi 3 "Обновить списки сейчас" "обычно — сами раз в неделю"
    mhead "Правила"
    mi 4 "Домены .ru .su .рф — напрямую" "$(onoff "$(cf RU_SUFFIX 1)")"
    mi 5 "IP-адреса России — напрямую" "$(onoff "$(cf RU_GEOIP 1)")"
    mi 6 "Заблокированные в РФ — через туннель" "$(onoff "$(cf RU_GUARD 1)")"
    mhead "Исключения"
    mi 7 "Домен — всегда напрямую"; mi 8 "Домен — всегда через туннель"; mi 9 "Убрать домен из исключений"; mi 10 "Показать исключения"
    mi 0 "Назад"
    mpick c
    case $c in
      1) if [[ $(cf RU_DIRECT 0) == 1 ]]; then (ru_disable); else (ru_enable); fi ;;
      2) ru_status ;; 3) (ru_update) ;;
      4) (ru_toggle RU_SUFFIX) ;; 5) (ru_toggle RU_GEOIP) ;; 6) (ru_toggle RU_GUARD) ;;
      7) (ru_exc_add direct) ;; 8) (ru_exc_add proxy) ;; 9) (ru_exc_del) ;; 10) ru_exc_list ;;
      0|q|Q|"") return 0 ;;
      *) warn "Введите число от 0 до 10"; sleep 1; continue ;;
    esac
    conf_load; pause
  done
}
gw_dns_menu() {
  local c
  while :; do
    cls; banner "TrustTunnel" "шлюз · DNS"
    note "У шлюза два DNS: для сайтов через туннель и для российских сайтов."
    note "DNS на устройствах значения не имеет — шлюз перехватывает запросы и решает сам."
    echo; MI_W=32
    mi 1 "Зарубежные и заблокированные" "$(doh_name "$(cf DOH)" "$(cf DOH_URL)") · через туннель"
    mi 2 "Российские сайты" "$(ru_dns_name "$(cf RU_DNS yandex)" "$(cf RU_DNS_CUSTOM)") · напрямую$([[ $(cf RU_DIRECT 0) == 1 ]] || echo ' (режим выключен)')"
    mi 0 "Назад"
    mpick c
    case $c in
      1) (dns_explain_tunnel; note "Сейчас: $(doh_name "$(cf DOH)" "$(cf DOH_URL)")"; DOH=$(cf DOH); DOH_URL=$(cf DOH_URL); pick_doh
          [[ $DOH == "$(cf DOH)" && $DOH_URL == "$(cf DOH_URL)" ]] && { note "Без изменений"; exit 0; }
          run "Применение" gw_set DOH "$DOH" DOH_URL "$DOH_URL" && ok "DNS для зарубежных сайтов: $(doh_name "$DOH" "$DOH_URL")") ;;
      2) (dns_explain_ru; note "Сейчас: $(ru_dns_name "$(cf RU_DNS yandex)" "$(cf RU_DNS_CUSTOM)")"; RU_DNS=$(cf RU_DNS yandex); pick_ru_dns
          run "Применение" gw_set RU_DNS "$RU_DNS" RU_DNS_CUSTOM "$RU_DNS_CUSTOM" && ok "DNS для российских сайтов: $(ru_dns_name "$RU_DNS" "$RU_DNS_CUSTOM")") ;;
      0|"") return 0 ;;
      *) warn "Введите 0, 1 или 2"; sleep 1; continue ;;
    esac
    conf_load; pause
  done
}
gw_udp_menu() {
  local m
  section "UDP через туннель" "tunnel — UDP (звонки, игры, QUIC) идёт через TrustTunnel." \
    "block — UDP наружу не выпускается: браузеры переходят на TCP, DNS работает." "Сейчас: $(cf UDP_MODE tunnel)"
  choose m "" auto "auto|Проверить и выбрать|рекомендуется" "tunnel|tunnel|UDP через туннель" "block|block|UDP наружу не выпускать"
  gw_udp "$m"
}
gw_menu() {
  local c n
  while :; do
    cls; banner "TrustTunnel" "шлюз · $(cf ENDPOINT)"
    printf '  %s  %sсервер %s · клиентов %s · РФ напрямую: %s%s\n' "$(gw_state)" "$c_dim" "$(ep_host)" \
      "$(client_names | wc -l)" "$([[ $(cf RU_DIRECT 0) == 1 ]] && echo вкл || echo выкл)" "$c_0"
    MI_W=28
    mhead "Клиенты WireGuard"
    mi 1 "Список и кто на связи"; mi 2 "Добавить"; mi 3 "Конфиг и QR-код"; mi 4 "Удалить"
    mhead "Маршруты и DNS"
    mi 5 "Российские сайты напрямую" "$([[ $(cf RU_DIRECT 0) == 1 ]] && echo включено || echo выключено) ›"
    mi 6 "DNS" "$(doh_name "$(cf DOH)" "$(cf DOH_URL)") / $(ru_dns_name "$(cf RU_DNS yandex)" "$(cf RU_DNS_CUSTOM)") ›"
    mhead "Сервер TrustTunnel"
    mi 7 "Сменить сервер" "$(ep_host)"; mi 8 "Режим UDP" "$(cf UDP_MODE tunnel)"
    mhead "Шлюз"
    mi 9 "Проверка состояния"; mi 10 "Обслуживание" "обновления, скорость, журнал ›"
    mi 0 "Выход"
    mpick c
    case $c in
      1) cl_list ;;
      2) (cl_add) ;;
      3) { local -a cs; mapfile -t cs < <(client_names); pick_from n "Чей конфиг показать" "${cs[@]}" && (cl_show "$n"); } ;;
      4) (cl_remove) ;;
      5) gw_ru_menu; continue ;;
      6) gw_dns_menu; continue ;;
      7) (gw_endpoint) ;;
      8) (gw_udp_menu) ;;
      9) gw_status ;;
      10) maint_menu; continue ;;
      0|q|Q) echo; exit 0 ;;
      *) warn "Введите число от 0 до 10"; sleep 1; continue ;;
    esac
    conf_load; pause
  done
}
