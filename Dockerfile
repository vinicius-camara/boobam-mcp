FROM node:20-alpine

RUN apk add --no-cache openssh-client bash curl netcat-openbsd

# Instalar dependências Node
WORKDIR /app
COPY package.json /app/package.json
RUN npm install --omit=dev

RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

COPY server.js /app/server.js
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 3000
CMD ["/start.sh"]
