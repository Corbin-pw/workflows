#!/usr/bin/env python3
"""The runner mode's two helpers, standard library only (Python 3.6 or newer).

    runner-service.py listener-uid <port>
        prints the uid of the process listening on 127.0.0.1:<port> (or
        0.0.0.0:<port>), nothing when none does
    runner-service.py forward --port P --gitlab-port G --gitlab-uid U --log FILE
        a loopback TCP forwarder: every connection to 127.0.0.1:P is opened
        to 127.0.0.1:G and relayed only once /proc/net/tcp shows that the
        socket accepted at the other end belongs to uid U (or to root, which
        publishes a port Docker maps); otherwise it is closed before a byte
        is sent, and the refusal is logged. The runner, Jacamar and git reach
        GitLab through it, so a process of another user that takes port G
        over never sees a runner token, a job token or a job's variables
    runner-service.py status --port P --state FILE --web DIR
        serves the one-page status of the runners on 127.0.0.1:P under
        pw endpoints run, in the platform's look (DIR holds the vendored
        theme and the fonts); GET /api/status answers the same as JSON

/proc/net/tcp lists every TCP socket of the host with the uid that owns it,
readable by everyone, which is what makes the loopback port of another user's
service checkable without root.
"""
import argparse
import asyncio
import html
import json
import os
import signal
import socket
import subprocess
import sys
import time
from http.server import HTTPServer, SimpleHTTPRequestHandler
from socketserver import ThreadingMixIn

LOOPBACK = {"0100007F", "00000000"}


def tcp_sockets():
    """(local ip, local port, remote ip, remote port, state, uid) of every TCP socket."""
    rows = []
    try:
        with open("/proc/net/tcp") as f:
            next(f)
            for line in f:
                p = line.split()
                if len(p) < 8:
                    continue
                lip, lport = p[1].split(":")
                rip, rport = p[2].split(":")
                rows.append((lip, int(lport, 16), rip, int(rport, 16), p[3], int(p[7])))
    except OSError:
        pass
    return rows


def listener_uid(port):
    for lip, lport, _rip, _rport, state, uid in tcp_sockets():
        if state == "0A" and lport == port and lip in LOOPBACK:
            return uid
    return None


def peer_uid(gitlab_port, our_port):
    """The uid owning the server-side socket of our connection to 127.0.0.1:gitlab_port."""
    for lip, lport, rip, rport, state, uid in tcp_sockets():
        if lport == gitlab_port and rport == our_port and lip in LOOPBACK and rip == "0100007F":
            return uid
    return None


def gitlab_state(gitlab_port, gitlab_uid):
    """What a connection to the GitLab port would meet right now."""
    uid = listener_uid(gitlab_port)
    if uid is None:
        return "down", "nothing listens on 127.0.0.1:%d" % gitlab_port
    if uid not in (gitlab_uid, 0):
        return "taken", "127.0.0.1:%d is held by uid %d, not by the GitLab's uid %d" % (gitlab_port, uid, gitlab_uid)
    return "up", "127.0.0.1:%d, uid %d" % (gitlab_port, uid)


# ---------------------------------------------------------------- forwarder

