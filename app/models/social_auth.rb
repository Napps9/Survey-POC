# Social sign-in registry. A provider is live only when every credential it
# needs is present in the environment, so each one can be rolled out
# independently (the auth pages and the OmniAuth initializer both read this).
module SocialAuth
  Provider = Struct.new(:key, :label, :env_keys)

  PROVIDERS = [
    Provider.new(:google_oauth2, "Google",    %w[GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET]),
    Provider.new(:entra_id,      "Microsoft", %w[MICROSOFT_CLIENT_ID MICROSOFT_CLIENT_SECRET]),
    Provider.new(:apple,         "Apple",     %w[APPLE_CLIENT_ID APPLE_TEAM_ID APPLE_KEY_ID APPLE_PRIVATE_KEY])
  ].freeze

  def self.enabled
    PROVIDERS.select { |p| p.env_keys.all? { |k| ENV[k].present? } }
  end

  def self.enabled?(key)
    enabled.any? { |p| p.key == key.to_sym }
  end

  def self.label_for(key)
    PROVIDERS.find { |p| p.key == key.to_sym }&.label || key.to_s.titleize
  end
end
