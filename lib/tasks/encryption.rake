namespace :encryption do
  # A short, non-reversible fingerprint of each key, so a backup can be checked
  # against what production is actually running WITHOUT either of them ever
  # being printed, pasted into a terminal history, or scrolled past on a shared
  # screen.
  #
  # Twelve hex characters of SHA-256. Enough that a match is not a coincidence,
  # far too little to reconstruct a 32+ character key from.
  FINGERPRINT_LENGTH = 12

  def fingerprint(value)
    return "(not set)" if value.to_s.strip.empty?

    Digest::SHA256.hexdigest(value.to_s)[0, FINGERPRINT_LENGTH]
  end

  desc "Print non-reversible fingerprints of the Active Record encryption keys, " \
       "so a backup can be verified against production without exposing either. " \
       "Run it on the server and against your stored copy; the pairs must match."
  task fingerprints: :environment do
    keys = {
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"         => ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"],
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"   => ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"],
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]
    }

    puts "Active Record encryption key fingerprints (SHA-256, first #{FINGERPRINT_LENGTH} hex chars)"
    puts "These are one-way. Compare them; do not treat them as the keys."
    puts
    keys.each { |name, value| puts format("  %-46s %s", name, fingerprint(value)) }
    puts

    missing = keys.select { |_n, v| v.to_s.strip.empty? }.keys
    if missing.any?
      puts "MISSING: #{missing.join(', ')}"
      puts "In production that means stored Google tokens cannot be decrypted."
      puts "See docs/ENCRYPTION_KEYS.md."
    else
      puts "All three are set."
    end
  end

  desc "Report how many stored Google tokens can no longer be decrypted — a direct " \
       "check that the keys in use still match the data. Reads nothing out."
  task verify: :environment do
    total = User.where.not(google_refresh_token: nil).count
    if total.zero?
      puts "No stored Google tokens; nothing to verify."
      next
    end

    unreadable = User.where.not(google_refresh_token: nil).count do |user|
      user.google_refresh_token
      false
    rescue ActiveRecord::Encryption::Errors::Decryption
      true
    end

    puts "Stored Google tokens: #{total}"
    puts "Undecryptable:        #{unreadable}"
    if unreadable.positive?
      puts
      puts "The encryption keys in use do not match the data. Restore the originals"
      puts "from your secret store, or put them in ACTIVE_RECORD_ENCRYPTION_PREVIOUS_KEYS."
      puts "See docs/ENCRYPTION_KEYS.md."
      exit 1
    end
  end
end
