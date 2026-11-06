# shellcheck shell=bash
# ── Роль «сервер»: TrustTunnel за рубежом + сайт-заглушка + сертификат ────────

ACME_HOME=/opt/acme.sh
ACME_BIN=$ACME_HOME/acme.sh
DECOY_ROOT=/var/www/tt-decoy
ACME_ROOT=/var/www/tt-acme
NAME_RE='^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$'
DOMAIN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$'

srv_domain() { cf DOMAIN; }
srv_port() { cf PORT 443; }
cert_dir() { echo "$ETC/certs/$(srv_domain)"; }
creds() { py creds "$@"; }
user_names() { creds list 2>/dev/null | cut -f1; }

dns_name() {
  case ${1:-} in
    "") echo "как в приложении" ;; tls://1.1.1.1) echo "Cloudflare" ;; tls://9.9.9.9) echo "Quad9" ;;
    tls://8.8.8.8) echo "Google" ;; tls://208.67.222.222) echo "OpenDNS" ;; *) echo "$1" ;;
  esac
}
theme_name() { case ${1:-random} in studio) echo "студия дизайна" ;; blog) echo "личный блог" ;; workshop) echo "мастерская" ;; *) echo "по имени домена" ;; esac; }
choose_theme() { # ПЕРЕМЕННАЯ умолчание
  choose "$1" "" "$2" \
    "studio|Студия дизайна|портфолио небольшой веб-студии" \
    "blog|Личный блог|заметки о технике, велосипеде и кофе" \
    "workshop|Мастерская|мебель ручной работы" \
    "random|По имени домена|выбор по домену, всегда один и тот же"
}
pick_app_dns() { # → APP_DNS (по текущему значению)
  local k cur=${APP_DNS:-} u def
  case $cur in tls://1.1.1.1) def=cloudflare ;; tls://9.9.9.9) def=quad9 ;; tls://8.8.8.8) def=google ;;
    tls://208.67.222.222) def=opendns ;; "") def=${1:-cloudflare} ;; *) def=custom ;; esac
  k=
  choose k "" "$def" \
    "cloudflare|Cloudflare|1.1.1.1 · самый быстрый" \
    "quad9|Quad9|9.9.9.9 · блокирует вредоносные сайты" \
    "google|Google|8.8.8.8" \
    "opendns|OpenDNS|208.67.222.222 · Cisco" \
    "app|Как в приложении|ничего не менять" \
    "custom|Свой сервер|tls://…, https://… или quic://…"
  case $k in
    cloudflare) APP_DNS=tls://1.1.1.1 ;; quad9) APP_DNS=tls://9.9.9.9 ;; google) APP_DNS=tls://8.8.8.8 ;;
    opendns) APP_DNS=tls://208.67.222.222 ;; app) APP_DNS= ;;
    custom) u=; [[ $def == custom ]] && u=$cur; APP_DNS=
            ask APP_DNS "Адрес DNS-сервера" "$u" '^(https|tls|quic)://[A-Za-z0-9._:/@%-]+$' "Нужен адрес вида tls://9.9.9.9 или https://dns.example/dns-query" ;;
  esac
}
dns_explain_app() {
  section "DNS для приложений" \
    "Через него приложения TrustTunnel на телефонах и компьютерах узнают адреса сайтов." \
    "Запросы идут внутри туннеля, провайдер их не видит. На шлюз не влияет — у него свой DNS."
}

