# Shared plumbing for the services that call Claude. Extracts the tool-use
# response helpers that were copy-pasted identically across every service, and
# adds lightweight per-call token-usage logging so spend (and prompt-cache hit
# rates) are observable in the logs.
module AnthropicHelpers
  private

  def tool_use?(block)
    type = block.respond_to?(:type) ? block.type : block[:type] || block["type"]
    type.to_s == "tool_use"
  end

  def input_of(block)
    raw = block.respond_to?(:input) ? block.input : (block[:input] || block["input"])
    raw.respond_to?(:to_h) ? raw.to_h : raw
  end

  def deep_stringify(obj)
    case obj
    when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
    when Array then obj.map { |v| deep_stringify(v) }
    else obj
    end
  end

  # Emit one line per Claude call with the token counts that drive the bill.
  # `cache_read` > 0 means the prompt-cache discount (0.1x input) kicked in;
  # `cache_write` is the one-time (1.25x input) cost of seeding the cache.
  # The cache_* fields are nil unless caching is in play, so they're guarded.
  #
  #   service: short label (e.g. "SurveyGenerator")
  #   usage:   an Anthropic::Usage (from response.usage, or the message_start
  #            event — which reliably carries the input/cache counts)
  #   model:   the model string actually used
  #   output_tokens: override for streaming, where the final output count arrives
  #            on the message_delta event rather than on message_start
  def log_usage(service, usage, model: nil, output_tokens: nil)
    return unless usage

    out = output_tokens || usage.output_tokens
    Rails.logger.info(
      "[AnthropicUsage] #{service}" \
      "#{" model=#{model}" if model}" \
      " in=#{usage.input_tokens} out=#{out}" \
      " cache_write=#{usage.cache_creation_input_tokens || 0}" \
      " cache_read=#{usage.cache_read_input_tokens || 0}"
    )
  rescue => e
    # Logging must never break a generation path.
    Rails.logger.warn("[AnthropicUsage] #{service}: failed to log usage: #{e.class}: #{e.message}")
  end
end
