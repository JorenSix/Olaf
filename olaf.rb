#!/usr/bin/env ruby

# Olaf: Overly Lightweight Acoustic Fingerprinting
# Copyright (C) 2019-2020  Joren Six

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

require 'json'
require 'fileutils'
require 'tempfile'
require 'open3'

ID_TO_AUDIO_FILENAME = File.expand_path("~/.olaf/file_list.json")
DB_FOLDER = File.expand_path("~/.olaf/db") #needs to be the same in the c code
EXECUTABLE_LOCATION = "/usr/local/bin/olaf_c"
CHECK_INCOMING_AUDIO = true
MONITOR_LENGTH_IN_SECONDS = 7
AVAILABLE_THREADS = 7 #change to e.g. your number of CPU cores -1

ALLOWED_AUDIO_FILE_EXTENSIONS = "**/*.{m4a,wav,mp4,wv,ape,ogg,mp3,flac,wma,M4A,WAV,MP4,WV,APE,OGG,MP3,FLAC,WMA}"
AUDIO_DURATION_COMMAND = "ffprobe -i \"__input__\" -show_entries format=duration -v quiet -of csv=\"p=0\""
AUDIO_CONVERT_COMMAND = "ffmpeg -hide_banner -y -loglevel panic  -i \"__input__\" -ac 1 -ar 8000 -f f32le -acodec pcm_f32le \"__output__\""
AUDIO_CONVERT_COMMAND_WITH_START_DURATION = "ffmpeg -hide_banner -y -loglevel panic -ss __start__ -i \"__input__\" -t __duration__ -ac 1 -ar 8000 -f f32le -acodec pcm_f32le \"__output__\""

#expand the argument to a list of files to process.
# a file is simply added to the list
# a text file is read and each line is interpreted as a path to a file
# for a folder each audio file within that folder (and subfolders) is added to the list
def audio_file_list(arg,files_to_process)
	arg = File.expand_path(arg)
	if File.directory?(arg)
		audio_files_in_dir = Dir.glob(File.join(arg,ALLOWED_AUDIO_FILE_EXTENSIONS))
		audio_files_in_dir.each do |audio_filename|
			files_to_process << audio_filename
		end
	elsif File.extname(arg).eql? ".txt"
		audio_files_in_txt = File.read(arg).split("\n")
		audio_files_in_txt.each do |audio_filename|
			audio_filename = File.expand_path(audio_filename)
			if File.exists?(audio_filename)
				files_to_process << audio_filename
			else
				STDERR.puts "Could not find: #{audio_filename}"
			end
		end
	elsif File.exists? arg
		files_to_process << arg
	else
		STDERR.puts "Could not find: #{arg}"
	end
	files_to_process
end


def audio_file_duration(audio_file)
	duration_command = AUDIO_DURATION_COMMAND.gsub("__input__",audio_file)
	`#{duration_command}`.to_f
end

def monitor(index,length,audio_filename,ignore_self_match, skip_size)
	audio_filename = File.expand_path(audio_filename)
	audio_filename_escaped =  escape_audio_filename(audio_filename) 

	tot_duration = audio_file_duration(audio_filename)
	start = 0
	stop = start + skip_size

	query_audio_identifer = audio_filename_to_olaf_id(audio_filename_escaped)

	while tot_duration > stop do

		with_converted_audio_part(audio_filename_escaped,start,skip_size) do |tempfile|

			stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} query \"#{tempfile.path}\" #{query_audio_identifer}")
			
			stdout.split("\n").each do |line|
				data = line.split(",")
				if(data[0] =~ /\d+/)
					matching_audio_id = data[0]

					#ignore self matches if requested (for deduplication)
					unless(ignore_self_match and query_audio_identifer.eql? matching_audio_id)
						filename = ID_TO_AUDIO_HASH[matching_audio_id]
						if(filename)
						  puts "#{index}, #{length}_#{start}s, #{File.basename audio_filename}, #{File.basename filename}, #{line}\n"
						else
						  #Report no match
						  puts "#{index}, #{length}_#{start}s, #{File.basename audio_filename}, NO_MATCH, #{line}"
						end
					end
				else 
					puts "#{index}, #{length}_#{start}s, #{File.basename audio_filename}, #{line}"
				end
			end
		end

		start = start + skip_size
		stop = start + skip_size
	end