class Forwarder:
    def __init__(self, port, gitlab_port, gitlab_uid, log_path):
        self.port = port
        self.gitlab_port = gitlab_port
        self.allowed = {gitlab_uid, 0}
        self.log_path = log_path

    def log(self, message):
        line = "%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), message)
        with open(self.log_path, "a") as f:
            f.write(line)

    async def pipe(self, reader, writer):
        try:
            while True:
                data = await reader.read(65536)
                if not data:
                    break
                writer.write(data)
                await writer.drain()
        except (ConnectionError, OSError, asyncio.CancelledError):
            pass
        finally:
            try:
                if writer.can_write_eof():
                    writer.write_eof()
            except (ConnectionError, OSError):
                pass

    async def handle(self, client_reader, client_writer):
        try:
            gitlab_reader, gitlab_writer = await asyncio.wait_for(
                asyncio.open_connection("127.0.0.1", self.gitlab_port), 10)
        except (OSError, asyncio.TimeoutError) as e:
            self.log("refused: cannot connect to 127.0.0.1:%d: %s" % (self.gitlab_port, e))
            client_writer.close()
            return
        our_port = gitlab_writer.get_extra_info("sockname")[1]
        uid = peer_uid(self.gitlab_port, our_port)
        if uid not in self.allowed:
            self.log("refused: 127.0.0.1:%d is held by uid %s, not by %s"
                     % (self.gitlab_port, uid, sorted(self.allowed)))
            gitlab_writer.close()
            client_writer.close()
            return
        try:
            await asyncio.gather(self.pipe(client_reader, gitlab_writer),
                                 self.pipe(gitlab_reader, client_writer))
        finally:
            for w in (gitlab_writer, client_writer):
                try:
                    w.close()
                except (ConnectionError, OSError):
                    pass

    def serve(self):
        loop = asyncio.get_event_loop()
        loop.run_until_complete(asyncio.start_server(self.handle, "127.0.0.1", self.port))
        self.log("forwarding 127.0.0.1:%d to 127.0.0.1:%d (uid %s)"
                 % (self.port, self.gitlab_port, sorted(self.allowed)))
        loop.run_forever()


# -------------------------------------------------------------- status page

ICONS = {
    "success": "M8 14A6 6 0 1 0 8 2a6 6 0 0 0 0 12ZM5.25 8.25 7 10l3.5-4",
    "error": "M8 14A6 6 0 1 0 8 2a6 6 0 0 0 0 12ZM8 4.75v3.75M8 11h.01",
    "warning": "M7.13 2.5a1 1 0 0 1 1.74 0l5.5 9.75a1 1 0 0 1-.87 1.5H2.5a1 1 0 0 1-.87-1.5ZM8 6.5v2.75M8 11.25h.01",
    "running": "M14 8a6 6 0 1 1-6-6",
    "mark": "M14.25 8H12l-2 5.5-4-11L4 8H1.75",
}


def icon(name):
    return ('<svg class="icon" viewBox="0 0 16 16" width="1em" height="1em" fill="none" '
            'stroke="currentColor" stroke-width="1.5" stroke-linecap="round" '
            'stroke-linejoin="round" aria-hidden="true"><path d="%s"/></svg>' % ICONS[name])


def badge(tone, text, glyph):
    return '<span class="badge badge-%s">%s%s</span>' % (tone, icon(glyph), html.escape(text))


def tail(path, lines):
    try:
        with open(path, errors="replace") as f:
            return "".join(f.readlines()[-lines:])
    except OSError:
        return ""


def pid_alive(path):
    try:
        with open(path) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


