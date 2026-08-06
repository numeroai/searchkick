require_relative "test_helper"

class MultiClusterTest < Minitest::Test
  def setup
    super
    setup_model(AltProduct)
  end

  # routing

  def test_model_index_uses_its_cluster
    assert_equal :secondary, AltProduct.searchkick_index.cluster
    assert_nil Product.searchkick_index.cluster
  end

  # numero_server specs stub Searchkick.client and assert on it while exercising
  # code that calls index.client - these must stay the same object
  def test_default_index_client_is_the_global_client
    assert Product.searchkick_index.client.equal?(Searchkick.client)
  end

  def test_secondary_index_uses_its_own_client
    assert AltProduct.searchkick_index.client.equal?(Searchkick.client(:secondary))
    refute AltProduct.searchkick_index.client.equal?(Searchkick.client)
  end

  def test_cluster_override
    index = Product.searchkick_index(cluster: :secondary)

    assert_equal :secondary, index.cluster
    assert_equal Product.searchkick_index.name, index.name
    # the override must not evict or alias the model's real index
    assert_nil Product.searchkick_index.cluster
  end

  # reindex + search round trip on the secondary cluster

  def test_reindex_and_search
    store_names ["Product A", "Product B"], AltProduct

    assert_equal ["Product A"], AltProduct.search("product a", fields: [:name], load: false).map(&:name)
  end

  def test_documents_do_not_leak_to_the_default_cluster
    store_names ["Only On Secondary"], AltProduct

    # distinct index names (index_prefix), so the default cluster has no such index
    refute Product.searchkick_index.name == AltProduct.searchkick_index.name
    assert_equal 0, Product.search("only on secondary", fields: [:name], load: false).total_count
  end

  def test_clean_indices_deletes_on_the_right_cluster
    index = AltProduct.searchkick_index
    original = index.name

    AltProduct.reindex
    index.clean_indices

    # the alias still resolves and the index is still queryable on the secondary
    assert index.exists?
    assert_equal original, AltProduct.searchkick_index.name
  end

  # bulk callbacks spanning clusters must not put one cluster's documents in the
  # other's bulk body
  def test_bulk_callbacks_partition_by_cluster
    buckets = nil
    Searchkick.callbacks(:bulk) do
      Product.create!(name: "Bulk Default")
      AltProduct.create!(name: "Bulk Secondary")
      buckets = Searchkick.indexer.queued_items_by_cluster.keys
    end

    assert_equal [nil, :secondary], buckets.sort_by(&:to_s)

    Product.searchkick_index.refresh
    AltProduct.searchkick_index.refresh
    assert_equal 1, Product.search("bulk default", fields: [:name], load: false).total_count
    assert_equal 1, AltProduct.search("bulk secondary", fields: [:name], load: false).total_count
  end

  # a search request targets one cluster

  def test_search_across_clusters_raises
    error = assert_raises(Searchkick::Error) do
      Searchkick.search("*", models: [Product, AltProduct], load: false).to_a
    end
    assert_includes error.message, "Cannot search across clusters"
    # multi_search is single-cluster too, so it must not be suggested as the fix
    refute_includes error.message, "multi_search"
  end

  # a raw index name contributes the default cluster, so mixing it with a
  # secondary model is caught rather than sent to the wrong server
  def test_search_mixing_raw_index_name_and_secondary_model_raises
    assert_raises(Searchkick::Error) do
      Searchkick.search("*", index_name: [AltProduct, "some_raw_index"], load: false).to_a
    end
  end

  def test_explicit_cluster_option
    store_names ["Explicit Cluster"], AltProduct

    results = Searchkick.search(
      "explicit cluster",
      index_name: [AltProduct.searchkick_index.name],
      cluster: :secondary,
      fields: [:name],
      load: false
    )

    assert_equal ["Explicit Cluster"], results.map(&:name)
  end

  def test_multi_search_across_clusters_raises
    error = assert_raises(Searchkick::Error) do
      Searchkick.multi_search([Product.search("*", load: false), AltProduct.search("*", load: false)])
    end
    assert_includes error.message, "Cannot multi search across clusters"
  end

  def test_multi_search_on_one_cluster_still_works
    store_names ["Multi A"], AltProduct
    store_names ["Multi B"], AltProduct

    a = AltProduct.search("multi a", fields: [:name], load: false)
    b = AltProduct.search("multi b", fields: [:name], load: false)
    Searchkick.multi_search([a, b])

    assert_equal ["Multi A"], a.map(&:name)
    assert_equal ["Multi B"], b.map(&:name)
  end

  # scroll must continue on the query's cluster
  def test_scroll
    store_names ["Scroll A", "Scroll B"], AltProduct

    names = []
    AltProduct.search("*", per_page: 1, scroll: "1m", load: false).scroll do |batch|
      names.concat(batch.map(&:name))
    end

    assert_equal ["Scroll A", "Scroll B"], names.sort
  end

  # jobs

  def test_async_reindex_pins_the_cluster
    AltProduct.create!(name: "Async")

    assert_enqueued_with(job: Searchkick::BulkReindexJob) do
      AltProduct.searchkick_index.reindex(AltProduct.all, mode: :async, refresh: false)
    end

    job = enqueued_jobs.last
    assert_equal "secondary", job["arguments"].first["cluster"]
  end

  def test_default_async_reindex_omits_the_cluster_argument
    Product.create!(name: "Async Default")

    assert_enqueued_with(job: Searchkick::BulkReindexJob) do
      Product.searchkick_index.reindex(Product.all, mode: :async, refresh: false)
    end

    # unpinned default work must stay wire-compatible with workers running an
    # older searchkick that does not accept cluster:
    job = enqueued_jobs.last
    refute job["arguments"].first.key?("cluster")
  end

  # queue mode

  def test_reindex_queue_key_is_cluster_scoped
    assert_equal(
      "searchkick:reindex_queue:#{Product.searchkick_index.name}",
      Product.searchkick_index.reindex_queue.send(:redis_key)
    )
    assert_equal(
      "searchkick:reindex_queue:secondary:#{AltProduct.searchkick_index.name}",
      AltProduct.searchkick_index.reindex_queue.send(:redis_key)
    )
  end

  def test_queues_on_different_clusters_do_not_steal_ids
    default_queue = Searchkick::ReindexQueue.new("shared_index_name")
    secondary_queue = Searchkick::ReindexQueue.new("shared_index_name", :secondary)
    default_queue.clear
    secondary_queue.clear

    default_queue.push(["1"])
    secondary_queue.push(["2"])

    assert_equal ["1"], default_queue.reserve
    assert_equal ["2"], secondary_queue.reserve
  ensure
    default_queue&.clear
    secondary_queue&.clear
  end

  def test_explicit_default_cluster_uses_the_unchanged_key
    assert_equal(
      Searchkick::ReindexQueue.new("products").send(:redis_key),
      Searchkick::ReindexQueue.new("products", :default).send(:redis_key)
    )
  end

  def test_queue_mode_reaches_the_secondary_cluster
    AltProduct.searchkick_index.reindex_queue.clear
    product = nil
    Searchkick.callbacks(:queue) do
      product = AltProduct.create!(name: "Queued")
    end

    assert_equal 1, AltProduct.searchkick_index.reindex_queue.length

    Searchkick::ProcessQueueJob.new.perform(class_name: "AltProduct", inline: true)
    AltProduct.searchkick_index.refresh

    assert_equal ["Queued"], AltProduct.search("queued", fields: [:name], load: false).map(&:name)
    assert product
  end

  def test_process_queue_job_propagates_the_cluster_to_batch_jobs
    AltProduct.searchkick_index.reindex_queue.clear
    Searchkick.callbacks(:queue) { AltProduct.create!(name: "Propagated") }

    Searchkick::ProcessQueueJob.new.perform(class_name: "AltProduct")

    job = enqueued_jobs.last
    assert_equal "secondary", job["arguments"].first["cluster"]
  end

  def test_process_queue_job_omits_the_cluster_for_default_work
    Product.searchkick_index.reindex_queue.clear
    Searchkick.callbacks(:queue) { Product.create!(name: "Default Queued") }

    Searchkick::ProcessQueueJob.new.perform(class_name: "Product")

    job = enqueued_jobs.last
    refute job["arguments"].first.key?("cluster")
  ensure
    Product.searchkick_index.reindex_queue.clear
  end

  # an explicitly pinned :default must serialize, or a worker would resolve the
  # model's own (secondary) cluster and write to the wrong place
  def test_explicit_default_pin_overrides_a_secondary_model
    index = AltProduct.searchkick_index(cluster: :default)

    assert_equal :default, index.cluster
    assert index.client.equal?(Searchkick.client)
  end

  def default_model
    AltProduct
  end
end
