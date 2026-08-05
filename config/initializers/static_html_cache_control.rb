# Static HTML under public/ — today that's the VertoNow one-pager
# (public/vertonow.html) — is served by ActionDispatch::Static. Production never
# sets `config.public_file_server.headers`, so those responses go out with no
# Cache-Control at all and browsers fall back to HEURISTIC caching: they invent
# a freshness lifetime from Last-Modified and serve the old copy without asking.
#
# For a page we iterate on that means an update can sit unseen behind a stale
# copy until someone thinks to hard-refresh — and nobody thinks to. That isn't
# hypothetical: it happened while the one-pager was being built.
#
# `public_file_server.headers` can't express this on its own: it's one flat hash
# for everything under public/, and the fingerprinted files in public/assets
# SHOULD cache hard (their digest is the cache key). So the rule has to be
# path-aware, which is what this is — HTML revalidates, everything else keeps
# whatever the app already sends.
#
# Inserted at position 0 so it wraps ActionDispatch::Static and can amend what
# Static serves, without depending on Static being present in every environment.
class StaticHtmlCacheControl
  CACHE_CONTROL = "public, max-age=0, must-revalidate".freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)

    if status == 200 && env["PATH_INFO"].to_s.end_with?(".html")
      # Rack 3 headers are lowercase; drop any capitalised copy set upstream
      # (config.public_file_server.headers writes the key as given) so we don't
      # send two conflicting Cache-Control values.
      headers.delete("Cache-Control")
      headers["cache-control"] = CACHE_CONTROL
    end

    [ status, headers, body ]
  end
end

Rails.application.config.middleware.insert(0, StaticHtmlCacheControl)
