// The emoji set behind the editor's emoji picker.
//
// Curated rather than exhaustive: ~230 emoji that actually turn up in survey
// answers, grouped so a creator can scan a category instead of hunting. The
// full Unicode set is ~3,800 — a picker that large needs virtualised scrolling
// and a data file bigger than the rest of this app's JS put together, and it
// buries the ones anyone picks. Search covers the same set by keyword.
//
// Adding one: put it in the category it belongs to, and give it search terms
// a creator would actually type (not the Unicode name).

export const EMOJI_CATEGORIES = [
  {
    key: "faces",
    label: "Faces",
    emoji: [
      [ "🙂", "happy smile pleased good" ],
      [ "😀", "grin happy" ],
      [ "😍", "love heart eyes adore" ],
      [ "🤩", "star struck amazed excited" ],
      [ "😌", "relieved calm content" ],
      [ "😐", "neutral meh ok" ],
      [ "🙁", "sad unhappy frown" ],
      [ "😟", "worried concerned" ],
      [ "😨", "scared afraid fear unsafe" ],
      [ "😰", "anxious stress worried sweat" ],
      [ "😢", "cry sad tear" ],
      [ "😡", "angry mad furious" ],
      [ "🤔", "thinking unsure maybe hmm" ],
      [ "😴", "sleep tired rest" ],
      [ "🤐", "quiet silent prefer not to say" ],
      [ "🥳", "party celebrate" ],
      [ "😎", "cool confident" ],
      [ "🫤", "unsure meh uncertain" ]
    ]
  },
  {
    key: "people",
    label: "People",
    emoji: [
      [ "👍", "yes agree thumbs up good" ],
      [ "👎", "no disagree thumbs down bad" ],
      [ "👋", "wave hello hi" ],
      [ "🙌", "celebrate praise yay" ],
      [ "👏", "clap applause well done" ],
      [ "🤝", "handshake deal partner agree" ],
      [ "💪", "strong strength fitness muscle" ],
      [ "🧠", "brain mental health mind think" ],
      [ "👀", "eyes watch look" ],
      [ "👨‍👩‍👧", "family parents children" ],
      [ "🫂", "hug friends support together" ],
      [ "👶", "baby child infant" ],
      [ "🧑", "person adult someone" ],
      [ "👴", "older elderly senior" ],
      [ "👮", "police officer patrol safety" ],
      [ "👩‍⚕️", "doctor nurse health medical" ],
      [ "👨‍🏫", "teacher school education" ],
      [ "🧑‍💻", "work computer developer office" ]
    ]
  },
  {
    key: "money",
    label: "Money & work",
    emoji: [
      [ "💷", "pound money salary income" ],
      [ "💰", "money bag savings wealth" ],
      [ "💳", "card debt credit payment" ],
      [ "🏦", "bank savings account" ],
      [ "📈", "up growth investment increase" ],
      [ "📉", "down decrease loss unemployment" ],
      [ "🧾", "bill receipt cost expenses" ],
      [ "🧮", "budget calculate abacus" ],
      [ "💼", "work job briefcase business" ],
      [ "🚀", "launch startup business grow" ],
      [ "🏢", "office building company" ],
      [ "🛒", "shopping groceries buy" ],
      [ "🏷️", "price tag discount" ],
      [ "⏰", "time hours deadline" ],
      [ "📊", "chart data results" ],
      [ "🤑", "rich money profit" ]
    ]
  },
  {
    key: "health",
    label: "Health & life",
    emoji: [
      [ "❤️", "heart love health" ],
      [ "🩺", "doctor health check medical" ],
      [ "🏥", "hospital healthcare" ],
      [ "💊", "medicine pills treatment" ],
      [ "🏃", "run exercise fitness active" ],
      [ "🚴", "cycle bike exercise" ],
      [ "🧘", "calm yoga meditation wellbeing" ],
      [ "🥗", "salad diet healthy food" ],
      [ "🍽️", "food meal eat dinner" ],
      [ "🥤", "drink water hydration" ],
      [ "🛌", "sleep bed rest" ],
      [ "🌱", "growth wellbeing plant new" ],
      [ "🚭", "no smoking quit" ],
      [ "🧴", "care hygiene wash" ],
      [ "🦷", "dental teeth" ],
      [ "🧑‍🦽", "accessibility disability wheelchair" ]
    ]
  },
  {
    key: "places",
    label: "Places & travel",
    emoji: [
      [ "🏠", "home house housing" ],
      [ "🏘️", "neighbourhood community houses" ],
      [ "🏫", "school college education" ],
      [ "🎓", "graduate university degree" ],
      [ "🏛️", "government council civic" ],
      [ "⛪", "church faith religion" ],
      [ "🏪", "shop store local" ],
      [ "🌳", "park tree green space nature" ],
      [ "🌍", "world environment climate earth" ],
      [ "🚌", "bus public transport" ],
      [ "🚗", "car drive vehicle" ],
      [ "🚲", "bicycle bike cycling" ],
      [ "🚶", "walk walking pedestrian" ],
      [ "✈️", "plane travel flight holiday" ],
      [ "🚉", "train station rail" ],
      [ "🛣️", "road street highway" ],
      [ "💡", "light lighting idea street lamp" ],
      [ "🚨", "alarm crime emergency police" ]
    ]
  },
  {
    key: "objects",
    label: "Things",
    emoji: [
      [ "📱", "phone mobile device" ],
      [ "💻", "laptop computer online" ],
      [ "📚", "books study reading learning" ],
      [ "✏️", "write pencil other edit" ],
      [ "📝", "note form survey write" ],
      [ "📅", "calendar date weekly daily" ],
      [ "🗓️", "calendar monthly schedule" ],
      [ "🔑", "key rent access" ],
      [ "🛡️", "shield safety protection secure" ],
      [ "🔧", "tool repair fix trade" ],
      [ "🧹", "clean cleaning tidy streets" ],
      [ "🎪", "event festival community fun" ],
      [ "🎁", "gift reward prize" ],
      [ "📢", "announce voice speak loud" ],
      [ "🔔", "bell notify reminder" ],
      [ "🗑️", "bin waste rubbish" ],
      [ "♻️", "recycle sustainable green" ],
      [ "🔋", "battery energy power" ]
    ]
  },
  {
    key: "symbols",
    label: "Symbols",
    emoji: [
      [ "✅", "yes tick check done correct" ],
      [ "❌", "no cross wrong incorrect" ],
      [ "⭐", "star favourite rating best" ],
      [ "🚫", "none never forbidden no" ],
      [ "⚠️", "warning caution risk" ],
      [ "❓", "question unknown unsure" ],
      [ "❗", "important urgent" ],
      [ "➕", "plus add more" ],
      [ "➖", "minus less fewer" ],
      [ "🔁", "repeat sometimes often again" ],
      [ "♾️", "always infinite forever" ],
      [ "🌙", "night rarely moon evening" ],
      [ "☀️", "day sun morning" ],
      [ "🔷", "blue diamond shape" ],
      [ "🔶", "orange diamond shape" ],
      [ "🟢", "green circle good go" ],
      [ "🟡", "yellow circle medium" ],
      [ "🔴", "red circle stop bad" ],
      [ "🟣", "purple circle" ],
      [ "🥇", "first gold best rank" ],
      [ "🥈", "second silver rank" ],
      [ "🥉", "third bronze rank" ],
      [ "💯", "hundred perfect full" ],
      [ "🔥", "fire hot popular trending" ]
    ]
  }
]

// Flat [emoji, terms] list, for search.
export const ALL_EMOJI = EMOJI_CATEGORIES.flatMap(c => c.emoji)

export function searchEmoji(query) {
  const q = String(query ?? "").trim().toLowerCase()
  if (!q) return []
  const words = q.split(/\s+/)
  return ALL_EMOJI
    .filter(([ , terms ]) => words.every(w => terms.includes(w)))
    .map(([ emoji ]) => emoji)
}
