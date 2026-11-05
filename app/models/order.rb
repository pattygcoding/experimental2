# frozen_string_literal: true

# The projection of an engine order. Never the source of truth: delete every row here and the
# log will rebuild them (see MarketReplay).
class Order < ApplicationRecord
  SIDES = %w[buy sell].freeze
  TYPES = %w[limit market].freeze
  TIFS = %w[gtc ioc fok].freeze
  STATUSES = %w[open filled cancelled].freeze

  belongs_to :instrument

  validates :engine_order_id, presence: true, uniqueness: { scope: :instrument_id }
  validates :side, inclusion: { in: SIDES }
  validates :order_type, inclusion: { in: TYPES }
  validates :tif, inclusion: { in: TIFS }
  validates :status, inclusion: { in: STATUSES }
  validates :qty, numericality: { greater_than: 0 }

  scope :open_orders, -> { where(status: "open") }
  scope :for_actor, ->(actor) { where(actor: actor) }

  def remaining = qty - filled
  def open? = status == "open"
end
