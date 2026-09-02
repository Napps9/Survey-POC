# syntax = docker/dockerfile:1

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t my-app .
# docker run -d -p 80:80 -p 443:443 --name my-app -e RAILS_MASTER_KEY=<value from config/master.key> my-app

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.3.6
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages.
#
# The second line is wkhtmltopdf's runtime: the wkhtmltopdf-binary gem ships a
# statically-linked Qt but still dynamically links libjpeg62, libpng16,
# libXrender, libX11, fontconfig and freetype (`ldd` on its debian_12 binary),
# none of which ruby:slim carries — and fontconfig needs at least one font
# installed or every glyph renders as a box. fonts-liberation is the
# metric-compatible Arial/Helvetica substitute the report stylesheet asks
# for. Without these every PDF render in production died at exec with
# "error while loading shared libraries", which the job surfaced only as
# "We couldn't build that PDF" (CI runs on Ubuntu runners that already have
# them, so the suite never saw it).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips sqlite3 \
      fonts-liberation libfontconfig1 libfreetype6 libjpeg62-turbo libpng16-16 libx11-6 libxrender1 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times
RUN bundle exec bootsnap precompile app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile




# Final stage for app image
FROM base

# Copy built artifacts: gems, application
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# Inflate the wkhtmltopdf binary now, while we're still root. The gem stores
# it gzipped and its launcher inflates it into the gem's own bin/ directory on
# first use — a directory owned by root under BUNDLE_PATH, which the uid-1000
# app user below can't write, so the first render in production raised
# Errno::EACCES instead of a PDF. Running --version here also execs the real
# binary, so a missing shared library fails the image build rather than the
# first download someone tries. Resolved through Gem.bin_path, which is
# exactly how config/initializers/wicked_pdf.rb finds it at runtime.
RUN bundle exec ruby -e 'exec Gem.bin_path("wkhtmltopdf-binary", "wkhtmltopdf"), "--version"'

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails db log storage tmp
USER 1000:1000

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start the server by default, this can be overwritten at runtime
EXPOSE 3000
CMD ["./bin/rails", "server"]