# ── сборка конфигурации ──────────────────────────────────────────────────────
srv_nginx_main() {
  local usr=nginx
  getent passwd nginx >/dev/null || usr=www-data
  cat <<EOF
# Создано tt. Порт 80 — проверка Let's Encrypt; сайт-заглушку показывает TrustTunnel на $(srv_port).
user $usr;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log warn;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    server_tokens off;
    sendfile on;
    keepalive_timeout 65;
    access_log /var/log/nginx/access.log;
    gzip on;
    gzip_types text/plain text/css application/javascript image/svg+xml;
    server {
        listen 80 default_server;
$([[ -e /proc/net/if_inet6 ]] && echo "        listen [::]:80 default_server;")
        server_name _;
        location ^~ /.well-known/acme-challenge/ { root $ACME_ROOT; default_type text/plain; }
        location / { return 301 https://\$host\$request_uri; }
    }
    server {
        listen 127.0.0.1:$DECOY_PORT;
        server_name _;
        root $DECOY_ROOT;
        index index.html;
        error_page 404 /404.html;
        add_header X-Content-Type-Options nosniff always;
        add_header Referrer-Policy strict-origin-when-cross-origin always;
        location / { try_files \$uri \$uri/ =404; }
        location ~ /\. { return 404; }
    }
}
EOF
}
srv_unit() {
  cat <<EOF
[Unit]
Description=TrustTunnel (сервер)
After=network-online.target nginx.service
Wants=network-online.target

[Service]
WorkingDirectory=$TT_DIR
ExecStart=$TT_DIR/trusttunnel_endpoint $TT_DIR/vpn.toml $TT_DIR/hosts.toml
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}
srv_renew_units() { # $1 — каталог
  local cmd
  case $(cf CERT_CLIENT) in
    certbot) cmd="$(certbot_bin) renew --quiet --deploy-hook $LIB/cert-hook.sh" ;;
    acme) cmd="$ACME_BIN --home $ACME_HOME --cron" ;;
    *) return 0 ;;
  esac
  printf '[Unit]\nDescription=TrustTunnel: продление сертификата\n[Service]\nType=oneshot\nExecStart=%s\n' "$cmd" >"$1/tt-cert.service"
  printf '[Unit]\nDescription=TrustTunnel: ежедневная проверка сертификата\n[Timer]\nOnCalendar=*-*-* 03:17:00\nRandomizedDelaySec=1h\nPersistent=true\n[Install]\nWantedBy=timers.target\n' >"$1/tt-cert.timer"
}
srv_stage() { # каталог → манифест
  local s=$1
  py render server "$s" || return 1
  srv_nginx_main >"$s/nginx.conf"
  srv_unit >"$s/trusttunnel.service"
  srv_renew_units "$s"
  cat <<EOF
trusttunnel.service|/etc/systemd/system/trusttunnel.service|644|root:root|daemon
tt-cert.service|/etc/systemd/system/tt-cert.service|644|root:root|daemon
tt-cert.timer|/etc/systemd/system/tt-cert.timer|644|root:root|restart:tt-cert.timer
nginx.conf|/etc/nginx/nginx.conf|644|root:root|nginx
vpn.toml|$TT_DIR/vpn.toml|600|root:root|restart:trusttunnel
hosts.toml|$TT_DIR/hosts.toml|600|root:root|restart:trusttunnel
rules.toml|$TT_DIR/rules.toml|600|root:root|restart:trusttunnel
EOF
}
srv_health() {
  local c d=${CFG[DECOY_DOMAIN]:-$(srv_domain)}
  unit_up trusttunnel 10 || { err "TrustTunnel не запустился"; journalctl -u trusttunnel -n 15 --no-pager >>"$LOG" 2>&1; return 1; }
  ss -Hlnt "sport = :$(srv_port)" | grep -q . || { err "TrustTunnel не слушает порт $(srv_port)"; return 1; }
  c=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$d:$(srv_port):127.0.0.1" "https://$d:$(srv_port)/" 2>/dev/null || true)
  [[ $c == 200 ]] || { err "Сайт-заглушка не открывается (ответ: ${c:-нет})"; return 1; }
}
srv_decoy() { # пересоздать сайт, если сменились домен или тема
  local want out
  want="$(cf DECOY_DOMAIN "$(srv_domain)") $(cf THEME random)"
  [[ -d $DECOY_ROOT && $(cat "$STATE/decoy.stamp" 2>/dev/null) == "$want" ]] && return 0
  out=$(py decoy "$DECOY_ROOT" $want) || return 1
  echo "$want" >"$STATE/decoy.stamp"
  command -v restorecon >/dev/null 2>&1 && restorecon -R "$DECOY_ROOT" 2>/dev/null
  DECOY_INFO=$out
}
# IPv6 включается в TrustTunnel, только если реально работает: «маршрут есть, а связи нет» у дешёвых VPS —
# частая история, и тогда сервер случайно выбирает IPv6-адрес сайта и соединение срывается.
ipv6_ok() {
  ip -6 route get 2001:4860:4860::8888 >/dev/null 2>&1 || return 1
  curl -6 -fsS -o /dev/null -m 6 https://www.google.com/generate_204 2>/dev/null \
    || curl -6 -fsS -o /dev/null -m 6 https://cloudflare.com/cdn-cgi/trace 2>/dev/null
}
srv_apply() {
  local s m rc=0
  if [[ $(cf IPV6 0) == 1 ]] && ! ipv6_ok; then
    conf_set IPV6 0; echo "$(date '+%F %T') IPv6 на сервере не работает — отключён в TrustTunnel" >>"$LOG"
  fi
  install -d -m 755 "$STATE"; install -d -m 755 "$ACME_ROOT"
  srv_decoy || { err "Не удалось создать сайт-заглушку"; return 1; }
  s=$(mktemp -d)
  m=$(srv_stage "$s") || { rm -rf "${s:?}"; return 1; }
  apply_manifest "$s" "$m" srv_health || rc=1
  rm -rf "${s:?}"
  return "$rc"
}
srv_restart_checked() { # перезапуск после изменения пользователей; при сбое — прежний credentials.toml
  local bk=$1
  systemctl restart trusttunnel >>"$LOG" 2>&1
  srv_health && { rm -f "$bk"; return 0; }
  [[ -f $bk ]] && cp -a "$bk" "$TT_DIR/credentials.toml" && systemctl restart trusttunnel >>"$LOG" 2>&1
  rm -f "$bk"
  warn "Изменение не применилось — прежние пользователи возвращены"
  return 1
}
creds_backup() { local b; b=$(mktemp "$STATE/creds.XXXXXX"); cp -a "$TT_DIR/credentials.toml" "$b" 2>/dev/null; echo "$b"; }

