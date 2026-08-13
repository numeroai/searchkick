# dependencies
require "active_support"
require "active_support/core_ext/hash/deep_merge"
require "active_support/core_ext/module/attr_internal"
require "active_support/core_ext/module/delegation"
require "active_support/deprecation"
require "active_support/log_subscriber"
require "active_support/notifications"

# stdlib
require "forwardable"

# modules
require_relative "searchkick/controller_runtime"
require_relative "searchkick/index"
require_relative "searchkick/index_cache"
require_relative "searchkick/index_options"
require_relative "searchkick/indexer"
require_relative "searchkick/hash_wrapper"
require_relative "searchkick/log_subscriber"
require_relative "searchkick/model"
require_relative "searchkick/multi_search"
require_relative "searchkick/query"
require_relative "searchkick/reindex_queue"
require_relative "searchkick/record_data"
require_relative "searchkick/record_indexer"
require_relative "searchkick/relation"
require_relative "searchkick/relation_indexer"
require_relative "searchkick/reranking"
require_relative "searchkick/results"
require_relative "searchkick/script"
require_relative "searchkick/version"
require_relative "searchkick/where"

# integrations
require_relative "searchkick/railtie" if defined?(Rails)

module Searchkick
  # requires faraday
  autoload :Middleware, "searchkick/middleware"

  # background jobs
  autoload :BulkReindexJob,  "searchkick/bulk_reindex_job"
  autoload :ProcessBatchJob, "searchkick/process_batch_job"
  autoload :ProcessQueueJob, "searchkick/process_queue_job"
  autoload :ReindexV2Job,    "searchkick/reindex_v2_job"

  # errors
  class Error < StandardError; end
  class MissingIndexError < Error; end
  class UnsupportedVersionError < Error
    def message
      "This version of Searchkick requires Elasticsearch 8+ or OpenSearch 2+"
    end
  end
  class InvalidQueryError < Error; end
  class DangerousOperation < Error; end
  class ImportError < Error; end

  ON_MISSING_VALUES = [:raise, :ignore, :full].freeze

  # the cluster every model uses unless it passes `cluster:`
  DEFAULT_CLUSTER = :default

  # keys both transports resolve ahead of `url` - see the chain in
  # OpenSearch::Transport::Client and Elastic::Transport::Client:
  #   hosts || host || url || urls
  # `urls` sits after `url`, so it cannot outrank a cluster's url.
  HOST_KEYS_ABOVE_URL = [:hosts, :host].freeze

  class << self
    attr_accessor :search_method_name, :models, :redis, :index_prefix, :index_suffix, :queue_name, :model_options, :parent_job
    # readers for these take an optional cluster - see below
    attr_writer :env, :search_timeout, :timeout, :client_options, :client_type
    attr_reader :clusters
  end
  self.search_method_name = :search
  self.timeout = 10
  self.models = []
  self.client_options = {}
  self.queue_name = :searchkick
  self.model_options = {}
  self.parent_job = "ActiveJob::Base"
  @clusters = {}.freeze
  @clients = {}
  @server_info = {}

  # Named clusters, keyed by symbol:
  #
  #   Searchkick.clusters = {archive: {url: "https://...", timeout: 30}}
  #
  # Assignment-only and frozen: mutating the returned hash would bypass
  # normalization and leave the memoized clients stale.
  def self.clusters=(value)
    value = (value || {}).to_h { |name, config| [name.to_sym, freeze_config(config.to_h)] }

    if value.key?(DEFAULT_CLUSTER)
      raise Error, "Configure the default cluster with Searchkick.timeout, Searchkick.client_options, etc., not Searchkick.clusters[#{DEFAULT_CLUSTER.inspect}]"
    end

    @clusters = value.freeze
    reset_clusters
  end

  # private
  # Drops memoized clients for named clusters, whose config just changed.
  #
  # The default cluster is left alone: cluster_config returns {} for it, so
  # nothing in the registry can affect how its client is built - and it may hold
  # a client installed through Searchkick.client=, which resetting would
  # silently replace with a freshly built one.
  def self.reset_clusters
    @clients = (@clients || {}).slice(DEFAULT_CLUSTER)
    @server_info = (@server_info || {}).slice(DEFAULT_CLUSTER)
  end

  # private
  # Copy and freeze the config's containers so the registry cannot be mutated
  # after assignment, without freezing the hash the caller still holds.
  #
  # Leaf values are carried by reference, never duplicated: a client passed via
  # `client:` must stay the caller's own object, or stubs and identity checks
  # against it would not apply to the client Searchkick actually uses.
  def self.freeze_config(value)
    case value
    when Hash
      value.to_h { |k, v| [k, freeze_config(v)] }.freeze
    when Array
      value.map { |v| freeze_config(v) }.freeze
    else
      value
    end
  end

  # private
  # nil, :default, and "default" all name the same physical cluster. Use this
  # anywhere cluster identity is compared or memoized - but not for job
  # serialization, where nil (unpinned) and :default (pinned) differ.
  def self.canonical_cluster(cluster)
    cluster&.to_sym || DEFAULT_CLUSTER
  end

  # private
  def self.cluster_config(cluster)
    return {} if cluster.nil? || cluster.to_sym == DEFAULT_CLUSTER

    clusters.fetch(cluster.to_sym) do
      raise Error, "Unknown cluster: #{cluster.inspect} (known: #{clusters.keys.map(&:inspect).join(", ")})"
    end
  end

  def self.timeout(cluster = nil)
    cluster_config(cluster)[:timeout] || @timeout
  end

  def self.client_options(cluster = nil)
    extra = cluster_config(cluster)[:client_options]
    # return the same object when there is no override - client_options is
    # documented as mutable in place (README: Searchkick.client_options[:x] = y)
    extra ? @client_options.deep_merge(extra) : @client_options
  end

  # nil unless explicitly configured, same as before - the engine sniff lives
  # in resolved_client_type
  def self.client_type(cluster = nil)
    cluster_config(cluster)[:client_type] || @client_type
  end

  def self.aws_credentials(cluster = nil)
    config = cluster_config(cluster)
    # key? so a cluster can pass `aws_credentials: nil` to opt out of the global
    config.key?(:aws_credentials) ? config[:aws_credentials] : @aws_credentials
  end

  def self.client(cluster = nil)
    (@clients ||= {})[canonical_cluster(cluster)] ||= build_client(cluster)
  end

  def self.client=(value)
    (@clients ||= {})[DEFAULT_CLUSTER] = value
  end

  # private
  def self.resolved_client_type(cluster = nil)
    type = client_type(cluster)
    return type if type

    if defined?(OpenSearch::Client) && defined?(Elasticsearch::Client)
      raise Error, "Multiple clients found - set Searchkick.client_type = :elasticsearch or :opensearch"
    elsif defined?(OpenSearch::Client)
      :opensearch
    elsif defined?(Elasticsearch::Client)
      :elasticsearch
    else
      raise Error, "No client found - install the `elasticsearch` or `opensearch-ruby` gem"
    end
  end

  # private
  def self.build_client(cluster = nil)
    config = cluster_config(cluster)
    return config[:client] if config[:client]

    credentials = aws_credentials(cluster)
    # the global writer requires this, but a cluster can carry its own credentials
    # without the writer ever being called
    require "faraday_middleware/aws_sigv4" if credentials

    if resolved_client_type(cluster) == :opensearch
      OpenSearch::Client.new(transport_config(cluster, ENV["OPENSEARCH_URL"])) do |f|
        f.use Searchkick::Middleware, {cluster: cluster}
        f.request :aws_sigv4, signer_middleware_aws_params(credentials) if credentials
      end
    else
      raise Error, "The `elasticsearch` gem must be 8+" if Elasticsearch::VERSION.to_i < 8

      Elasticsearch::Client.new(transport_config(cluster, ENV["ELASTICSEARCH_URL"])) do |f|
        f.use Searchkick::Middleware, {cluster: cluster}
        f.request :aws_sigv4, signer_middleware_aws_params(credentials) if credentials
      end
    end
  end

  # private
  #
  # Layered so that the more specific setting wins:
  #
  #   built-in defaults
  #     -> global client_options
  #     -> the cluster's own url / timeout
  #     -> the cluster's own client_options
  #
  # For the default cluster there is no cluster layer, so this collapses to
  # today's `{url:, transport_options:, retry_on_failure:}.deep_merge(client_options)`.
  # For a named cluster the ordering matters: a global `client_options[:url]`,
  # `[:hosts]`, or transport timeout must not silently outrank the url and
  # timeout that cluster was registered with.
  def self.transport_config(cluster, env_url)
    config = cluster_config(cluster)

    base = {
      url: env_url,
      transport_options: {request: {timeout: @timeout}},
      retry_on_failure: 2
    }.deep_merge(@client_options)

    if config[:url]
      base[:url] = config[:url]
      # both transports resolve `hosts || host || url`, so an inherited global
      # hosts/host would defeat the url this cluster names. Anything the cluster
      # sets itself is left alone.
      own_keys = (config[:client_options] || {}).keys
      (HOST_KEYS_ABOVE_URL - own_keys).each { |key| base.delete(key) }
    end
    base.deep_merge!(transport_options: {request: {timeout: config[:timeout]}}) if config[:timeout]

    base.deep_merge(config[:client_options] || {})
  end

  def self.env
    @env ||= ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
  end

  def self.search_timeout(cluster = nil)
    cluster_config(cluster)[:search_timeout] ||
      (defined?(@search_timeout) && @search_timeout) ||
      timeout(cluster)
  end

  # private
  def self.server_info(cluster = nil)
    (@server_info ||= {})[canonical_cluster(cluster)] ||= client(cluster).info
  end

  # memoized through server_info, so these stay plain lookups
  def self.server_version(cluster = nil)
    server_info(cluster)["version"]["number"]
  end

  def self.opensearch?(cluster = nil)
    server_info(cluster)["version"]["distribution"] == "opensearch"
  end

  def self.server_below?(version, cluster = nil)
    Gem::Version.new(server_version(cluster).split("-")[0]) < Gem::Version.new(version.split("-")[0])
  end

  # private
  def self.knn_support?(cluster = nil)
    if opensearch?(cluster)
      !server_below?("2.4.0", cluster)
    else
      !server_below?("8.6.0", cluster)
    end
  end

  def self.search(term = "*", model: nil, **options, &block)
    options = options.dup
    klass = model

    # convert index_name into models if possible
    # this should allow for easier upgrade
    if options[:index_name] && !options[:models] && Array(options[:index_name]).all? { |v| v.respond_to?(:searchkick_index) }
      options[:models] = options.delete(:index_name)
    end

    # make Searchkick.search(models: [Product]) and Product.search equivalent
    unless klass
      models = Array(options[:models])
      if models.size == 1
        klass = models.first
        options.delete(:models)
      end
    end

    if klass
      if (options[:models] && Array(options[:models]) != [klass]) || Array(options[:index_name]).any? { |v| v.respond_to?(:searchkick_index) && v != klass }
        raise ArgumentError, "Use Searchkick.search to search multiple models"
      end
    end

    options = options.merge(block: block) if block
    Relation.new(klass, term, **options)
  end

  def self.multi_search(queries, opaque_id: nil)
    return if queries.empty?

    queries = queries.map { |q| q.send(:query) }
    event = {
      name: "Multi Search",
      body: queries.flat_map { |q| [q.params.except(:body).to_json, q.body.to_json] }.map { |v| "#{v}\n" }.join
    }
    ActiveSupport::Notifications.instrument("multi_search.searchkick", event) do
      MultiSearch.new(queries, opaque_id: opaque_id).perform
    end
  end

  # script

  # experimental
  def self.script(source, **options)
    Script.new(source, **options)
  end

  # callbacks

  def self.enable_callbacks
    self.callbacks_value = nil
  end

  def self.disable_callbacks
    self.callbacks_value = false
  end

  def self.callbacks?(default: true)
    if callbacks_value.nil?
      default
    else
      callbacks_value != false
    end
  end

  # message is private
  def self.callbacks(value = nil, message: nil)
    if block_given?
      previous_value = callbacks_value
      begin
        self.callbacks_value = value
        result = yield
        if callbacks_value == :bulk && indexer.queued_items?
          event = {}
          if message
            message.call(event)
          else
            event[:name] = "Bulk"
            event[:count] = indexer.queued_items_count
          end
          ActiveSupport::Notifications.instrument("request.searchkick", event) do
            indexer.perform
          end
        end
        result
      ensure
        self.callbacks_value = previous_value
      end
    else
      self.callbacks_value = value
    end
  end

  def self.aws_credentials=(creds)
    require "faraday_middleware/aws_sigv4"

    @aws_credentials = creds
    @clients = {} # reset clients - named clusters may inherit these credentials
  end

  # private
  # keyed by cluster for named clusters only, so the default key - and any
  # in-flight batch state under it - is untouched
  def self.batches_key(index_name, cluster = nil)
    if canonical_cluster(cluster) == DEFAULT_CLUSTER
      "searchkick:reindex:#{index_name}:batches"
    else
      "searchkick:reindex:#{cluster}:#{index_name}:batches"
    end
  end

  # cluster: must match the one the reindex ran against, or this reads a
  # different key and reports completion for work that never happened
  def self.reindex_status(index_name, cluster: nil)
    raise Error, "Redis not configured" unless redis

    # redis-only (SCARD on the batches key), so this Index never resolves a
    # client - but it does need the cluster to build the right key
    batches_left = Index.new(index_name, cluster: cluster).batches_left
    {
      completed: batches_left == 0,
      batches_left: batches_left
    }
  end

  def self.with_redis
    if redis
      if redis.respond_to?(:with)
        redis.with do |r|
          yield r
        end
      else
        yield redis
      end
    end
  end

  def self.warn(message)
    super("[searchkick] WARNING: #{message}")
  end

  def self.normalize_on_missing(on_missing, ignore_missing)
    if !ignore_missing.nil? && !on_missing.nil?
      raise ArgumentError, "Cannot pass both on_missing and ignore_missing"
    end

    # Use a nil check instead of present? to distinguish between ignore_missing: nil (unset),
    # ignore_missing: true, and ignore_missing: false.
    if !ignore_missing.nil?
      case ignore_missing
      when true
        Searchkick.warn "ignore_missing is deprecated, use on_missing: :ignore instead of ignore_missing: true"
      when false
        Searchkick.warn "ignore_missing is deprecated, use on_missing: :raise instead of ignore_missing: false"
      end
      return ignore_missing ? :ignore : :raise
    end

    return :raise if on_missing.nil?

    on_missing = on_missing.to_sym if on_missing.is_a?(String)
    unless ON_MISSING_VALUES.include?(on_missing)
      raise ArgumentError,
      "Invalid value for on_missing: #{on_missing.inspect} (expected one of #{ON_MISSING_VALUES.map(&:inspect).join(', ')})"
    end
    on_missing
  end

  # private
  def self.load_records(relation, ids)
    relation =
      if relation.respond_to?(:primary_key)
        primary_key = relation.primary_key
        raise Error, "Need primary key to load records" if !primary_key

        relation.where(primary_key => ids)
      elsif relation.respond_to?(:queryable)
        relation.queryable.for_ids(ids)
      end

    raise Error, "Not sure how to load records" if !relation

    relation
  end

  # public (for reindexing conversions)
  def self.load_model(class_name, allow_child: false)
    model = class_name.safe_constantize
    raise Error, "Could not find class: #{class_name}" unless model
    if allow_child
      unless model.respond_to?(:searchkick_klass)
        raise Error, "#{class_name} is not a searchkick model"
      end
    else
      unless Searchkick.models.include?(model)
        raise Error, "#{class_name} is not a searchkick model"
      end
    end
    model
  end

  # private
  def self.indexer
    Thread.current[:searchkick_indexer] ||= Indexer.new
  end

  # private
  def self.callbacks_value
    Thread.current[:searchkick_callbacks_enabled]
  end

  # private
  def self.callbacks_value=(value)
    Thread.current[:searchkick_callbacks_enabled] = value
  end

  # private
  def self.signer_middleware_aws_params(credentials = aws_credentials)
    {service: "es", region: "us-east-1"}.merge(credentials)
  end

  # private
  # methods are forwarded to base class
  # this check to see if scope exists on that class
  # it's a bit tricky, but this seems to work
  def self.relation?(klass)
    if klass.respond_to?(:current_scope)
      !klass.current_scope.nil?
    else
      klass.is_a?(Mongoid::Criteria) || !Mongoid::Threaded.current_scope(klass).nil?
    end
  end

  # private
  def self.scope(model)
    # safety check to make sure used properly in code
    raise Error, "Cannot scope relation" if relation?(model)

    if model.searchkick_options[:unscope]
      model.unscoped
    else
      model
    end
  end

  # private
  def self.not_found_error?(e)
    (defined?(Elastic::Transport) && e.is_a?(Elastic::Transport::Transport::Errors::NotFound)) ||
    (defined?(Elasticsearch::Transport) && e.is_a?(Elasticsearch::Transport::Transport::Errors::NotFound)) ||
    (defined?(OpenSearch) && e.is_a?(OpenSearch::Transport::Transport::Errors::NotFound))
  end

  # private
  def self.transport_error?(e)
    (defined?(Elastic::Transport) && e.is_a?(Elastic::Transport::Transport::Error)) ||
    (defined?(Elasticsearch::Transport) && e.is_a?(Elasticsearch::Transport::Transport::Error)) ||
    (defined?(OpenSearch) && e.is_a?(OpenSearch::Transport::Transport::Error))
  end

  # private
  def self.not_allowed_error?(e)
    (defined?(Elastic::Transport) && e.is_a?(Elastic::Transport::Transport::Errors::MethodNotAllowed)) ||
    (defined?(Elasticsearch::Transport) && e.is_a?(Elasticsearch::Transport::Transport::Errors::MethodNotAllowed)) ||
    (defined?(OpenSearch) && e.is_a?(OpenSearch::Transport::Transport::Errors::MethodNotAllowed))
  end
end

ActiveSupport.on_load(:active_record) do
  extend Searchkick::Model
end

ActiveSupport.on_load(:mongoid) do
  Mongoid::Document::ClassMethods.include Searchkick::Model
end

ActiveSupport.on_load(:action_controller) do
  include Searchkick::ControllerRuntime
end

Searchkick::LogSubscriber.attach_to :searchkick