class Status:
    def __init__(self, state_path):
        self.state_path = state_path

    def collect(self):
        with open(self.state_path) as f:
            state = json.load(f)
        runner_pid = pid_alive(os.path.join(state["run_dir"], "runner.pid"))
        forward_pid = pid_alive(os.path.join(state["run_dir"], "forward.pid"))
        gitlab, gitlab_detail = gitlab_state(state["gitlab_port"], state["gitlab_uid"])
        jobs = []
        try:
            out = subprocess.run(["squeue", "-h", "-u", state["user"], "-o", "%i %j %T %M"],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 universal_newlines=True, timeout=10).stdout
            jobs = [line.split(None, 3) for line in out.splitlines() if line.startswith("ci-") or " ci-" in line]
        except (OSError, subprocess.SubprocessError):
            pass
        state.update({
            "runner_pid": runner_pid, "forward_pid": forward_pid,
            "gitlab_state": gitlab, "gitlab_detail": gitlab_detail,
            "runner_log": tail(os.path.join(state["runner_root"], "runner.log"), 40),
            "forward_log": tail(os.path.join(state["run_dir"], "forward.log"), 10),
            "slurm_jobs": jobs,
            "now": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })
        return state

    def page(self):
        s = self.collect()
        e = html.escape
        runner_badge = (badge("success", "running", "success") if s["runner_pid"]
                        else badge("error", "stopped", "error"))
        gitlab_badge = {
            "up": badge("success", "reachable", "success"),
            "down": badge("error", "not listening", "error"),
            "taken": badge("error", "port taken over", "error"),
        }[s["gitlab_state"]]
        rows = "".join(
            "<tr><td>%s</td><td>%s</td><td><code>%s</code></td><td>%s</td><td>%s</td></tr>" % (
                e(r["kind"]), e(r["executor"]), e(", ".join(r["tags"])),
                "yes" if r["untagged"] else "no",
                runner_badge)
            for r in s["runners"])
        jobs = "".join("<tr><td><code>%s</code></td><td>%s</td><td>%s</td><td>%s</td></tr>"
                       % tuple(e(c) for c in (j + ["", "", "", ""])[:4]) for j in s["slurm_jobs"])
        scope = ("%s <code>%s</code>" % (e(s["scope"]), e(s["path"]))) if s.get("scope") else e(s.get("path", ""))
        callout = ""
        if s["gitlab_state"] != "up":
            callout = ('<div class="callout callout-error">%s<div><strong>GitLab is not reachable:</strong> %s. '
                       'The forwarder refuses every connection until the GitLab at %s listens on this port again; '
                       'if it was restarted, delete this session and add the runners again.</div></div>'
                       % (icon("error"), e(s["gitlab_detail"]), e(s["gitlab_url"])))
        elif not s["runner_pid"]:
            callout = ('<div class="callout callout-warning">%s<div><strong>gitlab-runner is not running.</strong> '
                       'The end of its log is below; delete this session and add the runners again.</div></div>'
                       % icon("warning"))
        return """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="30">
<title>GitLab runners</title>
<script>
(function () {
  var path = window.location.pathname || "/";
  if (!path.endsWith("/")) path += "/";
  var base = document.createElement("base");
  base.href = window.location.origin + path;
  document.head.appendChild(base);
  var theme = null;
  try { theme = window.localStorage.getItem("gitlab-runners-theme"); } catch (e) { theme = null; }
  if (theme === "light" || theme === "dark") document.documentElement.dataset.theme = theme;
})();
</script>
<link rel="stylesheet" href="fonts.css">
<link rel="stylesheet" href="theme.css">
<link rel="stylesheet" href="styles.css">
</head>
<body>
<header class="page-header">
  <div class="page-header-trail">
    <span class="page-mark" aria-hidden="true">%(mark)s</span>
    <h1 class="page-title">GitLab runners</h1>
    <p class="page-description">CI runners of %(user)s on %(host)s</p>
  </div>
  <div class="page-actions">
    <button id="theme" class="btn btn-ghost" type="button" title="Light, dark or the device's">Theme</button>
  </div>
</header>
<main>
  %(callout)s
  <section class="panel">
    <div class="panel-header"><h2 class="panel-title">Where the jobs run</h2>
      <p class="panel-description">Every job of %(scope)s runs on this host as %(user)s, with that account's files, scheduler access and credentials. A job that calls <code>pw</code> needs <code>PW_API_KEY</code> as a masked CI/CD variable of the project.</p></div>
    <dl class="dl">
      <dt>GitLab</dt><dd><a href="%(gitlab_url)s" target="_blank" rel="noopener">%(gitlab_url)s</a> %(gitlab_badge)s <span class="muted mono">%(gitlab_detail)s</span></dd>
      <dt>Reached through</dt><dd><span class="mono">http://127.0.0.1:%(forward_port)s</span> <span class="muted">(a forwarder of this session that checks the uid at the other end)</span></dd>
      <dt>Runs as</dt><dd><span class="mono">%(user)s</span> on <span class="mono">%(host)s</span></dd>
      <dt>Runner directory</dt><dd><span class="mono">%(runner_root)s</span></dd>
      <dt>Session</dt><dd><span class="mono">%(run_slug)s</span>, started %(started)s; this page refreshes every 30 s (last %(now)s)</dd>
    </dl>
  </section>
  <section class="panel">
    <div class="panel-header"><h2 class="panel-title">Runners</h2></div>
    <table class="table">
      <thead><tr><th>Runner</th><th>Executor</th><th>Tags</th><th>Untagged jobs</th><th>Process</th></tr></thead>
      <tbody>%(rows)s</tbody>
    </table>
  </section>
  <section class="panel">
    <div class="panel-header"><h2 class="panel-title">SLURM jobs of the runners in the queue</h2></div>
    %(jobs_table)s
  </section>
  <section class="panel">
    <div class="panel-header"><h2 class="panel-title">gitlab-runner log</h2><p class="panel-description">The last 40 lines of <span class="mono">%(runner_root)s/runner.log</span></p></div>
    <pre class="code">%(runner_log)s</pre>
  </section>
  %(forward_section)s
</main>
<script>
(function () {
  var order = ["system", "light", "dark"], key = "gitlab-runners-theme", root = document.documentElement;
  var button = document.getElementById("theme");
  function current() { return root.dataset.theme || "system"; }
  function label() { button.textContent = "Theme: " + current(); }
  button.addEventListener("click", function () {
    var next = order[(order.indexOf(current()) + 1) %% order.length];
    if (next === "system") { delete root.dataset.theme; } else { root.dataset.theme = next; }
    try { if (next === "system") localStorage.removeItem(key); else localStorage.setItem(key, next); } catch (e) {}
    label();
  });
  label();
})();
</script>
</body>
</html>
""" % {
            "mark": icon("mark"), "user": e(s["user"]), "host": e(s["host"]), "callout": callout,
            "scope": scope, "gitlab_url": e(s["gitlab_url"]), "gitlab_badge": gitlab_badge,
            "gitlab_detail": e(s["gitlab_detail"]), "forward_port": s["forward_port"],
            "runner_root": e(s["runner_root"]), "run_slug": e(s["run_slug"]), "started": e(s["started"]),
            "now": e(s["now"]), "rows": rows,
            "jobs_table": ('<table class="table"><thead><tr><th>Job</th><th>Name</th><th>State</th><th>Time</th></tr></thead><tbody>%s</tbody></table>' % jobs)
                          if jobs else '<p class="empty">No job of the SLURM runner is queued or running.</p>',
            "runner_log": e(s["runner_log"]) or "(empty)",
            "forward_section": ('<section class="panel"><div class="panel-header"><h2 class="panel-title">Forwarder log</h2></div><pre class="code">%s</pre></section>' % e(s["forward_log"]))
                               if s["forward_log"] else "",
        }


