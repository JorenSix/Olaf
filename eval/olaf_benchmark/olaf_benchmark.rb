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

require 'benchmark'

PROC_THREADS = 92
QUERY_FILE_SIZE_IN = 35
QUERY_FILE_SIZE_OUT = 15

AUDIO_FILE_GLOB_PATTERN = "**/*mp3"
RND = Random.new(0)
START_SIZE = 64

folder = ARGV[0]

unless File.exist?(folder)
	STDERR.puts "Folder '#{folder}' should exist."
end

audio_files = Dir.glob(File.join(folder,AUDIO_FILE_GLOB_PATTERN))
#puts audio_files.size

times_two = (Math.log(audio_files.size)/Math.log(2)).to_i

audio_files = audio_files.shuffle(random: RND)

query_selection_in = audio_files[0..(QUERY_FILE_SIZE_IN - 1)]
query_selection_out = audio_files[(audio_files.size-QUERY_FILE_SIZE_OUT)..(audio_files.size-1)]

start_index=0
stop_index=START_SIZE

def files_to_list(files,filename)
  File.write(filename, files.join("\n") + "\n")
end

puts "songs, seconds, store_user_cpu, store_sys_cpu, store_sys_us_cpu, store_real_time, query_user_cpu, query_sys_cpu, query_user_sys_cpu, query_real_time"

while(stop_index <= (1<<times_two) ) do
  selection = audio_files[start_index..(stop_index-1)]
  #puts "Processing  #{selection.size} files  #{start_index}-#{stop_index-1}"
  

  progress_filename = "#{start_index}-#{stop_index-1}_cache_progress.txt" 
  list_filename = "#{start_index}-#{stop_index-1}_store_list.txt"
  files_to_list(selection,list_filename)

  #puts "Store #{selection.size} files\t#{PROC_THREADS} threads\t"

  store_times = Benchmark.measure{
    system "olaf cache #{list_filename} -n #{PROC_THREADS} 1> #{progress_filename} 2> stderr_#{progress_filename}"
    system "olaf store_cached > /dev/null"
  }.to_s.strip.gsub("(",'').gsub(")","")

  stats = `olaf stats`
  stats =~ /Total duration .s...(.*)/
  seconds = $1.to_f
  
  queries = query_selection_in + query_selection_out
  files_to_list(queries,"list.txt")

  query_times = Benchmark.measure{
     system "olaf query list.txt >/dev/null 2> /dev/null"
   }.to_s.strip.gsub("(",'').gsub(")","")

  line = "#{stop_index} #{seconds} #{store_times} #{query_times}"
  puts line.split(' ').join(", ")
  
  start_index = stop_index
  stop_index = start_index * 2
end
