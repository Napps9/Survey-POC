# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.

# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# to prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

# Number of worker processes. Without an explicit `workers` line Puma 8 ignores
# WEB_CONCURRENCY and starts its own default — two workers on the 512MB Render
# instance, which doubles memory and gets the process OOM-killed (the cause of
# the production 502s). Honour the env var so production runs the single worker
# it's configured for; unset (local dev/test) stays in single mode.
workers Integer(ENV.fetch("WEB_CONCURRENCY", 0))

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# Restart a worker before it OOM-kills the instance and Render 502s the whole
# app. `before_fork` only fires in clustered mode (workers >= 1), so this is a
# no-op in local dev/test single mode and only arms in production. Restart the
# largest worker when total RSS crosses ~85% of the 512MB box, checked every
# 20s. A restart drops in-flight requests on that one worker — a brief blip —
# so the ceiling is set high enough to fire only as a last resort.
before_fork do
  begin
    require "puma_worker_killer"
    PumaWorkerKiller.config do |config|
      config.ram               = Integer(ENV.fetch("PWK_RAM_MB", 512))
      config.frequency         = 20
      config.percent_usage     = 0.85
      config.rolling_restart_frequency = false
    end
    PumaWorkerKiller.start
  rescue LoadError
    # gem not present (e.g. non-production bundle) — skip the safety net.
  end
end

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Run Solid Queue inside this process instead of as a separate service. The
# worker needs the same Active Storage disk the web process has mounted, and a
# Render disk attaches to exactly one service — so a standalone worker could not
# read or write card imagery. Jobs get their own threads, which is the point:
# a 120s Claude call no longer occupies one of the three request threads.
#
# Off by default outside production so `bin/rails server` in development doesn't
# quietly start a worker; set SOLID_QUEUE_IN_PUMA=1 to opt in locally.
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"].present? || ENV["RAILS_ENV"] == "production"

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
