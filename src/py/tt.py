#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tt.py — генераторы конфигураций и служебные операции для tt (сервер и шлюз TrustTunnel).

Все настройки берутся из /etc/tt/tt.conf (единственный источник правды). Генераторы ничего
не меняют в системе: они пишут файлы в указанный каталог, а bash-часть (tt apply) сравнивает,
проверяет и атомарно подменяет рабочие конфиги с откатом при сбое.

Совместимо с Python 3.9+ (Rocky Linux 9) и без сторонних модулей.
"""
import base64
import hashlib
import html
import ipaddress
import json
import os
import random
import re
import secrets
import shutil
import socket
import string
import struct
import sys
import tempfile
import time
import zlib
from urllib.parse import urlsplit

ETC = os.environ.get("TT_ETC", "/etc/tt")
CONF = os.path.join(ETC, "tt.conf")
TT_DIR = "/opt/trusttunnel"
TTC_DIR = "/opt/trusttunnel_client"
RULES_DIR = "/var/lib/tt/rulesets"
EP_FILE = os.path.join(ETC, "endpoint.json")
PIN_FILE = os.path.join(ETC, "endpoint.ip")
PEERS_DIR = os.path.join(ETC, "peers")
EXC_DIRECT = os.path.join(ETC, "ru-direct.list")
EXC_PROXY = os.path.join(ETC, "ru-proxy.list")
DENY_LIST = os.path.join(ETC, "deny.list")
TEST_PORT = 18080
SOCKS_PORT = 1080
METRICS_PORT = 1987
DECOY_PORT = 8008          # входит в http_port_t (SELinux на Rocky)
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$")
HOST_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$")


# ── общее ─────────────────────────────────────────────────────────────────────
def die(msg, code=1):
    sys.stderr.write("Ошибка: %s\n" % msg)
    sys.exit(code)


def warn(msg):
    sys.stderr.write("Предупреждение: %s\n" % msg)


def load_conf(path=CONF):
    """KEY="value" построчно; кавычки и экранирование — как пишет tt (без подстановок shell)."""
    conf = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                conf[k.strip()] = v
    except OSError:
        pass
    return conf


def read_text(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def is_ip(text):
    try:
        ipaddress.ip_address(str(text).strip("[]"))
        return True
    except ValueError:
        return False


def write_file(path, text, mode=0o644):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tt.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def toml_val(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "[" + ", ".join(toml_val(x) for x in v) + "]"
    die("неподдерживаемое значение: %r" % (v,))


def toml_loads(text):
    """TOML: стандартный tomllib (3.11+) либо упрощённый разбор для экспорта TrustTunnel
    (ключ = строка / многострочная строка / число / true|false / массив строк, таблицы [x])."""
    try:
        import tomllib  # noqa: WPS433
        return tomllib.loads(text)
    except ImportError:
        pass
    data, cur = {}, None
    cur = data
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        i += 1
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            name = line.strip("[]").strip()
            cur = data.setdefault(name, {})
            continue
        if "=" not in line:
            raise ValueError("строка %d: ожидалось ключ = значение" % i)
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip()
        if v.startswith('"""') or v.startswith("'''"):
            q = v[:3]
            body = v[3:]
            if body.startswith("\n"):
                body = body[1:]
            buf = []
            if q in body:
                cur[k] = body.split(q, 1)[0]
                continue
            if body:
                buf.append(body)
            while i < len(lines):
                ln = lines[i]
                i += 1
                if q in ln:
                    buf.append(ln.split(q, 1)[0])
                    break
                buf.append(ln)
            cur[k] = "\n".join(buf)
            continue
        if v.startswith('"'):
            end = 1
            while end < len(v):
                if v[end] == "\\":
                    end += 2
                    continue
                if v[end] == '"':
                    break
                end += 1
            cur[k] = json.loads(v[: end + 1])
        elif v.startswith("'"):
            cur[k] = v[1: v.index("'", 1)]
        elif v.startswith("["):
            body = v.split("#", 1)[0].strip()
            cur[k] = json.loads(body.replace("'", '"')) if body != "[]" else []
        else:
            v = v.split("#", 1)[0].strip()
            if v in ("true", "false"):
                cur[k] = v == "true"
            elif re.fullmatch(r"[+-]?\d+", v):
                cur[k] = int(v)
            else:
                cur[k] = v
    return data


def human(n):
    n = float(n)
    for u in ("Б", "КБ", "МБ", "ГБ", "ТБ"):
        if n < 1024:
            return ("%.0f %s" if u == "Б" else "%.1f %s") % (n, u)
        n /= 1024.0
    return "%.1f ПБ" % n


def colors():
    e = os.environ
    return e.get("C_OK", ""), e.get("C_DIM", ""), e.get("C_0", "")


# ══ СЕРВЕР ═══════════════════════════════════════════════════════════════════
BASE_VPN = """# Создано tt. Не правьте вручную: изменения делаются через tt и /etc/tt/tt.conf.
tls_handshake_timeout_secs = 10
client_listener_timeout_secs = 600
connection_establishment_timeout_secs = 30
tcp_connections_timeout_secs = 604800
udp_connections_timeout_secs = 300

[listen_protocols.http1]

[listen_protocols.http2]

[listen_protocols.quic]

[forward_protocol]
direct = {}
"""
DEFAULT_DENY = ["169.254.0.0/16", "fe80::/10"]


