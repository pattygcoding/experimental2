# frozen_string_literal: true

# The fingerprint of the book after `position` commands. These rows are the receipt that makes a
# replay verifiable: rebuild the log and every one of them must match.
class BookCheckpoint < ApplicationRecord
  belongs_to :instrument

  validates :position, presence: true, uniqueness: { scope: :instrument_id }
  validates :fingerprint, presence: true

  scope :ordered, -> { order(:position) }
end
