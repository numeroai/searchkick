# thread-local (technically fiber-local) indexer
# used to aggregate bulk callbacks across models
module Searchkick
  class Indexer
    attr_reader :queued_items

    def initialize
      @queued_items = []
      @queued_clients = []
    end

    def queue(items, client: Searchkick.client)
      @queued_items.concat(items)
      @queued_clients.concat(Array.new(items.size, client))
      perform unless Searchkick.callbacks_value == :bulk
    end

    def perform
      items = @queued_items
      clients = @queued_clients
      @queued_items = []
      @queued_clients = []
      return if items.empty?

      first_error = nil
      # Bulk requests are not atomic, even for a single client. Process every
      # group after draining the queue so an error does not silently drop items
      # for clients that have not been attempted yet.
      items.zip(clients).group_by { |_, client| client.object_id }.each_value do |entries|
        client = entries.first.last
        begin
          perform_items(client, entries.map(&:first))
        rescue => e
          first_error ||= e
        end
      end
      raise first_error if first_error

      nil
    end

    private

    def perform_items(client, items)
      response = client.bulk(body: items)
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

      if retry_items.any?
        # retry items are full index_data with no @on_missing_full_builder set,
        # so they cannot trigger another retry — recursion depth is bounded at 1
        retry_error = nil
        begin
          perform_items(client, retry_items)
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
