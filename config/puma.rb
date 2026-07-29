# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.
#
# Production runs ONE Ruby process that does everything: Puma in single mode
# serving requests on 3 threads, with Solid Queue's dispatcher/worker/scheduler
# as supervised threads inside it (async plugin mode, below). The previous
# arrangement — cluster mode with one worker plus Solid Queue's forking
# supervisor tree — put SIX Ruby processes on the 512MB Render instance
# (master, worker, supervisor, dispatcher, queue worker, scheduler). Their
# combined footprint sat against the container's memory limit from boot, and
# the kernel OOM-killed the container over and over (the July 2026 crash
# loop) — while puma_worker_killer watched only master+worker RSS and so never
# fired. One process leaves real headroom for the transient spikes
# (wkhtmltopdf report renders, libvips variants) that used to tip the box over.

# Puma serves each request in a thread from an internal thread pool. The
# default of 3 is a decent compromise between throughput and latency for the
# average Rails application; libraries using a connection pool should provide
# at least as many connections (see config/database.yml, which also covers the
# in-process Solid Queue threads).
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

# Single mode (workers 0) everywhere unless WEB_CONCURRENCY explicitly opts
# into cluster workers. Without an explicit `workers` line Puma 8 ignores
# WEB_CONCURRENCY and starts its own default — two workers on the 512MB Render
# instance, which doubles memory and gets the process OOM-killed. On one vCPU
# a second worker buys no parallelism; it only duplicates the app's memory.
workers Integer(ENV.fetch("WEB_CONCURRENCY", 0))

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Run Solid Queue inside this process instead of as a separate service. The
# worker needs the same Active Storage disk the web process has mounted, and a
# Render disk attaches to exactly one service — so a standalone worker could not
# read or write card imagery.
#
# :async mode runs the dispatcher, worker and scheduler as supervised THREADS
# in this process, not as the default forked supervisor + three child
# processes — that fork tree cost ~150-250MB the 512MB instance didn't have
# (and is why it kept getting OOM-killed). Threads are all this workload
# needs: the jobs are I/O-bound Claude calls that release the GVL while they
# wait, which is also why they were moved off the request threads in the
# first place. Worker thread count lives in config/queue.yml.
#
# Off by default outside production so `bin/rails server` in development
# doesn't quietly start a worker; set SOLID_QUEUE_IN_PUMA=1 to opt in locally.
if !ENV["SOLID_QUEUE_IN_PUMA"].to_s.empty? || ENV["RAILS_ENV"] == "production"
  plugin :solid_queue
  solid_queue_mode :async
end

# Replace puma_worker_killer (cluster-only, and blind to everything but
# master+worker RSS) with a watchdog on the container's actual cgroup memory —
# the number the kernel OOM killer enforces. It logs usage every 30s and
# hot-restarts Puma gracefully if usage stays over 90% of the limit, instead
# of letting the platform SIGKILL the container mid-request. No-ops where no
# cgroup limit exists; set MEMORY_WATCHDOG=1 to exercise it locally.
if ENV["RAILS_ENV"] == "production" || !ENV["MEMORY_WATCHDOG"].to_s.empty?
  require_relative "../lib/puma/plugin/memory_watchdog"
  plugin :memory_watchdog
end

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
