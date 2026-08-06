module Searchkick
  class ProcessQueueJob < Searchkick.parent_job.constantize
    queue_as { Searchkick.queue_name }

    # cluster: pins this job to a cluster. Absent means unpinned - resolve the
    # model's configured cluster, which is the legacy behavior.
    def perform(class_name:, index_name: nil, cluster: nil, inline: false, job_options: nil)
      pinned_cluster = cluster&.to_sym
      model = Searchkick.load_model(class_name)
      index = model.searchkick_index(name: index_name, cluster: pinned_cluster)
      limit = model.searchkick_options[:batch_size] || 1000
      job_options = (model.searchkick_options[:job_options] || {}).merge(job_options || {})

      # The cluster these ids were actually reserved from - already reflects the
      # pin, since searchkick_index merges it in. Pass it down so a config change
      # between reservation and execution cannot redirect an already-reserved
      # batch, but only when pinned or non-default, so ordinary default work
      # enqueues the same payload as before and stays consumable by workers still
      # running an older searchkick.
      batch_cluster = index.cluster

      loop do
        record_ids = index.reindex_queue.reserve(limit: limit)
        if record_ids.any?
          batch_options = {
            class_name: class_name,
            record_ids: record_ids.uniq,
            index_name: index_name
          }
          batch_options[:cluster] = batch_cluster.to_s if batch_cluster

          if inline
            # use new.perform to avoid excessive logging
            Searchkick::ProcessBatchJob.new.perform(**batch_options)
          else
            Searchkick::ProcessBatchJob.set(job_options).perform_later(**batch_options)
          end

          # TODO when moving to reliable queuing, mark as complete
        end
        break unless record_ids.size == limit
      end
    end
  end
end
