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
end
