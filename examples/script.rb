# frozen_string_literal: true

# A cron job or worker script: errors, logs, a metric, a span and a check-in.
#
#   ARGUS_DSN=https://…@argus-in.naijacloud.com/41 ruby -Ilib examples/script.rb

require "naijacloud/argus"

NaijaCloud::Argus.init(release: "invoices@1.0.0")

NaijaCloud::Argus.monitor("nightly-invoices") do
  NaijaCloud::Argus.trace("send invoices") do |span|
    sent = 0
    %w[ord_1 ord_2 ord_3].each do |order|
      NaijaCloud::Argus.log.info("invoice sent", order_id: order)
      sent += 1
    end
    span.set_attribute("invoices.sent", sent)
    NaijaCloud::Argus.metrics.count("invoices.sent", sent)
  end
end

begin
  Integer("not a number")
rescue ArgumentError => e
  NaijaCloud::Argus.capture_exception(e, tags: { step: "parse" })
end
# Queued data is sent by the exit hook; no flush needed.