class Server(ThreadingMixIn, HTTPServer):
    daemon_threads = True


class Handler(SimpleHTTPRequestHandler):
    status = None
    extensions_map = dict(SimpleHTTPRequestHandler.extensions_map,
                          **{".css": "text/css", ".woff2": "font/woff2"})

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            body = self.status.page().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/api/status":
            body = json.dumps(self.status.collect(), indent=1).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        # The vendored theme and fonts, nothing else from the directory
        name = path.rsplit("/", 1)[-1]
        if name in ("theme.css", "fonts.css", "styles.css") or name.endswith(".woff2"):
            self.path = "/" + name
            return SimpleHTTPRequestHandler.do_GET(self)
        self.send_error(404)

    def log_message(self, format, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command")
    p = sub.add_parser("listener-uid")
    p.add_argument("port", type=int)
    p = sub.add_parser("forward")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--gitlab-port", type=int, required=True)
    p.add_argument("--gitlab-uid", type=int, required=True)
    p.add_argument("--log", required=True)
    p = sub.add_parser("status")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--web", required=True)
    args = parser.parse_args()
    if not args.command:
        parser.error("a command is required")

    if args.command == "listener-uid":
        uid = listener_uid(args.port)
        print("" if uid is None else uid)
    elif args.command == "forward":
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        Forwarder(args.port, args.gitlab_port, args.gitlab_uid, args.log).serve()
    elif args.command == "status":
        Handler.status = Status(os.path.abspath(args.state))
        os.chdir(args.web)
        server = Server(("127.0.0.1", args.port), Handler)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        server.serve_forever()


if __name__ == "__main__":
    main()
