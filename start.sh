#!/bin/bash
set -eu

echo "=== Iniciando Boobam MCP Server ==="
echo "Node: $(node --version)"

# ── Prepara chave SSH ────────────────────────────────────────────────────────
echo "$SSH_PRIVATE_KEY" | base64 -d > /root/.ssh/id_rsa && chmod 600 /root/.ssh/id_rsa
ssh-keyscan -p 443 -T 15 54.210.207.242 >> /root/.ssh/known_hosts 2>&1

BASTION="54.210.207.242"
BASTION_PORT="443"

# ── Variáveis do servidor Node (usadas também pela checagem dos túneis) ──────
export MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
export MYSQL_PORT="${MYSQL_PORT:-3307}"
export MYSQL_USER="${MYSQL_USER:-vinicius}"
export MYSQL_PASS="${MYSQL_PASS:-}"
export MYSQL_DB="${MYSQL_DB:-boobam}"
export PORT="${PORT:-3000}"

# Túnel 1 — QA / D-1 (obrigatório: o servidor não sobe sem ele)
RDS_HOST="boobam-aurora-qa.cluster-cnoog7catbsl.us-east-1.rds.amazonaws.com"
LOCAL_PORT="3307"
RDS_PORT="3306"
TUNNEL_PID=""

# Túnel 2 — D0 / produção, endpoint reader (opcional: falha não derruba o serviço)
D0_RDS_HOST="boobam-aurora-prod.cluster-ro-cnoog7catbsl.us-east-1.rds.amazonaws.com"
D0_LOCAL_PORT="3308"
D0_RDS_PORT="3306"
D0_TUNNEL_PID=""

# D0 só é ativado se D0_MYSQL_USER e D0_MYSQL_PASS estiverem definidos no Railway.
D0_ENABLED=""
if [ -n "${D0_MYSQL_USER:-}" ] && [ -n "${D0_MYSQL_PASS:-}" ]; then
  D0_ENABLED="1"
  export D0_MYSQL_HOST="${D0_MYSQL_HOST:-127.0.0.1}"
  export D0_MYSQL_PORT="${D0_MYSQL_PORT:-3308}"
  export D0_MYSQL_DB="${D0_MYSQL_DB:-boobam}"
else
  echo "⚠️ D0_MYSQL_USER/D0_MYSQL_PASS ausentes — fonte d0 desativada"
  unset D0_MYSQL_HOST || true
fi

# Mata um PID só se ele existir: `kill 0` (ou vazio) derrubaria o grupo inteiro.
stop_pid() { [ -n "$1" ] && [ "$1" != "0" ] && kill "$1" 2>/dev/null || true; }

# ── Funções: abrem túneis SSH em background ──────────────────────────────────
start_tunnel() {
  ssh -i /root/.ssh/id_rsa \
      -L "${LOCAL_PORT}:${RDS_HOST}:${RDS_PORT}" \
      devops@${BASTION} -p ${BASTION_PORT} -N \
      -o ConnectTimeout=20 \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      -o StrictHostKeyChecking=no \
      -o ExitOnForwardFailure=yes &
  TUNNEL_PID=$!
  echo "[tunnel d1] PID=$TUNNEL_PID iniciado"
}

start_d0_tunnel() {
  ssh -i /root/.ssh/id_rsa \
      -L "${D0_LOCAL_PORT}:${D0_RDS_HOST}:${D0_RDS_PORT}" \
      devops@${BASTION} -p ${BASTION_PORT} -N \
      -o ConnectTimeout=20 \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      -o StrictHostKeyChecking=no \
      -o ExitOnForwardFailure=yes &
  D0_TUNNEL_PID=$!
  echo "[tunnel d0] PID=$D0_TUNNEL_PID iniciado"
}

