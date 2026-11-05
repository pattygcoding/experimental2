# frozen_string_literal: true

# One line of the write-ahead log. Written *before* the engine sees the command, inside the
# engine's lock, so the log's order is the engine's order — that is what makes replay exact.
class Command < ApplicationRecord
  KINDS = %w[submit cancel amend].freeze

  belongs_to :instrument

  validates :position, presence: true, uniqueness: { scope: :instrument_id }
  validates :kind, inclusion: { in: KINDS }
  validates :actor, presence: true

  scope :ordered, -> { order(:position) }

  # Rebuild the engine command this row was logged from.
  def to_engine_command
    PIT::Commands.from_h(payload)
  end
end
