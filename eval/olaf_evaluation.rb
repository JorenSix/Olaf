require 'fileutils'
require 'tempfile'
require 'tmpdir'

ALLOWED_AUDIO_FILE_EXTENSIONS = "**/*.{m4a,wav,mp4,wv,ape,ogg,mp3,flac,wma,M4A,WAV,MP4,WV,APE,OGG,MP3,FLAC,WMA}"
AUDIO_FILES_TO_CHECK_FOR_TRUE_POSITIVES = 100
AUDIO_FILES_TO_CHECK_FOR_FALSE_POSITIVES = 100
AUDIO_FILES_OTHERS = 400
QUERY_LENGTHS = [10]
RANDOM_SEED = 1

#Make the test deterministic on the seed
Kernel.srand(RANDOM_SEED)

def file_length(file)
  duration_command = "ffprobe -i \"#{file}\" -show_entries format=duration -v quiet -of csv=\"p=0\""
  `#{duration_command}`.to_f
end

def seconds_to_time(seconds)
  min = seconds / 60
  seconds = seconds - min * 60
  '%02d' % min + ":" +  '%02d' % seconds
end

def cut_random_piece_to_dir(input_file,target_directory,piece_length)
  start =  rand(file_length(input_file) - piece_length) #in seconds
  basename = File.basename(input_file).gsub(/.(gsm|wav|mp3|ogg|flac)/,"")
  extname = File.extname(input_file)
  target_basename = "#{basename}_#{start}s-#{start+piece_length}s#{extname}"
  target_file = File.join(target_directory,target_basename)
  command = "sox -v 0.9 \"#{input_file}\" \"#{target_file}\" trim #{seconds_to_time(start)} #{seconds_to_time(piece_length)} 2> /dev/null"
  system(command)
  [target_basename,start]
end

#change the pitch of a file without affecting tempo
def create_pitch_shifted_file(input_file,target_file,cents)
  command = "sox \"#{input_file}\" \"#{target_file}\" pitch #{cents}"
  system(command)	
end

#factor gives the ratio of new tempo to the old tempo, so e.g. 1.1 speeds up the tempo by 10%, and 0.9 slows it down by 10%.
def change_tempo(input_file,target_file,factor)
  command = "sox \"#{input_file}\" \"#{target_file}\" tempo #{factor}"
  system(command)	
end

#Apply a flanging effect to the audio
def create_flanger_file(input_file,target_file)
  command = "sox \"#{input_file}\" \"#{target_file}\" flanger"
  system(command)	
end

def create_fm_compressed_file(input_file,target_file)
  command =  "sox \"#{input_file}\" \"#{target_file}\" gain -15 sinc  -b 29  -n 100 -8000 mcompand \
                   \"0.005,0.1 -47,-40,-34,-34,-17,-33\" 100 \
                   \"0.003,0.05 -47,-40,-34,-34,-17,-33\" 400 \
                   \"0.000625,0.0125 -47,-40,-34,-34,-15,-33\" 1600 \
                   \"0.0001,0.025 -47,-40,-34,-34,-31,-31,-0,-30\" 6400 \
                   \"0,0.025 -38,-31,-28,-28,-0,-25\" \
                   gain 15 highpass 22 highpass 22 sinc -n 255 -b 16 -17500 \
                   gain 9 lowpass -1 17801"
  system(command)
end

#Adjust the audio speed (pitch and tempo together). factor is either the ratio of 
# the new speed to the old speed: greater than 1 speeds up, less than 1 slows down
def create_sped_up_file(input_file,target_file,factor)
  command = "sox \"#{input_file}\" \"#{target_file}\" speed #{factor}"
  system(command)	
end

#Apply a band pass filter
def band_pass_filter(input_file,target_file,center)
  command = "sox \"#{input_file}\" \"#{target_file}\" band #{center}"
  system(command)
end

#Apply a corus effect filter
def chorus(input_file,target_file)
  command = "sox \"#{input_file}\" \"#{target_file}\" chorus 0.7 0.9 55 0.4 0.25 2 -t"
  system(command)	
end

#Apply an echo effect filter
def echo(input_file,target_file)
  command = "sox \"#{input_file}\" \"#{target_file}\" echo 0.8 0.9 500 0.3"
  system(command)	
end

#Apply a tremolo effect filter
def tremolo(input_file,target_file)
  command = "sox \"#{input_file}\" \"#{target_file}\" tremolo 8"
  system(command)		
end

