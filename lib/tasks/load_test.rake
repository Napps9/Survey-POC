namespace :load_test do
  desc "Seed the load-test Verto + N responses (LOAD_TEST_SEED=1 RESPONSES=50000). " \
       "IMAGES=N (IMAGE_KB=40) also attaches a logo + N card images — the full-branding " \
       "shape, so journey.js exercises the attachment loads. " \
       "Additive-only; for throwaway load-test databases — see test/load/README.md."
  task seed: :environment do
    LoadTestSeeder.run!(responses: Integer(ENV.fetch("RESPONSES", "50000")),
                        images:    Integer(ENV.fetch("IMAGES", "0")),
                        image_kb:  Integer(ENV.fetch("IMAGE_KB", "40")))
  end

  desc "Pre-warm an event Verto before doors open (TOKEN=<publish token>). " \
       "Builds the leaderboard snapshot in-process and warms the cached play " \
       "page so the first arrivals don't pay the cold render / board build."
  task prewarm: :environment do
    token = ENV["TOKEN"].to_s.strip
    abort "Set TOKEN=<publish token or link slug of the event Verto>" if token.empty?

    survey = Survey.find_by(publish_token: token) ||
             Survey.where.not(publish_token: nil).find_by(slug: token)
    abort "No published Verto resolves TOKEN=#{token.inspect}" unless survey

    puts "Pre-warming ##{survey.id} #{survey.theme.inspect} (#{token})"

    # 1) Leaderboard snapshot — built in-process, no network needed. Safe to call
    #    repeatedly (bootstrap! no-ops once a refresh has stamped the watermark).
    if survey.leaderboard_active?
      LeaderboardStanding.bootstrap!(survey)
      count = survey.leaderboard_standings.count
      puts "  leaderboard: bootstrapped (#{count} standings)"
    else
      puts "  leaderboard: not active — skipped"
    end

    # 2) Play page cache — must go through the real request path to populate the
    #    exact `player-page` key (token + updated_at + locale + wave + link), so
    #    warm it with an HTTP GET to the public URL. BASE_URL overrides; otherwise
    #    it is built from APP_PROTOCOL/APP_HOST (set in production).
    base = ENV["BASE_URL"].presence ||
           begin
             host = ENV["APP_HOST"].presence
             host && "#{ENV.fetch('APP_PROTOCOL', 'https')}://#{host}"
           end
    if base.nil?
      puts "  play page: skipped — set BASE_URL=https://app.example.com (or APP_HOST) to warm the page cache"
      next
    end

    require "net/http"
    [ "/play/#{token}", "/play/#{token}/leaderboard" ].each do |path|
      uri = URI.join(base, path)
      begin
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 15) do |http|
          http.get(uri.request_uri, "Accept" => "*/*")
        end
        puts "  GET #{path} → #{res.code}"
      rescue => e
        puts "  GET #{path} → ERROR #{e.class}: #{e.message}"
      end
    end
    puts "Done. A second run confirms the page is served from cache."
  end
end
