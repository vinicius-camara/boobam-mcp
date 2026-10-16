#!/bin/bash
set -eu

echo "=== Iniciando Boobam MCP Server ==="
echo "Node: $(node --version)"

# ── Prepara chave SSH ────────────────────────────────────────────────────────
echo "$SSH_PRIVATE_KEY" | base64 -d > /root/.ssh/id_rsa && chmod 600 /root/.ssh/id_rsa
ssh-keyscan -p 443 -T 15 54.210.207.242 >> /root/.ssh/known_hosts 2>&1

BASTION="54.210.207.242"
BASTION_PORT="443"

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

# ── Aguarda túnel ficar pronto (porta local acessível) ───────────────────────
wait_for_port() {
  local port="$1" pid="$2" label="$3"
  for i in $(seq 1 25); do
    if nc -z 127.0.0.1 "${port}" 2>/dev/null; then
      echo "✅ Túnel ${label} ativo na tentativa $i"
      return 0
    fi
    if ! kill -0 "${pid}" 2>/dev/null; then
      echo "❌ SSH ${label} encerrou antes de estar pronto (tentativa $i)"
      return 1
    fi
    sleep 2
  done
  echo "❌ Tempo esgotado aguardando túnel ${label}"
  return 1
}

# ── Primeira conexão (D-1, obrigatória) ──────────────────────────────────────
start_tunnel
until wait_for_port "${LOCAL_PORT}" "${TUNNEL_PID}" "d1"; do
  echo "[tunnel d1] Falha na conexão inicial, tentando novamente em 5s..."
  kill "${TUNNEL_PID}" 2>/dev/null || true
  sleep 5
  start_tunnel
done

# ── Primeira conexão (D0, melhor esforço) ────────────────────────────────────
start_d0_tunnel
if ! wait_for_port "${D0_LOCAL_PORT}" "${D0_TUNNEL_PID}" "d0"; then
  echo "[tunnel d0] ⚠️ Não ficou pronto no boot — watchdog seguirá tentando"
  kill "${D0_TUNNEL_PID}" 2>/dev/null || true
  D0_TUNNEL_PID="0"
fi

# ── Watchdog: monitora e reconecta os túneis em background ──────────────────
(
  while true; do
    sleep 10
    if ! kill -0 "${TUNNEL_PID}" 2>/dev/null || ! nc -z 127.0.0.1 "${LOCAL_PORT}" 2>/dev/null; then
      echo "[watchdog] Túnel d1 caiu (PID=${TUNNEL_PID}). Reconectando..."
      kill "${TUNNEL_PID}" 2>/dev/null || true
      sleep 3
      start_tunnel
      if wait_for_port "${LOCAL_PORT}" "${TUNNEL_PID}" "d1"; then
        echo "[watchdog] Túnel d1 restaurado com PID=${TUNNEL_PID}"
      else
        echo "[watchdog] Reconexão d1 falhou, nova tentativa em 10s"
        kill "${TUNNEL_PID}" 2>/dev/null || true
      fi
    fi
    if ! kill -0 "${D0_TUNNEL_PID}" 2>/dev/null || ! nc -z 127.0.0.1 "${D0_LOCAL_PORT}" 2>/dev/null; then
      echo "[watchdog] Túnel d0 caiu (PID=${D0_TUNNEL_PID}). Reconectando..."
      kill "${D0_TUNNEL_PID}" 2>/dev/null || true
      sleep 3
      start_d0_tunnel
      if wait_for_port "${D0_LOCAL_PORT}" "${D0_TUNNEL_PID}" "d0"; then
        echo "[watchdog] Túnel d0 restaurado com PID=${D0_TUNNEL_PID}"
      else
        echo "[watchdog] Reconexão d0 falhou, nova tentativa em 10s"
        kill "${D0_TUNNEL_PID}" 2>/dev/null || true
        D0_TUNNEL_PID="0"
      fi
    fi
  done
) &

WATCHDOG_PID=$!
echo "[watchdog] Iniciado com PID=$WATCHDOG_PID"

# ── Variáveis do servidor Node ───────────────────────────────────────────────
export MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
export MYSQL_PORT="${MYSQL_PORT:-3307}"
export MYSQL_USER="${MYSQL_USER:-vinicius}"
export MYSQL_PASS="${MYSQL_PASS:-}"
export MYSQL_DB="${MYSQL_DB:-boobam}"
export PORT="${PORT:-3000}"

# D0 (produção, somente leitura) — aponta para o túnel local 3308.
# Só é ativado se D0_MYSQL_USER e D0_MYSQL_PASS estiverem definidos no Railway.
if [ -n "${D0_MYSQL_USER:-}" ] && [ -n "${D0_MYSQL_PASS:-}" ]; then
  export D0_MYSQL_HOST="${D0_MYSQL_HOST:-127.0.0.1}"
  export D0_MYSQL_PORT="${D0_MYSQL_PORT:-3308}"
  export D0_MYSQL_DB="${D0_MYSQL_DB:-boobam}"
else
  echo "⚠️ D0_MYSQL_USER/D0_MYSQL_PASS ausentes — fonte d0 desativada"
  unset D0_MYSQL_HOST || true
fi

# ── Inicia Node.js (exec substitui o shell — watchdog segue em background) ──
exec node /app/server.js