def cert_dir(conf):
    return os.path.join(ETC, "certs", conf.get("DOMAIN", ""))


def render_server(out):
    c = load_conf()
    dom = c.get("DOMAIN", "")
    if not dom:
        die("в tt.conf не задан DOMAIN")
    port = int(c.get("PORT", "443") or 443)
    code = c.get("AUTH_CODE", "404")
    code = code if code in ("403", "404", "405", "407") else "404"
    head = [
        'listen_address = "0.0.0.0:%d"' % port,
        "ipv6_available = %s" % ("true" if c.get("IPV6") == "1" else "false"),
        "allow_private_network_connections = false",
        'credentials_file = "%s/credentials.toml"' % TT_DIR,
        'rules_file = "%s/rules.toml"' % TT_DIR,
        "speedtest_enable = false",
        "ping_enable = false",
        # 404 и для CONNECT: стандартный 407 «Proxy Authentication Required» сразу выдаёт прокси
        "non_connect_auth_failure_status_code = %s" % code,
        "auth_failure_status_code = %s" % code,
    ]
    tail = (
        '\n[reverse_proxy]\nserver_address = "127.0.0.1:%d"\npath_mask = "/"\nh3_backward_compatibility = true\n'
        '\n[metrics]\naddress = "127.0.0.1:%d"\nrequest_timeout_secs = 3\nper_client_metrics = true\n'
        % (DECOY_PORT, METRICS_PORT)
    )
    lines = BASE_VPN.splitlines()
    vpn = "\n".join(lines[:1] + head + lines[1:]).rstrip("\n") + "\n" + tail
    write_file(os.path.join(out, "vpn.toml"), vpn, 0o600)

    cd = cert_dir(c)
    hosts = '[[main_hosts]]\nhostname = "%s"\ncert_chain_path = "%s/fullchain.pem"\nprivate_key_path = "%s/privkey.pem"\n' % (dom, cd, cd)
    dd = c.get("DECOY_DOMAIN", "")
    if dd and dd != dom:
        hosts += '\n[[reverse_proxy_hosts]]\nhostname = "%s"\ncert_chain_path = "%s/fullchain.pem"\nprivate_key_path = "%s/privkey.pem"\n' % (dd, cd, cd)
    write_file(os.path.join(out, "hosts.toml"), hosts, 0o600)

    seen, rules = set(), []
    for net in DEFAULT_DENY + read_cidrs(DENY_LIST):
        if net not in seen:
            seen.add(net)
            rules.append('[[rule]]\ncidr = "%s"\naction = "deny"\n' % net)
    write_file(os.path.join(out, "rules.toml"),
               "# Создано tt: сети, недоступные пользователям VPN (tt → Настройки → Запрещённые адреса).\n\n"
               + "\n".join(rules), 0o600)


def read_cidrs(path):
    res = []
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                s = raw.split("#", 1)[0].strip()
                if not s:
                    continue
                try:
                    res.append(str(ipaddress.ip_network(s, strict=False)))
                except ValueError:
                    warn("пропущен некорректный адрес в %s: %s" % (path, s))
    except OSError:
        pass
    return res


# ── пользователи (credentials.toml TrustTunnel) ──────────────────────────────
CREDS = os.path.join(TT_DIR, "credentials.toml")


def creds_load():
    if not os.path.exists(CREDS):
        return []
    clients, cur = [], None
    for raw in read_text(CREDS).splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.split("#", 1)[0].strip() == "[[client]]":
            cur = {}
            clients.append(cur)
            continue
        if line.startswith("["):
            cur = None
            continue
        m = re.match(r"^([A-Za-z0-9_]+)\s*=\s*(.+)$", line)
        if cur is not None and m:
            v = m.group(2).strip()
            if v.startswith('"'):
                v = json.loads(v[: v.rindex('"') + 1])
            elif v.startswith("'"):
                v = v[1: v.index("'", 1)]
            else:
                v = v.split("#", 1)[0].strip()
            cur[m.group(1)] = v
    return [c for c in clients if "username" in c and "password" in c]


def creds_save(clients):
    out = []
    for c in clients:
        out += ["[[client]]", "username = %s" % json.dumps(c["username"]), "password = %s" % json.dumps(c["password"])]
        for k, v in c.items():
            if k not in ("username", "password"):
                out.append("%s = %s" % (k, v))
        out.append("")
    write_file(CREDS, "\n".join(out), 0o600)


def gen_password(n=24):
    return "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(n))


