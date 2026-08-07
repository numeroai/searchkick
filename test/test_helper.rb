require "bundler/setup"
Bundler.require(:default)
require "minitest/autorun"
require "active_support/notifications"

ENV["RACK_ENV"] = "test"

# A second named cluster for the multi-cluster tests.
#
# With SECONDARY_OPENSEARCH_URL (or SECONDARY_ELASTICSEARCH_URL) set, this is a
# genuinely separate server — see docker-compose.yml. Unset, it falls back to
# the same server CI runs, where AltProduct's index_prefix keeps the indices
# distinct; the routing is what is under test either way.
#
# Must be registered before the first Searchkick.client access below, since
# assigning clusters resets the client and server_info memos.
secondary_url = ENV["SECONDARY_OPENSEARCH_URL"] || ENV["SECONDARY_ELASTICSEARCH_URL"]
Searchkick.clusters = {secondary: secondary_url ? {url: secondary_url} : {}}

# for reloadable synonyms
if ENV["CI"]
  ENV["ES_PATH"] ||= File.join(ENV["HOME"], Searchkick.opensearch? ? "opensearch" : "elasticsearch", Searchkick.server_version)
end

$logger = ActiveSupport::Logger.new(ENV["VERBOSE"] ? STDOUT : nil)

if ENV["LOG_TRANSPORT"]
  transport_logger = ActiveSupport::Logger.new(STDOUT)
  if Searchkick.client.transport.respond_to?(:transport)
    Searchkick.client.transport.transport.logger = transport_logger
  else
    Searchkick.client.transport.logger = transport_logger
  end
end
Searchkick.search_timeout = 5
Searchkick.index_suffix = ENV["TEST_ENV_NUMBER"] # for parallel tests

puts "Running against #{Searchkick.opensearch? ? "OpenSearch" : "Elasticsearch"} #{Searchkick.server_version}"

I18n.config.enforce_available_locales = true

ActiveJob::Base.logger = $logger
ActiveJob::Base.queue_adapter = :test

ActiveSupport::LogSubscriber.logger = ActiveSupport::Logger.new(STDOUT) if ENV["VERBOSE"]

if defined?(Mongoid)
  require_relative "support/mongoid"
else
  require_relative "support/activerecord"
end

require_relative "support/redis"

# models
Dir["#{__dir__}/models/*"].each do |file|
  require file
end

require_relative "support/helpers"
