# mtsc
MTree SCanner

MTree clone implemented in Perl designed primarily for working with docker images.

## Installing on SUSE Linux
Install dependencies:
  * sudo zypper in perl-Digest-MD5 perl-XML-Bare perl-JSON-XS perl-File-Slurp perl-File-Temp perl-App-cpanminus
  * sudo cpanm Archive::Tar IO::Zlib
  
Download the script and an alias for it:
  * mkdir ~/github
  * cd ~/github
  * git clone git@github.com:nanoscopic/mtsc.git
  * alias mtsc="~/github/mtsc/mtsc.pl"
  
## Use Cases
* Comparing two docker images to see exact file differences
* Diffing the contents of two directory structures
* Viewing contents of a docker image without mounting it or using docker itself
* Generating a standalone index of the contents of a docker image
* Determining the resultant layer composition of a directory within a docker image
* Extracting a specific pathed file from a layered docker image

## Usage
mtsc [command] [command parameters]

## Commands
### scandir > report.mts
Scans a filesystem directory and generates an XML report of its contents.
    
### scantar sometar.tar > report.mts
Scans a tar file and generates a report from that.
tgz/tar.gz files can be read as well, as long as perl IO::Zlib is installed

### scanimage [optional directory to scan] > report.mts
Scans a docker image that has been extraced into a folder, and generates
an XML report of the contents of the image.
Standard .tar.xz docker images will need to be extracted manuall to get a report on them.

### compare report1 report2
Compares two already generated reports and displays what has changed.
    
### showfile report1 [path in image of file to show]
Given a report generated via 'scanimage':
Dumps the contentsof the specified file from the specified image to stdout
    
### diff report1 report2 [path of file]
Given two reports generated via 'scanimage':
Do a diff of the given file within two different docker images

### ls report1 [path]
List the files in a specific directory within a image, via the report
    
### ll report1 [path]
Print file details ( essentially ls -l ) of files within an image, via the report
