#!/usr/bin/env ruby

# Olaf: Overly Lightweight Acoustic Fingerprinting
# Copyright (C) 2019-2023  Joren Six

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.

# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# This script provides some utilities to deal with the csv output.
# Due to threading the CSV output is likely to be scrambled: lines of simultaneous
# queries are interleaved. This script is able to sort the lines.
# 
# cat result_output.csv | ruby eval/olaf_result_utils.rb sort
# 
# Also the results can be filtered for a minimum duration. Short duration results can be 
# false postitives. 
# 
# cat result_output.csv | ruby eval/olaf_result_utils.rb filter
# 
# To verify false or true positives it is of interest to listen to the 
# matches. This script selects the matching parts of the query and reference and
# stores them in a wav file for inspection. Here a random selection of 10 results are checked:
# 
# cat result_output.csv | sort --random-sort | head | ruby eval/olaf_result_utils.rb check
# 
# The utilities can be combined to filter, sort and check:
#  
# olaf query --threads 20 --fragmented music_directory > result_output.csv
# cat result_output.csv | ruby eval/olaf_result_utils.rb filter | ruby eval/olaf_result_utils.rb sort | sort --random-sort | head | ruby eval/olaf_result_utils.rb check
#
#

require_relative 'olaf_result_line.rb'

AUDIO_SELECT_COMMAND = proc{ |input, output, start, duration| %W[ffmpeg -hide_banner -y -loglevel panic  -i #{input} -ss #{start} -t #{duration} -ac 1 #{output}] }
MIN_DURATION_IN_SECONDS = 5
MIN_MATCH_SCORE = 8

def store_audio_part(in_audio_file, in_offset, duration, out_audio_file )
  select_command = AUDIO_SELECT_COMMAND[in_audio_file, out_audio_file, in_offset, duration]
  system(*select_command)
end

def result_line_to_wav(folder,duration,result_line)
  line = OlafResultLine.new(result_line)
  if line.valid
    #if the duration is nil use the match duration
    duration = (line.query_stop - line.query_start) unless duration
    
    #Find the query, first in the same folder, then in the ref folder, then in the given folder
    query = line.query
    query = File.join(File.dirname(line.ref_path),line.query) unless File.exist? query
    query = File.join(folder,line.query) unless File.exist? query

    if File.exist? query
      ref_out_name = "#{File.basename(query, File.extname(query))}_#{File.basename(line.ref_path, File.extname(line.ref_path))}.wav"
      store_audio_part(query,line.query_offset + line.query_start ,duration,ref_out_name)
    else
      STDERR.puts("Could not find query file #{query}")
    end

    if File.exist? line.ref_path
      ref_out_name = "#{File.basename(line.ref_path, File.extname(line.ref_path))}_#{File.basename(query, File.extname(query))}.wav"
      store_audio_part(line.ref_path,line.ref_start,duration,ref_out_name)
    else
      STDERR.puts("Could not find ref file #{line.ref_path}")
    end

  else
    STDERR.puts "Invalid line: '#{result_line}'"
  end
end

command = ARGV[0]

if command == "sort"

  lines = STDIN.read.split("\n")
  result_lines = Array.new
  lines.each do |line|
    result_line = OlafResultLine.new(line)
    result_lines << result_line if result_line.valid
  end
  result_lines.sort_by { |l| [l.query, l.query_offset,-l.match_count,l.query_start] }.each{|l| puts l}

elsif command == "filter"

  lines = STDIN.read.split("\n")
  result_lines = Array.new
  
  min_duration = ARGV[1] # can be nil
  min_duration = min_duration.to_f if min_duration
  min_duration = MIN_DURATION_IN_SECONDS unless min_duration

  lines.each do |line|
    result_line = OlafResultLine.new(line)
    if result_line.valid
      duration = (result_line.query_stop - result_line.query_start)
      duration_ok = duration > min_duration
      match_count_ok = result_line.match_count > MIN_MATCH_SCORE
      puts result_line if (duration_ok and match_count_ok)
    end
  end

elsif command == "check"
  duration = ARGV[1] #can be nil
  folder = ARGV[2] #can be nil
  result_lines = STDIN.read
  result_lines = result_lines.split("\n")
  result_lines.each do |result_line|
    puts result_line
    result_line_to_wav(folder,duration,result_line)
  end
end