#!/bin/bash
set -eu

echo "=== Iniciando Boobam MCP Server ==="
echo "Node: $(node --version)"

# ── 1. Chave SSH ──────────────────────────────────────────────────────────────
echo "🔑 Configurando chave SSH..."
if [ -z "${SSH_PRIVATE_KEY:-}" ]; then
  echo "❌ SSH_PRIVATE_KEY não definida!"
  exit 1
fi
echo "$SSH_PRIVATE_KEY" | base64 -d > /root/.ssh/id_rsa
chmod 600 /root/.ssh/id_rsa
if ! grep -q "BEGIN" /root/.ssh/id_rsa; then
  echo "❌ Chave SSH inválida (conteúdo inesperado)"
  exit 1
fi
echo "✅ Chave SSH OK"

# ── 2. known_hosts ────────────────────────────────────────────────────────────
echo "🔍 Escaneando fingerprint do bastion (porta 443)..."
ssh-keyscan -p 443 -T 15 54.210.207.242 >> /root/.ssh/known_hosts 2>&1
echo "✅ known_hosts configurado"

# ── 3. Túnel SSH via porta 443 ────────────────────────────────────────────────
echo "🚇 Abrindo túnel SSH..."
ssh -i /root/.ssh/id_rsa \
    -L 3307:boobam-aurora-qa.cluster-cnoog7catbsl.us-east-1.rds.amazonaws.com:3306 \
    ubuntu@54.210.207.242 \
    -p 443 -N \
    -o ConnectTimeout=20 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=5 \
    -o StrictHostKeyChecking=no \
    -o ExitOnForwardFailure=yes &
TUNNEL_PID=$!

# ── 4. Aguardar porta 3307 ────────────────────────────────────────────────────
echo "⏳ Aguardando túnel MySQL (porta 3307)..."
for i in $(seq 1 20); do
  if nc -z 127.0.0.1 3307 2>/dev/null; then
    echo "✅ Túnel ativo! (tentativa $i)"
    break
  fi
  if ! kill -0 $TUNNEL_PID 2>/dev/null; then
    echo "❌ Processo SSH encerrou prematuramente"
    exit 1
  fi
  echo "  aguardando... $i/20"
  sleep 2
done

if ! nc -z 127.0.0.1 3307 2>/dev/null; then
  echo "❌ Porta 3307 não ficou disponível após 40s"
  exit 1
fi

# ── 5. Variáveis de ambiente ──────────────────────────────────────────────────
export MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
export MYSQL_PORT="${MYSQL_PORT:-3307}"
export MYSQL_USER="${MYSQL_USER:-vinicius}"
export MYSQL_PASS="${MYSQL_PASS:-}"
export MYSQL_DB="${MYSQL_DB:-boobam}"
export PORT="${PORT:-3000}"

echo "🚀 Iniciando MCP server..."
echo "   MySQL: $MYSQL_USER@$MYSQL_HOST:$MYSQL_PORT/$MYSQL_DB"
echo "   HTTP:  0.0.0.0:$PORT"

# ── 6. Iniciar servidor Node.js ───────────────────────────────────────────────
exec node /app/server.js
