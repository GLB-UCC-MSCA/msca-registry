# =============================================================================
# Stage 1: Build the distribution registry binary
# =============================================================================
ARG DISTRIBUTION_VERSION=v3.1.1
FROM golang:alpine AS registry-builder

RUN apk add --no-cache git

ARG DISTRIBUTION_VERSION
WORKDIR /src
RUN git clone --branch "${DISTRIBUTION_VERSION}" --depth 1 https://github.com/distribution/distribution.git .

RUN CGO_ENABLED=0 go build -trimpath \
    -ldflags "-s -w" \
    -o /usr/bin/registry ./cmd/registry

# =============================================================================
# Stage 2: Final image — openSUSE Tumbleweed with supervisord
# =============================================================================
FROM opensuse/tumbleweed

# ── Install runtime & build dependencies ─────────────────────────────────────
RUN zypper --non-interactive refresh && \
    zypper --non-interactive install --no-recommends \
        nginx \
        ruby ruby-devel \
        supervisor \
        ca-certificates \
        git \
        # Build deps for native gem extensions
        gcc gcc-c++ make automake \
        libopenssl-devel zlib-devel \
        shared-mime-info \
        libyaml-devel \
        gzip tar \
    && zypper clean --all

# ── Copy registry binary & config ───────────────────────────────────────────
COPY --from=registry-builder /usr/bin/registry /usr/bin/registry
COPY registry-config.yml /etc/distribution/config.yml
RUN mkdir -p /var/lib/registry

# ── Install docker-registry-browser ─────────────────────────────────────────
WORKDIR /app
RUN git clone --depth 1 https://github.com/klausmeyer/docker-registry-browser.git .

RUN gem install bundler -v "$(tail -n1 Gemfile.lock | xargs)" && \
    bundle config set --local without "development test" && \
    bundle config set --local deployment true && \
    bundle install

RUN SECRET_KEY_BASE_DUMMY=1 RAILS_ENV=production \
    bundle exec rails assets:precompile

# ── Remove build-only dependencies to slim down the image ───────────────────
RUN zypper --non-interactive remove --clean-deps \
        gcc gcc-c++ make automake \
        ruby-devel libopenssl-devel zlib-devel libyaml-devel \
    ; zypper clean --all ; \
    rm -rf /tmp/* /var/tmp/*

# ── Copy nginx & supervisord configs ────────────────────────────────────────
COPY nginx.conf /etc/nginx/nginx.conf
COPY supervisord.conf /etc/supervisord.conf

# ── Create required runtime directories ─────────────────────────────────────
RUN mkdir -p /run/nginx /var/log/nginx /var/lib/nginx

# ── Default SECRET_KEY_BASE (override at runtime via -e) ────────────────────
ENV SECRET_KEY_BASE=replace_me_with_a_secure_random_value

EXPOSE 80
VOLUME ["/var/lib/registry"]

CMD ["supervisord", "-c", "/etc/supervisord.conf"]
