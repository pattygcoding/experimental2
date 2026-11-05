# frozen_string_literal: true

class MetricsController < ApplicationController
  def show
    render plain: MarketMetrics.prometheus, content_type: "text/plain; version=0.0.4"
  end
end
