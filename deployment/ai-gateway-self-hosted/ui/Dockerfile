FROM node:22-alpine

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY server.js ./server.js
COPY public ./public

ENV PORT=3000
EXPOSE 3000

USER node
CMD ["node", "server.js"]