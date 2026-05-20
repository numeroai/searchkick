require_relative "test_helper"

class PartialReindexTest < Minitest::Test
  def test_record_inline
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Searchkick.callbacks(false) do
      product.update!(name: "Bye", color: "Red")
    end

    product.reindex(:search_name, refresh: true)

    # name updated, but not color
    assert_search "bye", ["Bye"], fields: [:name], load: false
    assert_search "blue", ["Bye"], fields: [:color], load: false
  end

  def test_update_record_uses_default_on_missing
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Searchkick.callbacks(false) do
      product.update!(name: "Bye", color: "Red")
    end

    Product.searchkick_index.update_record(product, :search_name)
    Product.searchkick_index.refresh

    assert_search "bye", ["Bye"], fields: [:name], load: false
    assert_search "blue", ["Bye"], fields: [:color], load: false
  end

  def test_record_async
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Searchkick.callbacks(false) do
      product.update!(name: "Bye", color: "Red")
    end

    perform_enqueued_jobs do
      product.reindex(:search_name, mode: :async)
    end
    Product.searchkick_index.refresh

    # name updated, but not color
    assert_search "bye", ["Bye"], fields: [:name], load: false
    assert_search "blue", ["Bye"], fields: [:color], load: false
  end

  def test_record_queue
    Contact.searchkick_index.reindex_queue.clear

    contact = Contact.create!(name: "Hi", email: "hi@example.com")
    contact.reindex
    Contact.searchkick_index.refresh

    Searchkick.callbacks(false) do
      contact.update!(name: "Bye", email: "bye@example.com")
    end
    Contact.searchkick_index.refresh

    contact.reindex(:search_name, mode: :queue)
    perform_enqueued_jobs do
      Searchkick::ProcessQueueJob.perform_now(class_name: "Contact")
    end
    Contact.searchkick_index.refresh

    doc = Contact.search("*", where: {id: contact.id}, load: false).hits.first["_source"]
    assert_equal "Bye", doc["name"]
    assert_equal "hi@example.com", doc["email"]
  end

  def test_record_missing_inline
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Product.searchkick_index.remove(product)

    error = assert_raises(Searchkick::ImportError) do
      product.reindex(:search_name)
    end
    assert_match "document missing", error.message
  end

  def test_record_on_missing_ignore_inline
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Product.searchkick_index.remove(product)

    product.reindex(:search_name, on_missing: :ignore)
    Searchkick.callbacks(:bulk) do
      product.reindex(:search_name, on_missing: :ignore)
    end
  end

  def test_record_missing_async
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Product.searchkick_index.remove(product)

    perform_enqueued_jobs do
      error = assert_raises(Searchkick::ImportError) do
        product.reindex(:search_name, mode: :async)
      end
      assert_match "document missing", error.message
    end
  end

  def test_record_on_missing_ignore_async
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Product.searchkick_index.remove(product)

    perform_enqueued_jobs do
      product.reindex(:search_name, mode: :async, on_missing: :ignore)
    end
  end

  def test_record_missing_queue
    contact = Contact.create!(name: "Hi", email: "hi@example.com")
    Contact.searchkick_index.remove(contact)


    contact.reindex(:search_name, mode: :queue, on_missing: :raise)

    error = assert_raises(Searchkick::ImportError) do
      Searchkick::ProcessQueueJob.perform_now(class_name: "Contact", inline: true)
    end
    assert_match "document missing", error.message
  end

  def test_record_ignore_missing_queue
    contact = Contact.create!(name: "Hi", email: "hi@example.com")
    Contact.searchkick_index.remove(contact)


    contact.reindex(:search_name, mode: :queue, on_missing: :ignore)

    perform_enqueued_jobs do
      Searchkick::ProcessQueueJob.perform_now(class_name: "Contact", inline: true)
    end
  end

  def test_relation_inline
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Searchkick.callbacks(false) do
      product.update!(name: "Bye", color: "Red")
    end

    Product.reindex(:search_name)

    # name updated, but not color
    assert_search "bye", ["Bye"], fields: [:name], load: false
    assert_search "blue", ["Bye"], fields: [:color], load: false

    # scope
    Product.reindex(:search_name, scope: :all)
  end

  def test_relation_async
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Searchkick.callbacks(false) do
      product.update!(name: "Bye", color: "Red")
    end

    perform_enqueued_jobs do
      Product.reindex(:search_name, mode: :async)
    end

    # name updated, but not color
    assert_search "bye", ["Bye"], fields: [:name], load: false
    assert_search "blue", ["Bye"], fields: [:color], load: false
  end

  def test_relation_queue
    Contact.searchkick_index.reindex_queue.clear

    alice = Contact.create!(name: "Alice", email: "alice@example.com")
    bob   = Contact.create!(name: "Bob",   email: "bob@example.com")
    carol = Contact.create!(name: "Carol", email: "carol@example.com")
    [alice, bob, carol].each(&:reindex)

    Searchkick.callbacks(false) do
      alice.update!(name: "Alice-new", email: "alice-new@example.com")
      bob.update!(name:   "Bob-new",   email: "bob-new@example.com")
      carol.update!(name: "Carol-new", email: "carol-new@example.com")
    end

    Contact.where(id: [alice.id, bob.id]).reindex(:search_name, mode: :queue)

    perform_enqueued_jobs do
      Searchkick::ProcessQueueJob.perform_now(class_name: "Contact")
    end
    Contact.searchkick_index.refresh

    alice_doc = Contact.searchkick_index.retrieve(alice)
    bob_doc   = Contact.searchkick_index.retrieve(bob)
    carol_doc = Contact.searchkick_index.retrieve(carol)

    assert_equal "Alice-new",         alice_doc["name"]
    assert_equal "alice@example.com", alice_doc["email"]
    assert_equal "Bob-new",           bob_doc["name"]
    assert_equal "bob@example.com",   bob_doc["email"]

    assert_equal "Carol",              carol_doc["name"]
    assert_equal "carol@example.com",  carol_doc["email"]
  end

  def test_relation_missing_inline
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Product.searchkick_index.remove(product)

    error = assert_raises(Searchkick::ImportError) do
      Product.reindex(:search_name)
    end
    assert_match "document missing", error.message
  end

  def test_relation_on_missing_ignore_inline
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Product.searchkick_index.remove(product)

    Product.where(id: product.id).reindex(:search_name, on_missing: :ignore)
  end

  def test_relation_missing_async
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Product.searchkick_index.remove(product)

    perform_enqueued_jobs do
      error = assert_raises(Searchkick::ImportError) do
        Product.reindex(:search_name, mode: :async)
      end
      assert_match "document missing", error.message
    end
  end

  def test_relation_on_missing_ignore_async
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Product.searchkick_index.remove(product)

    perform_enqueued_jobs do
      Product.where(id: product.id).reindex(:search_name, mode: :async, on_missing: :ignore)
    end
  end

  def test_ignore_missing_deprecated
    store [{name: "Hi", color: "Blue"}]
    product = Product.first
    Product.searchkick_index.remove(product)

    assert_warns("ignore_missing is deprecated, use on_missing: :ignore instead") do
      product.reindex(:search_name, ignore_missing: true)
    end
  end

  def test_bulk_update_ignore_missing_deprecated
    store [{name: "Hi", color: "Blue"}]
    product = Product.first
    Product.searchkick_index.remove(product)

    assert_warns("ignore_missing is deprecated, use on_missing: :ignore instead") do
      Product.searchkick_index.bulk_update([product], :search_name, ignore_missing: true)
    end
  end

  def test_bulk_update_accepts_string_on_missing
    store [{name: "Hi", color: "Blue"}]
    product = Product.first
    Product.searchkick_index.remove(product)

    Product.searchkick_index.bulk_update([product], :search_name, on_missing: "ignore")
  end

  def test_record_on_missing_raise_explicit
    store [{name: "Hi", color: "Blue"}]
    product = Product.first
    Product.searchkick_index.remove(product)

    error = assert_raises(Searchkick::ImportError) do
      product.reindex(:search_name, on_missing: :raise)
    end
    assert_match "document missing", error.message
  end

  def test_record_on_missing_full_inline
    store [{name: "Hi", color: "Blue"}]
    product = Product.first
    Product.searchkick_index.remove(product)
    Searchkick.callbacks(false) { product.update!(name: "Bye", color: "Red") }

    product.reindex(:search_name, on_missing: :full, refresh: true)

    assert_search "bye", ["Bye"], fields: [:name], load: false
    assert_search "red", ["Bye"], fields: [:color], load: false
  end

  def test_record_on_missing_full_async
    store [{name: "Hi", color: "Blue"}]
    product = Product.first
    Product.searchkick_index.remove(product)
    Searchkick.callbacks(false) { product.update!(name: "Bye", color: "Red") }

    perform_enqueued_jobs do
      product.reindex(:search_name, mode: :async, on_missing: :full)
    end
    Product.searchkick_index.refresh

    assert_search "bye", ["Bye"], fields: [:name], load: false
    assert_search "red", ["Bye"], fields: [:color], load: false
  end

  def test_relation_on_missing_full_inline
    store [{name: "Hi", color: "Blue"}]
    product = Product.first
    Product.searchkick_index.remove(product)
    Searchkick.callbacks(false) { product.update!(name: "Bye", color: "Red") }

    Product.where(id: product.id).reindex(:search_name, on_missing: :full)
    Product.searchkick_index.refresh

    assert_search "bye", ["Bye"], fields: [:name], load: false
    assert_search "red", ["Bye"], fields: [:color], load: false
  end

  def test_relation_on_missing_full_async
    store [{name: "Hi", color: "Blue"}]
    product = Product.first
    Product.searchkick_index.remove(product)
    Searchkick.callbacks(false) { product.update!(name: "Bye", color: "Red") }

    perform_enqueued_jobs do
      Product.where(id: product.id).reindex(:search_name, mode: :async, on_missing: :full)
    end
    Product.searchkick_index.refresh

    assert_search "bye", ["Bye"], fields: [:name], load: false
    assert_search "red", ["Bye"], fields: [:color], load: false
  end

  def test_on_missing_full_mixed_batch
    store [{name: "Present", color: "Blue"}, {name: "Missing", color: "Blue"}]
    present = Product.find_by!(name: "Present")
    missing = Product.find_by!(name: "Missing")

    Product.searchkick_index.remove(missing)
    Searchkick.callbacks(false) do
      present.update!(name: "PresentUpdated", color: "Red")
      missing.update!(name: "MissingUpdated", color: "Red")
    end

    Product.where(id: [present.id, missing.id]).reindex(:search_name, on_missing: :full)
    Product.searchkick_index.refresh

    assert_search "presentupdated", ["PresentUpdated"], fields: [:name], load: false
    assert_search "missingupdated", ["MissingUpdated"], fields: [:name], load: false

    assert_search "blue", ["PresentUpdated"], fields: [:color], load: false

    assert_search "red", ["MissingUpdated"], fields: [:color], load: false
  end

  def test_on_missing_full_mixed_with_other_error
    store [
      {name: "Present", color: "Blue"},
      {name: "Missing", color: "Blue"},
      {name: "Error",   color: "Blue"}
    ]
    present_product = Product.find_by!(name: "Present")
    missing_product = Product.find_by!(name: "Missing")
    error_product = Product.find_by!(name: "Error")

    Product.searchkick_index.remove(missing_product)

    Searchkick.callbacks(false) do
      present_product.update!(name: "PresentUpdated", color: "Red")
      missing_product.update!(name: "MissingUpdated", color: "Red")
      error_product.update!(name: "ErrorUpdated", color: "Red")
    end

    # ES will reject with mapper_parsing_exception
    Product.class_eval do
      alias_method :__orig_search_name, :search_name
      define_method(:search_name) do
        self.name == "ErrorUpdated" ? {name: {nested: "x"}} : __orig_search_name
      end
    end

    error = assert_raises(Searchkick::ImportError) do
      Product.where(id: [present_product.id, missing_product.id, error_product.id])
        .reindex(:search_name, on_missing: :full)
    end

    refute_match "document_missing", error.message
    assert_match(/mapper|parsing|illegal/i, error.message)

    Product.searchkick_index.refresh

    assert_search "missingupdated", ["MissingUpdated"], fields: [:name], load: false
    assert_search "red",            ["MissingUpdated"], fields: [:color], load: false
  ensure
    Product.class_eval do
      alias_method :search_name, :__orig_search_name
      remove_method :__orig_search_name
    end
  end

  def test_on_missing_full_mixed_with_retry_error
    store [
      {name: "Present", color: "Blue"},
      {name: "Missing", color: "Blue"},
      {name: "Error",   color: "Blue"}
    ]
    present_product = Product.find_by!(name: "Present")
    missing_product = Product.find_by!(name: "Missing")
    error_product = Product.find_by!(name: "Error")

    Product.searchkick_index.remove(missing_product)

    Searchkick.callbacks(false) do
      present_product.update!(name: "PresentUpdated", color: "Red")
      missing_product.update!(name: "MissingUpdated", color: "Red")
      error_product.update!(name: "ErrorUpdated", color: "Red")
    end

    Product.class_eval do
      alias_method :__orig_search_name, :search_name
      alias_method :__orig_search_data, :search_data

      define_method(:search_name) do
        name == "ErrorUpdated" ? {name: {nested: "x"}} : __orig_search_name
      end

      define_method(:search_data) do
        name == "MissingUpdated" ? __orig_search_data.merge(name: {nested: "x"}) : __orig_search_data
      end
    end

    error = assert_raises(Searchkick::ImportError) do
      Product.where(id: [present_product.id, missing_product.id, error_product.id])
        .reindex(:search_name, on_missing: :full)
    end

    assert_match "full reindex retry failed", error.message
    assert_match error_product.id.to_s, error.message
    assert_match missing_product.id.to_s, error.message
  ensure
    Product.class_eval do
      alias_method :search_name, :__orig_search_name
      alias_method :search_data, :__orig_search_data
      remove_method :__orig_search_name
      remove_method :__orig_search_data
    end
  end

  def test_on_missing_invalid_value
    product = Product.create!(name: "Hi")
    error = assert_raises(ArgumentError) do
      product.reindex(:search_name, on_missing: :ful)
    end
    assert_match "on_missing", error.message
    assert_match ":raise", error.message
  end

  def test_on_missing_and_ignore_missing_conflict
    product = Product.create!(name: "Hi")
    assert_raises(ArgumentError) do
      product.reindex(:search_name, on_missing: :ignore, ignore_missing: true)
    end
  end

  def test_on_missing_and_ignore_missing_false_conflict
    product = Product.create!(name: "Hi")
    assert_raises(ArgumentError) do
      product.reindex(:search_name, on_missing: :raise, ignore_missing: false)
    end
  end

  def test_relation_missing_queue
    sarah = Contact.create!(name: "Sarah", email: "sarah@example.com")
    Contact.create!(name: "Susan", email: "susan@example.com")
    Contact.searchkick_index.remove(sarah)

    Contact.reindex(:search_name, mode: :queue, on_missing: :raise)

    error = assert_raises(Searchkick::ImportError) do
      Searchkick::ProcessQueueJob.perform_now(class_name: "Contact", inline: true)
    end
    assert_match "document missing", error.message
  end

  def test_relation_ignore_missing_queue
    sarah = Contact.create!(name: "Sarah", email: "sarah@example.com")
    Contact.create!(name: "Susan", email: "susan@example.com")
    Contact.searchkick_index.remove(sarah)


    Contact.reindex(:search_name, mode: :queue, on_missing: :ignore)

    perform_enqueued_jobs do
      Searchkick::ProcessQueueJob.perform_now(class_name: "Contact", inline: true)
    end
  end

  def test_queue_groups_by_method_name_ignore_missing
    Contact.searchkick_index.reindex_queue.clear

    contact_1 = Contact.create!(name: "Hi-1", email: "hi-1@example.com")
    contact_2 = Contact.create!(name: "Hi-2", email: "hi-2@example.com")
    contact_3 = Contact.create!(name: "Hi-3", email: "hi-3@example.com")
    [contact_1, contact_2, contact_3].each(&:reindex)
    Contact.searchkick_index.refresh

    Contact.searchkick_index.remove(contact_2)
    Contact.searchkick_index.refresh

    Searchkick.callbacks(false) do
      contact_1.update!(name: "Bye-1", email: "bye-1@example.com")
      contact_2.update!(name: "Bye-2", email: "bye-2@example.com")
      contact_3.update!(name: "Bye-3", email: "bye-3@example.com")
    end

    contact_1.reindex(:search_name,  mode: :queue)
    contact_1.reindex(:search_email, mode: :queue)
    contact_2.reindex(:search_name,  mode: :queue, on_missing: :ignore)
    contact_3.reindex(mode: :queue)

    perform_enqueued_jobs do
      Searchkick::ProcessQueueJob.perform_now(class_name: "Contact")
    end
    Contact.searchkick_index.refresh

    doc_1 = Contact.searchkick_index.retrieve(contact_1)
    assert_equal "Bye-1",             doc_1["name"]
    assert_equal "bye-1@example.com", doc_1["email"]

    doc_3 = Contact.searchkick_index.retrieve(contact_3)
    assert_equal "Bye-3",             doc_3["name"]
    assert_equal "bye-3@example.com", doc_3["email"]

    missing = Contact.search("*", where: {id: contact_2.id}, load: false).hits
    assert_equal 0, missing.length
  end

  def test_queue_legacy_pipe_format_still_processes
    Contact.searchkick_index.reindex_queue.clear

    contact = Contact.create!(name: "Hi", email: "hi@example.com")
    contact.reindex
    Contact.searchkick_index.refresh

    Searchkick.callbacks(false) do
      contact.update!(name: "Bye", email: "bye@example.com")
    end

    # Simulate a queue entry from an older Searchkick version, no method name or on_missing, just "id|routing"
    Contact.searchkick_index.reindex_queue.push(contact.id.to_s)

    perform_enqueued_jobs do
      Searchkick::ProcessQueueJob.perform_now(class_name: "Contact")
    end
    Contact.searchkick_index.refresh

    doc = Contact.searchkick_index.retrieve(contact)
    assert_equal "Bye",             doc["name"]
    assert_equal "bye@example.com", doc["email"]
  end

  def test_queue_legacy_pipe_format_with_routing
    Store.searchkick_index.reindex_queue.clear

    store = Searchkick.callbacks(false) { Store.create!(name: "Store A") }

    # Simulate a pre-sentinel entry as written by the old code: "id|routing"
    Store.searchkick_index.reindex_queue.push("#{store.id}|Store A")

    perform_enqueued_jobs do
      Searchkick::ProcessQueueJob.perform_now(class_name: "Store")
    end
    Store.searchkick_index.refresh

    assert_search "*", ["Store A"], {routing: "Store A"}, Store
  end

  def test_queue_entry_with_json_prefixed_id_is_treated_as_legacy
    # Regression: an entry whose body happens to be a valid JSON scalar
    # (e.g. an id of "json:42" left over from an older client) must be parsed
    # as a legacy id, not crash on transform_keys.
    Contact.searchkick_index.reindex_queue.clear

    Contact.searchkick_index.reindex_queue.push("json:42")

    # legacy id => bulk_delete of a non-existent doc; no raise
    Searchkick::ProcessQueueJob.perform_now(class_name: "Contact", inline: true)
  end

  def test_queue_parse_handles_malformed_json_sentinel_entry
    # rescue JSON::ParserError path: sentinel-prefixed entry with invalid JSON
    # falls back to legacy parsing instead of raising.
    result = Searchkick::ReindexQueue.parse("\x01\x01{not valid json")

    assert_equal "\x01\x01{not valid json", result[:id]
    assert_nil result[:routing]
  end

  def test_queue_parse_handles_non_hash_json_sentinel_entry
    # is_a?(Hash) guard: sentinel-prefixed entry whose JSON parses to a
    # non-Hash value (Integer, Array, etc.) falls back to legacy parsing
    # instead of NoMethodError on transform_keys.
    result = Searchkick::ReindexQueue.parse("\x01\x0142")

    assert_equal "\x01\x0142", result[:id]
    assert_nil result[:routing]
  end

  def test_queue_one_group_failure_does_not_drop_other_groups
    # Regression: items are RPOPed off Redis before processing, so if an
    # earlier option-group raises, later groups in the same batch must
    # still run — otherwise their items are permanently lost.
    Contact.searchkick_index.reindex_queue.clear

    # contact_1: removed from index; partial reindex with on_missing :raise
    # will trigger a document_missing_exception → ImportError
    contact_1 = Contact.create!(name: "Failing", email: "failing@example.com")
    contact_1.reindex
    Contact.searchkick_index.refresh
    Contact.searchkick_index.remove(contact_1)
    Contact.searchkick_index.refresh

    # contact_2: not yet indexed; will be indexed by the queue's full-reindex group
    contact_2 = Searchkick.callbacks(false) do
      Contact.create!(name: "Succeeding", email: "succeeding@example.com")
    end

    # Push the failing entry first so its group iterates first in group_by
    contact_1.reindex(:search_name, mode: :queue, on_missing: :raise)
    Contact.searchkick_index.reindex_queue.push(contact_2.id.to_s)

    assert_raises(Searchkick::ImportError) do
      Searchkick::ProcessQueueJob.perform_now(class_name: "Contact", inline: true)
    end
    Contact.searchkick_index.refresh

    # contact_2 must have been indexed despite contact_1's group raising first
    doc = Contact.searchkick_index.retrieve(contact_2)
    assert_equal "Succeeding", doc["name"]
  end

  def test_on_missing_full_uses_full_reindex_method_name_inline
    store [{name: "Hi", color: "Blue"}]
    product = Product.first
    Product.searchkick_index.remove(product)
    Searchkick.callbacks(false) { product.update!(name: "Bye", color: "Red") }

    product.reindex(:search_name, on_missing: :full, full_reindex_method_name: :alt_search_data, refresh: true)

    # name comes from alt_search_data (which delegates to search_data), color is overridden to marker
    assert_search "bye", ["Bye"], fields: [:name], load: false
    assert_search "altreindexmarker", ["Bye"], fields: [:color], load: false
  end

  def test_on_missing_full_uses_full_reindex_method_name_async
    store [{name: "Hi", color: "Blue"}]
    product = Product.first
    Product.searchkick_index.remove(product)
    Searchkick.callbacks(false) { product.update!(name: "Bye", color: "Red") }

    perform_enqueued_jobs do
      product.reindex(:search_name, mode: :async, on_missing: :full, full_reindex_method_name: :alt_search_data)
    end
    Product.searchkick_index.refresh

    assert_search "bye", ["Bye"], fields: [:name], load: false
    assert_search "altreindexmarker", ["Bye"], fields: [:color], load: false
  end

  def test_on_missing_full_uses_full_reindex_method_name_queue
    store [{name: "Hi", color: "Blue"}]
    product = Product.first
    Product.searchkick_index.remove(product)
    Searchkick.callbacks(false) { product.update!(name: "Bye", color: "Red") }

    product.reindex(:search_name, mode: :queue, on_missing: :full, full_reindex_method_name: :alt_search_data)

    perform_enqueued_jobs do
      Searchkick::ProcessQueueJob.perform_now(class_name: "Product")
    end
    
    Product.searchkick_index.refresh

    assert_search "bye", ["Bye"], fields: [:name], load: false
    assert_search "altreindexmarker", ["Bye"], fields: [:color], load: false
  end

  def test_partial_reindex_ignores_full_reindex_method_name
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Searchkick.callbacks(false) do
      product.update!(name: "Bye", color: "Red")
    end

    # explicit partial method wins; full_reindex_method_name is ignored for present docs
    product.reindex(:search_name, full_reindex_method_name: :alt_search_data, refresh: true)

    assert_search "bye", ["Bye"], fields: [:name], load: false
    # color is unchanged from the original indexed value
    assert_search "blue", ["Bye"], fields: [:color], load: false
  end
end
