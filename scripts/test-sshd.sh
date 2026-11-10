#!/bin/sh
# A throwaway, user-level sshd for testing Wierdr's SSH transport.
#
#   scripts/test-sshd.sh start    # listens on 127.0.0.1:2222 (idempotent)
#   scripts/test-sshd.sh stop
#   scripts/test-sshd.sh status
#   scripts/test-sshd.sh env      # prints paths/fingerprints for tests and the app
#
# Everything lives in $WIERDR_SSHD_DIR (default /tmp/wierdr-sshd): its own host
# key, a test client key (client_ed25519, no passphrase) and an authorized_keys
# file with that client key. Nothing in ~/.ssh or /etc/ssh is touched.
#
# The sshd runs as the current (non-root) user, so it can only log in that
# user, with the client key (no passwords: a non-root sshd cannot check them).
#
#   ssh -p 2222 -i /tmp/wierdr-sshd/client_ed25519 \
#       -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no 127.0.0.1 'echo ok'
#
# From the iOS simulator, connect to 127.0.0.1:2222 as "$(id -un)" and import
# /tmp/wierdr-sshd/client_ed25519 (or add the app's public key to
# /tmp/wierdr-sshd/authorized_keys).
set -eu

DIR=${WIERDR_SSHD_DIR:-/tmp/wierdr-sshd}
PORT=${WIERDR_SSHD_PORT:-2222}
ADDR=${WIERDR_SSHD_ADDR:-127.0.0.1}
SSHD=${SSHD:-/usr/sbin/sshd}

running() {
    [ -f "$DIR/sshd.pid" ] && kill -0 "$(cat "$DIR/sshd.pid")" 2>/dev/null
}

listening() {
    nc -z "$ADDR" "$PORT" >/dev/null 2>&1
}

start() {
    mkdir -p "$DIR"
    chmod 700 "$DIR"
    [ -f "$DIR/host_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C wierdr-test-host -f "$DIR/host_ed25519"
    [ -f "$DIR/client_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C wierdr-test-client -f "$DIR/client_ed25519"
    [ -f "$DIR/authorized_keys" ] || cp "$DIR/client_ed25519.pub" "$DIR/authorized_keys"
    chmod 600 "$DIR/authorized_keys"
    cat >"$DIR/sshd_config" <<EOF
Port $PORT
ListenAddress $ADDR
HostKey $DIR/host_ed25519
AuthorizedKeysFile $DIR/authorized_keys
PidFile $DIR/sshd.pid
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
StrictModes no
AllowUsers $(id -un)
LogLevel VERBOSE
EOF
    if running; then
        echo "test sshd already running (pid $(cat "$DIR/sshd.pid")) on $ADDR:$PORT"
        return 0
    fi
    "$SSHD" -t -f "$DIR/sshd_config"
    nohup "$SSHD" -D -e -f "$DIR/sshd_config" >"$DIR/sshd.log" 2>&1 &
    echo $! >"$DIR/sshd.pid"
    i=0
    while ! listening; do
        i=$((i + 1))
        if [ $i -gt 50 ] || ! running; then
            echo "test sshd did not start; log:" >&2
            cat "$DIR/sshd.log" >&2
            exit 1
        fi
        sleep 0.1
    done
    echo "test sshd running (pid $(cat "$DIR/sshd.pid")) on $ADDR:$PORT, log $DIR/sshd.log"
}

stop() {
    if running; then
        kill "$(cat "$DIR/sshd.pid")"
        echo "test sshd stopped"
    else
        echo "test sshd not running"
    fi
    rm -f "$DIR/sshd.pid"
}

case "${1:-}" in
start) start ;;
stop) stop ;;
restart) stop; start ;;
status)
    if running; then echo "running (pid $(cat "$DIR/sshd.pid")) on $ADDR:$PORT"; else echo "not running"; exit 1; fi
    ;;
env)
    echo "WIERDR_SSHD_DIR=$DIR"
    echo "WIERDR_SSHD_HOST=$ADDR"
    echo "WIERDR_SSHD_PORT=$PORT"
    echo "WIERDR_SSHD_USER=$(id -un)"
    echo "WIERDR_SSHD_CLIENT_KEY=$DIR/client_ed25519"
    echo "WIERDR_SSHD_HOST_FINGERPRINT=$(ssh-keygen -lf "$DIR/host_ed25519.pub" | awk '{print $2}')"
    ;;
*)
    echo "usage: $0 start|stop|restart|status|env" >&2
    exit 2
    ;;
esac