def create_real_noise_queries(query_length,input_files,noise_files,amount)
  amount.times do
    input = input_files[rand(input_files.size)]
    noise = noise_files[rand(noise_files.size)]
    
    start = cut_random_piece(input,"tmp_query.mp3",query_length)
    cut_random_piece(noise,"tmp_noise.mp3",query_length)
  
    output_file = File.basename(input).gsub("." + File.extname(input),"") + "_real_noise_#{start}s-#{start+query_length}s.mp3"
  
    #system("sox --combine mix --volume 0.6 tmp_query.wav --volume 0.4 tmp_noise.wav \"#{output_file}\"") 
    #sox -n noise.wav synth 50.0 whitenoise gain -25  

    #apply replay gain to normalize loudness
    system("mp3gain -r tmp_query.mp3")
    system("mp3gain -r tmp_noise.mp3")
    system("sox --combine mix-power tmp_query.mp3 tmp_noise.mp3 \"#{output_file}\"")
    FileUtils.rm("tmp_query.mp3")
    FileUtils.rm("tmp_noise.mp3")
  end
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

directory = ARGV[0]

unless File.directory? directory
  STDERR.puts "First argument needs to be a directory with audio files"
  exit 
end

input_files = Array.new
audio_file_list(directory,input_files)
input_files = input_files.shuffle

audio_files_needed = AUDIO_FILES_TO_CHECK_FOR_TRUE_POSITIVES + AUDIO_FILES_TO_CHECK_FOR_TRUE_POSITIVES + AUDIO_FILES_OTHERS
puts "Total audio files available: #{input_files.size}, evaluation needs #{audio_files_needed}"

if audio_files_needed > input_files.size
  STDERR.puts "Not enough audio items in folder to run evaluation"
  exit(-10)
end

true_positives = input_files[0..(AUDIO_FILES_TO_CHECK_FOR_TRUE_POSITIVES-1)]
true_negatives = input_files[AUDIO_FILES_TO_CHECK_FOR_TRUE_POSITIVES..(AUDIO_FILES_TO_CHECK_FOR_TRUE_POSITIVES+AUDIO_FILES_TO_CHECK_FOR_FALSE_POSITIVES-1)]
other_audio_files_to_store = input_files[(AUDIO_FILES_TO_CHECK_FOR_TRUE_POSITIVES+AUDIO_FILES_TO_CHECK_FOR_TRUE_POSITIVES)..(AUDIO_FILES_TO_CHECK_FOR_TRUE_POSITIVES+AUDIO_FILES_TO_CHECK_FOR_FALSE_POSITIVES + AUDIO_FILES_OTHERS - 1)]

#Removes invalid audio or files that are too short
puts "Check audio files"
true_positives = true_positives.delete_if{|f| file_length(f) < QUERY_LENGTHS.min  }
true_negatives = true_negatives.delete_if{|f| file_length(f) < QUERY_LENGTHS.min }
other_audio_files_to_store = other_audio_files_to_store.delete_if{|f| file_length(f) < QUERY_LENGTHS.min }

puts "Clear the current database"
system("olaf clear")

#store a temporary txt file with file list
audio_file_list_content = true_positives.map{|f| File.absolute_path(f)}.join("\n")
audio_file_list_content = audio_file_list_content + "\n" + other_audio_files_to_store.map{|f| File.absolute_path(f)}.join("\n")
audio_file_list_tmp = Tempfile.new(['audio_file_list', '.txt'])
audio_file_list_tmp.write(audio_file_list_content)
audio_file_list_tmp.flush

puts "Store the reference items (true positives + distractors) from file #{audio_file_list_tmp.path}"
system("olaf store '#{audio_file_list_tmp.path}'")
audio_file_list_tmp.close
audio_file_list_tmp.unlink

class Match
  attr_accessor :result_file_name, :modification, :parameter, :score, :query_file, :ref_file_start, :time_diff, :match_expected

  def hash_key
    "#{modification}_#{parameter}"
  end

  def file_names_match?
    q_basename = File.basename(query_file)
    #check if query and result names match
    q_basename =~ /(.*)_\d+s-\d+s.*/
    result_part = $1
    result_file_name =~ /.*#{result_part}.*/
  end

  def true_positive
    (match_expected && score > 0 && file_names_match?) ? 1 : 0
  end

  def true_negative
    (!match_expected && score == 0 )? 1 : 0
  end

  def false_postitive
    (!match_expected && score > 0  ) ? 1 : 0
  end

  def false_negative
    (match_expected && score == 0 )? 1 : 0
  end

end

