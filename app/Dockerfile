FROM node:20-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY otel.js server.js ./
EXPOSE 3000
USER node
CMD ["node", "-r", "./otel.js", "server.js"]
