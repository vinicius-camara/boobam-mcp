FROM node:20-alpine

# Instala openssh-client para o tunnel SSH
RUN apk add --no-cache openssh-client bash curl

# Instala o MCP server globalmente
RUN npm install -g @benborla29/mcp-server-mysql

# Cria diretório para a chave SSH
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

# Copia o script de inicialização
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 3000

CMD ["/start.sh"]
