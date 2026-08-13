# What the inbox row will look like, and what's wrong with it.
#
# The subject and the preheader are the only part of a campaign most people
# ever read, and they're the part the builder gave the least help with: two
# bare text inputs with no sense of where a client cuts them off.
#
# These checks are deliberately structural — length, casing, punctuation,
# repetition, emptiness — things that are true regardless of taste. No
# spam-word list: those are folklore, they fire on ordinary words like
# "free trial", and a false warning on every send teaches the author to
# ignore the real ones.
#
# Pure functions over two strings: no Active Record, no I/O, so the rules
# live in one place and the panel just paints what this returns.
module Comms
  module SubjectLine
    module_function

    # Where common clients cut. Gmail's desktop list is the widest of the
    # ones that matter; phones are far tighter, which is the point of
    # showing both.
    MOBILE_CHARS   = 35
    DESKTOP_CHARS  = 70
    HARD_CHARS     = 110
    PREHEADER_BEST = 90
    PREHEADER_MAX  = 140

    EMOJI = /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]/

    # -> [{ "level" => "warn"|"tip", "text" => "…" }], most important first.
    # `warn` is something that will visibly go wrong; `tip` is a judgement
    # call the author is free to ignore.
    def review(subject:, preheader:)
      subject = subject.to_s.strip
      preheader = preheader.to_s.strip
      out = []

      if subject.empty?
        out << warn("The subject is empty — the send will be refused until it has one.")
      else
        out.concat(subject_notes(subject))
      end

      out.concat(preheader_notes(preheader, subject))
      out
    end

    def subject_notes(subject)
      out = []
      length = subject.length

      # Nothing is said about the phone cut-off: almost every worthwhile
      # subject is longer than #{MOBILE_CHARS} characters, and a note that
      # fires every time teaches the author to skip the notes that matter.
      # The preview card shows the phone truncation instead — seeing it beats
      # being told about it.
      if length > HARD_CHARS
        out << warn("The subject is #{length} characters — everything past about #{DESKTOP_CHARS} is cut off everywhere.")
      elsif length > DESKTOP_CHARS
        out << tip("At #{length} characters the subject is cut off on most desktop clients (about #{DESKTOP_CHARS}).")
      end

      shouted = subject.scan(/\b[A-Z]{4,}\b/).reject { |w| w == "VERTO" }
      out << tip("#{shouted.first} is in capitals — inbox filters and readers both read that as shouting.") if shouted.any?

      out << tip("Repeated punctuation (#{subject[/[!?]{2,}/]}) reads as hard-selling.") if subject.match?(/[!?]{2,}/)

      emoji = subject.scan(EMOJI).size
      out << tip("#{emoji} emoji in one subject line is a lot — one is usually the most that helps.") if emoji > 1

      out
    end

    def preheader_notes(preheader, subject)
      return [ warn("No preheader: the inbox will show the top of the email instead, which is the masthead.") ] if
        preheader.empty?

      out = []
      if preheader.length > PREHEADER_MAX
        out << tip("The preheader is #{preheader.length} characters; most clients stop around #{PREHEADER_BEST}.")
      end
      if subject.present? && echoes?(preheader, subject)
        out << tip("The preheader repeats the subject — it's a second line of space, so it can say something new.")
      end
      out
    end

    # "Repeats" meaning a reader would see the same words twice, not a strict
    # prefix match.
    def echoes?(preheader, subject)
      a = words(preheader).first(5)
      b = words(subject).first(5)
      return false if a.empty? || b.empty?

      overlap = (a & b).size
      overlap >= [ 3, [ a.size, b.size ].min ].min
    end

    def words(value)
      value.downcase.scan(/[a-z0-9']+/)
    end

    # How the row reads once a client has cut it — what the panel previews.
    def truncate_for(subject, width)
      subject = subject.to_s.strip
      return subject if subject.length <= width

      "#{subject[0, width].rstrip}…"
    end

    def warn(text) = { "level" => "warn", "text" => text }
    def tip(text)  = { "level" => "tip",  "text" => text }
  end
end
