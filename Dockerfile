# syntax=docker/dockerfile:1.7

ARG RUBY_VERSION=4.0.0

FROM ruby:${RUBY_VERSION}-slim AS base

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT="development:test" \
    RAILS_ENV=production \
    RAILS_LOG_TO_STDOUT=true \
    RAILS_SERVE_STATIC_FILES=true

WORKDIR /lobsters

RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       libjemalloc2 \
       libvips \
       mariadb-client \
       tini \
    && rm -rf /var/lib/apt/lists/*

FROM base AS build

RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
       build-essential \
       clang \
       git \
       libffi-dev \
       libmariadb-dev \
       libyaml-dev \
       pkg-config \
    && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock .ruby-version ./
RUN bundle install \
    && bundle clean --force \
    && rm -rf "${BUNDLE_PATH}"/ruby/*/cache

COPY . .

RUN mkdir -p log tmp storage public/cache

RUN SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile

FROM base AS final

COPY --from=build ${BUNDLE_PATH} ${BUNDLE_PATH}
COPY --from=build /lobsters /lobsters

RUN chmod u+x /lobsters/docker-entrypoint.sh \
    && groupadd -r -g 1000 lobsters \
    && useradd -r -u 1000 -g lobsters -d /lobsters -s /usr/sbin/nologin lobsters \
    && chown -R lobsters:lobsters /lobsters

USER lobsters

EXPOSE 3000

ENTRYPOINT ["/usr/bin/tini", "--", "/lobsters/docker-entrypoint.sh"]
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0", "-p", "3000"]
