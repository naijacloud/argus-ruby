# frozen_string_literal: true

module NaijaCloud
  module Argus
    VERSION = "0.1.0"

    # The wire contract this gem implements (nc-argus spec/README.md). Sent as
    # the `argus.contract` resource attribute so ingest can tell which rules a
    # payload was built under.
    CONTRACT = "argus.sdk/1"

    SDK_NAME = "argus.ruby"
  end
end
