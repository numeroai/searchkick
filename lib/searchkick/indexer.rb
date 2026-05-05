# thread-local (technically fiber-local) indexer
# used to aggregate bulk callbacks across models
module Searchkick
  class Indexer
    attr_reader :queued_items

    def initialize
      @queued_items = []
    end

    def queue(items)
      @queued_items.concat(items)
      perform unless Searchkick.callbacks_value == :bulk
    end

    def perform
      items = @queued_items
      @queued_items = []
      return if items.empty?

      response = Searchkick.client.bulk(body: items)
      retry_items = []
      first_with_error = nil

      if response["errors"]
        response["items"].each_with_index do |resp, i|
          action = resp["index"] || resp["delete"] || resp["update"]
          next unless action["error"]

          missing = action["error"]["type"] == "document_missing_exception"
          full_reindex_builder = items[i].instance_variable_get(:@on_missing_full_builder)
          ignore = items[i].instance_variable_get(:@on_missing_ignore)

          if missing && full_reindex_builder
            retry_items.concat(full_reindex_builder.call)
            next
          end
          next if missing && ignore

          first_with_error ||= action
        end
      end

      if retry_items.any?
        @queued_items = retry_items
        perform
      end

      if first_with_error
          raise ImportError, "#{first_with_error["error"]} on item with id '#{first_with_error["_id"]}'"
      end

      nil
    end
  end
end
