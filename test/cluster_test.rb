require_relative "test_helper"

class ClusterTest < Minitest::Test
  def setup
    @previous_clusters = Searchkick.clusters
    @previous_search_timeout = Searchkick.instance_variable_get(:@search_timeout)
    @previous_timeout = Searchkick.instance_variable_get(:@timeout)
    @previous_client_type = Searchkick.instance_variable_get(:@client_type)
  end

  def teardown
    Searchkick.instance_variable_set(:@search_timeout, @previous_search_timeout)
    Searchkick.instance_variable_set(:@timeout, @previous_timeout)
    Searchkick.instance_variable_set(:@client_type, @previous_client_type)
    Searchkick.clusters = @previous_clusters
  end

  # resolution

  def test_default_cluster_is_nil_and_default
    assert_equal Searchkick.client(:default), Searchkick.client
    assert Searchkick.client.equal?(Searchkick.client(:default))
  end

  def test_unknown_cluster
    error = assert_raises(Searchkick::Error) { Searchkick.client(:nope) }
    assert_includes error.message, "Unknown cluster: :nope"
    assert_includes error.message, ":secondary"
  end

  def test_cannot_configure_default_cluster
    error = assert_raises(Searchkick::Error) { Searchkick.clusters = {default: {url: "http://localhost:9200"}} }
    assert_includes error.message, "Searchkick.timeout"
  end

  def test_string_keys_are_symbolized
    Searchkick.clusters = {"archive" => {timeout: 30}}
    assert_equal 30, Searchkick.timeout(:archive)
    assert_equal 30, Searchkick.timeout("archive")
  end

  # immutability

  def test_registry_is_frozen
    Searchkick.clusters = {archive: {timeout: 30, client_options: {retry_on_failure: 5}}}

    assert Searchkick.clusters.frozen?
    assert Searchkick.clusters[:archive].frozen?
    assert Searchkick.clusters[:archive][:client_options].frozen?
    assert_raises(FrozenError) { Searchkick.clusters[:archive] = {} }
  end

  def test_registry_does_not_freeze_the_callers_hash
    config = {timeout: 30, client_options: {retry_on_failure: 5}}
    Searchkick.clusters = {archive: config}

    refute config.frozen?
    refute config[:client_options].frozen?
  end

  # an injected client has to stay the caller's own object - a copy would break
  # stubs and identity checks against the instance they handed us
  def test_injected_client_is_not_duplicated
    injected = Object.new
    Searchkick.clusters = {custom: {client: injected}}

    assert Searchkick.client(:custom).equal?(injected)
    assert Searchkick.clusters[:custom][:client].equal?(injected)
    refute injected.frozen?
  end

  # config fallback

  def test_timeout_falls_back_to_global
    Searchkick.clusters = {archive: {}, slow: {timeout: 30}}

    assert_equal Searchkick.timeout, Searchkick.timeout(:archive)
    assert_equal 30, Searchkick.timeout(:slow)
  end

  def test_search_timeout_fallback_chain
    Searchkick.clusters = {archive: {}, slow: {timeout: 30}, precise: {search_timeout: 2}}

    Searchkick.instance_variable_set(:@search_timeout, nil)
    # unset globally: falls back to the cluster's own timeout, not the default's
    assert_equal Searchkick.timeout, Searchkick.search_timeout(:archive)
    assert_equal 30, Searchkick.search_timeout(:slow)

    Searchkick.search_timeout = 5
    assert_equal 5, Searchkick.search_timeout(:archive)
    assert_equal 5, Searchkick.search_timeout(:slow)
    # a cluster override still wins over the global
    assert_equal 2, Searchkick.search_timeout(:precise)
  end

  # client_options is documented as mutable in place, so the reader must return
  # the same object when there is nothing to merge
  def test_client_options_returns_same_object_without_override
    assert Searchkick.client_options.equal?(Searchkick.client_options)

    options = Searchkick.client_options
    options[:test_key] = true
    begin
      assert Searchkick.client_options.equal?(options)
      assert Searchkick.client_options[:test_key]
    ensure
      Searchkick.client_options.delete(:test_key)
    end
  end

  def test_client_options_merges_override
    Searchkick.client_options[:retry_on_failure] = 2
    Searchkick.clusters = {archive: {client_options: {reload_connections: true}}}

    merged = Searchkick.client_options(:archive)
    assert_equal 2, merged[:retry_on_failure]
    assert merged[:reload_connections]
    # the global is not modified by the merge
    refute Searchkick.client_options.key?(:reload_connections)
  ensure
    Searchkick.client_options.delete(:retry_on_failure)
  end

  # nil unless explicitly configured - the engine sniff lives in the private
  # resolved_client_type, so this stays a pure config read
  def test_client_type_is_nil_unless_configured
    Searchkick.clusters = {archive: {client_type: :opensearch}}

    assert_nil Searchkick.client_type
    assert_equal :opensearch, Searchkick.client_type(:archive)
  end

  def test_aws_credentials_can_be_disabled_per_cluster
    Searchkick.clusters = {inherits: {}, standalone: {aws_credentials: nil}}
    previous = Searchkick.instance_variable_get(:@aws_credentials)
    Searchkick.instance_variable_set(:@aws_credentials, {access_key_id: "key"})

    assert_equal({access_key_id: "key"}, Searchkick.aws_credentials(:inherits))
    assert_nil Searchkick.aws_credentials(:standalone)
  ensure
    Searchkick.instance_variable_set(:@aws_credentials, previous)
  end

  # clients

  def test_separate_client_per_cluster
    # same server, but a distinct connection pool
    refute Searchkick.client(:secondary).equal?(Searchkick.client)
    assert Searchkick.client(:secondary).equal?(Searchkick.client(:secondary))
  end

  # reassigning a named cluster must drop its memoized client, since its config
  # may have changed
  def test_assigning_clusters_resets_named_cluster_clients
    Searchkick.clusters = {archive: {}}
    before = Searchkick.client(:archive)
    Searchkick.clusters = {archive: {url: "http://127.0.0.1:9"}}

    refute Searchkick.client(:archive).equal?(before)
  end

  # ...but the default cluster is untouched by the registry, so its client must
  # survive - it may have been installed through Searchkick.client=
  def test_assigning_clusters_keeps_the_default_client
    before = Searchkick.client
    Searchkick.clusters = {archive: {}}

    assert Searchkick.client.equal?(before)
  end

  def test_assigning_clusters_keeps_a_custom_default_client
    previous = Searchkick.client
    custom = Object.new
    Searchkick.client = custom
    Searchkick.clusters = {archive: {}}

    assert Searchkick.client.equal?(custom)
  ensure
    Searchkick.client = previous
  end

  def test_client_writer_sets_default
    previous = Searchkick.client
    fake = Object.new
    Searchkick.client = fake

    assert_equal fake, Searchkick.client
  ensure
    Searchkick.client = previous
  end

  # cheapest proof that a per-cluster url is actually honored: port 9 (discard)
  # refuses immediately on loopback
  def test_cluster_url_is_used
    Searchkick.clusters = {unreachable: {url: "http://127.0.0.1:9", timeout: 1}}

    assert_raises(Searchkick::Error) do
      begin
        Searchkick::Index.new("whatever", cluster: :unreachable).exists?
      rescue => e
        raise Searchkick::Error, e.message
      end
    end

    # the default cluster is unaffected
    assert Searchkick.client.info
  end

  # middleware resolves timeouts against its own cluster
  def test_middleware_uses_cluster_timeout
    Searchkick.clusters = {slow: {timeout: 30, search_timeout: 7}}

    assert_equal Searchkick.search_timeout, middleware_timeout(nil, "/products/_search")
    assert_equal 7, middleware_timeout(:slow, "/products/_search")
  end

  def test_middleware_msearch_clamps_to_cluster_timeout
    Searchkick.clusters = {slow: {timeout: 30, search_timeout: 7}}

    # 10 searches * 7 = 70, clamped to the cluster's timeout
    assert_equal 30, middleware_timeout(:slow, "/_msearch", "a\nb\n" * 10)
  end

  private

  def middleware_timeout(cluster, path, body = nil)
    env = {url: URI("http://localhost:9200#{path}"), request: {}, request_body: body}
    Searchkick::Middleware.new(->(e) { e }, {cluster: cluster}).call(env)
    env[:request][:timeout]
  end
end