def creds_cmd(args):
    if not args:
        die("creds: list|count|exists|get|add|del|passwd|limits")
    cmd, rest = args[0], args[1:]
    cl = creds_load()
    find = lambda n: next((c for c in cl if c["username"] == n), None)  # noqa: E731
    if cmd == "list":
        for c in cl:
            print("%s\t%s\t%s" % (c["username"], c.get("max_http2_conns", "-"), c.get("max_http3_conns", "-")))
        return 0
    if cmd == "count":
        print(len(cl))
        return 0
    if not rest:
        die("укажите имя пользователя")
    name = rest[0]
    if cmd == "exists":
        return 0 if find(name) else 1
    if cmd == "get":
        c = find(name) or die("пользователя «%s» нет" % name)
        print(c["password"])
        return 0
    if cmd in ("add", "passwd"):
        pw = rest[1] if len(rest) > 1 and rest[1] else gen_password()
        if not re.fullmatch(r"[A-Za-z0-9._~!@#%^*()+=-]{8,128}", pw):
            die("пароль: 8–128 символов (латиница, цифры, . _ ~ ! @ # % ^ * ( ) + = -)")
        if cmd == "add":
            if not NAME_RE.match(name):
                die("имя: латиница, цифры, точка, _ и - (до 32 символов)")
            if find(name):
                die("пользователь «%s» уже есть" % name)
            cl.append({"username": name, "password": pw})
        else:
            (find(name) or die("пользователя «%s» нет" % name))["password"] = pw
        creds_save(cl)
        print(pw)
        return 0
    if cmd == "del":
        c = find(name) or die("пользователя «%s» нет" % name)
        if len(cl) == 1:
            die("нельзя удалить последнего пользователя")
        cl.remove(c)
        creds_save(cl)
        return 0
    if cmd == "limits":
        c = find(name) or die("пользователя «%s» нет" % name)
        if len(rest) != 3:
            die("limits ИМЯ H2 H3 (0 — без ограничений)")
        for key, val in (("max_http2_conns", rest[1]), ("max_http3_conns", rest[2])):
            if val in ("0", "-", ""):
                c.pop(key, None)
            elif val.isdigit() and int(val) <= 1000:
                c[key] = str(int(val))
            else:
                die("лимит — число от 0 до 1000")
        creds_save(cl)
        return 0
    die("creds: неизвестная команда %s" % cmd)


# ── ключ подключения шлюза ───────────────────────────────────────────────────
EP_KEYS = ("hostname", "custom_sni", "addresses", "username", "password", "upstream_protocol",
           "skip_verification", "certificate", "client_random", "anti_dpi", "tls_profile", "dns_upstreams")


def endpoint_from_toml(text):
    data = toml_loads(text)
    src = data.get("endpoint") if isinstance(data.get("endpoint"), dict) else data
    src = dict(src)
    if src.get("client_random_prefix") and not src.get("client_random"):
        src["client_random"] = src["client_random_prefix"]   # у сервера и клиента ключ называется по-разному
    ep = {}
    for k in EP_KEYS:
        v = src.get(k)
        if isinstance(v, str):
            v = v.strip()
        if v in (None, "", []):
            continue
        ep[k] = v
    return ep


