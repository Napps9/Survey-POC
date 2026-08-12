// Mirror of RichTextSanitizer's allowlists (app/lib/rich_text_sanitizer.rb —
// the authority; a parity test pins the two). The toolbar builds ONLY markup
// these lists accept: formatting tags, plus class tokens on <span> for fonts
// and sizes. No style attributes, ever.
export const ALLOWED_TAGS = [ "b", "strong", "i", "em", "u", "span", "br" ]
export const FONT_CLASSES = [ "font-anton", "font-spectral", "font-lora", "font-poppins", "font-caveat", "font-alata", "font-abeezee" ]
export const SIZE_CLASSES = [ "size-s", "size-l", "size-xl" ]

// Display names for the toolbar's font select, in menu order. "" = inherit
// (remove any font span).
export const FONT_LABELS = {
  "": "Default",
  "font-anton": "Anton",
  "font-spectral": "Spectral",
  "font-lora": "Lora",
  "font-poppins": "Poppins",
  "font-caveat": "Caveat",
  "font-alata": "Alata",
  "font-abeezee": "ABeeZee",
}

export const SIZE_LABELS = {
  "": "Normal",
  "size-s": "Small",
  "size-l": "Large",
  "size-xl": "XL",
}

// True when an element subtree contains any rich-text formatting — the
// serializer only captures innerHTML when this is true, so unformatted decks
// keep serialising byte-identically to the plain-text era.
export function hasFormatting(el) {
  return !!el && !!el.querySelector(ALLOWED_TAGS.filter((t) => t !== "br").join(","))
}

// The Comms email profile additionally allows anchors
// (RichTextSanitizer::EMAIL_ALLOWED_TAGS is the authority).
export const EMAIL_EXTRA_TAGS = [ "a" ]

export function hasEmailFormatting(el) {
  const tags = ALLOWED_TAGS.filter((t) => t !== "br").concat(EMAIL_EXTRA_TAGS)
  return !!el && !!el.querySelector(tags.join(","))
}
