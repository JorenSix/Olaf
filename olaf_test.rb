require 'fileutils'

ALLOWED_AUDIO_FILE_EXTENSIONS = "**/*.{m4a,wav,mp4,wv,ape,ogg,mp3,flac,wma,M4A,WAV,MP4,WV,APE,OGG,MP3,FLAC,WMA}"


def file_length(file)
  $1.to_i if `sox "#{file}" -n stat 2>&1` =~ /.*Length .*:\s*(\d*)\..*/
end

def seconds_to_time(seconds)
  min = seconds / 60
  seconds = seconds - min * 60
  '%02d' % min + ":" +  '%02d' % seconds
end

def cut_piece(input_file,target_file,start,piece_length)
  puts input_file
  command = "sox \"#{input_file}\" \"#{target_file}\" trim #{seconds_to_time(start)} #{seconds_to_time(piece_length)}"
  puts command
  system(command)
  start
end

def cut_random_piece(input_file,target_file,piece_length)
  puts input_file
  start =  rand(file_length(input_file) - piece_length) #in seconds
  command = "sox \"#{input_file}\" \"#{target_file}\" trim #{seconds_to_time(start)} #{seconds_to_time(piece_length)}"
  puts command
  system(command)
  start
end

def cut_random_piece_to_dir(input_file,target_directory,piece_length)
  puts input_file
  start =  rand(file_length(input_file) - piece_length) #in seconds
  basename = File.basename(input_file).gsub(/.(gsm|wav|mp3|ogg|flac)/,"")
  extname = File.extname(input_file)
  target_basename = "#{basename}_#{start}s-#{start+piece_length}s#{extname}"
  target_file = File.join(target_directory,target_basename)
  command = "sox \"#{input_file}\" \"#{target_file}\" trim #{seconds_to_time(start)} #{seconds_to_time(piece_length)}"
  puts command
  system(command)
  target_basename
end

#change the pitch of a file without affecting tempo
def create_pitch_shifted_file(input_file,target_file,cents)
  command = "sox \"#{input_file}\" \"#{target_file}\" pitch #{cents}"
  puts command
  system(command)	
end

#factor gives the ratio of new tempo to the old tempo, so e.g. 1.1 speeds up the tempo by 10%, and 0.9 slows it down by 10%.
def change_tempo(input_file,target_file,factor)
  command = "sox \"#{input_file}\" \"#{target_file}\" tempo #{factor}"
  puts command
  system(command)	
end

#Apply a flanging effect to the audio
def create_flanger_file(input_file,target_file)
  command = "sox \"#{input_file}\" \"#{target_file}\" flanger"
  puts command
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
  puts command
  system(command)
end

#Adjust the audio speed (pitch and tempo together). factor is either the ratio of 
# the new speed to the old speed: greater than 1 speeds up, less than 1 slows down
def create_sped_up_file(input_file,target_file,factor)
  command = "sox \"#{input_file}\" \"#{target_file}\" speed #{factor}"
  puts command
  system(command)	
end

#Apply a band pass filter
def band_pass_filter(input_file,target_file,center)
  command = "sox \"#{input_file}\" \"#{target_file}\" band #{center}"
  puts command
  system(command)
end

#Apply a corus effect filter
def chorus(input_file,target_file)
  command = "sox \"#{input_file}\" \"#{target_file}\" chorus 0.7 0.9 55 0.4 0.25 2 -t"
  puts command
  system(command)	
end

#Apply an echo effect filter
def echo(input_file,target_file)
  command = "sox \"#{input_file}\" \"#{target_file}\" echo 0.8 0.9 500 0.3"
  puts command
  system(command)	
end

#Apply a tremolo effect filter
def tremolo(input_file,target_file)
  command = "sox \"#{input_file}\" \"#{target_file}\" tremolo 8"
  puts command
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


def create_clean_queries(query_dir,query_length,input_files,amount)
  amount.times do
    input = input_files[rand(input_files.size)]
    start = cut_random_piece(input,"tmp_query.wav",query_length)
    output_file = query_dir +'/'+ File.basename(input).gsub(".wav","") + "_clean_#{start}s-#{start+query_length}s.wav"
    FileUtils.mv("tmp_query.wav",output_file)
  end
end

def create_small_dataset(input_files,noise_files,query_length)
  small_dataset_dir = "small_dataset"
  small_queries = "small_queries"
  #copy 30 files in small dataset folder
  30.times{FileUtils.cp( input_files[rand(input_files.size)],small_dataset_dir)} unless Dir.glob(small_dataset_dir+"/*.wav").size >= 30
  #generate 10 queries
  input_files = Dir.glob(small_dataset_dir+"/*.wav")
  create_clean_queries(small_queries,query_length,input_files,10)
  create_real_noise_queries(small_queries,query_length,input_files,noise_files,10)
end

def create_queries(input_files,target_dir=".",target_extension="mp3")
  input_files.each do |input_file|
    basename = File.basename(input_file).gsub(/.(gsm|wav|mp3|ogg|flac)/,"")
    ext = $1 if input_file =~ /.*.(gsm|wav|mp3|ogg|flac)/
    (-10..10).step(2).each do |shift| 
    	unless shift==0
    		create_pitch_shifted_file(input_file,File.join(target_dir,"#{basename}___pitch_shift_#{shift}_cents.#{target_extension}"),shift)
    	end
    end
    (96..104).step(1).each do |i|
  	  unless i ==100
  	    factor = i/100.to_f
  	    change_tempo(input_file,File.join(target_dir,"#{basename}___time_stretched_#{factor}.#{target_extension}"),factor)
        create_sped_up_file(input_file,File.join(target_dir,"#{basename}___speed_up_#{factor}.#{target_extension}"),factor)
  	  end
    end
    create_flanger_file(input_file,File.join(target_dir,"#{basename}___flanger.#{target_extension}"))
    band_pass_filter(input_file,File.join(target_dir,"#{basename}___band_passed_2000Hz.#{target_extension}"),2000)
    chorus(input_file,File.join(target_dir,"#{basename}___chorus.#{target_extension}"))
    echo(input_file,File.join(target_dir,"#{basename}___echo.#{target_extension}"))
    tremolo(input_file,File.join(target_dir,"#{basename}___tremolo.#{target_extension}"))
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
  puts "First argument needs to be a directory with audio files"
  exit 
end

input_files = Array.new
audio_file_list(directory,input_files)

query_lengths = [5,10]
query_lengths.each do |query_length|
 
  target_dir = "queries_#{query_length}s"
  FileUtils.mkdir(target_dir) unless File.exists?(target_dir)

  input_files[0..6].each do |f|
    target_extension = File.extname(f).gsub(".","")
    cut_file = cut_random_piece_to_dir(f,target_dir,query_length)
    cut_file = File.join(target_dir,cut_file)
    create_queries([cut_file],target_dir,target_extension)
  end
end

