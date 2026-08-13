require "faraday"

module Searchkick
  class Middleware < Faraday::Middleware
    def call(env)
      # the cluster this client was built for; nil for the default
      cluster = options[:cluster]
      path = env[:url].path.to_s
      if path.end_with?("/_search")
        env[:request][:timeout] = Searchkick.search_timeout(cluster)
      elsif path.end_with?("/_msearch")
        # assume no concurrent searches for timeout for now
        searches = env[:request_body].count("\n") / 2
        # do not allow timeout to exceed Searchkick.timeout
        timeout = [Searchkick.search_timeout(cluster) * searches, Searchkick.timeout(cluster)].min
        env[:request][:timeout] = timeout
      end
      @app.call(env)
    end
  end
end