def key_encode(args):
    """stdin: экспорт сервера (TOML) → ключ ttgw:… (сжатый JSON одной строкой)."""
    ep = endpoint_from_toml(sys.stdin.read())
    if not ep.get("hostname") or not ep.get("password"):
        die("в экспорте нет адреса или пароля")
    raw = json.dumps(ep, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    print("ttgw:" + base64.urlsafe_b64encode(zlib.compress(raw, 9)).decode().rstrip("="))
    return 0


# ── сайт-заглушка ────────────────────────────────────────────────────────────
THEMES = {
    "studio": dict(
        tag="Small design & web studio",
        intro="We help small teams ship clear, fast and accessible websites. No buzzwords, just careful work.",
        nav=("Work", "Services", "About", "Contact"),
        items=[("Brand refresh", "A new identity for a regional bakery chain: logo, palette and packaging."),
               ("Booking portal", "A lightweight reservation system for a family-run guesthouse."),
               ("Docs redesign", "Restructured documentation for an open-source library, cutting search time in half."),
               ("Landing pages", "Fast static landing pages with measurable conversion goals.")],
        about="%s is a two-person studio. We keep projects small on purpose, so every client works directly with the people doing the work."),
    "blog": dict(
        tag="Notes on software, cycling and coffee",
        intro="A personal notebook. Occasional posts about things I build, break and eventually fix.",
        nav=("Posts", "Archive", "About", "Contact"),
        items=[("Rebuilding my home network", "Why I replaced three routers with one and what I learned about VLANs."),
               ("A week with a fixed-gear bike", "Fewer gears, more thinking. Notes after 400 km."),
               ("Backups you will actually restore", "A boring checklist that has saved me twice."),
               ("Espresso on a budget", "What matters, what does not, and what to skip entirely.")],
        about="Hi, I'm the person behind %s. I write when I have something worth saying, which is not often."),
    "workshop": dict(
        tag="Handmade furniture and restoration",
        intro="Custom tables, shelves and restored classics, made to order in a small local workshop.",
        nav=("Projects", "Process", "About", "Contact"),
        items=[("Oak dining table", "Solid oak, hand-cut joinery, finished with natural oil."),
               ("Restored bookcase", "A 1960s bookcase brought back from the brink, original hardware kept."),
               ("Walnut shelving", "Floating shelves sized to the room, delivered and installed."),
               ("Repairs", "Chairs, drawers and veneer repairs. Send a photo for an estimate.")],
        about="%s started in a garage and moved to a proper workshop five years ago. Every piece is built to be repaired, not replaced."),
}
CSS = """*{box-sizing:border-box}body{margin:0;font:16px/1.6 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;color:#222;background:#fafafa}
header,main,footer{max-width:760px;margin:0 auto;padding:1.2rem}header{display:flex;justify-content:space-between;align-items:baseline;border-bottom:1px solid #e5e5e5}
header a.brand{font-weight:700;font-size:1.2rem;color:#111;text-decoration:none}nav a{margin-left:1rem;color:#444;text-decoration:none}nav a:hover{text-decoration:underline}
h1{font-size:2rem;line-height:1.2}.card{background:#fff;border:1px solid #e8e8e8;border-radius:8px;padding:1rem 1.2rem;margin:1rem 0}
.card h3{margin:.2rem 0}footer{color:#777;font-size:.85rem;border-top:1px solid #e5e5e5;margin-top:2rem}a{color:#0b5cad}
"""


def decoy(args):
    """decoy КАТАЛОГ ДОМЕН ТЕМА — статический сайт; печатает «тема бренд»."""
    root, domain, theme = args[0], args[1], (args[2] if len(args) > 2 else "random")
    parts = [p for p in domain.split(".") if p != "www"]
    brand = (parts[-2] if len(parts) >= 2 else parts[0]).replace("-", " ").title()
    rnd = random.Random(int(hashlib.sha256(domain.encode()).hexdigest(), 16))
    if theme not in THEMES:
        theme = rnd.choice(sorted(THEMES))
    t = THEMES[theme]
    year = time.gmtime().tm_year
    mail = ".".join(parts[-2:])

    def page(title, body):
        navl = "".join('<a href="/%s">%s</a>' % ("" if i == 0 else n.lower() + ".html", n) for i, n in enumerate(t["nav"]))
        return ('<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
                '<title>%s</title><meta name="description" content="%s"><link rel="icon" href="/favicon.svg"><link rel="stylesheet" href="/style.css"></head><body>'
                '<header><a class="brand" href="/">%s</a><nav>%s</nav></header><main>%s</main>'
                "<footer>&copy; %d %s. All rights reserved.</footer></body></html>\n"
                % (html.escape(title), html.escape(t["tag"]), html.escape(brand), navl, body, year, html.escape(brand)))

    cards = "".join('<div class="card"><h3>%s</h3><p>%s</p></div>' % (html.escape(a), html.escape(b)) for a, b in t["items"])
    _, n1, n2, n3 = t["nav"]
    files = {
        "index.html": page(brand, "<h1>%s</h1><p>%s</p>%s" % (html.escape(t["tag"]), html.escape(t["intro"]), cards)),
        n1.lower() + ".html": page(n1 + " — " + brand, "<h1>%s</h1>%s" % (n1, cards)),
        n2.lower() + ".html": page(n2 + " — " + brand, "<h1>%s</h1><p>%s</p>" % (n2, html.escape(t["about"] % brand))),
        n3.lower() + ".html": page(n3 + " — " + brand, '<h1>%s</h1><p>The best way to reach us is by email: <a href="mailto:hello@%s">hello@%s</a>. '
                                   "We usually reply within two working days.</p>" % (n3, html.escape(mail), html.escape(mail))),
        "404.html": page("Page not found — " + brand, '<h1>404</h1><p>The page you are looking for does not exist.</p><p><a href="/">Back to the home page</a></p>'),
        "style.css": CSS,
        "favicon.svg": '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="6" fill="#%06x"/>'
                       '<text x="16" y="22" font-size="18" text-anchor="middle" fill="#fff" font-family="sans-serif">%s</text></svg>\n'
                       % (rnd.randrange(0x224466, 0x995533), html.escape(brand[0])),
        "robots.txt": "User-agent: *\nAllow: /\n",
    }
    new, old = root.rstrip("/") + ".new", root.rstrip("/") + ".old"
    shutil.rmtree(new, ignore_errors=True)
    os.makedirs(new)
    for name, data in files.items():
        write_file(os.path.join(new, name), data, 0o644)
    os.chmod(new, 0o755)
    shutil.rmtree(old, ignore_errors=True)
    if os.path.exists(root):
        os.rename(root, old)
    os.rename(new, root)
    shutil.rmtree(old, ignore_errors=True)
    print("%s %s" % (theme, brand))
    return 0


# ── подключения пользователей ([metrics] TrustTunnel) ───────────────────────
def users_table(args):
    ok, dim, z = colors()
    try:
        import urllib.request
        rows = json.loads(urllib.request.urlopen("http://127.0.0.1:%d/clients" % METRICS_PORT, timeout=2).read())
    except Exception:
        rows = []
    if args and args[0] == "--online":
        print(len({r["username"] for r in rows if r.get("username") and r.get("sessions", 0) > 0}))
        return 0
    live = [r for r in rows if r.get("username") and r.get("sessions", 0) > 0]
    anon = sum(r.get("sessions", 0) for r in rows if not r.get("username"))
    users = [c["username"] for c in creds_load()]
    w = max([len(u) for u in users] + [12])
    print("    %s  %-*s  %-7s %-16s %s%s" % (dim, w, "ПОЛЬЗОВАТЕЛЬ", "СЕССИИ", "IP", "ТРАФИК ↓ / ↑", z))
    for u in users:
        mine = [r for r in live if r["username"] == u]
        if not mine:
            print("    %s○%s %-*s  %s—%s" % (dim, z, w, u, dim, z))
        for i, r in enumerate(mine):
            print("    %s●%s %-*s  %-7s %-16s %s / %s" % (ok, z, w, u if i == 0 else "", r.get("sessions", 0),
                                                      r.get("ip") or "-", human(r.get("inbound", 0)), human(r.get("outbound", 0))))
    if anon:
        print("    %s  + подключений без трафика: %d (имя появится с первым запросом)%s" % (dim, anon, z))
    print("    %s  трафик — с последнего запуска службы%s" % (dim, z))
    return 0


# ══ ШЛЮЗ ═════════════════════════════════════════════════════════════════════
# Наборы списков для режима «российские сайты напрямую». Скачиваются раз в неделю через туннель.
#   domain — домены РФ напрямую; ip — IP-адреса РФ напрямую (переключатель geoip);
#   guard  — заблокированные в РФ: всегда через туннель (приоритет выше).
# category-ru (v2fly) включает банки, маркетплейсы (Ozon, Wildberries, Avito…), ритейл, госсайты,
# операторов связи (МТС, МегаФон, Билайн, T2, Ростелеком…), Яндекс, VK, Mail.ru; остальные — страховка.
SG = "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/"
RU_SETS = [
    ("domain", "geosite-category-ru", SG + "geosite-category-ru.srs"),
    ("domain", "geosite-yandex", SG + "geosite-yandex.srs"),
    ("domain", "geosite-vk", SG + "geosite-vk.srs"),
    ("domain", "geosite-category-gov-ru", SG + "geosite-category-gov-ru.srs"),
    ("domain", "geosite-2gis", SG + "geosite-2gis.srs"),
    ("ip", "geoip-ru", "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs"),
    ("guard", "ru-blocked", "https://github.com/itdoginfo/allow-domains/releases/latest/download/russia_inside.srs"),
]

DOH_PRESETS = {   # DNS через туннель: (адрес, SNI, путь)
    "cloudflare": ("1.1.1.1", "cloudflare-dns.com", "/dns-query"),
    "quad9": ("9.9.9.9", "dns.quad9.net", "/dns-query"),
    "google": ("8.8.8.8", "dns.google", "/dns-query"),
    "opendns": ("208.67.222.222", "doh.opendns.com", "/dns-query"),
}
RU_DNS_PRESETS = {   # DNS для российских сайтов (напрямую)
    "yandex-doh": ("common.dns.yandex.net", "common.dns.yandex.net", "/dns-query"),
    "cloudflare-doh": ("1.1.1.1", "cloudflare-dns.com", "/dns-query"),
    "google-doh": ("8.8.8.8", "dns.google", "/dns-query"),
    "quad9-doh": ("9.9.9.9", "dns.quad9.net", "/dns-query"),
    "opendns-doh": ("208.67.222.222", "doh.opendns.com", "/dns-query"),
}
PRIVATE_CIDRS = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
                 "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16"]


