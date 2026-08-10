# thread-local (technically fiber-local) indexer
# used to aggregate bulk callbacks across models
module Searchkick
  class Indexer
    def initialize
      @queued_items = {}
    end

    # flat across clusters, for callers that want the items themselves
    def queued_items
      @queued_items.values.flatten(1)
    end

    # counted without flattening - Searchkick.callbacks asks on every bulk block
    def queued_items?
      @queued_items.any? { |_, items| items.any? }
    end

    def queued_items_count
      @queued_items.sum { |_, items| items.size }
    end

    # private - for tests
    def queued_items_by_cluster
      @queued_items
    end

    def queue(items, cluster: nil)
      # canonicalized: nil, :default and "default" are one physical cluster, so
      # they belong in one bulk request - separate buckets would cost an extra
      # round trip and could reorder operations on the same document
      (@queued_items[Searchkick.canonical_cluster(cluster)] ||= []).concat(items)
      perform unless Searchkick.callbacks_value == :bulk
    end

    def perform
      queued = @queued_items
      @queued_items = {}
      return if queued.empty?

      # one cluster is the overwhelmingly common case, and going straight to
      # perform_cluster keeps it identical to the pre-cluster behavior, including
      # which exception propagates
      if queued.size == 1
        cluster, items = queued.first
        return perform_cluster(cluster, items)
      end

      # every cluster is attempted: these items are already dequeued, so bailing
      # on the first failure would silently drop the other clusters' work
      first_error = nil
      queued.each do |cluster, items|
        begin
          perform_cluster(cluster, items)
        rescue => e
          first_error ||= e
        end
      end
      raise first_error if first_error

      nil
    end

    private

    def perform_cluster(cluster, items)
      return if items.empty?

      response = Searchkick.client(cluster).bulk(body: items)
      retry_items = []
      first_with_error = nil

      if response["errors"]
        response["items"].each_with_index do |resp_item, i|
          action = resp_item["index"] || resp_item["delete"] || resp_item["update"]
          next unless action["error"]

          missing = action["error"]["type"] == "document_missing_exception"
          full_reindex_builder = items[i].instance_variable_get(:@on_missing_full_builder)
          ignore = items[i].instance_variable_get(:@on_missing_ignore)

          if missing
            next if ignore
            if full_reindex_builder
              retry_items << full_reindex_builder.call
              next
            end
          end

          first_with_error ||= action
        end
      end

      retry_error = nil
      if retry_items.any?
        # retry items are full index_data with no @on_missing_full_builder set,
        # so they cannot trigger another retry — recursion depth is bounded at 1.
        # passed as an argument rather than through @queued_items so a concurrent
        # queue call cannot interleave with the retry
        begin
          perform_cluster(cluster, retry_items)
        rescue ImportError => retry_error
        end
        raise retry_error if retry_error && first_with_error.nil?
      end

      if first_with_error
        message = "#{first_with_error["error"]} on item with id '#{first_with_error["_id"]}'"
        message = "#{message}; additionally, full reindex retry failed: #{retry_error.message}" if retry_error
        raise ImportError, message
      end

      nil
    end
  end
end
