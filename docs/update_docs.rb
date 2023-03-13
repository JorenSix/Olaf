#small script to update the gh-pages branch with the newest doxygen docs

require 'tmpdir'

html_files = "docs/api/html/"

#call doxygen
system("doxygen")

Dir.mktmpdir do |d|
	system("cd '#{d}' && git clone git@github.com:JorenSix/Olaf.git")
	system("cd '#{d}/Olaf' && git checkout gh-pages")
	system("cp -r #{html_files} #{d}/Olaf")
	system("cd '#{d}/Olaf' && git add .")
	system("cd '#{d}/Olaf' && git commit -m docs")
	system("cd '#{d}/Olaf' && git push origin gh-pages")
end



