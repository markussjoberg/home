FROM node:22-alpine
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile --prod
COPY tsconfig.json ./
COPY src ./src
COPY drizzle ./drizzle
ENV NODE_ENV=production
EXPOSE 8080
# Traefik/Docker näkevät palvelun tilan; /healthz ei vaadi tokenia.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
CMD ["pnpm", "start"]