end

def query(index,length,audio_filename,ignore_self_match)
	audio_filename_escaped =  escape_audio_filename(audio_filename)
	return unless audio_filename_escaped

	query_audio_identifer = audio_filename_to_olaf_id(audio_filename_escaped)

	with_converted_audio(audio_filename_escaped) do |tempfile|
		stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} query \"#{tempfile.path}\"")

		stdout.split("\n").each do |line|
			data = line.split(",")
			if(data[0] =~ /\d+/)
				matching_audio_id = data[0]

				#ignore self matches if requested (for deduplication)
				unless(ignore_self_match and query_audio_identifer.eql? matching_audio_id)
					filename = ID_TO_AUDIO_HASH[matching_audio_id]
					if(filename)
						puts "#{index}, #{length}, #{File.basename audio_filename}, #{File.basename filename}, #{line}\n"
					else
						 puts "#{index}, #{length}, #{File.basename audio_filename}, NO_MATCH, #{line}"
					end
				end
			else 
				puts "#{index}/#{length} #{File.basename audio_filename} #{line}"
			end
		end

		#prints optional debug or error messages
		STDERR.puts stderr unless (stderr == nil or stderr.strip.size == 0)
	end	
end

def with_converted_audio(audio_filename_escaped)
	tempfile = Tempfile.new(["olaf_audio_#{rand(20000)}", '.raw'])
	convert_command = AUDIO_CONVERT_COMMAND
	convert_command = convert_command.gsub("__input__",audio_filename_escaped)
	convert_command = convert_command.gsub("__output__",tempfile.path)
	system convert_command

	yield tempfile

	#remove the temp file afer use
	tempfile.close
	tempfile.unlink
end

def with_converted_audio_files(audio_filenames_escaped)
	tempfiles = Array.new

	audio_filenames_escaped.each do |audio_filename_escaped|
		tempfile = Tempfile.new(["olaf_audio_#{rand(200000)}", '.raw'])
		convert_command = AUDIO_CONVERT_COMMAND
		convert_command = convert_command.gsub("__input__",audio_filename_escaped)
		convert_command = convert_command.gsub("__output__",tempfile.path)
	
		system convert_command

		#puts "Transcoded #{File.basename audio_filename_escaped}"

		tempfiles << tempfile
	end

	yield tempfiles

	tempfiles.each do |tempfile|
		#remove the temp file afer use
		tempfile.close
		tempfile.unlink
	end	
end

def with_converted_audio_part(audio_filename_escaped,start,duration)
	tempfile = Tempfile.new(["olaf_audio_#{rand(20000)}", '.raw'])
	convert_command = AUDIO_CONVERT_COMMAND_WITH_START_DURATION
	convert_command = convert_command.gsub("__input__",audio_filename_escaped)
	convert_command = convert_command.gsub("__output__",tempfile.path)
	convert_command = convert_command.gsub("__start__",start.to_s)
	convert_command = convert_command.gsub("__duration__",duration.to_s)
	
	system convert_command

	yield tempfile

	#remove the temp file afer use
	tempfile.close
	tempfile.unlink
end

def audio_filename_to_olaf_id(audio_filename_escaped)
	`#{EXECUTABLE_LOCATION} name_to_id "#{audio_filename_escaped}"`.to_i.to_s
end

def escape_audio_filename(audio_filename)
	begin
		audio_filename.gsub(/(["])/, '\\\\\1')
	rescue
		puts "ERROR, probably invalid byte sequence in UTF-8 in #{audio_filename}"
		return nil
	end
end

def print(index,length,audio_filename)
	audio_filename_escaped = escape_audio_filename(audio_filename)
	return unless audio_filename_escaped
	with_converted_audio(audio_filename_escaped) do |tempfile|
	
		stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} print \"#{tempfile.path}\"")
		stdout.split("\n").each do |line|
			puts "#{index}/#{length},#{File.basename audio_filename},#{line}\n"
		end
	end
end


def store(index,length,audio_filename)

	audio_filename_escaped = escape_audio_filename(audio_filename)
	return unless audio_filename_escaped

	audio_identifer = audio_filename_to_olaf_id(audio_filename_escaped)

	#Do not store same audio twice
	if(ID_TO_AUDIO_HASH.has_key? audio_identifer)
		puts "#{index}/#{length} #{File.basename audio_filename} already in storage"
	elsif(CHECK_INCOMING_AUDIO && audio_file_duration(audio_filename) == 0)
		puts "#{index}/#{length} #{File.basename audio_filename} INVALID audio file? Duration zero."
	else
		with_converted_audio(audio_filename_escaped) do |tempfile|
			ID_TO_AUDIO_HASH[audio_identifer] = audio_filename;
			File.write(ID_TO_AUDIO_FILENAME,JSON.pretty_generate(ID_TO_AUDIO_HASH) + "\n")

			stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} store \"#{tempfile.path}\" #{audio_identifer}")

			puts "#{index}/#{length} #{File.basename audio_filename} #{stderr.strip}" 
		end
	end
