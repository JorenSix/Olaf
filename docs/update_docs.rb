#small script to update the gh-pages branch with the newest doxygen docs

require 'tmpdir'

html_files = "docs/api/html/"

#Call doxygen to generate the new html docs
system("doxygen")

#In a temp dir do the following
Dir.mktmpdir do |d|
	# Clone the olaf repo in a temporary dir
	system("cd '#{d}' && git clone git@github.com:JorenSix/Olaf.git")

	# Checkout the gh-pages branch
	system("cd '#{d}/Olaf' && git checkout gh-pages")

	# Copy the new docs to the directory
	system("cp -r #{html_files} '#{d}/Olaf' ")

	# Add, commit and push to the branch
	system("cd '#{d}/Olaf' && git add .")
	system("cd '#{d}/Olaf' && git commit -m docs")
	system("cd '#{d}/Olaf' && git push origin gh-pages")
end

