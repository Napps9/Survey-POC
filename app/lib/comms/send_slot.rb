# Rolls a due time forward into an automation's send window: send_hour
# (0-23) pins the hour, send_days (ISO 1=Mon..7=Sun) pins the weekdays,
# both interpreted in COMMS_TIME_ZONE (no per-recipient timezone exists).
# nil hour + empty days = deliver as due.
module Comms
  module SendSlot
    module_function

    def resolve(base, send_hour, send_days, tz: ENV.fetch("COMMS_TIME_ZONE", "UTC"))
      zone = ActiveSupport::TimeZone[tz] || ActiveSupport::TimeZone["UTC"]
      t = base.in_time_zone(zone)
      days = Array(send_days).map(&:to_i).select { |d| (1..7).cover?(d) }

      if send_hour.present?
        slot = t.change(hour: send_hour.to_i, min: 0)
        t = slot < t ? slot + 1.day : slot
      end

      if days.any?
        t += 1.day until days.include?(iso_wday(t))
        t = t.change(hour: send_hour.to_i, min: 0) if send_hour.present?
      end

      t
    end

    def iso_wday(time)
      time.wday.zero? ? 7 : time.wday
    end
  end
end
