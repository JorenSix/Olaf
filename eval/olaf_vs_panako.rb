# This script compares olaf runtimes with panako directly 
# the by storing items in an empty database and now and then run a query
# 
# Run the script with a (large) collection of music (e.g. the free music archive)
# 
# ruby eval/olaf_vs_panako.rb /home/user/music
# 
# - Note that this script does not check the result of the commands
# - It assumes the indexes of both systems is empty at the start
# - It assumes both panako and olaf are installed correctly on the system
# 

RANDOM_SEED = 0
ALLOWED_AUDIO_FILE_EXTENSIONS = "**/*.{m4a,wav,mp4,wv,ape,ogg,mp3,flac,wma,M4A,WAV,MP4,WV,APE,OGG,MP3,FLAC,WMA}"
OLAF_STORE_COMMAND = "olaf store '%s'"
OLAF_QUERY_COMMAND = "olaf query '%s'"
PANAKO_STORE_COMMAND = "panako STRATEGY=OLAF store '%s'"
PANAKO_QUERY_COMMAND = "panako STRATEGY=OLAF query '%s'"
NUMBER_OF_QUERIES = 5
NUMBER_OF_SECONDS_TO_INDEX = 4 * 60 * 500  #500 four minute songs
RUN_QUERY_AFTER = 4 * 60 * 20 #Every 20 four minute songs

Kernel.srand(RANDOM_SEED)

# Returns the time it takes to execute a command, in seconds
# This assumes that the /usr/bin/time utility is present.
# Modify according to your system if this is not the case.
def time_command(command)
	res = `/usr/bin/time #{command} 2>&1`
	if res =~ / (\d*\.\d*) real/
		return $1.to_f
	end
	return -1.0
end

# Returns the duration of a media file in seconds
# Assumes that ffprobe is installed!
# Install ffprobe or modify the command to return a duration of an audio file.
def file_length(file)
  duration_command = "ffprobe -i \"#{file}\" -show_entries format=duration -v quiet -of csv=\"p=0\""
  `#{duration_command}`.to_f
end


# Expands the list of audio files recursively according to an allowed list of extensions.
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

directory = ARGV[0]

unless File.directory? directory
  STDERR.puts "First argument needs to be a directory with audio files"
  exit 
end

input_files = Array.new
audio_file_list(directory,input_files)
input_files = input_files.shuffle

total_indexed_seconds = 0
total_olaf_store_time = 0
total_panako_store_time = 0

next_threshold = RUN_QUERY_AFTER

query_files = input_files[-NUMBER_OF_QUERIES..-1]

puts "index_size,olaf_store_time,panako_store_time,olaf_query_time,panako_query_time"

input_files.each_with_index do |file, index|

	total_indexed_seconds  = total_indexed_seconds + file_length(file)

	olaf_store_cmd = OLAF_STORE_COMMAND.gsub('%s',file)
	olaf_store_time = time_command(olaf_store_cmd)

	panako_store_cmd = PANAKO_STORE_COMMAND.gsub('%s',file)
	panako_store_time = time_command(panako_store_cmd)

	total_panako_store_time = total_panako_store_time + panako_store_time
	total_olaf_store_time = total_olaf_store_time + olaf_store_time



	#STDERR.puts "#{index}, #{file}, #{total_indexed_seconds.round}, #{olaf_store_time}, #{panako_store_time}"

	if (total_indexed_seconds > next_threshold or total_indexed_seconds > NUMBER_OF_SECONDS_TO_INDEX)
		olaf_query_time = 0
		panako_query_time = 0
		query_files.each do |query_file|
			olaf_query_cmd = OLAF_QUERY_COMMAND.gsub("%s",query_file)
			olaf_query_time += time_command(olaf_query_cmd)

			panako_query_cmd = PANAKO_QUERY_COMMAND.gsub("%s",query_file)
			panako_query_time += time_command(panako_query_cmd)
		end

		puts "#{total_indexed_seconds.round}, #{"%.2f" % total_olaf_store_time}, #{"%.2f" % total_panako_store_time}, #{"%.2f" % olaf_query_time}, #{"%.2f" % panako_query_time}"
		next_threshold  = next_threshold + RUN_QUERY_AFTER
		total_olaf_store_time = 0
		total_olaf_store_time = 0
	end
	if total_indexed_seconds > NUMBER_OF_SECONDS_TO_INDEX
		exit(0)
	end
end
