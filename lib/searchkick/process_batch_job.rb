module Searchkick
  class ProcessBatchJob < Searchkick.parent_job.constantize
    queue_as { Searchkick.queue_name }

    def perform(class_name:, record_ids:, index_name: nil)
      model = Searchkick.load_model(class_name)
      index = model.searchkick_index(name: index_name)

      items = record_ids.map { |r| ReindexQueue.parse(r) }

      relation = Searchkick.scope(model)

      # one bulk per distinct (method_name, on_missing, full_reindex_method_name)
      # combination; a queue mixing many combinations will fan out to many bulk
      # requests rather than one. process every group even if an earlier one
      # raises — items have already been RPOPed and would otherwise be lost.
      first_error = nil
      items.group_by { |i| i.except(:id, :routing) }.each do |extra_options, batched_items|
        begin
          RecordIndexer.new(index).reindex_items(relation, batched_items, **extra_options)
        rescue => e
          first_error ||= e
        end
      end
      raise first_error if first_error
    end
  end
end
