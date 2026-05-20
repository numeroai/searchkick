require "json"
module Searchkick
  class ProcessBatchJob < Searchkick.parent_job.constantize
    queue_as { Searchkick.queue_name }

    def perform(class_name:, record_ids:, index_name: nil)
      model = Searchkick.load_model(class_name)
      index = model.searchkick_index(name: index_name)

      items =
        record_ids.map do |r|
          parsed =
            if r.start_with?("json:")
              begin
                JSON.parse(r.delete_prefix("json:")).transform_keys(&:to_sym)
              rescue JSON::ParserError
                nil
              end
            end

          if parsed
            parsed
          else
            parts = r.split(/(?<!\|)\|(?!\|)/, 2).map { |v| v.gsub("||", "|") }
            {id: parts[0], routing: parts[1]}
          end
        end

      relation = Searchkick.scope(model)

      items.group_by { |i| i.except(:id, :routing) }.each do |extra_options, batched_items|
        RecordIndexer.new(index).reindex_items(relation, batched_items, **extra_options)
      end
    end
  end
end
