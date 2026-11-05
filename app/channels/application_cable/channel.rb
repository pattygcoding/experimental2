# frozen_string_literal: true

module ApplicationCable
  # The base for every channel. PIT's only channel is OrderBookChannel, which is downstream-only.
  class Channel < ActionCable::Channel::Base
  end
end