def wanted_sets(args):
    """Печатает «вид тег url» для наборов, нужных при текущих переключателях (--all — все)."""
    c = load_conf()
    every = bool(args and args[0] == "--all")
    for kind, tag, url in RU_SETS:
        if not every:
            if kind == "ip" and c.get("RU_GEOIP", "1") != "1":
                continue
            if kind == "guard" and c.get("RU_GUARD", "1") != "1":
                continue
        print("%s %s %s" % (kind, tag, url))
    return 0


# ── параметры сервера TrustTunnel (endpoint.json) ────────────────────────────
def split_hostport(addr, default=443):
    addr = addr.strip()
    if addr.startswith("["):
        end = addr.find("]")
        host, rest = addr[1:end], addr[end + 1:]
        return host, int(rest[1:]) if rest[1:].isdigit() else default
    if addr.count(":") == 1:
        h, p = addr.rsplit(":", 1)
        if p.isdigit():
            return h, int(p)
    return addr, default


def ep_save(ep):
    for k in ("hostname", "addresses", "username", "password"):
        if not ep.get(k):
            die("в параметрах сервера нет поля %s" % k)
    if not isinstance(ep["addresses"], list):
        ep["addresses"] = [ep["addresses"]]
    if not (HOST_RE.match(ep["hostname"]) or is_ip(ep["hostname"])):
        die("некорректный адрес сервера: %s" % ep["hostname"])
    ep["has_ipv6"] = False   # IPv6 через шлюз не пропускается
    write_file(EP_FILE, json.dumps(ep, ensure_ascii=False, indent=2), 0o600)


def ep_load():
    try:
        return json.loads(read_text(EP_FILE))
    except (OSError, ValueError) as exc:
        die("нет параметров сервера TrustTunnel (%s)" % exc)


def ep_describe(ep):
    _, port = split_hostport(ep["addresses"][0])
    return "%s:%d · %s · %s" % (ep["hostname"], port, ep.get("username", "?"),
                                "HTTP/3" if ep.get("upstream_protocol") == "http3" else "HTTP/2")


