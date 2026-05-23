#!/bin/bash
set -eu

echo "=== Iniciando Boobam MCP Server ==="
echo "Node: $(node --version)"

# ── Prepara chave SSH ────────────────────────────────────────────────────────
echo "$SSH_PRIVATE_KEY" | base64 -d > /root/.ssh/id_rsa && chmod 600 /root/.ssh/id_rsa
ssh-keyscan -p 443 -T 15 54.210.207.242 >> /root/.ssh/known_hosts 2>&1

BASTION="54.210.207.242"
BASTION_PORT="443"
RDS_HOST="boobam-aurora-qa.cluster-cnoog7catbsl.us-east-1.rds.amazonaws.com"
LOCAL_PORT="3307"
RDS_PORT="3306"
TUNNEL_PID=""

# ── Função: abre o túnel SSH em background ───────────────────────────────────
start_tunnel() {
  ssh -i /root/.ssh/id_rsa \
      -L "${LOCAL_PORT}:${RDS_HOST}:${RDS_PORT}" \
      ubuntu@${BASTION} -p ${BASTION_PORT} -N \
      -o ConnectTimeout=20 \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      -o StrictHostKeyChecking=no \
      -o ExitOnForwardFailure=yes &
  TUNNEL_PID=$!
  echo "[tunnel] PID=$TUNNEL_PID iniciado"
}

# ── Aguarda túnel ficar pronto (porta local acessível) ───────────────────────
wait_for_tunnel() {
  for i in $(seq 1 25); do
    if nc -z 127.0.0.1 "${LOCAL_PORT}" 2>/dev/null; then
      echo "✅ Túnel ativo na tentativa $i"
      return 0
    fi
    if ! kill -0 "${TUNNEL_PID}" 2>/dev/null; then
      echo "❌ SSH encerrou antes de estar pronto (tentativa $i)"
      return 1
    fi
    sleep 2
  done
  echo "❌ Tempo esgotado aguardando túnel"
  return 1
}

# ── Primeira conexão ─────────────────────────────────────────────────────────
start_tunnel
until wait_for_tunnel; do
  echo "[tunnel] Falha na conexão inicial, tentando novamente em 5s..."
  kill "${TUNNEL_PID}" 2>/dev/null || true
  sleep 5
  start_tunnel
done

# ── Watchdog: monitora e reconecta o túnel em background ────────────────────
(
  while true; do
    sleep 10
    # Verifica se o processo SSH ainda existe E se a porta local está acessível
    if ! kill -0 "${TUNNEL_PID}" 2>/dev/null || ! nc -z 127.0.0.1 "${LOCAL_PORT}" 2>/dev/null; then
      echo "[watchdog] Túnel caiu (PID=${TUNNEL_PID}). Reconectando..."
      kill "${TUNNEL_PID}" 2>/dev/null || true
      # Aguarda porta liberar antes de abrir novo túnel
      sleep 3
      start_tunnel
      if wait_for_tunnel; then
        echo "[watchdog] Túnel restaurado com PID=${TUNNEL_PID}"
      else
        echo "[watchdog] Reconexão falhou, watchdog tentará novamente em 10s"
        kill "${TUNNEL_PID}" 2>/dev/null || true
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

# ── Inicia Node.js (exec substitui o shell — watchdog segue em background) ──
exec node /app/server.js
