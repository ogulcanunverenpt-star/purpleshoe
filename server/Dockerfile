# Stage 1: Build
FROM node:20-alpine AS builder

WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .

# Stage 2: Production
FROM node:20-alpine

WORKDIR /app
COPY --from=builder /app /app

EXPOSE 3000
EXPOSE 8000

ENV NODE_ENV=production
ENV PORT=3000
ENV TCP_PORT=8000

CMD ["node", "server.js"]
