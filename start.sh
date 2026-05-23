#!/bin/bash

echo "🔑 Configurando chave SSH..."

# Verifica se SSH_PRIVATE_KEY está definida
if [ -z "$SSH_PRIVATE_KEY" ]; then
  echo "❌ SSH_PRIVATE_KEY não está definida!"
  exit 1
fi

echo "🌐 IP externo deste container: $(curl -s --max-time 5 ifconfig.me || echo 'nao obtido')"

echo "📏 Tamanho da chave base64: ${#SSH_PRIVATE_KEY} chars"

# Decodifica a chave
echo "$SSH_PRIVATE_KEY" | base64 -d > /root/.ssh/id_rsa 2>/tmp/b64err
B64_EXIT=$?
if [ $B64_EXIT -ne 0 ]; then
  echo "❌ Falha no base64 decode (exit $B64_EXIT):"
  cat /tmp/b64err
  exit 1
fi

KEYSIZE=$(wc -c < /root/.ssh/id_rsa)
echo "✅ Chave decodificada: $KEYSIZE bytes"
chmod 600 /root/.ssh/id_rsa

echo "🔍 Adicionando fingerprint do bastion..."
ssh-keyscan -T 10 -H 54.210.207.242 >> /root/.ssh/known_hosts 2>&1
echo "   ssh-keyscan exit: $?"

echo "🔌 Abrindo tunnel SSH..."
ssh -v \
    -i /root/.ssh/id_rsa \
    -L 3307:boobam-aurora-qa.cluster-cnoog7catbsl.us-east-1.rds.amazonaws.com:3306 \
    devops@54.210.207.242 \
    -N \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=5 \
    -o StrictHostKeyChecking=no \
    -o ExitOnForwardFailure=yes \
    2>&1 &

TUNNEL_PID=$!
echo "⏳ Aguardando 5s (PID: $TUNNEL_PID)..."
sleep 5

if ! kill -0 $TUNNEL_PID 2>/dev/null; then
  echo "❌ Tunnel falhou — verifique logs SSH acima"
  exit 1
fi

echo "✅ Tunnel ativo!"
echo "🚀 Iniciando MCP Server MySQL..."
exec mcp-server-mysql
