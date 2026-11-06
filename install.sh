#!/usr/bin/env bash
#
#  Установка TrustTunnel (сервер или шлюз) одной командой, под root:
#
#    bash <(curl -fsSL https://raw.githubusercontent.com/fLex0id/trusttunnel-gateway/main/install.sh)
#
#  Скачивает tt из последнего релиза, сверяет SHA256, ставит в /usr/local/sbin/tt и запускает установку.
#  Конкретная версия: TT_RELEASE=v3.0.0 bash <(curl …)
#
# Весь код — внутри main: если загрузка оборвётся, недокачанный скрипт ничего не выполнит.
main() {
  set -euo pipefail
  local repo=fLex0id/trusttunnel-gateway rel=${TT_RELEASE:-latest} base tmp
  if [[ $EUID -ne 0 ]]; then
    echo "Нужны права root. Войдите как root (sudo -i) и повторите команду." >&2
    exit 1
  fi
  for c in curl sha256sum install; do
    command -v "$c" >/dev/null 2>&1 || { echo "Не найдена программа $c" >&2; exit 1; }
  done
  if [[ $rel == latest ]]; then base=https://github.com/$repo/releases/latest/download
  else base=https://github.com/$repo/releases/download/$rel; fi
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  echo "  Загрузка tt ($rel)…"
  curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp/tt.sh" "$base/tt.sh"
  curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp/tt.sh.sha256" "$base/tt.sh.sha256"
  if ! (cd "$tmp" && sha256sum -c --status tt.sh.sha256); then
    echo "Контрольная сумма не совпала — файл повреждён или подменён. Установка отменена." >&2
    exit 1
  fi
  install -d -m 755 /usr/local/sbin
  install -m 0755 "$tmp/tt.sh" /usr/local/sbin/tt
  exec /usr/local/sbin/tt install </dev/tty
}
main "$@"
