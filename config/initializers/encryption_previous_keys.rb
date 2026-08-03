# frozen_string_literal: true

# Keys the encrypted columns may ALSO have been written with.
#
# Reading tries the primary key first and falls back through these, so the
# encryption keys can be rotated without a re-encryption window: set the OLD
# primary in ACTIVE_RECORD_ENCRYPTION_PREVIOUS_KEYS, deploy the new one, and
# rows written under the old key keep decrypting until they are next saved.
#
# Without it, rotating is indistinguishable from losing the keys — and losing
# them is the failure this path exists to survive (see docs/ENCRYPTION_KEYS.md).
# Comma-separated so a staged rotation can carry more than one generation.
#
# It lives in an initializer rather than in config/application.rb because
# ActiveRecord::Encryption::DerivedSecretKeyProvider derives its key IN THE
# CONSTRUCTOR, from `key_derivation_salt` on the global encryption config — and
# that config is not applied until after application.rb has run. Building it
# there raises "Missing Active Record encryption credential" at boot, which is
# how this was found.
previous_keys = ENV["ACTIVE_RECORD_ENCRYPTION_PREVIOUS_KEYS"].to_s
                   .split(",").map(&:strip).reject(&:empty?)

if previous_keys.any? && ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present?
  Rails.application.config.after_initialize do
    previous_keys.each do |old_key|
      ActiveRecord::Encryption.config.previous_schemes << ActiveRecord::Encryption::Scheme.new(
        key_provider: ActiveRecord::Encryption::DerivedSecretKeyProvider.new(old_key)
      )
    end
    # The per-attribute scheme list is SNAPSHOTTED when the encrypted attribute
    # type is built, and memoized. Today types build lazily, after this hook —
    # but enabling the standard schema-cache boot optimization builds them
    # earlier, and this append would then silently do nothing, killing the
    # disaster-recovery path exactly when it is needed. Resetting the one model
    # with encrypted columns forces its types to rebuild with the appended
    # schemes, whichever order boot ran in.
    User.reset_column_information if defined?(User)
  end
end
