# ================================
# Build stage
# ================================
# Use the glibc (Debian) bun image, NOT the -alpine (musl) variant. Bun's
# musl/JavaScriptCore builds segfault during `next build` on arm64 (the x64
# musl image builds fine, arm64 crashes) — see the arm64 frontend digest
# failures on main. The glibc image is the path CI's setup-bun jobs already
# build this frontend with successfully on both arches. This is only the build
# stage; the runtime image below stays on node:22-alpine.
FROM oven/bun:1.3.14 AS builder

WORKDIR /app

# Copy package files
COPY package.json bun.lock* ./

# Install dependencies
RUN bun install --frozen-lockfile

# Copy source code
COPY . .

# Build identity, baked into the client bundle (see src/lib/version.ts). The
# build context is control-plane/web with no .git, so next.config.ts's git
# fallback yields nothing here — these args are the only source. Mirrors the
# control-plane image's STRATO_VERSION/STRATO_GIT_SHA args. Pass via
# `docker build --build-arg STRATO_VERSION=... --build-arg STRATO_GIT_SHA=...`.
ARG STRATO_VERSION="dev"
ARG STRATO_GIT_SHA=""
ENV STRATO_VERSION=${STRATO_VERSION}
ENV STRATO_GIT_SHA=${STRATO_GIT_SHA}

# Build the application
RUN bun run build

# ================================
# Production stage
# ================================
FROM node:22-alpine AS runner

# OCI image labels. `image.source` links the GHCR package to this repo (and
# grants the publishing workflow its package permissions); description and
# licenses populate the package page. See
# https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#labelling-container-images
LABEL org.opencontainers.image.source="https://github.com/samcat116/strato"
LABEL org.opencontainers.image.title="strato-frontend"
LABEL org.opencontainers.image.description="Strato web frontend: Next.js UI for the Strato private cloud platform."
LABEL org.opencontainers.image.licenses="FSL-1.1-MIT"

WORKDIR /app

ENV NODE_ENV=production
ENV PORT=3000

# Create non-root user
RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs

# Copy built application from builder
# Next.js standalone output includes everything needed to run
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static

# Set correct ownership
RUN chown -R nextjs:nodejs /app

USER nextjs

EXPOSE 3000

# Start the Next.js server
CMD ["node", "server.js"]
