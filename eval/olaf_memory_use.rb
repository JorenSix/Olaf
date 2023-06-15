# This script returns the memory use when running a query
# To see the influence of the size of the index the memory use 
# is measured after every 10 stored files. 
# The size of the index is expressed in seconds 
# The memory use is reported in kilobytes
# 
# The script needs access to a folder with mp3 or other audio files.
# For example:
# 
# ruby eval/olaf_melory_use.rb /User/Music
# 
# The script assumes that the installed version of olaf uses the same index as 
# bin/olaf_c which is used for memory consumption.
#
# To measure memory use the macOS utility /usr/bin/time is used.
# Similar utilities are available for Linux or other systems.
# To use the script on your system check and adapt the memory_use 
# function accordingly 

# Number of files to store
number_of_files_to_store = 500
report_memory_use_every_x_files = 10

# measure yourself by compiling a c program with only a
# main function and measuring it with the same command as below
# On my mac the following oneliner works (zsh)
# echo "int main(int argc, char** argv) { return 0; }" > t.c && gcc t.c && /usr/bin/time -l  ./a.out
NUMBER_OF_BYTES_TO_RUN_EMPTY_C_PROGRAM = 950976

RANDOM_SEED = 0

ALLOWED_AUDIO_FILE_EXTENSIONS = "**/*.{m4a,wav,mp4,wv,ape,ogg,mp3,flac,wma,M4A,WAV,MP4,WV,APE,OGG,MP3,FLAC,WMA}"

Kernel.srand(RANDOM_SEED)

#returns the memory use of a command in kbytes
def memory_use(command)
	res = `/usr/bin/time -l #{command} 2>&1`
	if res =~ /.* (\d*)  peak memory footprint.*/
		memory_use_in_bytes = $1.to_i
		return ((memory_use_in_bytes - NUMBER_OF_BYTES_TO_RUN_EMPTY_C_PROGRAM)/1024.0).round
	else
		puts "Unexpected result for memory use command"
	end
	return 0
end

class OlafStats
    attr_reader :number_of_songs, :total_duration, :number_of_fingerprints

    def initialize
        res = `olaf stats`
        res =~ /.*.songs.+?:\t?(\d+).*/m
        @number_of_songs = $1.to_i
        res =~ /.*.otal.dura.+?:\t?(\d+.\d+).*/m
        @total_duration = $1.to_f
        res =~ /.*umber of items in databases.\s+(\d+)\s.*/m
        @number_of_fingerprints = $1.to_i
    end
end

if OlafStats.new.number_of_songs != 0
	STDERR.puts "Database should be empty, before running test run 'olaf clear -f'"
	exit(-10)
end

REF_TARGET_FOLDER = "dataset/ref"
#check dataset, if not available, download
ref_files = Dir.glob(File.join(REF_TARGET_FOLDER,"*mp3"))
if ref_files.length == 0
    STDERR.puts 'Test dataset not found. Downloading...'
    system("ruby eval/olaf_download_dataset.rb")
end

QUERY_TARGET_FOLDER = "dataset/queries"
QUERY_FILES = Dir.glob(File.join(QUERY_TARGET_FOLDER,"*mp3")).sort

#raw files
system("olaf to_raw #{QUERY_TARGET_FOLDER} > /dev/null" )
system("mkdir -p dataset/raw/queries > /dev/null")
system("mv olaf_audio* dataset/raw/queries > /dev/null")
QUERY_FILES_RAW = Dir.glob(File.join("dataset/raw/queries","*raw")).sort

raw_query_file = QUERY_FILES_RAW.first

system("make clean > /dev/null")
system("make > /dev/null")

directory = ARGV[0]

unless File.directory? directory
  STDERR.puts "First argument needs to be a directory with audio files"
  exit 
end


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

input_files = Array.new
audio_file_list(directory,input_files)
input_files = input_files.shuffle[0..number_of_files_to_store]

puts "Index size (s), Memory use for query (kB)"
input_files.each_with_index do |file,index|
	#store each file
    cmd = "olaf store '#{file}' > /dev/null"
    system(cmd)

    #report memory only once every x times
    if(((index+1) % report_memory_use_every_x_files == 0))
    	cmd = "bin/olaf_c query #{raw_query_file} #{raw_query_file}"
    	memory_use_in_kb = memory_use(cmd)
    	total_duration = OlafStats.new.total_duration.round
    	puts "#{total_duration},#{memory_use_in_kb}"
	end
end