def ep_cmd(args):
    if not args:
        die("ep: import|set|info|host|pin")
    cmd = args[0]
    if cmd == "import":
        src = (args[1] if len(args) > 1 else "").strip()
        if src.startswith("ttgw:"):
            raw = src[5:]
            try:
                data = zlib.decompress(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))).decode("utf-8")
            except Exception:
                die("ключ повреждён — скопируйте строку ttgw:… целиком (на сервере: tt → Ключ для шлюза)")
            ep = json.loads(data) if data.lstrip().startswith("{") else endpoint_from_toml(data)   # v2: TOML
        else:
            try:
                ep = endpoint_from_toml(read_text(src))
            except OSError as exc:
                die("не удалось прочитать %s: %s" % (src, exc.strerror))
            except ValueError as exc:
                die("файл %s — не экспорт TrustTunnel (%s)" % (src, exc))
        ep = {k: v for k, v in ep.items() if k in EP_KEYS}
        if "hostname" not in ep and ep.get("addresses"):
            ep["hostname"] = split_hostport(ep["addresses"][0])[0]
        if not (ep.get("hostname") and ep.get("password")):
            die("в ключе нет адреса или пароля сервера")
        ep_save(ep)
        print(ep_describe(ep))
        return 0
    if cmd == "set":   # из окружения TT_HOST TT_PORT TT_USER TT_PASS [TT_PROTO]
        e = os.environ
        host, port = e.get("TT_HOST", ""), int(e.get("TT_PORT") or 443)
        proto = e.get("TT_PROTO") or "http2"
        if proto not in ("http2", "http3"):
            die("протокол: http2 или http3")
        ep = {"hostname": host, "addresses": ["%s:%d" % (host if ":" not in host else "[%s]" % host, port)],
              "username": e.get("TT_USER", ""), "password": e.get("TT_PASS", ""), "upstream_protocol": proto}
        ep_save(ep)
        print(ep_describe(ep))
        return 0
    ep = ep_load()
    if cmd == "info":
        print(ep_describe(ep))
    elif cmd == "host":
        print(ep["hostname"])
    elif cmd == "pin":
        ips = []
        for a in ep["addresses"]:
            host, port = split_hostport(a)
            if is_ip(host):
                ips.append("%s:%d" % (host if ":" not in host else "[%s]" % host, port))
                continue
            try:
                infos = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
            except OSError as exc:
                die("не удалось узнать IP %s: %s" % (host, exc))
            for inf in infos:
                s = "%s:%d" % (inf[4][0], port)
                if s not in ips:
                    ips.append(s)
        if not ips:
            die("адрес сервера не определился")
        write_file(PIN_FILE, "\n".join(ips) + "\n", 0o600)
        print(", ".join(ips))
    else:
        die("ep: неизвестная команда %s" % cmd)
    return 0


def render_client(out):
    c = load_conf()
    ep = dict(ep_load())
    if c.get("PIN_MODE", "pin") == "pin" and os.path.exists(PIN_FILE):
        pins = [x.strip() for x in read_text(PIN_FILE).splitlines() if x.strip()]
        if pins:
            ep["addresses"] = pins
    lines = ["# Создано tt. Не правьте вручную: tt → Сервер TrustTunnel.",
             'loglevel = "info"', 'vpn_mode = "general"', "killswitch_enabled = true", "", "[endpoint]"]
    order = ["hostname", "addresses", "username", "password", "upstream_protocol"]
    for k in order + [k for k in ep if k not in order]:
        if k in ep:
            lines.append("%s = %s" % (k, toml_val(ep[k])))
    lines += ["", "[listener.socks]", 'address = "127.0.0.1:%d"' % SOCKS_PORT, ""]
    write_file(os.path.join(out, "trusttunnel_client.toml"), "\n".join(lines), 0o640)


# ── sing-box ─────────────────────────────────────────────────────────────────
def parse_doh_url(url):
    u = urlsplit(url)
    if u.scheme != "https" or not u.hostname:
        die("некорректный адрес DoH: %s" % url)
    path = (u.path or "/dns-query") + ("?" + u.query if u.query else "")
    return u.hostname, u.hostname, path, u.port or 443


def make_doh(tag, host, sni, path, port, detour=None):
    """С detour домен DoH-сервера уходит в туннель как есть; без detour резолвится через dns-tunnel-boot."""
    srv = {"type": "https", "tag": tag, "server": host, "server_port": port, "path": path,
           "tls": {"enabled": True, "server_name": sni}}
    boot = False
    if detour:
        srv["detour"] = detour
    elif not is_ip(host):
        srv["domain_resolver"] = {"server": "dns-tunnel-boot", "strategy": "ipv4_only"}
        boot = True
    return srv, boot


def read_domains(path):
    out = []
    try:
        lines = read_text(path).splitlines()
    except OSError:
        return out
    for raw in lines:
        item = raw.split("#", 1)[0].strip().lower().lstrip(".")
        if not item:
            continue
        try:
            item = item.encode("idna").decode("ascii")
        except UnicodeError:
            continue
        if re.fullmatch(r"[a-z0-9]([a-z0-9._-]*[a-z0-9])?", item) and item not in out:
            out.append(item)
    return out


