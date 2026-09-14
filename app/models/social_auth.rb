# Social sign-in registry. A provider is live only when every credential it
# needs is present in the environment (the auth pages and the OmniAuth
# initializer both read this). Google-only for now — adding a provider means
# a strategy gem, an entry here, an initializer block and a button icon.
#
# Two lists, not one, and the same Google client behind both. CREATORS sign in
# as a User through /auth/google_oauth2; RESPONDENTS sign in as a Player
# through /auth/google_player. Mounting the strategy twice under different
# names is what gives each population its own callback path, and that is the
# whole point: the two are different tables with different cookies (see
# PlayerAuthentication), so which account a callback is entitled to create
# must be decided by the URL Google was sent to, not by a flag left in a
# session that the other flow could still be carrying.
module SocialAuth
  Provider = Struct.new(:key, :label, :env_keys)

  GOOGLE_ENV = %w[GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET].freeze

  PROVIDERS = [
    Provider.new(:google_oauth2, "Google", GOOGLE_ENV)
  ].freeze

  # The respondent side. Each needs its own authorized redirect URI on the
  # Google client — see .env.example.
  PLAYER_PROVIDERS = [
    Provider.new(:google_player, "Google", GOOGLE_ENV)
  ].freeze

  ALL = (PROVIDERS + PLAYER_PROVIDERS).freeze

  def self.enabled
    PROVIDERS.select { |p| configured?(p) }
  end

  def self.enabled?(key)
    enabled.any? { |p| p.key == key.to_sym }
  end

  def self.player_enabled
    PLAYER_PROVIDERS.select { |p| configured?(p) }
  end

  def self.player_enabled?(key = nil)
    key ? player_enabled.any? { |p| p.key == key.to_sym } : player_enabled.any?
  end

  # Whether this strategy name belongs to the respondent side AT ALL — the
  # registry, not the environment. #failure has to route someone back to the
  # right door even in a configuration where the strategy is no longer mounted,
  # and "is it switched on" is a different question from "whose is it".
  def self.player_strategy?(key)
    return false if key.blank?

    PLAYER_PROVIDERS.any? { |p| p.key.to_s == key.to_s }
  end

  def self.label_for(key)
    ALL.find { |p| p.key == key.to_sym }&.label || key.to_s.titleize
  end

  def self.configured?(provider)
    provider.env_keys.all? { |k| ENV[k].present? }
  end
  private_class_method :configured?
end
