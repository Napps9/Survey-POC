# wicked_pdf renders the downloadable AI results report (HTML → PDF). The
# wkhtmltopdf-binary gem ships the platform binary, so no system install is
# needed; point wicked_pdf at it explicitly rather than relying on PATH lookup.
WickedPdf.configure do |config|
  config.exe_path = Gem.bin_path("wkhtmltopdf-binary", "wkhtmltopdf")
rescue Gem::Exception, NameError
  # Binary gem unavailable (shouldn't happen in normal installs) — leave default
  # so wicked_pdf falls back to a PATH lookup and surfaces a clear error if used.
  nil
end
