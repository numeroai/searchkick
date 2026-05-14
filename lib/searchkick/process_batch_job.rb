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
            {id: parts[0], routing: parts[1].presence}
          end
        end

      relation = Searchkick.scope(model)


      items.group_by { |i| i.except(:id, :routing) }.each do |extra_options, batched_items|
        extra_options = extra_options.dup
        extra_options[:on_missing] = extra_options[:on_missing].to_sym if extra_options[:on_missing]
        RecordIndexer.new(index).reindex_items(relation, batched_items, **extra_options)
      end

      items.group_by { |i| [i[:method_name], i[:on_missing]] }.each do |(method_name, on_missing), method_items|
        RecordIndexer.new(index).reindex_items(relation, method_items, method_name:, on_missing: on_missing.is_a?(String) ? on_missing.to_sym : on_missing)
      end
    end
  end
end
