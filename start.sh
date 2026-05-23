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
if ! grep -q "BEGIN" /root/.ssh/id_rsa; then
  echo "❌ Chave SSH inválida"
  exit 1
fi
echo "✅ Chave SSH configurada"

# 2. known_hosts via porta 443
echo "🔍 Escaneando host na porta 443..."
ssh-keyscan -p 443 -T 15 54.210.207.242 >> /root/.ssh/known_hosts 2>&1
echo "✅ known_hosts configurado"

# 3. Túnel SSH
echo "🚇 Abrindo túnel SSH (porta 443)..."
ssh -i /root/.ssh/id_rsa \
    -L 3307:boobam-aurora-qa.cluster-cnoog7catbsl.us-east-1.rds.amazonaws.com:3306 \
    ubuntu@54.210.207.242 \
    -p 443 -N \
    -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=5 \
    -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes &
TUNNEL_PID=$!

# 4. Aguardar túnel
echo "⏳ Aguardando túnel..."
RETRIES=0
while [ $RETRIES -lt 15 ]; do
  if nc -z 127.0.0.1 3307 2>/dev/null; then
    echo "✅ Túnel ativo na porta 3307!"
    break
  fi
  RETRIES=$((RETRIES + 1))
  echo "  tentativa $RETRIES/15..."
  sleep 2
done

if [ $RETRIES -ge 15 ]; then
  echo "❌ Túnel não ficou disponível"
  exit 1
fi

# 5. Iniciar MCP server com logs detalhados
export MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
export MYSQL_PORT="${MYSQL_PORT:-3307}"
export MYSQL_USER="${MYSQL_USER:-vinicius}"
export MYSQL_PASS="${MYSQL_PASS}"
export MYSQL_DB="${MYSQL_DB:-boobam}"
export TRANSPORT_TYPE="sse"
export PORT="${PORT:-3000}"
export HOST="0.0.0.0"

echo "🚀 Iniciando MCP server na porta $PORT (host=$HOST, db=$MYSQL_DB)..."
echo "📦 Versão do node: $(node --version)"
echo "📍 Binário mcp-server-mysql: $(which mcp-server-mysql)"

# Iniciar em background para ver se sobe
mcp-server-mysql &
MCP_PID=$!
sleep 3

# Verificar se porta está ouvindo
if nc -z 127.0.0.1 $PORT 2>/dev/null; then
  echo "✅ MCP server está ouvindo na porta $PORT!"
else
  echo "⚠️  MCP server NÃO está ouvindo em 127.0.0.1:$PORT"
fi

# Verificar em 0.0.0.0 / via netstat
netstat -tlnp 2>/dev/null | grep $PORT || echo "(netstat não disponível)"
ss -tlnp 2>/dev/null | grep $PORT || echo "(ss output acima)"

# Aguardar processo MCP
wait $MCP_PID
