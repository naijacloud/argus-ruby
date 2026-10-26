# frozen_string_literal: true

# Plain Rack (Sinatra, Hanami and Roda are the same two lines).
#
#   ARGUS_DSN=https://…@argus-in.naijacloud.com/41 rackup examples/config.ru

require "naijacloud/argus"

NaijaCloud::Argus.init
use NaijaCloud::Argus::Rack

run lambda { |env|
  raise "boom" if env["PATH_INFO"] == "/boom"

  if NaijaCloud::Argus.flags.on?("new-greeting", env["REMOTE_ADDR"].to_s)
    [200, { "content-type" => "text/plain" }, ["Ẹ ku abọ!\n"]]
  else
    [200, { "content-type" => "text/plain" }, ["Hello\n"]]
  end
}
