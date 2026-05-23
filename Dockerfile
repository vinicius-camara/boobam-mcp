FROM node:20-alpine

RUN apk add --no-cache openssh-client bash curl netcat-openbsd

RUN npm install -g @benborla29/mcp-server-mysql

RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 3000

CMD ["/start.sh"]
