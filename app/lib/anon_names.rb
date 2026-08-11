# The word pools behind the leaderboard's anonymous names ("Clever Axolotl").
#
# Names are deliberately English-only, proper-noun style, and never localized:
# ~3,000 combinations across 19 locale files is unmaintainable, and one board
# must read identically to every viewer regardless of their UI language — a
# name is an identity, not a UI string. Growing either list later is safe
# precisely because names are stored on assignment (PlayerAlias), never
# re-derived from the lists.
module AnonNames
  module_function

  ADJECTIVES = %w[
    Amber Bold Brave Breezy Bright Calm Cheery Clever Cosmic Crafty
    Curious Daring Dandy Eager Fabled Fancy Fearless Gentle Giddy Glad
    Golden Groovy Happy Hardy Humble Jaunty Jolly Keen Kindly Lively
    Lucky Mellow Merry Mighty Nimble Noble Peppy Perky Plucky Proud
    Quick Quiet Rosy Shiny Snazzy Snoozy Spry Sturdy Sunny Swift
    Tidy Witty Zesty Zippy
  ].freeze

  ANIMALS = %w[
    Alpaca Axolotl Badger Beaver Bison Bobcat Capybara Caracal Cheetah Chinchilla
    Cormorant Coyote Dingo Dormouse Echidna Falcon Fennec Ferret Finch Gazelle
    Gecko Gibbon Heron Hoopoe Ibex Iguana Jackdaw Jerboa Kestrel Kingfisher
    Kiwi Lemur Lynx Macaw Magpie Manatee Marmot Meerkat Mongoose Narwhal
    Numbat Ocelot Okapi Osprey Otter Pangolin Puffin Quokka Raccoon Seahorse
    Serval Skylark Stoat Tapir Toucan Wallaby Wombat Yak
  ].freeze

  # One fresh candidate name. Uniqueness within a survey is PlayerAlias's job
  # (retry + suffix there), not this sampler's.
  def sample
    "#{ADJECTIVES.sample} #{ANIMALS.sample}"
  end
end