# ── сертификат ───────────────────────────────────────────────────────────────
certbot_bin() { command -v certbot 2>/dev/null || echo /opt/certbot/bin/certbot; }
acme_install() {
  [[ -x $ACME_BIN ]] && return 0
  local tmp; tmp=$(mktemp -d)
  fetch https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.tar.gz "$tmp/a.tgz" && tar -xzf "$tmp/a.tgz" -C "$tmp" \
    && (cd "$tmp"/acme.sh-master && sh ./acme.sh --install --home "$ACME_HOME" --nocron --no-profile ${CFG[EMAIL]:+--accountemail "${CFG[EMAIL]}"}) \
    || { rm -rf "${tmp:?}"; return 1; }
  rm -rf "${tmp:?}"
  "$ACME_BIN" --home "$ACME_HOME" --set-default-ca --server letsencrypt
}
certbot_install() {
  command -v certbot >/dev/null 2>&1 || [[ -x /opt/certbot/bin/certbot ]] && return 0
  pkg_install certbot && return 0
  python3 -m venv /opt/certbot && /opt/certbot/bin/pip install --quiet --upgrade pip certbot
}
cert_hook_write() { # копия сертификата + SIGHUP: TrustTunnel перечитывает его без разрыва подключений
  install -d -m 755 "$LIB"
  cat >"$LIB/cert-hook.sh" <<EOF
#!/bin/sh
D=\$(sed -n 's/^DOMAIN="\\(.*\\)"/\\1/p' $CONF)
if [ -n "\${RENEWED_LINEAGE:-}" ] && [ -f "\$RENEWED_LINEAGE/fullchain.pem" ]; then
  mkdir -p "$ETC/certs/\$D" && chmod 700 "$ETC/certs/\$D"
  cp -L "\$RENEWED_LINEAGE/fullchain.pem" "$ETC/certs/\$D/fullchain.pem"
  cp -L "\$RENEWED_LINEAGE/privkey.pem" "$ETC/certs/\$D/privkey.pem"; chmod 600 "$ETC/certs/\$D/privkey.pem"
fi
systemctl is-active trusttunnel >/dev/null 2>&1 && systemctl reload trusttunnel || true
EOF
  chmod 755 "$LIB/cert-hook.sh"
}
cert_names_ok() {
  local crt have want
  crt=$(cert_dir)/fullchain.pem
  [[ -s $crt ]] || return 1
  have=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^,[:space:]]*' | cut -d: -f2 | sort -u | tr '\n' ' ')
  want=$(printf '%s\n' "$(srv_domain)" ${CFG[DECOY_DOMAIN]:+"${CFG[DECOY_DOMAIN]}"} | sort -u | tr '\n' ' ')
  [[ $have == "$want" ]]
}
cert_days() {
  local e; e=$(openssl x509 -enddate -noout -in "$(cert_dir)/fullchain.pem" 2>/dev/null | cut -d='' -f2) || { echo "-"; return; }
  [[ -n $e ]] || { echo "-"; return; }
  echo $(( ( $(date -d "$e" +%s) - $(date +%s) ) / 86400 ))
}
cert_label() { [[ $(cf CERT_CLIENT) == self ]] && echo "самоподписанный (тест)" || echo "Let's Encrypt · $([[ $(cf CERT_CLIENT) == certbot ]] && echo certbot || echo acme.sh)"; }
cert_issue() { # вывод — в журнал
  local d args=() em cdir rc=0
  cdir=$(cert_dir)
  for d in "$(srv_domain)" ${CFG[DECOY_DOMAIN]:+"${CFG[DECOY_DOMAIN]}"}; do args+=(-d "$d"); done
  install -d -m 700 "$ETC/certs" "$cdir"
  cert_hook_write
  if [[ $(cf ACME_CLIENT acme) == certbot ]]; then
    em=(--register-unsafely-without-email); [[ -n $(cf EMAIL) ]] && em=(-m "$(cf EMAIL)")
    "$(certbot_bin)" certonly --webroot -w "$ACME_ROOT" "${args[@]}" --cert-name "$(srv_domain)" --expand --keep-until-expiring \
      --non-interactive --agree-tos "${em[@]}" --deploy-hook "$LIB/cert-hook.sh" || return 1
    RENEWED_LINEAGE=/etc/letsencrypt/live/$(srv_domain) sh "$LIB/cert-hook.sh"
  else
    "$ACME_BIN" --home "$ACME_HOME" --issue --server letsencrypt "${args[@]}" -w "$ACME_ROOT" || rc=$?
    [[ $rc -eq 0 || $rc -eq 2 ]] || return 1   # 2 — сертификат ещё действителен
    "$ACME_BIN" --home "$ACME_HOME" --install-cert -d "$(srv_domain)" --fullchain-file "$cdir/fullchain.pem" \
      --key-file "$cdir/privkey.pem" --reloadcmd "$LIB/cert-hook.sh" || return 1
  fi
  [[ -s $cdir/fullchain.pem && -s $cdir/privkey.pem ]] && chmod 600 "$cdir/privkey.pem"
}
cert_self() {
  local cdir san
  san="DNS:$(srv_domain)"
  cdir=$(cert_dir)
  [[ -n ${CFG[DECOY_DOMAIN]:-} ]] && san+=",DNS:${CFG[DECOY_DOMAIN]}"
  install -d -m 700 "$ETC/certs" "$cdir"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 90 -subj "/CN=$(srv_domain)" \
    -addext "subjectAltName=$san" -keyout "$cdir/privkey.pem" -out "$cdir/fullchain.pem" && chmod 600 "$cdir/privkey.pem"
  cert_hook_write
}
cert_renew_check() { if [[ $(cf CERT_CLIENT) == certbot ]]; then "$(certbot_bin)" renew; else "$ACME_BIN" --home "$ACME_HOME" --cron; fi; }
cert_renew_force() { if [[ $(cf CERT_CLIENT) == certbot ]]; then "$(certbot_bin)" renew --force-renewal; else "$ACME_BIN" --home "$ACME_HOME" --renew -d "$(srv_domain)" --force; fi; }