end

def store_all(audio_filenames)

	audio_filenames_escaped = Array.new
	audio_identifiers = Array.new
	orig_audio_filenames = Array.new

	audio_filenames.each do |audio_filename|
		audio_filename_escaped = escape_audio_filename(audio_filename)
		next unless audio_filename_escaped

		audio_identifier = audio_filename_to_olaf_id(audio_filename_escaped)

		if ID_TO_AUDIO_HASH.has_key? audio_identifier
			puts "#{File.basename audio_filename} already in storage"
		elsif(CHECK_INCOMING_AUDIO && audio_file_duration(audio_filename) == 0)
			puts "#{File.basename audio_filename} INVALID audio file? Duration zero."
		else
			audio_filenames_escaped << audio_filename_escaped
			audio_identifiers << audio_identifier
		
			ID_TO_AUDIO_HASH[audio_identifier] = audio_filename;
		end
	end

	return unless audio_filenames_escaped.size > 0

	with_converted_audio_files(audio_filenames_escaped) do |tempfiles|

		argument = ""

		tempfiles.each_with_index do |tempfile, index|
			argument = argument + " \"#{tempfile.path}\" #{audio_identifiers[index]}" 
		end


		Open3.popen3("#{EXECUTABLE_LOCATION} store #{argument}") do |stdin, stdout, stderr, wait_thr|
			Thread.new do
    			stdout.each {|l| puts l }
  			end

  			Thread.new do
    			stderr.each {|l| puts l }
  			end

			wait_thr.value
		end
		
	end

	File.write(ID_TO_AUDIO_FILENAME,JSON.pretty_generate(ID_TO_AUDIO_HASH) + "\n")
end

def del(index,length,audio_filename)

	audio_filename_escaped = escape_audio_filename(audio_filename)
	return unless audio_filename_escaped

	audio_identifer = audio_filename_to_olaf_id(audio_filename_escaped)
			
	#Do not store same audio twice
	with_converted_audio(audio_filename_escaped) do |tempfile|
		
		ID_TO_AUDIO_HASH.delete(audio_identifer);

		File.write(ID_TO_AUDIO_FILENAME,JSON.pretty_generate(ID_TO_AUDIO_HASH) + "\n")
		stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} del \"#{tempfile.path}\" #{audio_identifer}")
		puts "#{index}/#{length} #{File.basename audio_filename} #{stderr.strip}" 
	end
end

def bulk_store(index,length,audio_filename)

	audio_filename_escaped = escape_audio_filename(audio_filename)
	return unless audio_filename_escaped

	audio_identifer = audio_filename_to_olaf_id(audio_filename_escaped)
			
	
	#Do not store same audio twice
	if(ID_TO_AUDIO_HASH.has_key? audio_identifer)
		puts "#{index}/#{length} #{File.basename audio_filename} already in storage"
	elsif(CHECK_INCOMING_AUDIO && audio_file_duration(audio_filename) == 0)
		puts "#{index}/#{length} #{File.basename audio_filename} INVALID audio file? Duration zero."
	else
		with_converted_audio(audio_filename_escaped) do |tempfile|
			ID_TO_AUDIO_HASH[audio_identifer] = audio_filename;
			
			stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} bulk_store \"#{tempfile.path}\" #{audio_identifer}")

			puts "#{index}/#{length} #{File.basename audio_filename} #{stderr.strip}" 
		end
	end
end

