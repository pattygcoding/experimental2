class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :identify_trader

  helper_method :current_trader

  private

  # The trading identity is issued by the server and kept in a signed cookie, so the browser
  # cannot claim to be someone else. Two tabs share it — one person, one account — which is what
  # makes a self-trade possible to demonstrate.
  def identify_trader
    current_trader
  end

  def current_trader
    @current_trader ||= cookies.signed[:pit_trader] ||= "trader-#{SecureRandom.hex(3)}"
  end
end
