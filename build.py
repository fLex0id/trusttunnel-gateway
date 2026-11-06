#!/usr/bin/env python3
"""Сборка dist/tt.sh из модулей src/ (один файл: bash + встроенные Python-модуль и ключ подписи).

  python3 build.py          → dist/tt.sh и dist/tt.sh.sha256
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
MODULES = ["ui.sh", "core.sh", "server.sh", "gateway.sh", "main.sh"]


def rd(*p):
    with open(os.path.join(ROOT, *p), encoding="utf-8") as fh:
        return fh.read()


def body(text):
    return "".join(l for l in text.splitlines(keepends=True) if not l.startswith("# shellcheck shell=bash"))


def heredoc_fn(name, text, tag):
    assert "\n%s\n" % tag not in "\n" + text, tag
    return "%s() {\n  cat <<'%s'\n%s%s\n}\n" % (name, tag, text if text.endswith("\n") else text + "\n", tag)


def main():
    version = rd("VERSION").strip()
    out = [
        "#!/usr/bin/env bash\n",
        "#\n",
        "#  tt — TrustTunnel: свой VPN из двух серверов (сервер за рубежом + шлюз в России)\n",
        "#  https://github.com/fLex0id/trusttunnel-gateway · лицензия MIT\n",
        "#\n",
        "#  Установка:  bash <(curl -fsSL https://raw.githubusercontent.com/fLex0id/trusttunnel-gateway/main/install.sh)\n",
        "#  Управление: tt          (справка: tt help)\n",
        "#\n",
        "#  Файл собран из исходников (src/) командой build.py — правьте исходники, а не этот файл.\n",
        "#\n",
        "set -uo pipefail\n",
        "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n",
        "umask 022\n",
        "SELF_VERSION=%s\n\n" % version,
    ]
    for m in MODULES:
        out.append(body(rd("src", "lib", m)))
        out.append("\n")
    out.append(heredoc_fn("py_source", rd("src", "py", "tt.py"), "TT_PY_EOF"))
    out.append(heredoc_fn("gpg_key", rd("src", "keys", "adguard-trusttunnel.asc"), "TT_KEY_EOF"))
    out.append('\nmain "$@"\n')
    text = "".join(out)
    os.makedirs(os.path.join(ROOT, "dist"), exist_ok=True)
    path = os.path.join(ROOT, "dist", "tt.sh")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(path, 0o755)
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    with open(path + ".sha256", "w", encoding="utf-8") as fh:
        fh.write("%s  tt.sh\n" % digest)
    print("dist/tt.sh %s · %d строк · sha256 %s" % (version, text.count("\n"), digest[:16]))


if __name__ == "__main__":
    main()
