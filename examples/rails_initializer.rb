# frozen_string_literal: true

# config/initializers/argus.rb -- optional. `bundle add naijacloud-argus` and
# ARGUS_DSN are the whole setup; add this file only to change options.

NaijaCloud::Argus.init do |c|
  c.release = ENV["GIT_SHA"]
  c.traces_sample_rate = 0.2
  c.rails_logs = true
  c.before_send = lambda do |event|
    # Drop a noisy error you have decided not to fix.
    next nil if event.dig(:exception, :values)&.last&.dig(:type) == "Rack::Timeout::RequestTimeoutException"

    event
  end
end
