module Searchkick
  class ProcessBatchJob < Searchkick.parent_job.constantize
    queue_as { Searchkick.queue_name }

    def perform(class_name:, record_ids:, index_name: nil)
      model = Searchkick.load_model(class_name)
      index = model.searchkick_index(name: index_name)

      items = record_ids.map { |r| ReindexQueue.parse(r) }

      relation = Searchkick.scope(model)

      items.group_by { |i| i.except(:id, :routing) }.each do |extra_options, batched_items|
        RecordIndexer.new(index).reindex_items(relation, batched_items, **extra_options)
      end
    end
  end
end
