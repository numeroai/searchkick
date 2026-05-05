module Searchkick
  class ProcessBatchJob < Searchkick.parent_job.constantize
    queue_as { Searchkick.queue_name }

    def perform(class_name:, record_ids:, index_name: nil)
      model = Searchkick.load_model(class_name)
      index = model.searchkick_index(name: index_name)

      items =
        record_ids.map do |r|
          if r.start_with?("json:")
            JSON.parse(r[5..-1]).transform_keys(&:to_sym)
          else
            parts = r.split(/(?<!\|)\|(?!\|)/, 2).map { |v| v.gsub("||", "|") }
            {id: parts[0], routing: parts[1].presence, method_name: nil, ignore_missing: nil}
          end
        end

      relation = Searchkick.scope(model)

      items.group_by { |i| [i[:method_name], i[:ignore_missing]] }.each do |(method_name, ignore_missing), method_items|
        RecordIndexer.new(index).reindex_items(relation, method_items, method_name:, ignore_missing:)
      end
    end
  end
end