def bulk_load
	folder_name = DB_FOLDER

	sorted_file = File.join(folder_name,"sorted.tdb")

	system("rm '#{sorted_file}'") if(File.exists? sorted_file)

	puts "Sorting tdb files"

	system("sort -m -n #{File.join(folder_name,"*.tdb")} > '#{sorted_file}'")
	
	puts "Storing in Olaf DB"

	Open3.popen3("#{EXECUTABLE_LOCATION} bulk_load") do |stdin, stdout, stderr, wait_thr|
		Thread.new do
			stdout.each {|l| puts l }
		end

		Thread.new do
			stderr.each {|l| puts l }
		end
		wait_thr.value
	end

	Open3.popen3("#{EXECUTABLE_LOCATION} stats") do |stdin, stdout, stderr, wait_thr|
		Thread.new do
			stdout.each {|l| puts l }
		end

		Thread.new do
			stderr.each {|l| puts l }
		end
		wait_thr.value
	end
end

#create the db folder unless it exists
FileUtils.mkdir_p DB_FOLDER unless File.exist?(DB_FOLDER)

#create the id->audio file json file unless it exists
FileUtils.touch(ID_TO_AUDIO_FILENAME) unless File.exist?(ID_TO_AUDIO_FILENAME)

command  = ARGV[0]

if(command and command.eql? "stats" )
	system("#{EXECUTABLE_LOCATION} stats")
	exit(0)
end

json_content = File.read(ID_TO_AUDIO_FILENAME)
json_content = "{}" if(json_content.empty?)
ID_TO_AUDIO_HASH = JSON.parse(json_content)

ARGV.shift

audio_files = Array.new
ARGV.each do |audio_argument|
	audio_files = audio_file_list(audio_argument,audio_files)
end

return unless command 

if command.eql? "store"

	slice_number = 0
	slice_size = 50
	audio_files.each_slice(slice_size) do |audio_files_slice|
		store_all(audio_files_slice)
		slice_number = slice_number + 1
		puts "Processed #{[slice_number * slice_size,audio_files.size].min} / #{audio_files.size}"
	end

	#audio_files.each_with_index do |audio_file, index|
		#store(index+1,audio_files.length,audio_file)
	#end
elsif command.eql? "bulk_store"
	require 'threach'
	audio_files.threach(AVAILABLE_THREADS, :each_with_index) do |audio_file, index|
		bulk_store(index+1,audio_files.length,audio_file)

		if (index % 100 == 0)
			File.write(ID_TO_AUDIO_FILENAME,JSON.pretty_generate(ID_TO_AUDIO_HASH) + "\n")
		end
	end

	File.write(ID_TO_AUDIO_FILENAME,JSON.pretty_generate(ID_TO_AUDIO_HASH) + "\n")
elsif command.eql? "bulk_load"
	bulk_load
elsif command.eql? "del"
	audio_files.each_with_index do |audio_file, index|
		del(index+1,audio_files.length,audio_file)
	end
elsif command.eql? "print"
	audio_files.each_with_index do |audio_file, index|
		print(index+1,audio_files.length,audio_file)
	end
elsif command.eql? "query"
	puts "query index,total queries, query name, match name, match id, match count (#), q to ref time delta (s), ref start (s), ref stop (s), query time (s)\n"
	audio_files.each_with_index do |audio_file, index|
		query(index+1,audio_files.length,audio_file,false)
	end
elsif command.eql? "dedup"
	
	audio_files.each_with_index do |audio_file, index|
		store(index+1,audio_files.length,audio_file)
	end

	require 'threach'
	audio_files.threach(AVAILABLE_THREADS, :each_with_index) do |audio_file, index|
		query(index+1,audio_files.length,audio_file,true)
	end
elsif command.eql? "dedupm"
	
	audio_files.each_with_index do |audio_file, index|
		store(index+1,audio_files.length,audio_file)
	end

	audio_files.each_with_index do |audio_file, index|
		monitor(index+1,audio_files.length,audio_file,true,MONITOR_LENGTH_IN_SECONDS)
	end
elsif command.eql? "monitor"
	puts "query index,total queries, query name, match name, match id, match count (#), q to ref time delta (s), ref start (s), ref stop (s), query time (s)\n"
	audio_files.each_with_index do |audio_file, index|
		monitor(index + 1,audio_files.length,audio_file,false, MONITOR_LENGTH_IN_SECONDS)
	end
elsif command.eql? "clear"
	puts "Clear the db"
	system("rm ~/.olaf/*.json ~/.olaf/db/*")
end
