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
require 'find'

DB_FOLDER = File.expand_path("~/.olaf/db") #needs to be the same in the c code
CACHE_FOLDER = File.expand_path("~/.olaf/cache") #needs to be the same in the c code
EXECUTABLE_LOCATION = "/usr/local/bin/olaf_c"
CHECK_INCOMING_AUDIO = true
SKIP_DUPLICATES = true
MONITOR_LENGTH_IN_SECONDS = 7
AVAILABLE_THREADS = 7 #change to e.g. your number of CPU cores -1

ALLOWED_AUDIO_FILE_EXTENSIONS = "**/*.{m4a,wav,mp4,wv,ape,ogg,mp3,flac,wma,M4A,WAV,MP4,WV,APE,OGG,MP3,FLAC,WMA}"
AUDIO_DURATION_COMMAND = "ffprobe -i \"__input__\" -show_entries format=duration -v quiet -of csv=\"p=0\""
AUDIO_CONVERT_COMMAND = "ffmpeg -hide_banner -y -loglevel panic  -i \"__input__\" -ac 1 -ar 16000 -f f32le -acodec pcm_f32le \"__output__\""
AUDIO_CONVERT_COMMAND_WITH_START_DURATION = "ffmpeg -hide_banner -y -loglevel panic -ss __start__ -i \"__input__\" -t __duration__ -ac 1 -ar 16000 -f f32le -acodec pcm_f32le \"__output__\""
MIC_INPUT = "ffmpeg -hide_banner -loglevel panic  -f avfoundation -i 'none:default' -ac 1 -ar 16000 -f f32le -acodec pcm_f32le pipe:1"

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
			if File.exist?(audio_filename)
				files_to_process << audio_filename
			else
				STDERR.puts "Could not find: #{audio_filename}"
			end
		end
	elsif File.exist? arg
		files_to_process << arg
	else
		STDERR.puts "Could not find: #{arg}"
	end
	files_to_process
end

#Folder size in MB
def folder_size(folder)
	folder = folder
	total_size = 0
	Find.find(folder) do |path|
	  if File.file?(path)
	    total_size += File.size(path)
	  end
	end
	total_size / (1024.0 * 1024.0)
end


def has(audio_file)
	result = `#{EXECUTABLE_LOCATION} has '#{audio_file}'`
	unless(result.empty?)
		result_line = result.split("\n")[1]
		result_line.split(";").size > 1
	else
		false
	end
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

	while tot_duration > stop do

		with_converted_audio_part(audio_filename_escaped,start,skip_size) do |tempfile|

			stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} query \"#{tempfile.path}\" \"#{audio_filename_escaped}\"")
			
			stdout.split("\n").each do |line|
				data = line.split(",")
				if(data[0] =~ /\d+/)
					matching_audio_id = data[0]

					#ignore self matches if requested (for deduplication)
					unless(ignore_self_match and query_audio_identifer.eql? matching_audio_id)
						puts "#{index}, #{length}_#{start}s, #{File.basename audio_filename}, #{line}\n"
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

	with_converted_audio(audio_filename_escaped) do |tempfile|
		stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} query \"#{tempfile.path}\" \"#{audio_filename_escaped}\"")

		stdout.split("\n").each do |line|
			data = line.split(",")
			if(data[0] =~ /\d+/)
				matching_audio_id = data[0]

				#ignore self matches if requested (for deduplication)
				unless(ignore_self_match and query_audio_identifer.eql? matching_audio_id)
					
					puts "#{index}, #{length}, #{File.basename audio_filename}, #{line}\n"
				
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

def to_raw(index,length,audio_filename)
	audio_filename_escaped = escape_audio_filename(audio_filename)
	return unless audio_filename_escaped
	with_converted_audio(audio_filename_escaped) do |tempfile|
		system("cp #{tempfile.path} .")
		puts "#{index}/#{length},#{File.basename audio_filename},#{File.basename tempfile}\n"
	end
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
		stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} print \"#{tempfile.path}\" \"#{audio_filename_escaped}\"")
		stdout.split("\n").each do |line|
			puts "#{index}/#{length},#{File.expand_path audio_filename},#{line}\n"
		end
	end
end

def store_cached
	cached_files = Dir.glob(File.join(CACHE_FOLDER,"*tdb"))
	length = cached_files.size
	cached_files.each_with_index  do |cache_file,index|
		audio_filename = nil
		File.open(cache_file, "r") do |f|
  			first_line =  f.gets
  			audio_filename = first_line.split(",")[1].strip
		end

		audio_filename_escaped = escape_audio_filename(audio_filename)

		if (SKIP_DUPLICATES && has(audio_filename_escaped))
			puts "#{index}/#{length} #{File.basename audio_filename} SKIP: already stored audio "
		else
			stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} store_cached \"#{cache_file}\"")
			puts "#{index}/#{length} #{File.basename audio_filename} #{stdout.strip}" 
		end
	end
end

