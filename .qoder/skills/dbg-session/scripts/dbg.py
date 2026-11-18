#!/usr/bin/env python3
"""CLI-обёртка над MCP-сервером 1c-debug (HTTP JSON-RPC).

Зачем: навыку /dbg-session нужно управлять отладчиком 1С и тогда, когда MCP-сервер не
подключён к агенту. Скрипт говорит с тем же сервером, что и плагин, — по
`http://127.0.0.1:<порт>/mcp`, поэтому поведение инструментов одинаковое.

Запуск: python scripts/dbg.py <команда> [параметры]
Справка: python scripts/dbg.py <команда> --help
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

DEFAULT_PORT = int(os.environ.get("V8_DEBUG_MCP_PORT", "8123"))
DEFAULT_TYPES = "Server,JOB,WEBService,HTTPService"

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")


def url(port):
    return "http://127.0.0.1:%d/" % port


def health(port, timeout=1.0):
    try:
        with urllib.request.urlopen(url(port), timeout=timeout) as resp:
            return json.load(resp)
    except Exception:
        return None


def rpc(port, tool, arguments, timeout=180.0):
    payload = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
               "params": {"name": tool, "arguments": arguments}}
    req = urllib.request.Request(url(port) + "mcp", data=json.dumps(payload).encode("utf-8"),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        raise RuntimeError("HTTP %s: %s" % (exc.code, body[:500]))
    if "error" in data:
        raise RuntimeError(data["error"].get("message") or data["error"])
    result = data.get("result") or {}
    content = result.get("content") or []
    text = content[0].get("text", "") if content else ""
    if result.get("isError"):
        raise RuntimeError(text or "инструмент вернул ошибку")
    try:
        return json.loads(text)
    except (ValueError, TypeError):
        return text


def project_config(start_dir=None):
    path = os.path.abspath(start_dir or os.getcwd())
    while True:
        candidate = os.path.join(path, ".v8-project.json")
        if os.path.isfile(candidate):
            try:
                with open(candidate, encoding="utf-8-sig") as fh:
                    return json.load(fh)
            except Exception:
                return None
        parent = os.path.dirname(path)
        if parent == path:
            return None
        path = parent


def find_server(args):
    if args.server:
        return os.path.abspath(args.server)
    candidates = [args.home, os.environ.get("V8_DEBUG_MCP_HOME")]
    cfg = project_config()
    if isinstance(cfg, dict):
        candidates.append(cfg.get("debugMcpHome"))
        tools = cfg.get("tools")
        if isinstance(tools, dict):
            candidates.append(tools.get("debugMcpHome"))
    for home in candidates:
        if not home:
            continue
        for rel in ("qoder-1c-debug/server/debug_mcp_http.py", "server/debug_mcp_http.py"):
            path = os.path.join(home, *rel.split("/"))
            if os.path.isfile(path):
                return path
    return None


def cmd_ensure(args):
    alive = health(args.port)
    if alive:
        print(json.dumps({"already": True, "port": args.port, "server": alive.get("server"),
                          "tools": len(alive.get("tools") or [])}, ensure_ascii=False, indent=2))
        return 0
    script = find_server(args)
    if not script:
        sys.stderr.write(
            "MCP-сервер 1c-debug не найден.\n"
            "Укажите репозиторий: --home <каталог> или V8_DEBUG_MCP_HOME, либо ключ\n"
            "debugMcpHome в .v8-project.json. Репозиторий: "
            "https://github.com/MaxVMarkov/1c-debug-mcp\n")
        return 1
    kwargs = {}
    if os.name == "nt":
        kwargs["creationflags"] = 0x00000008 | 0x00000200  # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
    proc = subprocess.Popen([sys.executable, script, "--port", str(args.port)],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, close_fds=True, **kwargs)
    for _ in range(40):
        time.sleep(0.25)
        alive = health(args.port)
        if alive:
            print(json.dumps({"started": True, "pid": proc.pid, "port": args.port,
                              "script": script, "tools": len(alive.get("tools") or [])},
                             ensure_ascii=False, indent=2))
            return 0
    sys.stderr.write("сервер не поднялся за 10 с: %s\n" % script)
    return 1


def need_base(args):
    base = args.base or os.environ.get("V8_DEBUG_BASE")
    if not base:
        raise SystemExit("нужен --base <alias> (infoBaseAlias) или V8_DEBUG_BASE")
    return base


def parse_module(text):
    name, sep, lines = text.rpartition(":")
    if not sep or not name:
        raise SystemExit("формат модуля: Имя.Модуля:строка[,строка] — получено %r" % text)
    try:
        nums = [int(x) for x in lines.replace(" ", "").split(",") if x]
    except ValueError:
        raise SystemExit("строки должны быть числами: %r" % text)
    return {"name": name, "lines": nums}


def add_base(command, **extra):
    def run(args):
        data = {"base": need_base(args)}
        data.update(extra(args) if callable(extra) else extra)
        return call(args.port, command, data, getattr(args, "http_timeout", 180.0))
    return run


def call(port, tool, data, timeout=180.0, **kwargs):
    result = rpc(port, tool, data, timeout=timeout)
    print(json.dumps(result, ensure_ascii=False, indent=2, default=str))
    return 0


def main(argv=None):
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--port", type=int, default=argparse.SUPPRESS, help="порт HTTP-MCP (8123)")
    common.add_argument("--home", default=argparse.SUPPRESS, help="каталог репозитория 1c-debug-mcp")
    common.add_argument("--server", default=argparse.SUPPRESS, help="путь к debug_mcp_http.py")

    parser = argparse.ArgumentParser(prog="dbg.py", description="CLI к MCP-серверу 1c-debug",
                                     parents=[common])
    parser.set_defaults(port=DEFAULT_PORT, home=None, server=None)
    sub = parser.add_subparsers(dest="command", required=True)
    add = lambda name, **kw: sub.add_parser(name, parents=[common], **kw)  # noqa: E731

    add("ensure", help="проверить или поднять MCP-сервер").set_defaults(func=cmd_ensure)

    p = add("status", help="жив ли dbgs и какие сеансы открыты")
    p.add_argument("--dbgs-host")
    p.add_argument("--dbgs-port", type=int)
    def _status(args):
        data = {}
        if args.dbgs_host: data["host"] = args.dbgs_host
        if args.dbgs_port: data["port"] = args.dbgs_port
        return call(args.port, "debug_status", data, 30.0)
    p.set_defaults(func=_status)

    p = add("start", help="attachDebugUI")
    p.add_argument("--base"); p.add_argument("--wait", type=float)
    p.add_argument("--dbgs-host"); p.add_argument("--dbgs-port", type=int)
    def _start(args):
        data = {"base": need_base(args)}
        if args.wait is not None: data["wait"] = args.wait
        if args.dbgs_host: data["host"] = args.dbgs_host
        if args.dbgs_port: data["port"] = args.dbgs_port
        return call(args.port, "session_start", data, (args.wait or 30) + 60)
    p.set_defaults(func=_start)

    p = add("stop", help="detachDebugUI")
    p.add_argument("--base")
    p.set_defaults(func=add_base("session_stop"))

    p = add("targets", help="снимок целей отладки")
    p.add_argument("--base")
    p.set_defaults(func=add_base("targets"))

    p = add("attach", help="присоединить/отсоединить цель")
    p.add_argument("--base"); p.add_argument("--target-id"); p.add_argument("--detach", action="store_true")
    def _attach(args):
        data = {"base": need_base(args), "attach": not args.detach}
        if args.target_id: data["target_id"] = args.target_id
        return call(args.port, "target_attach", data)
    p.set_defaults(func=_attach)

    p = add("bp-list", help="точки из профиля конфигуратора")
    p.set_defaults(func=lambda args: call(args.port, "breakpoints_list", {}))

    p = add("bp-set", help="поставить точки")
    p.add_argument("--base"); p.add_argument("--config", help="каталог XML-выгрузки или ConfigDumpInfo.xml")
    p.add_argument("--module", action="append", default=[], help="Имя.Модуля:строка[,строка]")
    p.add_argument("--module-json", help="JSON-массив модулей как в инструменте")
    def _bp_set(args):
        modules = [parse_module(m) for m in args.module]
        if args.module_json:
            modules.extend(json.loads(args.module_json))
        data = {"base": need_base(args)}
        config = args.config or os.environ.get("V8_CONFIG_SRC")
        if config: data["configPath"] = config
        if modules: data["modules"] = modules
        return call(args.port, "breakpoints_set", data, 120.0)
    p.set_defaults(func=_bp_set)

    p = add("bp-clear", help="снять все точки")
    p.add_argument("--base")
    p.set_defaults(func=add_base("breakpoints_clear"))

    p = add("wait", help="дождаться останова")
    p.add_argument("--base"); p.add_argument("--timeout", type=float, default=60.0)
    def _wait(args):
        return call(args.port, "wait_stop", {"base": need_base(args), "timeout": args.timeout},
                    args.timeout + 60)
    p.set_defaults(func=_wait)

    p = add("locals", help="локальные переменные кадра")
    p.add_argument("--base")
    p.set_defaults(func=add_base("locals"))

    p = add("eval", help="вычислить выражение")
    p.add_argument("--base"); p.add_argument("--expr", required=True)
    def _eval(args):
        return call(args.port, "eval", {"base": need_base(args), "expression": args.expr})
    p.set_defaults(func=_eval)

    p = add("set-var", help="присвоить значение")
    p.add_argument("--base"); p.add_argument("--path", required=True); p.add_argument("--value", required=True)
    def _set(args):
        return call(args.port, "set_variable", {"base": need_base(args), "path": args.path,
                                                "value_expression": args.value})
    p.set_defaults(func=_set)

    p = add("step", help="шаг отладки")
    p.add_argument("--base"); p.add_argument("--action", required=True,
                                             choices=["Step", "StepIn", "StepOut", "Continue"])
    def _step(args):
        return call(args.port, "step", {"base": need_base(args), "action": args.action})
    p.set_defaults(func=_step)

    p = add("rte", help="останов на ран-тайм ошибке")
    group = p.add_mutually_exclusive_group()
    group.add_argument("--on", dest="on", action="store_true", default=True)
    group.add_argument("--off", dest="on", action="store_false")
    p.add_argument("--pattern", action="append", default=[], help="подстрока текста ошибки")
    p.add_argument("--exclude", action="store_true", help="подстроки как запреты")
    def _rte(args):
        data = {"base": need_base(args), "on": args.on}
        if args.pattern: data["patterns"] = args.pattern
        if args.exclude: data["exclude"] = True
        return call(args.port, "stop_on_error", data)
    p.set_defaults(func=_rte)

    p = add("auto-attach", help="авто-присоединение целей")
    p.add_argument("--base")
    p.add_argument("--types", default=DEFAULT_TYPES, help="через запятую; пусто = выключить")
    def _auto(args):
        types = [t.strip() for t in args.types.split(",") if t.strip()]
        return call(args.port, "auto_attach_targets", {"base": need_base(args), "types": types})
    p.set_defaults(func=_auto)

    p = add("raw", help="вызвать любой инструмент с JSON")
    p.add_argument("tool"); p.add_argument("--json", default="{}"); p.add_argument("--timeout", type=float, default=180.0)
    def _raw(args):
        return call(args.port, args.tool, json.loads(args.json), args.timeout)
    p.set_defaults(func=_raw)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except (RuntimeError, urllib.error.URLError, OSError) as exc:
        sys.stderr.write("ошибка: %s\n" % exc)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
