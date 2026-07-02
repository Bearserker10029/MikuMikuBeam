# syntax=docker/dockerfile:1.7
#
# MikuMikuBeam (Go + React) — multi-stage build
#
# Stage 1: build the React/Vite web client
# Stage 2: build the Go binaries (server + cli) as static binaries
# Stage 3: minimal runtime image with both binaries, the built web-client
#          assets, and the proxy/user-agent data files.

ARG GO_VERSION=1.24.5
ARG NODE_VERSION=20

# ---------- Stage 1: frontend ----------
FROM node:${NODE_VERSION}-alpine AS frontend

WORKDIR /web-client

# Install JS dependencies with a clean cache-friendly layer.
COPY web-client/package*.json web-client/bun.lockb* ./
RUN npm install --no-audit --no-fund

# Build the Vite app. Output goes to web-client/dist/public/ (per vite.config.ts).
COPY web-client/ ./
RUN npm run build

# ---------- Stage 2: backend (Go) ----------
FROM golang:${GO_VERSION}-alpine AS backend

WORKDIR /src

# Cache module downloads.
COPY go.mod go.sum ./
RUN go mod download

# Build static binaries so the final image can run on a minimal base (no glibc).
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/mmb-server ./cmd/mmb-server \
 && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/mmb-cli    ./cmd/mmb-cli

# ---------- Stage 3: runtime ----------
FROM alpine:3.20

# ca-certificates lets the Go server do TLS to upstream targets/proxies.
# wget is handy for HEALTHCHECK.
RUN apk add --no-cache ca-certificates wget

WORKDIR /app

# Copy the Go binaries.
COPY --from=backend /out/mmb-server /app/bin/mmb-server
COPY --from=backend /out/mmb-cli    /app/bin/mmb-cli

# Copy the built web-client assets where mmb-server expects them
# (it looks for ./bin/web-client relative to its CWD).
COPY --from=frontend /web-client/dist/public/ /app/bin/web-client/

# Copy data files (proxies, user agents). Keep them writable so the panel
# can update them at runtime via /configuration.
COPY data/ /app/data/

# Run as non-root.
RUN addgroup -S miku && adduser -S miku -G miku \
 && chown -R miku:miku /app
USER miku

ENV NODE_ENV=production \
    PORT=3000

EXPOSE 3000

# Lightweight healthcheck against the root — the server returns 200 for /
# when the panel is available.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/ >/dev/null 2>&1 || exit 1

CMD ["bin/mmb-server"]