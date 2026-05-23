#!/bin/bash
set -e

echo "🔑 Configurando chave SSH..."

# A chave SSH vem como variável de ambiente em base64
echo "$SSH_PRIVATE_KEY" | base64 -d > /root/.ssh/id_rsa
chmod 600 /root/.ssh/id_rsa

# Aceita o fingerprint do bastion automaticamente
ssh-keyscan -H 54.210.207.242 >> /root/.ssh/known_hosts 2>/dev/null

echo "🔌 Abrindo tunnel SSH para Aurora RDS..."
ssh -i /root/.ssh/id_rsa \
    -L 3307:boobam-aurora-qa.cluster-cnoog7catbsl.us-east-1.rds.amazonaws.com:3306 \
    devops@54.210.207.242 \
    -N \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=5 \
    -o StrictHostKeyChecking=no \
    -o ExitOnForwardFailure=yes &

TUNNEL_PID=$!
echo "✅ Tunnel aberto (PID: $TUNNEL_PID)"

# Aguarda o tunnel estabilizar
sleep 3

# Verifica se o tunnel está ativo
if ! kill -0 $TUNNEL_PID 2>/dev/null; then
  echo "❌ Tunnel falhou ao iniciar"
  exit 1
fi

echo "🚀 Iniciando MCP Server..."
exec mcp-server-mysql

# Se o tunnel cair, reinicia o container
wait $TUNNEL_PID
echo "⚠️ Tunnel encerrado — reiniciando..."
exit 1