# ── пользователи, ссылки, ключ шлюза ─────────────────────────────────────────
tt_link() {
  local out l args=("$TT_DIR/vpn.toml" "$TT_DIR/hosts.toml" -c "$1" -a "$(srv_domain):$(srv_port)" --name "$(srv_domain)" --format deeplink)
  [[ -n $(cf APP_DNS) ]] && args+=(--dns-upstream "$(cf APP_DNS)")
  out=$(cd "$TT_DIR" && ./trusttunnel_endpoint "${args[@]}" 2>/dev/null) || return 1
  while IFS= read -r l; do [[ $l == tt://* ]] && { printf '%s\n' "$l"; return 0; }; done <<<"$out"   # без конвейера: SIGPIPE
  return 1
}
tt_export() { (cd "$TT_DIR" && ./trusttunnel_endpoint "$TT_DIR/vpn.toml" "$TT_DIR/hosts.toml" -c "$1" -a "$(srv_domain):$(srv_port)" --format toml 2>/dev/null); }
gw_key() { tt_export "$1" | py key-encode; }
show_user() {
  local n=$1 l
  l=$(tt_link "$n") && [[ -n $l ]] || { err "Не удалось сформировать ссылку для $n"; return 1; }
  card "Пользователь $n"
  KV_W=9 kv "Сервер" "$(srv_domain):$(srv_port)"
  KV_W=9 kv "Логин" "$n"
  KV_W=9 kv "Пароль" "$(creds get "$n" 2>/dev/null)"
  card_end
  printf '\n  %s\n' "$l"
  command -v qrencode >/dev/null 2>&1 && { echo; qrencode -t ansiutf8 -m 2 "$l" 2>/dev/null | sed 's/^/  /'; }
  note "Приложение TrustTunnel или AdGuard VPN: «Добавить по ссылке» или отсканируйте QR-код."
}
show_key() {
  local k; k=$(gw_key "$1") || { err "Не удалось сформировать ключ"; return 1; }
  card "Ключ подключения шлюза · $1"
  card_line "На шлюзе запустите установку и вставьте эту строку, когда она спросит"
  card_line "«Ключ подключения» (на готовом шлюзе: tt → Сменить сервер)."
  card_end
  printf '\n%s\n\n' "$k"
  note "В ключе пароль — не публикуйте его. Показать снова: tt key $1"
}
pick_user() { local -a us; mapfile -t us < <(user_names); pick_from "$1" "${2:-Пользователь}" "${us[@]}"; }
users_table() { C_OK="$c_ok" C_DIM="$c_dim" C_0="$c_0" py users; }

u_add() {
  local n=${1:-} p=${2:-} b
  if [[ -z $n ]]; then
    note "Латиница, цифры, точка, _ и -. Для шлюза удобно отдельное имя, например gw."
    ask n "Имя нового пользователя" "" "$NAME_RE" "До 32 символов: латиница, цифры, . _ -"
  fi
  creds exists "$n" 2>/dev/null && die "Пользователь $n уже есть"
  b=$(creds_backup)
  creds add "$n" "$p" >/dev/null || return 1
  srv_restart_checked "$b" || return 1
  ok "Пользователь $n добавлен"
  show_user "$n"
}
u_del() {
  local n=${1:-} b
  [[ -n $n ]] || { pick_user n "Кого удалить" && yesno "Удалить $n? Его устройства отключатся" n; } || return 0
  creds exists "$n" 2>/dev/null || die "Пользователя «$n» нет"
  b=$(creds_backup)
  creds del "$n" || return 1
  srv_restart_checked "$b" && ok "Пользователь $n удалён"
}
u_pass() {
  local n=${1:-} p=${2:-} b
  [[ -n $n ]] || pick_user n "Чей пароль сменить" || return 1
  creds exists "$n" 2>/dev/null || die "Пользователя «$n» нет"
  b=$(creds_backup)
  creds passwd "$n" "$p" >/dev/null || return 1
  srv_restart_checked "$b" || return 1
  ok "Пароль $n изменён — прежние ссылки больше не работают"
  show_user "$n"
}
u_limits() {
  local n h2 h3 b
  pick_user n "Кому задать лимит" || return 1
  note "Сколько одновременных подключений разрешено (0 — без ограничений)."
  ask h2 "HTTP/2 (TCP)" "0" '^[0-9]{1,4}$' "Число от 0 до 1000"
  ask h3 "HTTP/3 (QUIC)" "0" '^[0-9]{1,4}$' "Число от 0 до 1000"
  b=$(creds_backup)
  creds limits "$n" "$h2" "$h3" || return 1
  srv_restart_checked "$b" && ok "Лимиты $n заданы"
}

# ── настройки ────────────────────────────────────────────────────────────────
srv_set() { # srv_set КЛЮЧ ЗНАЧЕНИЕ … — изменить и применить; при сбое вернуть прежнее
  local -A old=(); local k
  for ((k = 1; k < $#; k += 2)); do old[${!k}]=${CFG[${!k}]:-}; done
  conf_set "$@"
  srv_apply && return 0
  for k in "${!old[@]}"; do conf_set "$k" "${old[$k]}"; done
  srv_apply >>"$LOG" 2>&1 || true
  return 1
}
s_dns() {
  dns_explain_app; note "Сейчас: $(dns_name "$(cf APP_DNS)")"
  APP_DNS=$(cf APP_DNS); pick_app_dns
  [[ $APP_DNS == "$(cf APP_DNS)" ]] && { note "Без изменений"; return 0; }
  conf_set APP_DNS "$APP_DNS"
  ok "DNS для приложений: $(dns_name "$APP_DNS")"
  note "Он попадает в ссылки: отправьте пользователям новые (пункт «Ссылка и QR-код»)."
}
s_theme() {
  local t
  section "Сайт-заглушка" "Его видит любой, кто откроет https://$(cf DECOY_DOMAIN "$(srv_domain)") в браузере." "Сейчас: $(theme_name "$(cf THEME)")"
  choose_theme t "$(cf THEME random)"
  conf_set THEME "$t"
  srv_decoy && ok "Сайт обновлён: $(theme_name "$t")"
}
s_authcode() {
  local v
  section "Ответ на чужие запросы" "Что сервер отвечает на попытку подключиться без пароля (в том числе CONNECT)." \
    "404 выглядит как обычный сайт; 407 — стандартный ответ прокси, он выдаёт VPN." "Сейчас: $(cf AUTH_CODE 404)"
  choose v "" "$(cf AUTH_CODE 404)" \
    "404|404 Not Found|как у обычного сайта · рекомендуется" \
    "403|403 Forbidden|доступ запрещён" \
    "405|405 Method Not Allowed|метод не поддерживается" \
    "407|407 Proxy Auth Required|только если старое приложение не подключается"
  [[ $v == "$(cf AUTH_CODE 404)" ]] && { note "Без изменений"; return 0; }
  run "Применение" srv_set AUTH_CODE "$v" && ok "Ответ на чужие запросы: $v"
}
deny_list() { grep -vE '^\s*(#|$)' "$ETC/deny.list" 2>/dev/null || true; }
s_deny() {
  local c a
  while :; do
    section "Запрещённые адреса" "Сети, куда пользователи VPN не смогут подключаться (например, локальная сеть сервера)." \
      "Служебные 169.254.0.0/16 и fe80::/10 запрещены всегда."
    if [[ -n $(deny_list) ]]; then deny_list | sed 's/^/    /'; else note "  своих запретов нет"; fi
    echo; MI_W=28
    mi 1 "Запретить сеть или адрес"; mi 2 "Снять запрет"; mi 0 "Назад"
    mpick c
    case $c in
      1) a=; ask a "Сеть или адрес (например 192.168.0.0/16)" "" '^[0-9a-fA-F:.]+(/[0-9]{1,3})?$' "Нужен IP-адрес или сеть"
         grep -qxF "$a" "$ETC/deny.list" 2>/dev/null || echo "$a" >>"$ETC/deny.list"
         run "Применение" srv_apply && ok "Запрещено: $a" ;;
      2) a=; ask a "Какой запрет снять" "" '^[0-9a-fA-F:./]+$' "Введите адрес из списка"
         grep -qxF "$a" "$ETC/deny.list" 2>/dev/null || { warn "Такой записи нет"; continue; }
         grep -vxF "$a" "$ETC/deny.list" >"$ETC/deny.list.new"; mv -f "$ETC/deny.list.new" "$ETC/deny.list"
         run "Применение" srv_apply && ok "Запрет снят: $a" ;;
      0|"") return 0 ;;
      *) warn "Введите 0, 1 или 2" ;;
    esac
  done
}
s_cert() {
  section "Сертификат" "$(cert_label) · $(srv_domain)${CFG[DECOY_DOMAIN]:+, ${CFG[DECOY_DOMAIN]}} · осталось $(cert_days) дн." \
    "Продлевается сам (проверка раз в сутки); сервер подхватывает его без разрыва подключений."
  [[ $(cf CERT_CLIENT) == self ]] && { note "Тестовый сертификат не продлевается."; return 0; }
  echo; MI_W=24
  mi 1 "Проверить продление" "продлит, только если пора"
  mi 2 "Перевыпустить сейчас" "расходует квоту Let's Encrypt"
  mi 0 "Назад"
  local c; mpick c
  case $c in
    1) run "Проверка продления сертификата" cert_renew_check ;;
    2) yesno "Перевыпустить? У Let's Encrypt лимит — 5 одинаковых сертификатов в неделю" n && run "Перевыпуск сертификата" cert_renew_force ;;
  esac
  return 0
}

