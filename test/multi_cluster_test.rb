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
    # distinctive terms - single letters are within misspelling distance of each other
    store_names ["Apple", "Banana"], AltProduct

    assert_equal ["Apple"], AltProduct.search("apple", fields: [:name], load: false).map(&:name)
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

    assert_equal %i[default secondary], buckets.sort

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
  # a raw index name carries no cluster, so the model must still decide -
  # otherwise this silently queries that index name on the default cluster
  def test_raw_index_name_keeps_the_models_cluster
    assert_equal :secondary, cluster_for(AltProduct.search("*", index_name: "alternate", load: false))
    # Searchkick.search collapses a single models: entry into klass
    assert_equal :secondary, cluster_for(Searchkick.search("*", models: [AltProduct], index_name: "alternate", load: false))
    assert_equal Searchkick::DEFAULT_CLUSTER, cluster_for(Product.search("*", index_name: "alternate", load: false))
  end

  def test_raw_index_name_without_model_context_is_default
    assert_equal Searchkick::DEFAULT_CLUSTER, cluster_for(Searchkick.search("*", index_name: "alternate", load: false))
  end

  def test_explicit_cluster_still_overrides_the_model
    assert_equal Searchkick::DEFAULT_CLUSTER, cluster_for(AltProduct.search("*", cluster: :default, load: false))
  end

  # a model/index_name mismatch is caught either way: searchkick's own guard
  # rejects it when there is a klass, and the cluster check when there is not
  def test_index_name_naming_a_model_on_another_cluster_raises
    assert_raises(ArgumentError) { AltProduct.search("*", index_name: [Product], load: false) }
    assert_raises(Searchkick::Error) { cluster_for(Searchkick.search("*", index_name: [AltProduct, Product], load: false)) }
    assert_raises(Searchkick::Error) { cluster_for(Searchkick.search("*", index_name: [AltProduct, "raw_name"], load: false)) }
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

  # nil and :default name the same cluster, so mixing them is not a conflict
  def test_implicit_and_explicit_default_are_the_same_cluster
    Searchkick.multi_search([
      Product.search("*", load: false),
      Product.search("*", cluster: :default, load: false)
    ])

    assert_equal Searchkick::DEFAULT_CLUSTER, Product.search("*", load: false).send(:query).cluster
    assert_equal Searchkick::DEFAULT_CLUSTER, Product.search("*", cluster: :default, load: false).send(:query).cluster
    assert_equal Searchkick::DEFAULT_CLUSTER, Product.search("*", cluster: "default", load: false).send(:query).cluster
  end

  # canonicalizing identity must not leak into job payloads: nil is unpinned,
  # :default is pinned, and only the latter serializes
  def test_canonicalization_does_not_pin_default_jobs
    assert_nil Product.searchkick_index.cluster
    assert_equal :default, Product.searchkick_index(cluster: :default).cluster
  end

  # ...but they are one physical cluster, so they share a bulk request
  def test_default_variants_share_one_bulk_bucket
    Searchkick.callbacks(:bulk) do
      Searchkick.indexer.queue([{index: {_id: 1}}])
      Searchkick.indexer.queue([{index: {_id: 2}}], cluster: :default)
      Searchkick.indexer.queue([{index: {_id: 3}}], cluster: "default")
      Searchkick.indexer.queue([{index: {_id: 4}}], cluster: :secondary)

      buckets = Searchkick.indexer.queued_items_by_cluster
      assert_equal %i[default secondary], buckets.keys.sort
      assert_equal 3, buckets[:default].size
      assert_equal 4, Searchkick.indexer.queued_items_count
      assert Searchkick.indexer.queued_items?

      # drop them rather than sending nonsense documents at teardown
      buckets.clear
    end
  end

  def test_multi_search_across_clusters_raises
    error = assert_raises(Searchkick::Error) do
      Searchkick.multi_search([Product.search("*", load: false), AltProduct.search("*", load: false)])
    end
    assert_includes error.message, "Cannot multi search across clusters"
  end

  def test_multi_search_on_one_cluster_still_works
    store_names ["Apple", "Banana"], AltProduct

    apple = AltProduct.search("apple", fields: [:name], load: false)
    banana = AltProduct.search("banana", fields: [:name], load: false)
    Searchkick.multi_search([apple, banana])

    assert_equal ["Apple"], apple.map(&:name)
    assert_equal ["Banana"], banana.map(&:name)
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

  # two clusters running async reindexes of the same index name must not share
  # one batch set - a completion on either would clear the other's outstanding
  # batch and report done early
  def test_batches_key_is_cluster_scoped
    assert_equal(
      "searchkick:reindex:products_test_123:batches",
      Searchkick.batches_key("products_test_123")
    )
    assert_equal(
      "searchkick:reindex:products_test_123:batches",
      Searchkick.batches_key("products_test_123", :default)
    )
    assert_equal(
      "searchkick:reindex:secondary:products_test_123:batches",
      Searchkick.batches_key("products_test_123", :secondary)
    )
  end

  def test_batches_do_not_cross_clusters
    name = "shared_batch_index"
    default_index = Searchkick::Index.new(name)
    secondary_index = Searchkick::Index.new(name, cluster: :secondary)
    Searchkick.with_redis { |r| r.call("DEL", Searchkick.batches_key(name), Searchkick.batches_key(name, :secondary)) }

    Searchkick.with_redis do |r|
      r.call("SADD", Searchkick.batches_key(name), [1])
      r.call("SADD", Searchkick.batches_key(name, :secondary), [1])
    end

    # completing batch 1 on the default cluster must not clear the secondary's
    Searchkick::RelationIndexer.new(default_index).batch_completed(1)

    assert_equal 0, default_index.batches_left
    assert_equal 1, secondary_index.batches_left
  ensure
    Searchkick.with_redis { |r| r.call("DEL", Searchkick.batches_key(name), Searchkick.batches_key(name, :secondary)) }
  end

  # reindex_status has to read the same key the reindex wrote, or wait: true
  # reports completion for work that never happened and promotes an empty index
  def test_reindex_status_reads_the_clusters_key
    name = "status_index"
    Searchkick.with_redis { |r| r.call("SADD", Searchkick.batches_key(name, :secondary), [1]) }

    assert_equal 0, Searchkick.reindex_status(name)[:batches_left]
    assert Searchkick.reindex_status(name)[:completed]

    status = Searchkick.reindex_status(name, cluster: :secondary)
    assert_equal 1, status[:batches_left]
    refute status[:completed]
  ensure
    Searchkick.with_redis { |r| r.call("DEL", Searchkick.batches_key(name, :secondary)) }
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

  private

  def cluster_for(relation)
    relation.send(:query).cluster
  end
end