def build_singbox(c):
    tproxy_port = int(c.get("TPROXY_PORT", "14205") or 14205)
    block = c.get("UDP_MODE", "tunnel") == "block"
    proxy = {"type": "socks", "tag": "proxy", "server": "127.0.0.1", "server_port": SOCKS_PORT, "version": "5"}
    if block:
        proxy["network"] = "tcp"
    direct = {"type": "direct", "tag": "direct"}

    name = c.get("DOH", "cloudflare")
    if name in DOH_PRESETS:
        host, sni, path = DOH_PRESETS[name]
        port = 443
    elif name == "custom" and c.get("DOH_URL"):
        host, sni, path, port = parse_doh_url(c["DOH_URL"])
    else:
        die("неизвестный DNS для туннеля: %s" % name)
    servers = [{"type": "local", "tag": "dns-bootstrap"}, make_doh("dns-remote", host, sni, path, port, "proxy")[0]]
    dns_rules, rule_sets = [], []
    rules = [
        {"inbound": ["test-in"], "action": "route", "outbound": "proxy"},   # самопроверка — всегда через туннель
        {"action": "sniff"},
        {"protocol": "dns", "action": "hijack-dns"},
        {"port": 53, "action": "hijack-dns"},
        {"ip_cidr": PRIVATE_CIDRS, "action": "reject"},
    ]
    pnet = {"network": "tcp"} if block else {}

    if c.get("RU_DIRECT") == "1":
        suffix = c.get("RU_SUFFIX", "1") == "1"
        dom = [t for k, t, _ in RU_SETS if k == "domain"]
        ipt = [t for k, t, _ in RU_SETS if k == "ip"] if c.get("RU_GEOIP", "1") == "1" else []
        grd = [t for k, t, _ in RU_SETS if k == "guard"] if c.get("RU_GUARD", "1") == "1" else []
        for tag in dom + ipt + grd:
            p = os.path.join(RULES_DIR, tag + ".srs")
            if not os.path.isfile(p):
                die("нет списка %s — обновите списки: tt ru update" % tag)
            rule_sets.append({"type": "local", "tag": tag, "format": "binary", "path": p})
        rname = c.get("RU_DNS", "yandex")
        boot = False
        if rname == "yandex":
            ru = {"type": "udp", "tag": "dns-ru", "server": "77.88.8.8", "server_port": 53}
        elif rname == "system":
            ru = {"type": "local", "tag": "dns-ru"}
        elif rname in RU_DNS_PRESETS:
            ru, boot = make_doh("dns-ru", *RU_DNS_PRESETS[rname], 443)
        elif rname == "custom" and c.get("RU_DNS_CUSTOM", "").startswith("https://"):
            ru, boot = make_doh("dns-ru", *parse_doh_url(c["RU_DNS_CUSTOM"]))
        elif rname == "custom" and is_ip(c.get("RU_DNS_CUSTOM", "")):
            ru = {"type": "udp", "tag": "dns-ru", "server": c["RU_DNS_CUSTOM"], "server_port": 53}
        else:
            die("неизвестный DNS для российских сайтов: %s" % rname)
        servers.append(ru)
        if boot:
            servers.append({"type": "https", "tag": "dns-tunnel-boot", "server": "1.1.1.1", "server_port": 443,
                            "path": "/dns-query", "tls": {"enabled": True, "server_name": "cloudflare-dns.com"},
                            "detour": "proxy"})
        direct["domain_resolver"] = {"server": "dns-ru", "strategy": "ipv4_only"}
        exc_p, exc_d = read_domains(EXC_PROXY), read_domains(EXC_DIRECT)
        # Приоритет: исключения «через туннель» > заблокированные в РФ > исключения «напрямую» > российские
        if exc_p:
            dns_rules.append({"domain_suffix": exc_p, "action": "route", "server": "dns-remote"})
            rules.append(dict({"domain_suffix": exc_p, "action": "route", "outbound": "proxy"}, **pnet))
        if grd:
            dns_rules.append({"rule_set": grd, "action": "route", "server": "dns-remote"})
            rules.append(dict({"rule_set": grd, "action": "route", "outbound": "proxy"}, **pnet))
        if exc_d:
            dns_rules.append({"domain_suffix": exc_d, "action": "route", "server": "dns-ru"})
            rules.append({"domain_suffix": exc_d, "action": "route", "outbound": "direct"})
        dns_rules.append({"rule_set": dom, "action": "route", "server": "dns-ru"})
        rules.append({"rule_set": dom, "action": "route", "outbound": "direct"})
        if suffix:
            tld = ["ru", "su", "xn--p1ai"]
            dns_rules.append({"domain_suffix": tld, "action": "route", "server": "dns-ru"})
            rules.append({"domain_suffix": tld, "action": "route", "outbound": "direct"})
        if ipt:
            rules.append({"rule_set": ipt, "action": "route", "outbound": "direct"})
    if block:   # UDP вне правил «напрямую» отбрасывается — браузеры откатываются на TCP
        rules.append({"network": "udp", "action": "reject"})

    dns = {"servers": servers, "final": "dns-remote", "strategy": "ipv4_only"}
    if dns_rules:
        dns["rules"] = dns_rules
    route = {"rules": rules, "final": "proxy",
             "default_domain_resolver": {"server": "dns-bootstrap", "strategy": "prefer_ipv4"}}
    if rule_sets:
        route["rule_set"] = rule_sets
    return {
        "log": {"level": c.get("LOG_LEVEL", "warn"), "timestamp": True},
        "dns": dns,
        "inbounds": [
            {"type": "tproxy", "tag": "tproxy-in", "listen": "0.0.0.0", "listen_port": tproxy_port},
            {"type": "mixed", "tag": "test-in", "listen": "127.0.0.1", "listen_port": TEST_PORT},
        ],
        "outbounds": [proxy, direct],
        "route": route,
    }


# ── WireGuard ────────────────────────────────────────────────────────────────
def peers():
    """[(имя, ip, pubkey, psk)] по возрастанию адреса."""
    res = []
    if os.path.isdir(PEERS_DIR):
        for f in sorted(os.listdir(PEERS_DIR)):
            if not f.endswith(".peer"):
                continue
            d = {}
            for line in read_text(os.path.join(PEERS_DIR, f)).splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    d[k.strip()] = v.strip()
            if d.get("PublicKey") and d.get("Address"):
                res.append((f[:-5], d["Address"], d["PublicKey"], d.get("PresharedKey", "")))
    res.sort(key=lambda p: ipaddress.ip_address(p[1]))
    return res


