# Renders a stored Ask Verto answer back onto the page.
#
# The raw text is persisted with its markers intact ([[c:3]], [[q:88]]) rather
# than pre-rendered, for the same reason the citations are a snapshot: the answer
# is a record of what was said, and the markers are part of it. Rendering happens
# here, at read time, from the citation list stored alongside.
#
# A quote is looked up from CorpusQuote and printed from the record — the same
# rule the live stream follows. If the quote has since been retired, the marker
# simply disappears rather than leaving a dangling reference; the answer reads a
# little thinner, which is the honest outcome.
module AskHelper
  MARKER = /\[\[(c|q):(\d+)\]\]/

  def render_ask_answer(message)
    numbers = message.citation_list.index_by { |c| c["n"] }
    quotes  = quote_bodies(message)

    safe_join(
      message.text.to_s.split(MARKER_SPLIT).map { |part| render_ask_part(part, numbers, quotes) }
    )
  end

  private

  # Capturing split, so the markers survive as their own parts.
  MARKER_SPLIT = /(\[\[(?:c|q):\d+\]\])/

  def render_ask_part(part, numbers, quotes)
    match = part.match(/\A\[\[(c|q):(\d+)\]\]\z/)
    return part unless match

    id = match[2].to_i
    match[1] == "c" ? render_ask_citation(id, numbers) : render_ask_quote(id, quotes)
  end

  def render_ask_citation(number, numbers)
    source = numbers[number]
    # A marker with no matching stored source was already stripped when the answer
    # was written; this is belt and braces for older rows.
    return "".html_safe if source.nil?

    # The chip is painted in its question type's accent, so a reader can see
    # what KIND of evidence an answer leans on before opening anything: pink for
    # someone's own words, gold for a rating, indigo for a choice.
    #
    # Read from the stored citation where present, and derived from the card type
    # otherwise — rows written before accents shipped still colour correctly
    # rather than falling back to a uniform violet.
    accent = source["accent"].presence || CardTypes.accent(source["card_type"])

    tag.button(number,
               type:  "button",
               class: "ask-cite",
               style: "--cite-accent:#{accent};",
               title: "#{source["verto"]} · #{source["question"]}",
               data:  { action: "click->ask-verto#openCitation", source: number })
  end

  def render_ask_quote(id, quotes)
    quote = quotes[id]
    return "".html_safe if quote.nil?

    tag.blockquote(class: "ask-quote") do
      concat quote.body
      concat tag.span(quote.theme, class: "theme") if quote.theme.present?
    end
  end

  # Only quotes that are still citable. A withdrawn Verto's words stop being
  # shown, in an old answer as much as in a new one — that is what the creator
  # was promised.
  def quote_bodies(message)
    ids = message.text.to_s.scan(/\[\[q:(\d+)\]\]/).flatten.map(&:to_i)
    return {} if ids.empty?

    CorpusQuote.citable.where(id: ids).index_by(&:id)
  end
end
