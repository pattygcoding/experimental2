# frozen_string_literal: true

module ApplicationCable
  # The cable connection's identity is the same signed cookie the HTTP side issues, so a browser
  # cannot claim to be another trader — which is what makes self-trade prevention meaningful.
  class Connection < ActionCable::Connection::Base
    identified_by :trader

    def connect
      self.trader = cookies.signed[:pit_trader] || "trader-#{SecureRandom.hex(3)}"
    end
  end
end