# ── состояние, обновление, удаление ──────────────────────────────────────────
srv_status() {
  local c d ip dnsip
  section "Сервер $(srv_domain)"
  KV_W=16
  kv "TrustTunnel" "$(dot_state trusttunnel) · $(bin_version "$TT_DIR")"
  kv "Адрес" "$(srv_domain):$(srv_port) (TCP + UDP)"
  kv "Пользователи" "$(creds count) · онлайн $(py users --online)"
  kv "DNS приложений" "$(dns_name "$(cf APP_DNS)")"
  kv "Сертификат" "$(cert_label) · $(cert_days) дн."
  section "Проверки"
  chk() { if eval "$2"; then ok "$1"; else err "$1"; fi; }
  chk "TrustTunnel работает" 'systemctl is-active --quiet trusttunnel'
  chk "Порт $(srv_port): TCP (HTTP/2) и UDP (HTTP/3)" 'ss -Hlnt "sport = :$(srv_port)" | grep -q . && ss -Hlnu "sport = :$(srv_port)" | grep -q .'
  chk "nginx работает (сайт и продление сертификата)" 'systemctl is-active --quiet nginx'
  for d in "$(srv_domain)" ${CFG[DECOY_DOMAIN]:+"${CFG[DECOY_DOMAIN]}"}; do
    c=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$d:$(srv_port):127.0.0.1" "https://$d:$(srv_port)/" 2>/dev/null || true)
    chk "https://$d открывается как обычный сайт" '[[ $c == 200 ]]'
  done
  if [[ $(cf CERT_CLIENT) != self ]]; then
    ip=$(public_ip)
    for d in "$(srv_domain)" ${CFG[DECOY_DOMAIN]:+"${CFG[DECOY_DOMAIN]}"}; do
      dnsip=$(resolve4 "$d")
      chk "DNS: $d → ${dnsip:-нет записи}" '[[ -n $ip && $dnsip == "$ip" ]]'
    done
  fi
  section "Подключения"; users_table
}
# shellcheck disable=SC2120  # необязательный аргумент — версия
srv_update() {
  local cur want
  cur=$(bin_version "$TT_DIR"); want=${1:-$(gh_latest TrustTunnel/TrustTunnel)}
  section "Обновление TrustTunnel" "Установлено: $cur · последняя стабильная: ${want:-не удалось узнать}"
  [[ -n $want ]] || return 1
  want="v${want#v}"
  [[ $want == "$cur" ]] && { ok "Уже последняя версия"; return 0; }
  local bk; bk=$(mktemp -d)
  cp -a "$TT_DIR"/trusttunnel_endpoint* "$TT_DIR/VERSION" "$bk/" 2>/dev/null
  if ! run "Загрузка и проверка подписи $want" bin_install server "$want"; then rm -rf "${bk:?}"; warn "Обновление не удалось — оставлена $cur"; return 1; fi
  systemctl restart trusttunnel >>"$LOG" 2>&1
  if srv_health; then rm -rf "${bk:?}"; conf_set TT_VERSION "$want"; ok "TrustTunnel обновлён: $cur → $want"; return 0; fi
  cp -a "$bk"/. "$TT_DIR"/; rm -rf "${bk:?}"; systemctl restart trusttunnel >>"$LOG" 2>&1
  warn "Версия $want не заработала — возвращена $cur"; return 1
}
srv_uninstall() {
  local b
  section "Удаление сервера" "Будут остановлены и удалены TrustTunnel, сайт-заглушка и настройки tt." \
    "Копия настроек, пользователей и сертификата останется в /root."
  yesno "Удалить сервер TrustTunnel с этого VPS?" n || return 0
  b=/root/tt-backup-$(date +%Y%m%d-%H%M%S); install -d -m 700 "$b"
  cp -a "$ETC" "$b/etc-tt" 2>/dev/null; cp -a "$TT_DIR/credentials.toml" "$b/" 2>/dev/null
  systemctl disable --now trusttunnel tt-cert.timer >>"$LOG" 2>&1 || true
  rm -f /etc/systemd/system/trusttunnel.service /etc/systemd/system/tt-cert.service /etc/systemd/system/tt-cert.timer
  systemctl daemon-reload
  [[ -f $ETC/nginx.conf.orig ]] && cp -a "$ETC/nginx.conf.orig" /etc/nginx/nginx.conf && { nginx -t >>"$LOG" 2>&1 && systemctl reload-or-restart nginx >>"$LOG" 2>&1 || true; }
  fw_close "$(srv_port)/tcp" "$(srv_port)/udp"
  rm -rf "${TT_DIR:?}" "${DECOY_ROOT:?}" "${ACME_ROOT:?}" "${ETC:?}" "${STATE:?}" "${LIB:?}"
  ok "Сервер удалён. Копия настроек: $b"
  note "acme.sh/certbot и nginx оставлены (могут использоваться другими сайтами). Команда tt удалится последней."
  rm -f "$BIN"
}