# ── Checa se o túnel chega até o MySQL (não só se a porta local está aberta) ─
# O ssh escuta na porta local mesmo quando o bastion não alcança o RDS, então
# `nc -z` dá falso positivo. Aqui abrimos uma conexão MySQL completa: sucesso ou
# erro do próprio MySQL (ex.: Access denied) = túnel ok; erro de rede = caído.
# Login completo, e não um connect/close cru, para não somar handshake errors
# no host_cache do RDS (max_connect_errors bloquearia o IP do bastion).
db_reachable() {
  PROBE_PORT="$1" PROBE_USER="$2" PROBE_PASS="$3" PROBE_DB="$4" timeout 15 node -e '
    const e = process.env;
    require("/app/node_modules/mysql2/promise")
      .createConnection({ host: "127.0.0.1", port: +e.PROBE_PORT, user: e.PROBE_USER,
                          password: e.PROBE_PASS, database: e.PROBE_DB, connectTimeout: 10000 })
      .then(c => c.end())
      .then(() => process.exit(0), err => {
        console.error("[probe] " + (err.code || err.message));
        process.exit(err.sqlState ? 0 : 1);
      });' 2>&1 | sed 's/^/  /' >&2
  return "${PIPESTATUS[0]}"
}

d1_reachable() { db_reachable "${LOCAL_PORT}" "${MYSQL_USER}" "${MYSQL_PASS}" "${MYSQL_DB}"; }
d0_reachable() { db_reachable "${D0_LOCAL_PORT}" "${D0_MYSQL_USER}" "${D0_MYSQL_PASS}" "${D0_MYSQL_DB}"; }

# ── Aguarda túnel ficar pronto (MySQL acessível pelo túnel) ──────────────────
wait_for_tunnel() {
  local check="$1" pid="$2" label="$3"
  for i in $(seq 1 10); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      echo "❌ SSH ${label} encerrou antes de estar pronto (tentativa $i)"
      return 1
    fi
    if "${check}"; then
      echo "✅ Túnel ${label} ativo na tentativa $i"
      return 0
    fi
    sleep 3
  done
  echo "❌ Tempo esgotado aguardando túnel ${label} chegar ao MySQL"
  return 1
}

# ── Primeira conexão (D-1, obrigatória) ──────────────────────────────────────
start_tunnel
until wait_for_tunnel d1_reachable "${TUNNEL_PID}" "d1"; do
  echo "[tunnel d1] Falha na conexão inicial, tentando novamente em 5s..."
  stop_pid "${TUNNEL_PID}"
  sleep 5
  start_tunnel
done

# ── Primeira conexão (D0, melhor esforço) ────────────────────────────────────
if [ -n "${D0_ENABLED}" ]; then
  start_d0_tunnel
  if ! wait_for_tunnel d0_reachable "${D0_TUNNEL_PID}" "d0"; then
    echo "[tunnel d0] ⚠️ Não chegou ao MySQL no boot — watchdog seguirá tentando"
    stop_pid "${D0_TUNNEL_PID}"
    D0_TUNNEL_PID=""
  fi
fi

# ── Watchdog: monitora e reconecta os túneis em background ──────────────────
(
  while true; do
    sleep 30
    if ! kill -0 "${TUNNEL_PID}" 2>/dev/null || ! d1_reachable; then
      echo "[watchdog] Túnel d1 caiu (PID=${TUNNEL_PID}). Reconectando..."
      stop_pid "${TUNNEL_PID}"
      sleep 3
      start_tunnel
      if wait_for_tunnel d1_reachable "${TUNNEL_PID}" "d1"; then
        echo "[watchdog] Túnel d1 restaurado com PID=${TUNNEL_PID}"
      else
        echo "[watchdog] Reconexão d1 falhou, nova tentativa em 30s"
        stop_pid "${TUNNEL_PID}"
      fi
    fi
    if [ -n "${D0_ENABLED}" ] && { ! kill -0 "${D0_TUNNEL_PID}" 2>/dev/null || ! d0_reachable; }; then
      echo "[watchdog] Túnel d0 caiu (PID=${D0_TUNNEL_PID}). Reconectando..."
      stop_pid "${D0_TUNNEL_PID}"
      sleep 3
      start_d0_tunnel
      if wait_for_tunnel d0_reachable "${D0_TUNNEL_PID}" "d0"; then
        echo "[watchdog] Túnel d0 restaurado com PID=${D0_TUNNEL_PID}"
      else
        echo "[watchdog] Reconexão d0 falhou, nova tentativa em 30s"
        stop_pid "${D0_TUNNEL_PID}"
        D0_TUNNEL_PID=""
      fi
    fi
  done
) &

WATCHDOG_PID=$!
echo "[watchdog] Iniciado com PID=$WATCHDOG_PID"

# ── Inicia Node.js (exec substitui o shell — watchdog segue em background) ──
exec node /app/server.js
