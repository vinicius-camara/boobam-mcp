#!/bin/bash

echo "🔑 Configurando chave SSH..."

if [ -z "$SSH_PRIVATE_KEY" ]; then
  echo "❌ SSH_PRIVATE_KEY não está definida!"
  exit 1
fi

echo "🌐 IP externo deste container: $(curl -s --max-time 5 ifconfig.me || echo 'nao obtido')"

echo "🧪 Testando saída porta 22 (github.com)..."
nc -zv -w 5 github.com 22 && echo "✅ Porta 22 SAÍDA OK" || echo "❌ Porta 22 BLOQUEADA pelo Railway"

echo "🧪 Testando saída porta 443 (github.com)..."
nc -zv -w 5 github.com 443 && echo "✅ Porta 443 OK" || echo "❌ Porta 443 bloqueada"

echo "🧪 Testando porta 22 no bastion..."
nc -zv -w 10 54.210.207.242 22 && echo "✅ Bastion porta 22 OK" || echo "❌ Bastion porta 22 INACESSIVEL"

sleep 30