# ── установка ────────────────────────────────────────────────────────────────
srv_preflight_ports() {
  local p who svc
  for p in 80 443; do
    who=$(port_users tcp "$p")
    [[ -z $who || $who == *nginx* || $who == *trusttunnel* ]] && continue
    warn "Порт $p/tcp занят: $who"
    svc=; case $who in *apache2*) svc=apache2 ;; *httpd*) svc=httpd ;; esac
    if [[ -n $svc ]] && yesno "Остановить и отключить $svc? Порты 80 и 443 нужны серверу" n; then
      systemctl disable --now "$svc" >>"$LOG" 2>&1 || true; sleep 1
      [[ -z $(port_users tcp "$p") ]] && { ok "$svc остановлен и отключён"; continue; }
    fi
    yesno "Продолжить с занятым портом? Сервер может не запуститься" n || die "Освободите порт $p и запустите установку снова"
  done
  who=$(port_users udp 443)
  [[ -n $who && $who != *trusttunnel* ]] && warn "Порт 443/udp занят ($who) — HTTP/3 работать не будет"
  ok "Порты 80 и 443 свободны"
}
norm_domain() { local d=${1,,}; d=${d//[[:space:]]/}; d=${d#http://}; d=${d#https://}; d=${d%%/*}; d=${d%%:*}; printf '%s' "${d%.}"; }
v_domain() { [[ $(norm_domain "$1") =~ $DOMAIN_RE ]]; }
v_domain_or_dash() { [[ $1 == - ]] || v_domain "$1"; }
v_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
v_users() { local n seen=" "; for n in $1; do [[ $n =~ $NAME_RE && $seen != *" $n "* ]] || return 1; seen+="$n "; done; [[ $seen != " " ]]; }

srv_questions() {
  local ip r existing t dd p ac
  ip=$(public_ip)
  section "Домен" \
    "Создайте у регистратора A-запись: домен → ${ip:-IP этого сервера}." \
    "По этому имени подключается VPN, а посторонние видят обычный сайт." \
    "Лучше нейтральное имя: www, cdn, mail. В Cloudflare — режим «DNS only»."
  DOMAIN=${DOMAIN:-}; [[ -n $DOMAIN ]] || DOMAIN=
  ask DOMAIN "Домен сервера" "$(cf DOMAIN)" "" "Нужно доменное имя, например www.example.com" v_domain
  DOMAIN=$(norm_domain "$DOMAIN")
  r=$(resolve4 "$DOMAIN")
  if [[ -n $r && $r == "$ip" ]]; then ok "$DOMAIN → $r"
  else warn "$DOMAIN пока указывает ${r:+на $r}${r:-в никуда}. Создайте запись — проверю ещё раз перед выпуском сертификата."; fi

  EMAIL=${EMAIL:-}
  if [[ ${CERT_SELF_SIGNED:-0} != 1 ]]; then
    section "E-mail" "Let's Encrypt напишет, если с сертификатом что-то пойдёт не так. Можно пропустить."
    ask EMAIL "E-mail" "$(cf EMAIL)" '^([^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+)?$' "Похоже, в адресе ошибка"
  fi

  existing=$(user_names | tr '\n' ' ' | sed 's/ $//')
  if [[ -n $existing ]]; then
    USERS=; section "Пользователи"; ok "Сохраняются: $existing"
  else
    section "Пользователи" "Имена через пробел — каждому своя ссылка и пароль." \
      "Для шлюза заведите отдельного пользователя, например gw."
    USERS=${USERS:-}; ask USERS "Пользователи" "phone gw" "" "Латиница, цифры, . _ - (до 32 символов), без повторов" v_users
  fi

  dns_explain_app
  if [[ -n ${APP_DNS:-} ]]; then ok "DNS: $(dns_name "$APP_DNS")"
  else APP_DNS=$(cf APP_DNS); [[ -f $CONF ]] || APP_DNS=; pick_app_dns cloudflare; fi

  PORT=${PORT:-$(cf PORT 443)}; THEME=${THEME:-$(cf THEME random)}; ACME_CLIENT=${ACME_CLIENT:-$(cf ACME_CLIENT acme)}
  DECOY_DOMAIN=${DECOY_DOMAIN:-$(cf DECOY_DOMAIN)}
  echo
  if yesno "Дополнительные параметры (порт, сайт-заглушка, сертификаты)?" n; then
    section "Порт" "443 — как у любого сайта. Другой порт заметнее."
    p=$PORT; PORT=; ask PORT "Порт" "$p" "" "Число от 1 до 65535" v_port; PORT=$((10#$PORT))
    section "Сайт-заглушка" "Его видит любой, кто откроет домен в браузере."
    t=$THEME; THEME=; choose_theme THEME "$t"
    section "Второе имя для сайта" "Обычно не нужно: сайт открывается по тому же домену." \
      "Если указать второе имя, оба попадут в сертификат. «-» — не нужно."
    dd=${DECOY_DOMAIN:--}; DECOY_DOMAIN=; ask DECOY_DOMAIN "Второе имя" "$dd" "" "Доменное имя или «-»" v_domain_or_dash
    if [[ ${CERT_SELF_SIGNED:-0} != 1 ]]; then
      section "Программа для сертификатов"
      ac=$ACME_CLIENT; ACME_CLIENT=
      choose ACME_CLIENT "" "$ac" "acme|acme.sh|лёгкая, без лишних пакетов · рекомендуется" "certbot|certbot|официальный клиент Let's Encrypt"
    fi
  fi
  [[ $DECOY_DOMAIN == - ]] && DECOY_DOMAIN=
  DECOY_DOMAIN=$(norm_domain "$DECOY_DOMAIN"); [[ $DECOY_DOMAIN == "$DOMAIN" ]] && DECOY_DOMAIN=
  [[ $PORT == 443 ]] || warn "Порт $PORT: проверка Let's Encrypt всё равно идёт через 80/tcp"

  card "Проверьте настройки"
  kv "Сервер" "$DOMAIN:$PORT  (TCP + UDP)"
  kv "Сайт-заглушка" "https://${DECOY_DOMAIN:-$DOMAIN} · тема: $(theme_name "$THEME")"
  if [[ ${CERT_SELF_SIGNED:-0} == 1 ]]; then kv "Сертификат" "самоподписанный (тестовый стенд)"
  else kv "Сертификат" "Let's Encrypt · $([[ $ACME_CLIENT == certbot ]] && echo certbot || echo acme.sh)${EMAIL:+ · $EMAIL}"; fi
  kv "Пользователи" "${USERS:-$existing}"
  kv "DNS приложений" "$(dns_name "$APP_DNS")"
  kv "TrustTunnel" "${TT_VERSION:-последняя стабильная версия}"
  card_end
  echo
  yesno "Начать установку?" y || die "Отменено — ничего не изменено"
}

srv_install() {
  steps 7
  step "Проверка системы"
  ok "$(sys_line)"
  arch >/dev/null || die "Процессор $(uname -m) не поддерживается: нужен x86_64 или aarch64"
  srv_preflight_ports
  srv_questions
  conf_set ROLE server DOMAIN "$DOMAIN" DECOY_DOMAIN "$DECOY_DOMAIN" PORT "$PORT" EMAIL "$EMAIL" ACME_CLIENT "$ACME_CLIENT" \
    THEME "$THEME" APP_DNS "$APP_DNS" AUTH_CODE "$(cf AUTH_CODE 404)" \
    IPV6 "$(ipv6_ok && echo 1 || echo 0)"

  step "Подготовка системы"
  ensure_swap
  run "Установка пакетов (nginx, python3, openssl, gnupg)" srv_pkgs || die "Пакеты не установились"
  [[ -f $ETC/nginx.conf.orig || ! -f /etc/nginx/nginx.conf ]] || cp -a /etc/nginx/nginx.conf "$ETC/nginx.conf.orig"
  if [[ ${CERT_SELF_SIGNED:-0} != 1 ]]; then
    if [[ $ACME_CLIENT == certbot ]]; then run "Установка certbot" certbot_install || die "Не удалось установить certbot"
    else run "Установка acme.sh" acme_install || die "Не удалось установить acme.sh (нет доступа к github.com?)"; fi
  fi

  step "TrustTunnel"
  local ver=${TT_VERSION:-}
  if [[ -x $TT_DIR/trusttunnel_endpoint && -z $ver ]]; then ok "Уже установлен: $(bin_version "$TT_DIR") (обновление — в меню tt)"
  else
    [[ -n $ver ]] || ver=$(gh_latest TrustTunnel/TrustTunnel)
    if [[ -n $ver ]]; then ok "Версия: ${ver}"; else ver=$TT_PINNED; warn "GitHub не ответил — ставлю проверенную $ver"; fi
    run "Загрузка и проверка подписи" bin_install server "v${ver#v}" || die "Не удалось установить TrustTunnel"
    conf_set TT_VERSION "v${ver#v}"
  fi

  step "Сайт-заглушка"
  install -d -m 755 "$STATE" "$ACME_ROOT"
  srv_decoy || die "Не удалось создать сайт"
  ok "Сайт «${DECOY_INFO#* }» готов — $(theme_name "${DECOY_INFO%% *}")"
  local s; s=$(mktemp -d); srv_nginx_main >"$s/nginx.conf"
  apply_manifest "$s" "nginx.conf|/etc/nginx/nginx.conf|644|root:root|nginx" true || die "nginx не принял настройки. Журнал: $LOG"
  rm -rf "${s:?}"
  case $(fw_kind) in
    none) note "Файрвол не включён — проверьте, что у хостера открыты 80/tcp и $PORT tcp+udp" ;;
    *) fw_open 80/tcp "$PORT/tcp" "$PORT/udp"; ok "Файрвол: открыты 80/tcp и $PORT tcp+udp" ;;
  esac

  step "Сертификат"
  if [[ ${CERT_SELF_SIGNED:-0} == 1 ]]; then
    if [[ $(cf CERT_CLIENT) != self ]] || ! cert_names_ok; then run "Самоподписанный сертификат" cert_self || die "Не удалось создать сертификат"; else cert_hook_write; fi
    conf_set CERT_CLIENT self
    warn "Тестовый режим: самоподписанный сертификат (уходит в ссылки и ключ шлюза)"
  elif [[ $(cf CERT_CLIENT) == "$ACME_CLIENT" ]] && cert_names_ok && (( $(cert_days) > 20 )); then
    cert_hook_write; ok "Действующий сертификат: ещё $(cert_days) дн. — Let's Encrypt не трогаю"
  else
    local ip r bad d
    ip=$(public_ip)
    while :; do
      bad=0
      for d in "$DOMAIN" ${DECOY_DOMAIN:+"$DECOY_DOMAIN"}; do
        r=$(resolve4 "$d")
        if [[ -n $r && $r == "$ip" ]]; then ok "DNS: $d → $r"; else err "DNS: $d → ${r:-нет записи} (нужно $ip)"; bad=1; fi
      done
      (( bad )) || break
      note "  Let's Encrypt проверит домен по этой записи. Обычно она появляется за 1–10 минут."
      yesno "Проверить ещё раз?" y || die "Создайте A-запись и запустите установку снова"
    done
    until run "Выпуск сертификата Let's Encrypt" cert_issue; do
      note "  Частые причины: закрыт 80/tcp у хостера, домен за CDN-прокси, запись ещё не обновилась."
      yesno "Попробовать ещё раз?" y || die "Без сертификата сервер не запустится. Исправьте и запустите установку снова"
    done
    conf_set CERT_CLIENT "$ACME_CLIENT"
    ok "Сертификат на $(cert_days) дн., продлевается сам"
  fi

  step "Запуск сервера"
  local u
  for u in $USERS; do creds exists "$u" 2>/dev/null || { creds add "$u" >/dev/null && ok "Пользователь $u создан"; }; done
  [[ $(creds count) -gt 0 ]] || die "Нет ни одного пользователя"
  run "Настройка и запуск TrustTunnel" srv_apply || die "Сервер не запустился. Журнал: $LOG"
  systemctl enable trusttunnel >>"$LOG" 2>&1
  [[ -f /etc/systemd/system/tt-cert.timer ]] && systemctl enable --now tt-cert.timer >>"$LOG" 2>&1
  ok "TrustTunnel слушает $PORT: HTTP/2 (TCP) и HTTP/3 (QUIC)"

  step "Проверка"
  srv_status >/dev/null 2>&1 || true
  srv_health && ok "Сервер отвечает, сайт-заглушка открывается" || warn "Проверьте состояние: tt status"

  printf '\n  %s✓ Сервер TrustTunnel готов%s\n' "$c_ok$c_b" "$c_0"
  card "Сервер"
  kv "Адрес" "$DOMAIN:$PORT"
  kv "Сайт" "https://${DECOY_DOMAIN:-$DOMAIN} — обычный сайт для посторонних"
  kv "Сертификат" "$(cert_label)"
  kv "Управление" "tt"
  kv "Журнал" "$LOG"
  card_end
  note "Маскировка: сервер выглядит как обычный сайт, но при пристальном анализе (объём и время трафика,"
  note "отпечаток TLS) VPN можно распознать. Это свойство любого VPN, а не настройки."
  local gw=''
  for u in $(user_names); do
    case $u in gw|gateway|router) gw=$u; continue ;; esac
    show_user "$u"
  done
  if [[ -n $gw ]]; then show_key "$gw"; else echo; note "Для шлюза: tt key ИМЯ — ключ подключения одной строкой."; fi
}
srv_pkgs() {
  case $PM in
    apt) pkg_install curl tar gnupg ca-certificates nginx python3 openssl iproute2; pkg_install qrencode || true ;;
    dnf) pkg_install epel-release || true
         pkg_install curl tar gnupg2 ca-certificates nginx python3 openssl iproute; pkg_install qrencode policycoreutils-python-utils || true ;;
  esac
  local m; for m in nginx python3 openssl curl gpg ss; do command -v "$m" >/dev/null 2>&1 || { echo "нет $m"; return 1; }; done
}

