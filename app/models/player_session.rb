# A signed-in respondent's session. As bare as `Session` for the same reason:
# the signed permanent cookie carries the row id, so there is no token here to
# leak.
class PlayerSession < ApplicationRecord
  belongs_to :player
end