def render_wg(out):
    c = load_conf()
    base = c.get("WG_BASE", "10.11.42")
    key = read_text(os.path.join(ETC, "wg.key")).strip()
    lines = ["# Создано tt. Клиенты: tt → Клиенты WireGuard.", "[Interface]", "Address = %s.1/24" % base,
             "ListenPort = %s" % c.get("WG_PORT", "51820"), "PrivateKey = %s" % key,
             "PostUp = /usr/local/sbin/tt rules up", "PostDown = /usr/local/sbin/tt rules down", ""]
    for name, ip, pub, psk in peers():
        lines += ["# %s" % name, "[Peer]", "PublicKey = %s" % pub]
        if psk:
            lines.append("PresharedKey = %s" % psk)
        lines += ["AllowedIPs = %s/32" % ip, ""]
    write_file(os.path.join(out, "wg0.conf"), "\n".join(lines), 0o600)


def next_ip(args):
    base = load_conf().get("WG_BASE", "10.11.42")
    used = {p[1] for p in peers()}
    for n in range(2, 255):
        ip = "%s.%d" % (base, n)
        if ip not in used:
            print(ip)
            return 0
    die("свободные адреса в %s.0/24 закончились" % base)


def clients_table(args):
    ok, dim, z = colors()
    dump = {}
    for line in os.environ.get("WG_DUMP", "").splitlines():
        f = line.split("\t")
        if len(f) >= 7:
            dump[f[0]] = (int(f[4] or 0), int(f[5] or 0), int(f[6] or 0))
    rows = peers()
    if not rows:
        print("    %sклиентов нет — добавьте: tt add ИМЯ%s" % (dim, z))
        return 0

    def ago(t):
        if not t:
            return "ещё не подключался"
        s = int(time.time()) - t
        if s < 60:
            return "только что"
        if s < 3600:
            return "%d мин назад" % (s // 60)
        if s < 86400:
            return "%d ч назад" % (s // 3600)
        return "%d дн. назад" % (s // 86400)

    w = max(len(r[0]) for r in rows + [("КЛИЕНТ",)])
    print("    %s  %-*s  %-14s %-19s %s%s" % (dim, w, "КЛИЕНТ", "АДРЕС", "СВЯЗЬ", "ТРАФИК ↓ / ↑", z))
    for name, ip, pub, _ in rows:
        hs, rx, tx = dump.get(pub, (0, 0, 0))
        mark = ("%s●%s" % (ok, z)) if hs and time.time() - hs < 180 else ("%s○%s" % (dim, z))
        print("    %s %-*s  %-14s %-19s %s" % (mark, w, name, ip, ago(hs), ("%s / %s" % (human(tx), human(rx))) if hs else ""))
    return 0


# ── проверка UDP через SOCKS5 (UDP ASSOCIATE) ────────────────────────────────
def udp_test(args):
    port = int(args[0]) if args and args[0].isdigit() else TEST_PORT
    dns_q = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01"
    probes = [("1.1.1.1", 53, dns_q, lambda d: len(d) > 12 and d[:2] == b"\x12\x34"),
              ("8.8.8.8", 53, dns_q, lambda d: len(d) > 12 and d[:2] == b"\x12\x34"),
              ("162.159.200.1", 123, b"\x1b" + b"\x00" * 47, lambda d: len(d) >= 48)]
    for addr, dport, payload, check in probes:
        try:
            tcp = socket.create_connection(("127.0.0.1", port), timeout=5)
        except OSError:
            return 1
        try:
            tcp.settimeout(5)
            tcp.sendall(b"\x05\x01\x00")
            if tcp.recv(2) != b"\x05\x00":
                continue
            tcp.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
            rep = tcp.recv(10)
            if len(rep) < 10 or rep[1] != 0 or rep[3] != 1:
                continue
            raddr = socket.inet_ntoa(rep[4:8])
            raddr = "127.0.0.1" if raddr == "0.0.0.0" else raddr
            rport = struct.unpack(">H", rep[8:10])[0]
            udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            udp.settimeout(4)
            pkt = b"\x00\x00\x00\x01" + socket.inet_aton(addr) + struct.pack(">H", dport) + payload
            for _ in range(3):
                udp.sendto(pkt, (raddr, rport))
                try:
                    data, _src = udp.recvfrom(4096)
                except socket.timeout:
                    continue
                if len(data) > 10 and check(data[10:]):
                    return 0
        except OSError:
            continue
        finally:
            tcp.close()
    return 1


# ══ CLI ══════════════════════════════════════════════════════════════════════
def render(args):
    if len(args) < 2:
        die("render server|client|singbox|wg КАТАЛОГ")
    what, out = args[0], args[1]
    if what == "server":
        render_server(out)
    elif what == "client":
        render_client(out)
    elif what == "singbox":
        write_file(os.path.join(out, "config.json"), json.dumps(build_singbox(load_conf()), indent=2, ensure_ascii=False) + "\n", 0o640)
    elif what == "wg":
        render_wg(out)
    else:
        die("render: неизвестная цель %s" % what)
    return 0


COMMANDS = {
    "render": render, "creds": creds_cmd, "key-encode": key_encode, "decoy": decoy, "users": users_table,
    "ep": ep_cmd, "sets": wanted_sets, "next-ip": next_ip, "clients": clients_table, "udp-test": udp_test,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        die("команды: " + ", ".join(sorted(COMMANDS)))
    return COMMANDS[argv[1]](argv[2:]) or 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
