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

    # def perform
    #   items = @queued_items
    #   @queued_items = []

    #   return if items.empty?

    #   response = Searchkick.client.bulk(body: items)
    #   if response["errors"]
    #     # note: delete does not set error when item not found
    #     first_with_error = response["items"].map do |item|
    #       (item["index"] || item["delete"] || item["update"])
    #     end.find.with_index { |item, i| item["error"] && !ignore_missing?(items[i], item["error"]) }
    #     if first_with_error
    #       raise ImportError, "#{first_with_error["error"]} on item with id '#{first_with_error["_id"]}'"
    #     end
    #   end

    #   # maybe return response in future
    #   nil
    # end
    # 
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
          mode = items[i].instance_variable_get(:@on_missing)

          if missing && mode == :ignore
            next
          elsif missing && mode == :full
            builder = items[i].instance_variable_get(:@on_missing_full_builder)
            retry_items.concat(builder.call) if builder
            next
          end

          first_with_error ||= action
        end

        if first_with_error
          raise ImportError,
          "#{first_with_error["error"]} on item with id '#{first_with_error["_id"]}'"
        end
      end

      if retry_items.any?
        @queued_items = retry_items
        perform
      end

      nil
    end

    private

    # def ignore_missing?(item, error)
    #   error["type"] == "document_missing_exception" && item.instance_variable_defined?(:@ignore_missing)
    # end
  end
end