# ── меню ─────────────────────────────────────────────────────────────────────
srv_settings_menu() {
  local c
  while :; do
    cls; banner "TrustTunnel" "настройки · $(srv_domain)"
    MI_W=32
    mi 1 "DNS для приложений" "$(dns_name "$(cf APP_DNS)")"
    mi 2 "Сайт-заглушка" "$(theme_name "$(cf THEME)")"
    mi 3 "Ответ на чужие запросы" "$(cf AUTH_CODE 404)"
    mi 4 "Лимит подключений пользователя"
    mi 5 "Запрещённые адреса" "$(deny_list | wc -l)"
    mi 6 "Сертификат" "$(cert_days) дн."
    mi 0 "Назад"
    mpick c
    case $c in
      1) (s_dns) ;; 2) (s_theme) ;; 3) (s_authcode) ;; 4) (u_limits) ;;
      5) (s_deny); conf_load; continue ;; 6) (s_cert) ;;
      0|"") return 0 ;;
      *) warn "Введите число от 0 до 6"; sleep 1; continue ;;
    esac
    conf_load; pause
  done
}
srv_menu() {
  local c n
  while :; do
    cls; banner "TrustTunnel" "сервер · $(srv_domain)"
    printf '  %s  %s%s · %s польз. · онлайн %s · сертификат %s дн.%s\n' "$(dot_state trusttunnel)" "$c_dim" \
      "$(bin_version "$TT_DIR")" "$(creds count)" "$(py users --online)" "$(cert_days)" "$c_0"
    MI_W=26
    mhead "Пользователи"
    mi 1 "Список и подключения"; mi 2 "Добавить"; mi 3 "Ссылка и QR-код"; mi 4 "Ключ для шлюза"
    mi 5 "Сменить пароль"; mi 6 "Удалить"
    mhead "Сервер"
    mi 7 "Проверка состояния"; mi 8 "Настройки" "DNS, сайт, сертификат ›"; mi 9 "Обслуживание" "обновления, журнал ›"
    mi 0 "Выход"
    mpick c
    case $c in
      1) echo; users_table ;;
      2) (u_add) ;;
      3) pick_user n "Чью ссылку показать" && (show_user "$n") ;;
      4) note "Ключ переносит на шлюз адрес сервера, логин и пароль одной строкой."; pick_user n "Для какого пользователя" && (show_key "$n") ;;
      5) (u_pass) ;;
      6) (u_del) ;;
      7) srv_status ;;
      8) srv_settings_menu; continue ;;
      9) maint_menu; continue ;;
      0|q|Q) echo; exit 0 ;;
      *) warn "Введите число от 0 до 9"; sleep 1; continue ;;
    esac
    conf_load; pause
  done
}
