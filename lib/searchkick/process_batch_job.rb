module Searchkick
  class ProcessBatchJob < Searchkick.parent_job.constantize
    queue_as { Searchkick.queue_name }

    def perform(class_name:, record_ids:, index_name: nil)
      model = Searchkick.load_model(class_name)
      index = model.searchkick_index(name: index_name)

      items =
        record_ids.map do |r|
          parts = r.split(/(?<!\|)\|(?!\|)/, 3)
            .map { |v| v.gsub("||", "|") }
          {id: parts[0], routing: parts[1], method_name: parts[2]}
        end

      relation = Searchkick.scope(model)


      items_by_method = items.group_by { |item| item[:method_name] }

      items_by_method.each do |method_name, method_items|
        RecordIndexer.new(index).reindex_items(relation, method_items, method_name:, ignore_missing:)
      end
    end
  end
end
