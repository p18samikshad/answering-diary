# The Answering Diary — Cloud Run container.
# Security: no secrets baked in (the Gemini key is fetched from Secret Manager at runtime),
# production-only dependencies, and the process runs as a non-root user.
FROM node:22-slim

ENV NODE_ENV=production
WORKDIR /app

# Install dependencies first so this layer caches across code changes.
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

# Application code and the static frontend.
COPY server.js ./
COPY lib ./lib
COPY public ./public

# Drop privileges — the node image ships a non-root `node` user.
USER node

# Cloud Run injects PORT; 8080 is the default it expects.
ENV PORT=8080
EXPOSE 8080

CMD ["node", "server.js"]
