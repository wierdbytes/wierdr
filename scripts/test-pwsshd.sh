#!/bin/sh
# A throwaway SSH server that takes a password, for testing Wierdr's password sign-in
# (the prompt, the setup sheet's Sign In section): scripts/test-sshd.sh can't, a non-root
# sshd cannot check passwords.
#
#   scripts/test-pwsshd.sh start    # 127.0.0.1:2223, user "$(id -un)", password "wierdr-test" (idempotent)
#   scripts/test-pwsshd.sh stop
#   scripts/test-pwsshd.sh status
#
# Python's asyncssh in its own venv; any exec runs this Mac's `hc connect`, as Wierdr's
# remote command would. Everything lives in $WIERDR_PWSSHD_DIR (default /tmp/wierdr-pwsshd).
# Careful: "Install This iPhone's Key" from such a session appends the device's key to this
# Mac's real ~/.ssh/authorized_keys (through herdr-core): take it out afterwards.
set -eu

DIR=${WIERDR_PWSSHD_DIR:-/tmp/wierdr-pwsshd}
PORT=${WIERDR_PWSSHD_PORT:-2223}

running() { [ -f "$DIR/server.pid" ] && kill -0 "$(cat "$DIR/server.pid")" 2>/dev/null; }

start() {
  if running; then echo "running (pid $(cat "$DIR/server.pid")) on 127.0.0.1:$PORT"; return; fi
  mkdir -p "$DIR"
  [ -x "$DIR/venv/bin/python" ] || python3 -m venv "$DIR/venv"
  "$DIR/venv/bin/python" -c "import asyncssh" 2>/dev/null || "$DIR/venv/bin/pip" install -q asyncssh
  [ -f "$DIR/host_key" ] || ssh-keygen -q -t ed25519 -N "" -f "$DIR/host_key"
  cat > "$DIR/server.py" <<'PY'
import asyncio, asyncssh, getpass, os, shutil, sys

HC = shutil.which("hc") or os.path.expanduser("~/.local/bin/hc")

class Server(asyncssh.SSHServer):
    def begin_auth(self, username): return True
    def password_auth_supported(self): return True
    def validate_password(self, username, password):
        return username == getpass.getuser() and password == "wierdr-test"

async def handle(process):
    proc = await asyncio.create_subprocess_exec(HC, "connect", stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    await process.redirect(stdin=proc.stdin, stdout=proc.stdout, stderr=proc.stderr)
    process.exit(await proc.wait())

async def main():
    await asyncssh.create_server(Server, "127.0.0.1", int(sys.argv[1]), server_host_keys=[sys.argv[2]],
                                 process_factory=handle, encoding=None)
    await asyncio.Future()

asyncio.run(main())
PY
  nohup "$DIR/venv/bin/python" "$DIR/server.py" "$PORT" "$DIR/host_key" > "$DIR/server.log" 2>&1 &
  echo $! > "$DIR/server.pid"
  sleep 1
  running || { cat "$DIR/server.log"; exit 1; }
  echo "running (pid $(cat "$DIR/server.pid")) on 127.0.0.1:$PORT: user $(id -un), password wierdr-test"
}

case "${1:-}" in
  start) start ;;
  stop) if running; then kill "$(cat "$DIR/server.pid")"; fi; rm -f "$DIR/server.pid"; echo stopped ;;
  status) if running; then echo "running (pid $(cat "$DIR/server.pid")) on 127.0.0.1:$PORT"; else echo "not running"; fi ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
