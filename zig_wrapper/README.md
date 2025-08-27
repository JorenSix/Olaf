## Olaf command line interface

This Zig wrapper is the main command line interface for Olaf. 

To Build
````
zig build -Doptimize=ReleaseSmall
zig build run -- config

zig build install-system

````

Cross compilation for Windows

````

zig build  -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall
zig build install-system
file zig-out/bin/olaf.exe # PE32+ executable (console) x86-64, for MS Windows
````

### Configuring Olaf

Olaf looks for a configuration file named `olaf_config.json` in the same directory as the executable and in the users home directory `~/.olaf/olaf_config.json`. If a configuration file is found in the home directory it takes precedence over the config file in the executable directory. If no config files is found, defaults are used.


