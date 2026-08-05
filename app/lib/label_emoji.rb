# Pulls a leading (or trailing) emoji out of an answer option's label so it can
# live in the option's icon tile instead of sitting inline beside the words.
#
# Generated decks routinely produce labels like "🎯 Pay off debt". The emoji
# rendered in the text while the tile beside it keyword-matched a DIFFERENT icon
# — OptionIconLibrary.normalize strips non-alphanumerics, so the emoji never
# blocked the match, it just doubled up with it. Survey#hoist_option_label_emoji
# promotes what this returns into option_styles[i]["emoji"], after which every
# existing render path (option_tile_icon, choice_templates.js, the repaint
# paths) already draws it in the tile.
#
# Codepoints, not String#grapheme_clusters: the cluster rules below are the
# contract this app relies on, and they must not shift under it when Ruby
# updates its UAX#29 tables. Ruby 3.3 also has no \p{Emoji} /
# \p{Extended_Pictographic} (both raise RegexpError), so a property class isn't
# an option server-side anyway.
module LabelEmoji
  module_function

  # Emoji by default — no variation selector needed. 1F000–1FAFF covers the
  # emoticon/transport/supplemental/extended-A blocks, and with them the
  # regional indicators (1F1E6–1F1FF, flags) and skin-tone modifiers
  # (1F3FB–1F3FF), so both are consumed by the cluster loop for free.
  EMOJI_RANGES = [
    0x1F000..0x1FAFF, 0x2600..0x27BF, 0x2B00..0x2BFF,
    0x2934..0x2935, 0x3030..0x3030, 0x303D..0x303D,
    0x3297..0x3297, 0x3299..0x3299
  ].freeze

  # Emoji ONLY when followed by U+FE0F. Without this gate "©", "→" and "▪"
  # would be torn off the front of perfectly ordinary labels — including CJK
  # and RTL ones, where leading punctuation is common.
  TEXT_STYLE_RANGES = [
    0x00A9..0x00A9, 0x00AE..0x00AE, 0x2122..0x2122, 0x2139..0x2139,
    0x203C..0x203C, 0x2049..0x2049, 0x2190..0x21FF, 0x231A..0x231B,
    0x24C2..0x24C2, 0x25AA..0x25FE
  ].freeze

  ZWJ         = 0x200D
  VS16        = 0xFE0F
  KEYCAP      = 0x20E3
  TAG_RANGE   = 0xE0020..0xE007F
  RI_RANGE    = 0x1F1E6..0x1F1FF
  SKIN_RANGE  = 0x1F3FB..0x1F3FF

  # A run longer than this is decoration, not an icon — hoist nothing rather
  # than cram "🎉🎊✨🥳" into a 56px tile.
  MAX_TILE_EMOJI = 3

  # [glyphs, text] — `glyphs` is nil when nothing should move to the tile, and
  # `text` is then the label unchanged (stripped). Leading run wins; a trailing
  # run is only considered when the label doesn't start with one.
  def split(label)
    s = trim(label.to_s)
    return [ nil, s ] if s.empty?

    cps = s.codepoints
    lead = run_length(cps, 0)
    if lead.positive?
      glyphs = cps[0, lead].pack("U*")
      rest   = trim(cps[lead..].pack("U*"))
      return [ glyphs, rest ] if hoistable?(glyphs, rest, lead, cps)
      return [ nil, s ]
    end

    trail = trailing_run(cps)
    if trail.positive?
      glyphs = cps[-trail..].pack("U*")
      rest   = trim(cps[0, cps.length - trail].pack("U*"))
      return [ glyphs, rest ] if hoistable?(glyphs, rest, trail, cps)
    end

    [ nil, s ]
  end

  # String#strip only knows ASCII whitespace, and a generated label routinely
  # separates its emoji from the words with a non-breaking space — which would
  # otherwise survive as a leading blank on the visible label.
  def trim(str)
    str.gsub(/\A[[:space:]]+|[[:space:]]+\z/, "")
  end

  # A hoist must leave real WORDS behind. An emoji-only label ("🎯", or
  # "🎯 🔥") stays put: blanking it would make the editor's serialize() drop
  # the option entirely (trimmedOpts.filter(Boolean)), taking its option_styles
  # entry with it, and leaving one lone emoji as the label reads as a bug.
  def hoistable?(glyphs, rest, run_len, cps)
    return false if run_len == cps.length
    return false unless words?(rest)
    cluster_count(glyphs) <= MAX_TILE_EMOJI
  end

  # Does this string contain anything that isn't an emoji or whitespace?
  def words?(text)
    cps = trim(text.to_s).codepoints
    i = 0
    while i < cps.length
      nxt = cluster_end(cps, i)
      if nxt
        i = nxt
      elsif cps[i].chr(Encoding::UTF_8).match?(/\s/)
        i += 1
      else
        return true
      end
    end
    false
  end

  # How many codepoints from `i` form an unbroken run of emoji clusters. The
  # separating whitespace isn't included — split() strips the remainder, and
  # nothing here has to reproduce the original label byte-for-byte (the emoji
  # is promoted into option_styles, not re-joined).
  def run_length(cps, i)
    pos = i
    loop do
      nxt = cluster_end(cps, pos)
      break if nxt.nil?
      pos = nxt
    end
    pos > i ? pos - i : 0
  end

  # Length of the final unbroken run of clusters. Scanning forward and
  # resetting on every non-cluster codepoint is both simpler and safer than
  # walking backwards: a ZWJ sequence read right-to-left is ambiguous.
  def trailing_run(cps)
    i = 0
    run_start = nil
    while i < cps.length
      nxt = cluster_end(cps, i)
      if nxt
        run_start ||= i
        i = nxt
      else
        run_start = nil
        i += 1
      end
    end
    run_start ? cps.length - run_start : 0
  end

  # Index just past the emoji cluster starting at `i`, or nil if there isn't
  # one. Handles: flag (RI pair), keycap, base + modifiers, and ZWJ sequences.
  def cluster_end(cps, i)
    return nil if i >= cps.length

    # Flag: a pair of regional indicators.
    if RI_RANGE.cover?(cps[i]) && cps[i + 1] && RI_RANGE.cover?(cps[i + 1])
      return i + 2
    end

    # Keycap: [0-9#*] VS16? U+20E3 — checked before `base`, since the digit
    # itself is not an emoji on its own ("1. Option A" must never hoist).
    if keycap_base?(cps[i])
      j = i + 1
      j += 1 if cps[j] == VS16
      return j + 1 if cps[j] == KEYCAP
      return nil
    end

    return nil unless base?(cps, i)

    j = i + 1
    j += 1 if cps[j] == VS16
    loop do
      # Skin tone / tag sequence (subdivision flags) modifiers.
      j += 1 while cps[j] && (SKIN_RANGE.cover?(cps[j]) || TAG_RANGE.cover?(cps[j]))
      break unless cps[j] == ZWJ && base?(cps, j + 1)
      j += 2
      j += 1 if cps[j] == VS16
    end
    j
  end

  def base?(cps, i)
    cp = cps[i]
    return false if cp.nil?
    return true if EMOJI_RANGES.any? { |r| r.cover?(cp) }
    TEXT_STYLE_RANGES.any? { |r| r.cover?(cp) } && cps[i + 1] == VS16
  end

  def keycap_base?(cp)
    cp && (cp == 0x23 || cp == 0x2A || (0x30..0x39).cover?(cp))
  end

  # Clusters in an already-extracted run — the MAX_TILE_EMOJI budget counts
  # 👨‍👩‍👧 and 🇬🇧 as one each, not five and two.
  def cluster_count(glyphs)
    cps = trim(glyphs.to_s).codepoints
    n = 0
    i = 0
    while i < cps.length
      nxt = cluster_end(cps, i)
      break if nxt.nil?
      n += 1
      i = nxt
    end
    n
  end
end
