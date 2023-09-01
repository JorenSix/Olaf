class OlafResultLine
    attr_reader :valid, :empty_match
    attr_accessor :index, :total, :query, :query_offset, :match_count,:query_start,:query_stop,:ref_path,:ref_id,:ref_start,:ref_stop
    
    def initialize(line)
        data = line.split(",").map(&:strip)

        @valid = (data.size == 11 and data[3] =~/\d+/)
        if(@valid)
            @index = data[0].to_i
            @total = data[1].to_i
            @query = data[2]
            @query_offset = data[3].to_f
            @match_count = data[4].to_i
            @query_start = data[5].to_f
            @query_stop = data[6].to_f
            @ref_path = data[7]
            @ref_id = data[8]
            @ref_start = data[9].to_f
            @ref_stop = data[10].to_f
        end
        @empty_match = @match_count == 0 
    end

    def to_s
        "#{index} , #{total} , #{query} , #{query_offset} , #{match_count} , #{query_start} , #{query_stop} , #{ref_path} , #{ref_id} , #{ref_start} , #{ref_stop}"
    end    
end
