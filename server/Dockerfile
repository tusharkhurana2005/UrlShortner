# ---- deps: production node_modules only -------------------------------------
FROM node:24-alpine@sha256:44fce696f38ba8c987c4db89954051000bbd05ffd8d8659ba15ed4a8602e937f AS deps
WORKDIR /app
COPY package.json package-lock.json ./
# --ignore-scripts: no third-party install scripts run during the build.
# bcrypt ships prebuilt musl binaries, so nothing needs compiling.
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

# ---- runtime ------------------------------------------------------------------
FROM node:24-alpine@sha256:44fce696f38ba8c987c4db89954051000bbd05ffd8d8659ba15ed4a8602e937f AS runtime
# Pick up Alpine security fixes released after the base image was built, and
# drop npm/yarn/corepack (not needed at runtime) along with their CVEs.
RUN apk upgrade --no-cache && \
    rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack /usr/local/bin/npm /usr/local/bin/npx \
           /usr/local/bin/corepack /opt/yarn* /usr/local/bin/yarn /usr/local/bin/yarnpkg

ARG APP_VERSION=dev
ARG GIT_COMMIT=unknown
ARG BUILD_TIME=unknown
LABEL org.opencontainers.image.title="urlshortener-api" \
      org.opencontainers.image.source="https://github.com/TUSHAR1651/UrlShortner" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.created="${BUILD_TIME}"

ENV NODE_ENV=production \
    PORT=8000 \
    APP_VERSION=${APP_VERSION} \
    GIT_COMMIT=${GIT_COMMIT} \
    BUILD_TIME=${BUILD_TIME}

WORKDIR /app
# Code stays owned by root and is only readable by the app user, so a
# compromised process cannot rewrite its own code.
COPY --from=deps /app/node_modules ./node_modules
COPY . .

USER 1000:1000
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s CMD ["wget", "-qO-", "http://127.0.0.1:8000/healthz"]
CMD ["node", "--require", "./tracing.js", "index.js"]