def print_olaf_query_result(query_file,modification,parameter,ref_file_start,matches,tp_or_tn_expected)
  lines = `olaf query #{query_file} 2>/dev/null`.split("\n")

  lines.shift #remove header
  line = lines.first

  #match count (#), q start (s) , q stop (s), ref path, ref ID, ref start (s), ref stop (s)
  #store only first match

  score,query_start,query_stop,ref_path,ref_id,ref_start,ref_stop = line.split(",")
  m = Match.new

  m.score = score.to_i
  m.result_file_name = ref_path
  m.modification = modification
  m.parameter = parameter
  m.ref_file_start = ref_start.to_f
  m.time_diff = ref_start.to_f - query_start.to_f
  m.match_expected = ("tp"==tp_or_tn_expected)
  m.query_file = query_file

  matches << m

  #print each result
  lines.each do |line|
    puts "#{line},#{modification},#{parameter},#{ref_file_start},#{("tp"==tp_or_tn_expected)}"
  end
end

hash_files = Hash.new

true_positives.each do |tp|
  hash_files[tp] = "tp"
end

true_negatives.each do |tn|
  hash_files[tn] = "tn"
end

matches = Array.new

hash_files.each do |ref_file, tn_or_tp|
  
  Dir.mktmpdir do |target_dir|

    puts "Storing query audio in #{target_dir}"

    QUERY_LENGTHS.each do |query_length|
      target_extension = File.extname(ref_file).gsub(".","")
      input_file,ref_file_start = cut_random_piece_to_dir(ref_file,target_dir,query_length)
      input_file = File.join(target_dir,input_file)

      basename = File.basename(input_file).gsub(/.(gsm|wav|mp3|ogg|flac)/,"")
      ext = $1 if input_file =~ /.*.(gsm|wav|mp3|ogg|flac)/

      #no modification only reencoding
      target_file = input_file
      print_olaf_query_result(target_file,"none","0",ref_file_start,matches,tn_or_tp)

      # #Create time stretched and sped up queries
      # (98..102).step(1).each do |i|
      #   unless i ==100
      #     factor = i/100.to_f

      #     target_file = File.join(target_dir,"#{basename}___time_stretched_#{factor}.#{target_extension}")
      #     change_tempo(input_file,target_file,factor)
      #     print_olaf_query_result(target_file,"time_stretched",factor.to_s,ref_file_start,matches,tn_or_tp)
          
      #     target_file = File.join(target_dir,"#{basename}___speed_up_#{factor}.#{target_extension}")
      #     create_sped_up_file(input_file,target_file,factor)
      #     print_olaf_query_result(target_file,"speed_up",factor.to_s,ref_file_start,matches,tn_or_tp)
      #   end
      # end

      target_file = File.join(target_dir,"#{basename}___flanger.#{target_extension}")#Create other queries
      create_flanger_file(input_file,target_file)
      print_olaf_query_result(target_file,"flanger","0",ref_file_start,matches,tn_or_tp)

      target_file = File.join(target_dir,"#{basename}___band_passed_2000Hz.#{target_extension}")
      band_pass_filter(input_file,target_file,2000)
      print_olaf_query_result(target_file,"band_passed","2000Hz",ref_file_start,matches,tn_or_tp)

      target_file = File.join(target_dir,"#{basename}___chorus.#{target_extension}")
      chorus(input_file,target_file)
      print_olaf_query_result(target_file,"chorus","0",ref_file_start,matches,tn_or_tp)

      target_file = File.join(target_dir,"#{basename}___echo.#{target_extension}")
      echo(input_file,target_file)
      print_olaf_query_result(target_file,"echo","0",ref_file_start,matches,tn_or_tp)
    end     
  end
  #now the temp directory and queries do not exist any more
end

tp = 0
tn = 0
fp = 0
fn = 0

stats_hash = Hash.new

matches.each do |match|
  unless stats_hash.has_key? match.hash_key
    stats_hash[match.hash_key] = Hash.new 
    stats_hash[match.hash_key]["tp"] = 0
    stats_hash[match.hash_key]["tn"] = 0
    stats_hash[match.hash_key]["fp"] = 0
    stats_hash[match.hash_key]["fn"] = 0
  end

  stats_hash[match.hash_key]["tp"] = stats_hash[match.hash_key]["tp"] + match.true_positive 
  stats_hash[match.hash_key]["tn"] = stats_hash[match.hash_key]["tn"] + match.true_negative 
  stats_hash[match.hash_key]["fp"] = stats_hash[match.hash_key]["fp"] + match.false_postitive
  stats_hash[match.hash_key]["fn"] = stats_hash[match.hash_key]["fn"] + match.false_negative
end

stats_hash.each do |modification,metrics|
  tpr = (metrics["tp"].to_f / (metrics["tp"].to_f + metrics["fn"].to_f))
  tnr = (metrics["tn"].to_f / (metrics["tn"].to_f + metrics["fp"].to_f))
  puts "True positive rate for #{modification} #{"%.3f" % tpr}"
  puts "True negative rate for #{modification} #{"%.3f" % tnr}"
end
