# The one place that tells Claude which language — and which ENGLISH — to write
# a Verto in.
#
# Five services carried a copy of the same six lines, each opening
# `return "" if locale == SupportedLocales::DEFAULT`. Two consequences, and the
# second is a bug a user reported.
#
# 1. An English Verto sent no language instruction at all. The model therefore
#    inherited the dialect of the prompts it was reading, and those are written
#    in British English throughout ("optimised", "PRIORITISE", "prioritise",
#    "organisation") with nothing to counterbalance them. So a creator whose
#    questions were in US English had them handed back in UK English by the PDF
#    import's optimiser, and there was no setting anywhere that could have
#    stopped it — silence was the only thing the code could say about English.
#
# 2. Adding `en-US` to the registry would have sailed straight past that guard
#    into the generic branch, which ends "Do not use English." — nonsense for
#    an English variant, and the kind of self-contradiction that makes a model's
#    output unpredictable rather than merely wrong.
#
# So English is now stated explicitly, in both directions, and the "do not use
# English" clause is withheld from the variants where it cannot apply.
#
# The instruction says PREFER rather than CONVERT for spelling, deliberately.
# The optimiser's job is to fix a rules violation; a creator's own words coming
# back re-spelled is not a fix, it is a second edit they did not ask for — see
# CardOptimiser and PdfQuestionImporter, which say so again at the point of use.
module PromptLanguage
  module_function

  SPELLING = {
    "en"    => "British English (colour, organise, prioritise, -ise endings)",
    "en-US" => "US English (color, organize, prioritize, -ize endings)"
  }.freeze

  # `scope` names what the model is being asked to write, so the sentence reads
  # naturally at each call site: "the ENTIRE Verto — title, description, …",
  # "the question text, any description and ALL option labels", and so on.
  #
  # Returns "" for nothing to say, which no caller can currently produce — every
  # supported locale gets an instruction now — but keeping the empty case means
  # a caller can still concatenate unconditionally.
  def instruction(locale, scope:)
    code = SupportedLocales.coerce(locale)

    if SupportedLocales.english?(code)
      "\nLANGUAGE: Write #{scope} in #{SPELLING.fetch(code)}. " \
      "Use that variant's spelling throughout, and never convert spelling that " \
      "is already in it.\n"
    else
      "\nLANGUAGE: Write #{scope} in #{name_for(code)}. Do not use English.\n"
    end
  end

  # A standalone line for the services whose job is to REWRITE a creator's own
  # words rather than to write new ones. Orthography is not a defect, so a
  # rewrite must not treat it as one — which is precisely what was happening.
  PRESERVE_SPELLING =
    "SPELLING: Preserve the author's own spelling, punctuation and terminology " \
    "exactly as given. Do not convert between English variants (e.g. " \
    "organize/organise, color/colour), and do not \"correct\" a regional " \
    "spelling. You are fixing the issues listed, nothing else.".freeze

  def name_for(code)
    lang = SupportedLocales.find(code)
    lang ? "#{lang.english_name} (#{lang.native_name})" : code.to_s
  end
end
