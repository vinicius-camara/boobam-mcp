#!/bin/bash

echo "🔑 Configurando chave SSH..."

if [ -z "$SSH_PRIVATE_KEY" ]; then
  echo "❌ SSH_PRIVATE_KEY não está definida!"
  exit 1
fi

echo "🌐 IP externo deste container: $(curl -s --max-time 5 ifconfig.me || echo 'nao obtido')"

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

echo "🔌 Testando TCP na porta 22 do bastion..."
nc -zv -w 10 54.210.207.242 22
NC_EXIT=$?
if [ $NC_EXIT -ne 0 ]; then
  echo "❌ PORTA 22 INACESSIVEL (nc exit $NC_EXIT) — bloqueio de rede confirmado"
  sleep 30
  exit 1
fi
echo "✅ TCP porta 22 OK"

echo "🔍 Adicionando fingerprint do bastion..."
ssh-keyscan -T 10 -H 54.210.207.242 >> /root/.ssh/known_hosts 2>&1
echo "   ssh-keyscan exit: $?"

echo "🔌 Abrindo tunnel SSH..."
ssh -v \
    -i /root/.ssh/id_rsa \
    -L 3307:boobam-aurora-qa.cluster-cnoog7catbsl.us-east-1.rds.amazonaws.com:3306 \
    devops@54.210.207.242 \
    -N \
    -o ConnectTimeout=20 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=5 \
    -o StrictHostKeyChecking=no \
    -o ExitOnForwardFailure=yes \
    2>&1 &

TUNNEL_PID=$!

echo "⏳ Aguardando tunnel (porta 3307)..."
for i in $(seq 1 25); do
  if nc -z 127.0.0.1 3307 2>/dev/null; then
    echo "✅ Tunnel ativo! Porta 3307 acessível (tentativa $i)"
    break
  fi
  if ! kill -0 $TUNNEL_PID 2>/dev/null; then
    echo "❌ Processo SSH morreu na tentativa $i"
    exit 1
  fi
  echo "   aguardando... ($i/25)"
  sleep 1
done

if ! nc -z 127.0.0.1 3307 2>/dev/null; then
  echo "❌ Timeout: porta 3307 nunca ficou disponível"
  exit 1
fi

echo "🚀 Iniciando MCP Server MySQL..."
exec mcp-server-mysql
