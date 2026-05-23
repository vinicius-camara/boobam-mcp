#!/bin/bash
set -u

echo "=== Iniciando MCP Boobam ==="

# 1. Configurar chave SSH
echo "🔑 Configurando chave SSH..."
if [ -z "${SSH_PRIVATE_KEY:-}" ]; then
  echo "❌ SSH_PRIVATE_KEY não está definida!"
  exit 1
fi

echo "$SSH_PRIVATE_KEY" | base64 -d > /root/.ssh/id_rsa
chmod 600 /root/.ssh/id_rsa

# Verificar se a chave foi decodificada corretamente
if ! grep -q "BEGIN" /root/.ssh/id_rsa; then
  echo "❌ Chave SSH inválida (base64 decode falhou)"
  exit 1
fi
echo "✅ Chave SSH configurada"

# 2. Adicionar bastion ao known_hosts via porta 443
echo "🔍 Escaneando host na porta 443..."
ssh-keyscan -p 443 -T 15 54.210.207.242 >> /root/.ssh/known_hosts 2>&1
if [ $? -ne 0 ]; then
  echo "⚠️  ssh-keyscan falhou, adicionando StrictHostKeyChecking=no como fallback"
fi
echo "✅ known_hosts configurado"

# 3. Abrir túnel SSH via porta 443
echo "🚇 Abrindo túnel SSH (porta 443)..."
ssh -i /root/.ssh/id_rsa \
    -L 3307:boobam-aurora-qa.cluster-cnoog7catbsl.us-east-1.rds.amazonaws.com:3306 \
    ubuntu@54.210.207.242 \
    -p 443 \
    -N \
    -o ConnectTimeout=20 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=5 \
    -o StrictHostKeyChecking=no \
    -o ExitOnForwardFailure=yes \
    &
TUNNEL_PID=$!

# 4. Aguardar túnel ficar pronto
echo "⏳ Aguardando túnel ficar disponível em 127.0.0.1:3307..."
RETRIES=0
MAX_RETRIES=15
while [ $RETRIES -lt $MAX_RETRIES ]; do
  if nc -z 127.0.0.1 3307 2>/dev/null; then
    echo "✅ Túnel ativo na porta 3307!"
    break
  fi
  RETRIES=$((RETRIES + 1))
  echo "  tentativa $RETRIES/$MAX_RETRIES..."
  sleep 2
done

if [ $RETRIES -ge $MAX_RETRIES ]; then
  echo "❌ Túnel não ficou disponível após $MAX_RETRIES tentativas"
  kill $TUNNEL_PID 2>/dev/null
  exit 1
fi

# 5. Iniciar servidor MCP
echo "🚀 Iniciando MCP server (SSE mode)..."
export MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
export MYSQL_PORT="${MYSQL_PORT:-3307}"
export MYSQL_USER="${MYSQL_USER:-vinicius}"
export MYSQL_PASS="${MYSQL_PASS}"
export MYSQL_DB="${MYSQL_DB:-boobam}"
export TRANSPORT_TYPE="${TRANSPORT_TYPE:-sse}"
export PORT="${PORT:-3000}"

mcp-server-mysql