def cache(index,length,audio_filename)
	audio_filename_escaped = escape_audio_filename(audio_filename)
	return unless audio_filename_escaped

	with_converted_audio(audio_filename_escaped) do |tempfile|
		

		audio_identifier = `olaf_c name_to_id '#{audio_filename_escaped}'`.strip
		cache_file_name = File.join(CACHE_FOLDER,"#{audio_identifier}.tdb")
		if File.exist? cache_file_name
			puts "#{index}/#{length},#{File.basename audio_filename},#{cache_file_name}, SKIPPED: already present"
		else
			stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} print \"#{tempfile.path}\" \"#{audio_filename_escaped}\"")
			data = stdout.split("\n")
			File.open(cache_file_name,"w") do |cache_file|
				data.each do |line|
					cache_file.puts "#{index}/#{length},#{File.expand_path audio_filename},#{line}\n"
				end
			end
			puts "#{index}/#{length},#{File.basename audio_filename},#{cache_file_name},#{data.size}"
		end
	end
end

def store(index,length,audio_filename)
	audio_filename_escaped = escape_audio_filename(audio_filename)
	return unless audio_filename_escaped

	#Do not store same audio twice
	if(CHECK_INCOMING_AUDIO && audio_file_duration(audio_filename) == 0)
		puts "#{index}/#{length} #{File.basename audio_filename} INVALID audio file? Duration zero."
	elsif (SKIP_DUPLICATES && has(audio_filename_escaped))
		puts "#{index}/#{length} #{File.basename audio_filename} SKIP: already stored audio "
	else
		with_converted_audio(audio_filename_escaped) do |tempfile|
			stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} store \"#{tempfile.path}\" \"#{audio_filename_escaped}\"")
			puts "#{index}/#{length} #{File.basename audio_filename} #{stderr.strip}" 
		end
	end
end

def microphone
	argument = ""
	puts "#{MIC_INPUT} | #{EXECUTABLE_LOCATION} query"
	Open3.popen3("#{MIC_INPUT} | #{EXECUTABLE_LOCATION} query") do |stdin, stdout, stderr, wait_thr|
		pid = wait_thr.pid

		Thread.new do 
			sleep(1)
			Process.kill("SIGALRM", pid)
		end

		Thread.new do
			sleep(5)
			Process.kill("SIGINFO", pid)
		end
		
		#Thread.new do
		#	stdout.each {|l| puts l }
		#end

		#Thread.new do
		#	stderr.each {|l| puts l }
		#end

		wait_thr.value
	end
end

def clear(arguments)
	force = arguments.include? "-f"
	delete_db = force
	delete_cache = force

	if !force
		puts "Proceed with deleting the olaf db (#{"%d MB" % folder_size(DB_FOLDER)} #{DB_FOLDER})? (yes/no)"
		confirmation = gets.chomp
		if confirmation == "yes"
		  delete_db = true
		else
		  puts "Nothing deleted"
		end

		puts "Proceed with deleting the olaf cache (#{"%d MB" % folder_size(CACHE_FOLDER)} #{CACHE_FOLDER})? (yes/no)"
		confirmation = gets.chomp
		if confirmation == "yes"
			delete_cache = true
		else
			puts "Operation cancelled."
		end
	end

	if(delete_db)
		puts "Clear the database folder."
		FileUtils.rm Dir.glob("#{DB_FOLDER}/*") if File.exist? DB_FOLDER
	end

	if(delete_cache)
		puts "Clear the cache folder"
		FileUtils.rm Dir.glob("#{DB_FOLDER}/*") if File.exist? DB_FOLDER
	end
end

def delete(index,length,audio_filename)

	audio_filename_escaped = escape_audio_filename(audio_filename)
	return unless audio_filename_escaped
	
	#Do not store same audio twice
	with_converted_audio(audio_filename_escaped) do |tempfile|
		stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} delete \"#{tempfile.path}\" \"#{audio_filename_escaped}\"")
		puts "#{index}/#{length} #{File.basename audio_filename} #{stderr.strip}" 
	end
end

#create the db folders unless it exist
FileUtils.mkdir_p DB_FOLDER unless File.exist?(DB_FOLDER)
FileUtils.mkdir_p CACHE_FOLDER unless File.exist?(CACHE_FOLDER)

command  = ARGV[0]

if(command and command.eql? "stats" )
	system("#{EXECUTABLE_LOCATION} stats")
	exit(0)
end

ARGV.shift

audio_files = Array.new
unless %w(mic clear store_cached ).include? command
	ARGV.each do |audio_argument|
		audio_files = audio_file_list(audio_argument,audio_files)
	end
end

return unless command 

if command.eql? "store"
	audio_files.each_with_index do |audio_file, index|
		store(index+1,audio_files.length,audio_file)
	end
elsif command.eql? "to_raw"
	audio_files.each_with_index do |audio_file, index|
		to_raw(index+1,audio_files.length,audio_file)
	end
elsif command.eql? "mic"
	microphone
elsif command.eql? "delete"
	audio_files.each_with_index do |audio_file, index|
		delete(index+1,audio_files.length,audio_file)
	end
elsif command.eql? "print"
	audio_files.each_with_index do |audio_file, index|
		print(index+1,audio_files.length,audio_file)
	end
elsif command.eql? "query"
	audio_files.each_with_index do |audio_file, index|
		query(index+1,audio_files.length,audio_file,false)
	end
elsif command.eql? "cache"
	require 'threach'
	audio_files.threach(AVAILABLE_THREADS, :each_with_index) do |audio_file, index|
		cache(index+1,audio_files.length,audio_file)
	end
elsif command.eql? "store_cached"
	store_cached
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
	clear(ARGV)
end
