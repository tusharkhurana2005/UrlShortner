# ---- build: compile the React app to static files ----------------------------
FROM node:24-alpine@sha256:44fce696f38ba8c987c4db89954051000bbd05ffd8d8659ba15ed4a8602e937f AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts
COPY . .
ARG APP_VERSION=dev
ARG GIT_COMMIT=unknown
ARG BUILD_TIME=unknown
ENV REACT_APP_VERSION=${APP_VERSION} \
    GENERATE_SOURCEMAP=false
# version.json lets anyone identify the deployed frontend build with curl.
RUN npm run build && \
    printf '{"version":"%s","commit":"%s","buildTime":"%s"}\n' "$APP_VERSION" "$GIT_COMMIT" "$BUILD_TIME" > build/version.json

# ---- runtime: unprivileged nginx serving static files ------------------------
FROM nginxinc/nginx-unprivileged:1.30-alpine@sha256:782bb89768cc87b7f95c18b95baa1af250e5d451f26794f59363540161147c01 AS runtime
ARG APP_VERSION=dev
ARG GIT_COMMIT=unknown
ARG BUILD_TIME=unknown
LABEL org.opencontainers.image.title="urlshortener-web" \
      org.opencontainers.image.source="https://github.com/tusharkhurana2005/UrlShortner" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.created="${BUILD_TIME}"

# Pick up Alpine security fixes released after the base image was built.
USER 0
RUN apk upgrade --no-cache

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build /usr/share/nginx/html
USER 101:101
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
