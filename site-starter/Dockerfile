# Build the static site, then serve it from nginx. Two stages, so the running
# image carries no node, no source and no build tools: just html, css, images
# and a web server.
FROM node:22-alpine AS build
WORKDIR /app

# Dependencies first, so a content-only change doesn't reinstall everything.
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY . .
ARG BUILD_ID=dev
ENV PUBLIC_BUILD_ID=${BUILD_ID}
# The checks run INSIDE the build: a site that fails them never becomes an image,
# so it can never replace the running one.
RUN npm run build && npm run check

FROM nginx:1.30-alpine AS runtime
RUN rm -rf /usr/share/nginx/html/*
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -q --spider http://127.0.0.1/healthz || exit 1

EXPOSE 80
