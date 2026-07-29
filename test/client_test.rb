require_relative "test_helper"

class ClientTest < Minitest::Test
  class TrackingClient
    attr_reader :calls

    def initialize(client)
      @client = client
      @calls = []
    end

    def method_missing(name, *args, **kwargs, &block)
      calls << [name, args, kwargs]
      @client.public_send(name, *args, **kwargs, &block)
    end

    def respond_to_missing?(name, include_private = false)
      @client.respond_to?(name, include_private) || super
    end
  end

  class InfoClient
    def initialize(distribution, version)
      @distribution = distribution
      @version = version
    end

    def info
      {"version" => {"distribution" => @distribution, "number" => @version}}
    end
  end

  def test_named_client
    with_secondary_client do |client|
      assert_same client, Searchkick.client(:secondary)
      assert_same client, Searchkick.client("secondary")
      Searchkick.clients = {"secondary" => client}
      assert_same client, Searchkick.client(:secondary)

      with_options({client_name: :secondary}, Song) do
        assert_same client, Song.searchkick_index.client
        assert client.calls.any? { |call| call.first == :indices }

        Song.create!(name: "Secondary")
        Song.searchkick_index.refresh

        assert_equal ["Secondary"], Song.search("*", load: false).map { |result| result["name"] }
        assert client.calls.any? { |call| call.first == :bulk }
        assert client.calls.any? { |call| call.first == :search }
      end
    end
  end

  def test_unknown_named_client
    error = assert_raises(Searchkick::Error) do
      Searchkick::Index.new("missing", client_name: :missing).client
    end
    assert_equal "Unknown client: :missing", error.message
  end

  def test_server_features_use_named_client
    previous_clients = Searchkick.clients
    old_opensearch = InfoClient.new("opensearch", "2.3.0")
    new_elasticsearch = InfoClient.new("elasticsearch", "9.0.0")
    Searchkick.clients = {old_opensearch: old_opensearch, new_elasticsearch: new_elasticsearch}

    assert Searchkick.opensearch?(Searchkick.client(:old_opensearch))
    refute Searchkick.knn_support?(Searchkick.client(:old_opensearch))
    refute Searchkick.opensearch?(Searchkick.client(:new_elasticsearch))
    assert Searchkick.knn_support?(Searchkick.client(:new_elasticsearch))

    index = Searchkick::Index.new(
      "old_opensearch",
      client_name: :old_opensearch,
      knn: {embedding: {dimensions: 3, distance: "cosine"}}
    )
    error = assert_raises(Searchkick::Error) { index.index_options }
    assert_equal "knn requires OpenSearch 2.4+", error.message
  ensure
    Searchkick.clients = previous_clients
  end

  def test_bulk_callbacks_are_split_by_client
    with_secondary_client do |client|
      with_options({client_name: :secondary}, Song) do
        client.calls.clear

        Searchkick.callbacks(:bulk) do
          Product.create!(name: "Default")
          Song.create!(name: "Secondary")
        end

        bulk_calls = client.calls.select { |call| call.first == :bulk }
        assert_equal 1, bulk_calls.size
        body = call_params(bulk_calls.first).fetch(:body)
        assert body.all? { |item| item.values.first[:_index] == Song.searchkick_index.name }
      end
    end
  end

  def test_multi_search_is_split_by_client
    with_secondary_client do |client|
      with_options({client_name: :secondary}, Song) do
        Product.create!(name: "Default")
        Song.create!(name: "Secondary")
        Product.searchkick_index.refresh
        Song.searchkick_index.refresh
        client.calls.clear

        products = Product.search("*", load: false)
        songs = Song.search("*", load: false)
        queries = [products, songs]
        assert_equal 2, Searchkick.multi_search(queries).size

        assert_equal ["Default"], products.map { |result| result["name"] }
        assert_equal ["Secondary"], songs.map { |result| result["name"] }

        multi_search_calls = client.calls.select { |call| call.first == :msearch }
        assert_equal 1, multi_search_calls.size
        assert_equal 2, call_params(multi_search_calls.first).fetch(:body).size
      end
    end
  end

  def test_single_query_cannot_span_clients
    with_secondary_client do
      with_options({client_name: :secondary}, Song) do
        query = Searchkick.search("*", models: [Product, Song], load: false)
        error = assert_raises(Searchkick::Error) { query.to_a }
        assert_equal "Cannot search models on multiple clients in a single query - use Searchkick.multi_search", error.message
      end
    end
  end

  def test_scroll_uses_named_client
    with_secondary_client do |client|
      with_options({client_name: :secondary}, Song) do
        Song.create!([{name: "One"}, {name: "Two"}])
        Song.searchkick_index.refresh
        client.calls.clear

        results = Song.search("*", load: false, order: {name: :asc}, scroll: "1m", per_page: 1)
        assert_equal ["One"], results.map { |result| result["name"] }
        results = results.scroll
        assert_equal ["Two"], results.map { |result| result["name"] }
        results.clear_scroll
        assert client.calls.any? { |call| call.first == :scroll }
        assert client.calls.any? { |call| call.first == :clear_scroll }
      end
    end
  end

  def test_reindex_job_uses_named_client
    with_secondary_client do |client|
      with_options({client_name: :secondary}, Song) do
        song = Searchkick.callbacks(false) { Song.create!(name: "Secondary") }
        client.calls.clear

        Searchkick::ReindexV2Job.perform_now("Song", song.id.to_s)

        assert client.calls.any? { |call| call.first == :bulk }
      end
    end
  end

  private

  def call_params(call)
    args = call[1]
    kwargs = call[2]
    kwargs.any? ? kwargs : args.first
  end

  def with_secondary_client
    previous_clients = Searchkick.clients
    client = TrackingClient.new(Searchkick.client)
    Searchkick.clients = previous_clients.merge(secondary: client)
    Song.delete_all
    yield client
  ensure
    Searchkick.clients = previous_clients
    Song.delete_all
  end
end
