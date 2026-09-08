# frozen_string_literal: true

require "uri"

# The browser-facing origins of the Active Storage `bucket` service, derived
# from the same env the service itself reads (config/storage.yml).
#
# Needed at BOOT by the Content-Security-Policy initializer: a redirect-mode
# blob URL (rails_blob_path — every card image) answers with a 302 to a
# presigned URL on the bucket's host, and the browser evaluates img-src and
# connect-src against the redirect TARGET as well as the original request.
# Without these origins in the policy every card image is silently blocked the
# moment the app is switched to the bucket, while the same-origin logo (served
# through the proxy route) keeps working — a confusing half-broken page.
#
# Lives in lib/ and is `require`d explicitly (like lib/request_timeout) because
# reloadable app/ constants can't be referenced from an initializer.
module ObjectStorageOrigins
  module_function

  # [] when no bucket is configured (local disk: everything is same-origin).
  # Otherwise both addressing styles the SDK might presign — path-style (host
  # is the endpoint itself) and virtual-hosted (bucket.<endpoint host>) — so a
  # change of `force_path_style` can never take the images down.
  def allowed(env = ENV)
    bucket = env["STORAGE_BUCKET"].to_s.strip
    return [] if bucket.empty?

    endpoint = env["STORAGE_ENDPOINT"].to_s.strip
    return amazon(bucket, env["STORAGE_REGION"]) if endpoint.empty?

    uri = URI.parse(endpoint)
    return [] unless uri.host && uri.scheme

    port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
    [ "#{uri.scheme}://#{uri.host}#{port}", "#{uri.scheme}://*.#{uri.host}#{port}" ]
  rescue URI::InvalidURIError
    []
  end

  # Plain AWS S3 (no custom endpoint): the regional virtual-hosted and
  # path-style hosts. "auto" is R2's region and means nothing to AWS.
  def amazon(bucket, region)
    region = region.to_s.strip
    region = "us-east-1" if region.empty? || region == "auto"
    [ "https://#{bucket}.s3.#{region}.amazonaws.com", "https://s3.#{region}.amazonaws.com" ]
  end
  private_class_method :amazon
end
