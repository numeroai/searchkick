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

  def test_record_ignore_missing_inline
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Product.searchkick_index.remove(product)

    product.reindex(:search_name, ignore_missing: true)
    Searchkick.callbacks(:bulk) do
      product.reindex(:search_name, ignore_missing: true)
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

  def test_record_ignore_missing_async
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Product.searchkick_index.remove(product)

    perform_enqueued_jobs do
      product.reindex(:search_name, mode: :async, ignore_missing: true)
    end
  end

  def test_record_missing_queue
    contact = Contact.create!(name: "Hi", email: "hi@example.com")
    Contact.searchkick_index.remove(contact)


    contact.reindex(:search_name, mode: :queue, ignore_missing: false)

    error = assert_raises(Searchkick::ImportError) do
      Searchkick::ProcessQueueJob.perform_now(class_name: "Contact", inline: true)
    end
    assert_match "document missing", error.message
  end

  def test_record_ignore_missing_queue
    contact = Contact.create!(name: "Hi", email: "hi@example.com")
    Contact.searchkick_index.remove(contact)


    contact.reindex(:search_name, mode: :queue, ignore_missing: true)

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

  # def test_relation_queue
  #   Product.create!(name: "Hi")
  #   error = assert_raises(Searchkick::Error) do
  #     Product.reindex(:search_name, mode: :queue)
  #   end
  #   assert_equal "Partial reindex not supported with queue option", error.message
  # end
  # 
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

  # Reindex only alice + bob via relation; carol should be untouched.
  Contact.where(id: [alice.id, bob.id]).reindex(:search_name, mode: :queue)

  perform_enqueued_jobs do
    Searchkick::ProcessQueueJob.perform_now(class_name: "Contact")
  end
  Contact.searchkick_index.refresh

  alice_doc = Contact.searchkick_index.retrieve(alice)
  bob_doc   = Contact.searchkick_index.retrieve(bob)
  carol_doc = Contact.searchkick_index.retrieve(carol)

  # In scope: name updated, email preserved
  assert_equal "Alice-new",         alice_doc["name"]
  assert_equal "alice@example.com", alice_doc["email"]
  assert_equal "Bob-new",           bob_doc["name"]
  assert_equal "bob@example.com",   bob_doc["email"]

  # Out of scope: untouched entirely
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

  def test_relation_ignore_missing_inline
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Product.searchkick_index.remove(product)

    Product.where(id: product.id).reindex(:search_name, ignore_missing: true)
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

  def test_relation_ignore_missing_async
    store [{name: "Hi", color: "Blue"}]

    product = Product.first
    Product.searchkick_index.remove(product)

    perform_enqueued_jobs do
      Product.where(id: product.id).reindex(:search_name, mode: :async, ignore_missing: true)
    end
  end

  def test_relation_missing_queue
    sarah = Contact.create!(name: "Sarah", email: "sarah@example.com")
    Contact.create!(name: "Susan", email: "susan@example.com")
    Contact.searchkick_index.remove(sarah)

    Contact.reindex(:search_name, mode: :queue, ignore_missing: false)

    error = assert_raises(Searchkick::ImportError) do
      Searchkick::ProcessQueueJob.perform_now(class_name: "Contact", inline: true)
    end
    assert_match "document missing", error.message
  end

  def test_relation_ignore_missing_queue
    sarah = Contact.create!(name: "Sarah", email: "sarah@example.com")
    Contact.create!(name: "Susan", email: "susan@example.com")
    Contact.searchkick_index.remove(sarah)


    Contact.reindex(:search_name, mode: :queue, ignore_missing: true)

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

    # contact_2's doc is missing from the index but still in the DB
    Contact.searchkick_index.remove(contact_2)
    Contact.searchkick_index.refresh

    Searchkick.callbacks(false) do
      contact_1.update!(name: "Bye-1", email: "bye-1@example.com")
      contact_2.update!(name: "Bye-2", email: "bye-2@example.com")
      contact_3.update!(name: "Bye-3", email: "bye-3@example.com")
    end

    # Three queue entries, three distinct group keys:
    #   [:search_name,  nil ]  -> contact_1
    #   [:search_email, nil ]  -> contact_1
    #   [:search_name,  true]  -> contact_2 (missing from index)
    contact_1.reindex(:search_name,  mode: :queue)
    contact_1.reindex(:search_email, mode: :queue)
    contact_2.reindex(:search_name,  mode: :queue, ignore_missing: true)
    contact_3.reindex(mode: :queue)

    perform_enqueued_jobs do
      Searchkick::ProcessQueueJob.perform_now(class_name: "Contact")
    end
    Contact.searchkick_index.refresh

    # contact_1: both :search_name and :search_email groups ran in the same drain
    doc_1 = Contact.searchkick_index.retrieve(contact_1)
    assert_equal "Bye-1",             doc_1["name"]
    assert_equal "bye-1@example.com", doc_1["email"]

    doc_3 = Contact.searchkick_index.retrieve(contact_3)
    assert_equal "Bye-3",             doc_3["name"]
    assert_equal "bye-3@example.com", doc_3["email"]

    # contact_2: ignore_missing: true suppressed the "document missing" error;
    # doc is still absent from the index (no ghost write)
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

    # Simulate a queue entry from an older Searchkick: bare pipe-delimited id,
    # no "json:" prefix, no method_name, no ignore_missing. This is the exact
    # payload that ReindexQueue used to write before the JSON switch.
    Contact.searchkick_index.reindex_queue.push(contact.id.to_s)

    perform_enqueued_jobs do
      Searchkick::ProcessQueueJob.perform_now(class_name: "Contact")
    end
    Contact.searchkick_index.refresh

    # Legacy entries parse with method_name: nil, so they fall through to a
    # FULL reindex. Both fields should reflect current DB state.
    doc = Contact.searchkick_index.retrieve(contact)
    assert_equal "Bye",             doc["name"]
    assert_equal "bye@example.com", doc["email"]
  end

  def test_queue_legacy_pipe_format_with_routing
    Store.searchkick_index.reindex_queue.clear

    store = Store.create!(name: "Store A")
    # intentionally do NOT reindex via callbacks/explicit call —
    # the legacy queue entry is the only path that will index this doc

    # Simulate a pre-JSON-format entry as written by the old code: "id|routing"
    Store.searchkick_index.reindex_queue.push("#{store.id}|Store A")

    perform_enqueued_jobs do
      Searchkick::ProcessQueueJob.perform_now(class_name: "Store")
    end
    Store.searchkick_index.refresh

    # Routing survived the legacy-format parse and was used on the Update API write:
    # the doc is findable on the "Store A" shard, and the search with routing returns it.
    assert_search "*", ["Store A"], {routing: "Store A"}, Store
  end
end
