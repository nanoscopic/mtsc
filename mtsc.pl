#!/usr/bin/perl -w

# Copyright (C) 2018 SUSE
# Apache License 2.0 - See LICENSE file

use strict;
use Digest::MD5;
use XML::Bare qw/forcearray/;
use Fcntl ':mode';
use Data::Dumper;
use JSON::XS;
use File::Slurp;
use Archive::Tar;
# Reccomend IO::Zlib
use Cwd qw/realpath/;
use File::Temp qw/tempfile/;

go();

sub showhelp {
    print <<DONE;
Usage: mtsc [command] [command parameters]
Commands:
    scandir > report.mts
        Scans a filesystem directory and generates an XML report of its contents.
    scantar sometar.tar > report.mts
        Scans a tar file and generates a report from that.
        tgz/tar.gz files can be read as well, as long as perl IO::Zlib is installed
    scanimage [optional directory to scan] > report.mts
        Scans a docker image that has been extraced into a folder, and generates
        an XML report of the contents of the image.
        Standard .tar.xz docker images will need to be extracted manuall to get a report on them.
    compare report1 report2
        Compares two already generated reports and displays what has changed.
    showfile report1 [path in image of file to show]
        Given a report generated via 'scanimage':
        Dumps the contentsof the specified file from the specified image to stdout
    diff report1 report2 [path of file]
        Given two reports generated via 'scanimage':
        Do a diff of the given file within two different docker images
    ls report1 [path]
        List the files in a specific directory within a image, via the report
    ll report1 [path]
        Print file details ( essentially ls -l ) of files within an image, via the report
DONE
    exit;
}

sub valid_cmd {
    my $cmd = shift;
    my %valid_cmds = (
        scandir   => 1,
        scantar   => 1,
        scanimage => 1,
        compare   => 1,
        showfile  => 1,
        diff      => 1,
        ls        => 1,
        ll        => 1
        );
    return $valid_cmds{$cmd} ? 1 : 0;
}

sub go {
    my $argc = scalar @ARGV;
    showhelp() if( !$argc );
    
    my $cmd = $ARGV[0];
    if( !valid_cmd( $cmd ) ) {
        print "Invalid command '$cmd'\n";
        showhelp();
    }
        
    if( $cmd eq 'compare' ) {
        my $r1 = $ARGV[1];
        my $r2 = $ARGV[2];
        $r1 .= ".mtp" if( $r1 !~ m/\./ );
        $r2 .= ".mtp" if( $r2 !~ m/\./ );
        my $rep1xml = read_file( $r1 );
        my $rep2xml = read_file( $r2 );
        my $rep1 = xml_to_report( $rep1xml );
        my $rep2 = xml_to_report( $rep2xml );
        compare_reports( $rep1, $rep2 );
    }
    
    if( $cmd eq 'scanimage' ) {
        #my $layers = find_layers( ".", [] );
        my $r1 = $ARGV[1];
        my $layers = get_layers_via_manifest( $r1 || '' );
        my $rootreport;
        my $report_layers = [];
        for my $layer ( @$layers ) {
            my $tar = $layer->{'tar'};
            print STDERR "Processing $tar\n";
            my $layer_num = $layer->{'num'};
            my $report = tar_to_dir_report( $tar, $layer_num );
            #print Dumper( $report );
            print STDERR "  File count: ".$report->{'filecnt'}."\n";
            push( @$report_layers, {
                num => $layer_num,
                tar => $tar
            } );
            if( !$rootreport ) {
                $rootreport = $report;
                next;
            }
            merge_reports( $rootreport, $report ); 
        }
        $rootreport->{'layers'} = $report_layers;
                
        $rootreport->{'extracted_image_path'} = realpath('.');
        #print Dumper( $rootreport );
        my $xmltext = report_to_xml( $rootreport );
        print "$xmltext\n";
    }
    
    if( $cmd eq 'scantar' ) {
        my $r1 = $ARGV[1];
        if( $r1 =~ m/\.tar$/ ) {
            my $report = tar_to_dir_report( $r1 );
            my $xmltext = report_to_xml( $report );
            print "$xmltext\n";
        }
        else {
            print "Tar file should end in '.tar'";
        }
    }
    
    if( $cmd eq 'scandir' ) {
        my $report = create_dir_report( '.' );
        #print Dumper( $report );
        my $xmltext = report_to_xml( $report );
        print "$xmltext\n";
        #my $jsontext = dir_report_to_json( $report );
        #print "$jsontext\n";
        #print Dumper( xml_to_report( $xmltext ) );
    }
    
    if( $cmd eq 'showfile' ) {
        my $r1 = $ARGV[1];
        $r1 .= ".mtp" if( $r1 !~ m/\./ );
        my $file = $ARGV[2];
        my $xmltext = read_file( $r1 );
        my $report = xml_to_report( $xmltext );
        
        my $contents = get_file_from_report( $report, $file );
        print $contents;
    }
    
    if( $cmd eq 'diff' ) {
        my $r1 = $ARGV[1];
        my $r2 = $ARGV[2];
        $r1 .= ".mtp" if( $r1 !~ m/\./ );
        $r2 .= ".mtp" if( $r2 !~ m/\./ );
        my $file = $ARGV[3];
        
        my $xmltext1 = read_file( $r1 );
        my $report1 = xml_to_report( $xmltext1 );
        
        my $xmltext2 = read_file( $r2 );
        my $report2 = xml_to_report( $xmltext2 );
        
        my $content1 = get_file_from_report( $report1, $file );
        my $content2 = get_file_from_report( $report2, $file );
        my ($fh1,$fname1) = tempfile();
        my ($fh2,$fname2) = tempfile();
        print "Temp 1: $fname1\n";
        print "Temp 2: $fname2\n";
        print $fh1 $content1;
        print $fh2 $content2;
        close( $fh1 );
        close( $fh2 );
        #system("diff",$fname1,$fname2,"--color","--ignore-all-space");
        #system("vimdiff",$fname1,$fname2);
        system("diffuse",$fname1,$fname2);
        unlink( $fname1 );
        unlink( $fname2 );
    }
    
    if( $cmd eq 'ls' ) {
        my $r1 = $ARGV[1];
        $r1 .= ".mtp" if( $r1 !~ m/\./ );
        my $path = $ARGV[2] || '/';
        my $xmltext = read_file( $r1 );
        my $report = xml_to_report( $xmltext );
        ls( $report, $path );
    }
    
    if( $cmd eq 'll' ) {
        my $r1 = $ARGV[1];
        $r1 .= ".mtp" if( $r1 !~ m/\./ );
        my $path = $ARGV[2] || '/';
        my $xmltext = read_file( $r1 );
        my $report = xml_to_report( $xmltext );
        ll( $report, $path );
    }
}

sub ls {
    my ( $report, $path ) = @_;
    my $dirnode;
    my $isfile;
    if( $path eq '/' ) {
        $dirnode = $report;
    }
    else {
        $path =~ s|^/||;
        my @parts = split( '/', $path );
        ( $isfile, $dirnode ) = navigate_to_node( $report, \@parts );
    }
    if( $isfile ) {
      print "File exists:\n";
      print "  $path\n";
      return;
    }
    
    my $files = $dirnode->{'files'};
    print "Files:\n";
    for my $file ( sort keys %$files ) {
        print "  $file\n";
    }
    my $dirs = $dirnode->{'dirs'};
    print "Dirs:\n";
    for my $dir ( sort keys %$dirs ) {
        print "  $dir\n";
    }
}

sub ll {
    my ( $report, $path ) = @_;
    my $dirnode;
    my $isfile;
    if( $path eq '/' ) {
        $dirnode = $report;
    }
    else {
        $path =~ s|^/||;
        my @parts = split( '/', $path );
        ( $isfile, $dirnode ) = navigate_to_node( $report, \@parts );
    }
    if( $isfile ) {
      print "File:\n";
      file_detail( $dirnode->{'name'}, $dirnode );
      return;
    }
    
    my $files = $dirnode->{'files'};
    print "Files:\n";
    for my $file ( sort keys %$files ) {
        my $filenode = $files->{ $file };
        file_detail( $file, $filenode );
    }
    my $dirs = $dirnode->{'dirs'};
    print "Dirs:\n";
    for my $dir ( sort keys %$dirs ) {
        my $node = $dirs->{ $dir };
        #my $perms = $node->{'perms'};
        #my $uid = $node->{'uid'};
        #my $gid = $node->{'gid'};
        #print "  $perms\t$uid:$gid\t$dir\n";
        print "  $dir\n";
    }
}

sub file_detail {
    my ( $name, $node ) = @_;
    #print Dumper( $node );
    #my $name = $filenode->{'name'};
    my $type = $node->{'type'} || '';
    my $perms = $node->{'perms'};
    my $uid = $node->{'uid'};
    my $gid = $node->{'gid'};
    my $mtime = $node->{'mtime'};
    if( $mtime ) {
      $mtime = format_time( $mtime );
    }
    my $size = format_size( $node->{'size'} );
    if( $type eq 'link' ) {
      my $dest = $node->{'dest'};
      print "  $perms\t$uid:$gid\t$mtime\t-   \t$name -> $dest\n";
    }
    else {
      print "  $perms\t$uid:$gid\t$mtime\t$size\t$name\n";
    }
}

sub format_time {
    my $unix = shift;
    my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime($unix);
    my @mons = qw/x Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec/;
    $mon = $mons[ $mon ];
    $mday = " $mday" if( $mday < 10 );
    $hour = " $hour" if( $hour < 10 );
    $min = "0$min" if( $min < 10 );
    return "$mon $mday $hour:$min";
}

sub format_size {
    my $n = shift;
    my $ks = 1000; # 1024
    if( $n > $ks * $ks ) {
      my $m = $n / ( $ks * $ks );
      $m *= 10;
      $m = int( $m );
      $m /= 10;
      return "${m}M";
    }
    if( $n > $ks ) {
      my $k = $n / $ks;
      $k *= 10;
      $k = int( $k );
      $k /= 10;
      return "${k}K";
    }
    return $n;
}

sub get_file_from_report {
    my ( $report, $file ) = @_;
    my $image_path = $report->{'extracted_image_path'};
    #print STDERR "Image path: $image_path\n";
    $file =~ s|^\.?/||;
    my @parts = split( '/', $file );
    my $name = pop @parts;
    my ( $isfile, $dirnode ) = navigate_to_node( $report, \@parts );
    if( !$dirnode ) {
        print STDERR "Could not navigate to path ".join('/',@parts)."\n";
        return undef;
    }
    my $files = $dirnode->{'files'};
    my $filenode = $files->{ $name };
    if( !$filenode ) {
        print STDERR "Could not find file $file\n";
        return undef;
    }
    my $layer_num = $filenode->{'layer'};
    #print STDERR "Layer: $layer_num\n";
    my $layer = get_layer_from_report( $report, $layer_num );
    if( !$layer ) {
        print STDERR "Could not get layer $layer_num\n";
        return undef;
    }
    my $tar = $layer->{'tar'};
    my $tarfull;
    if( $tar =~ m|^/| ) {
      $tarfull = $tar;
    }
    else {
      $tarfull = "$image_path/$tar";
    }
    if( ! -e $tarfull ) {
        print STDERR "File does not exist: $tarfull\n";
        return undef;
    }
    #print Dumper( $layer );
    my $size = $filenode->{'size'};
    #print STDERR "Size: $size\n";
    #print STDERR "Archive: $tarfull\n";
    #print STDERR "File to fetch: $file\n";
    return get_file_contents_from_tar( $tarfull, $file );
}

sub get_file_contents_from_tar {
    my ( $tarpath, $filepath ) = @_;
    my $tar = Archive::Tar->new;
    $tar->read( $tarpath ) or die "Could not open $tarpath";
    my $file = $tar->_find_entry( $filepath );
    if( !$file ) {
        die "Could not get file $filepath from tar";
    }
    return $file->get_content;
}

sub get_layer_from_report {
    my ( $report, $num ) = @_;
    my $layers = $report->{'layers'};
    #print Dumper( $layers );
    for my $layer ( @$layers ) {
        my $anum = $layer->{'num'};
        if( $anum == $num ) {
            return $layer;
        }
    }
    return 0;
}

sub merge_reports {
    my ( $root, $add ) = @_;
    merge_dir_node( $root, $add );
    return $root;
}

sub merge_dir_node {
    my ( $root, $add ) = @_;
    my $rootfiles = $root->{'files'};
    my $addfiles = $add->{'files'};
    for my $key ( keys %$addfiles ) {
        $rootfiles->{ $key } = $addfiles->{ $key }; # just overwrite
    }
    my $rootdirs = $root->{'dirs'};
    my $add_dirs = $add->{'dirs'};
    for my $add_dir_name ( keys %$add_dirs ) {
        my $rootdir = $rootdirs->{ $add_dir_name };
        my $add_dir = $add_dirs->{ $add_dir_name };
        if( !$rootdir ) { # new; just stuff it in
            $rootdirs->{ $add_dir_name } = $add_dir;
            next;
        }
        # need to merge; exists already
        merge_dir_node( $rootdir, $add_dir );
    }
}

sub get_layers_via_manifest {
    my $path = shift;
    
    my $coder = JSON::XS->new();
    my $rawjson;
    if( $path ) {
      $rawjson = read_file( "$path/manifest.json" );
    }
    else {
      $rawjson = read_file( "manifest.json" );
    }
    my $json = $coder->decode( $rawjson );
    my $layer_files = forcearray( $json->[0]{'Layers'} );
    my @layers;
    my $layer_num = 1;
    for my $layer_file ( @$layer_files ) {
        if( $path ) {
            $layer_file = "$path/$layer_file";
        }
        my $layer = {
            tar => $layer_file,
            num => $layer_num++
        };
        if( $layer_file =~ m|(.+)/layer.tar$| ) {
            $layer->{'hash'} = $1;
        }
        push( @layers, $layer );
    }
    return \@layers;
}

# blindly find layers and return them in fetched order - not correct
sub find_layers {
    my ( $path, $res ) = @_;
    my $info = dir_entries( $path );
    my $files = $info->{'files'};
    my $dirs = $info->{'dirs'};
    for my $dir ( @$dirs ) {
        find_layers( "$path/$dir", $res );
    }
    #print Dumper( $files );
    for my $file ( @$files ) {
        next if( $file ne 'layer.tar' );
        push( @$res, "$path/layer.tar" );
    }
    return $res;
}

sub tar_to_dir_report {
    my ( $tarfile, $layer_num ) = @_;
    my $report = { files => {}, dirs => {}, filecnt => 0 };
    my $tar = Archive::Tar->new;
    $tar->read( $tarfile ) or die "Could not open $tarfile";
    my @files = $tar->get_files();
    for my $file ( @files ) {
        my $full = $file->full_path();
        $full =~ s|/$||; # strip ending slash of directories
        $full =~ s|^\./||; # strip ./ from beginnign
        my $mode = $file->mode();
        my $size = $file->size();
        my $type = $file->type();
        my $mtime = $file->mtime();
        my $texttype = tartype_to_text( $type );
        my $uid = $file->uid();
        my $gid = $file->gid();
        
        #print "$full\n";
        #print "  perms=".sprintf("\%o",$mode)."\n";
        #print "  size=$size\n";
        if( $type ne 'dir' ) {
            #print "  mtime=$mtime\n";
            $report->{'filecnt'}++;
        }
        #print "  type=$texttype\n";
        my $dest = '';
        if( $texttype eq 'link' ) {
            $dest = $file->linkname();
            #print "  dest=$dest\n";
        }
        my $node = add_entry_to_report(
            $report, 
            name => $full,
            size => $size,
            type => $texttype,
            mtime => $mtime,
            uid => $uid,
            gid => $gid,
            perms => sprintf("\%o",$mode),
            dest => $dest
        );
        if( $layer_num ) {
            $node->{'layer'} = $layer_num;
        }
        
        if( $texttype eq 'file' ) {
            my $dataref = $file->get_content_by_ref();
            my $ctx = Digest::MD5->new;
            $ctx->add( $$dataref );
            my $md5hex = $ctx->hexdigest();
            $node->{'hash'} = { md5 => $md5hex };
        }
    }
    return $report;
}

sub add_entry_to_report {
    my $report = shift;
    my %props = @_;
    my $full = $props{'name'};
    my @parts = split( '/', $full );
    my $name = pop @parts;
    my ( $isfile, $dirnode ) = navigate_to_node( $report, \@parts );
    
    my $type = $props{'type'};
    my $node;
    if( $type eq 'dir' ) {
        my $dirs = $dirnode->{'dirs'};
        if( !$dirs->{ $name } ) {
            $node = $dirs->{ $name } = {
                files => {},
                dirs => {}
            };
        }
    }
    else {
        my $files = $dirnode->{'files'};
        $node = $files->{ $name } = {
            size => $props{'size'},
            type => $type,
            mtime => $props{'mtime'},
            uid => $props{'uid'},
            gid => $props{'gid'},
            perms => $props{'perms'}
        };
        if( $type eq 'link' ) {
            $node->{'dest'} = $props{'dest'};
        }
    }
    return $node;
}

sub navigate_to_node {
    my ( $node, $path ) = @_;
    my $partCount = scalar @$path;
    my $pos = 0;
    while( @$path ) {
        $pos++;
        my $part = shift @$path;
        my $dirs = $node->{'dirs'};
        my $files = $node->{'files'};
        if( $pos eq $partCount ) {
          if( !$dirs->{ $part } && $files->{ $part } ) {
            my $node = $files->{ $part };
            $node->{'name'} = $part;
            return ( 1, $node );
          }
        }
        
        my $newnode = $dirs->{ $part };
        if( $newnode ) {
            $node = $newnode;
            next;
        }
      
        $node = $dirs->{ $part } = {
            files => {},
            dirs => {}
        };
    }
    return ( 0, $node );
}

sub tartype_to_text {
    my $type = shift;
    my %map = (
            Archive::Tar::Constant::FILE => 'file',
            Archive::Tar::Constant::SYMLINK => 'link',
            Archive::Tar::Constant::CHARDEV => 'char',
            Archive::Tar::Constant::BLOCKDEV => 'block',
            Archive::Tar::Constant::DIR => 'dir',
            Archive::Tar::Constant::FIFO => 'fifo',
            Archive::Tar::Constant::SOCKET => 'socket'
        );
    return $map{ $type } || 'unknown';
}

sub compare_reports {
    my ( $r1, $r2 ) = @_;
    compare_dirs( ".", $r1, $r2, [] );
}

sub compare_dirs {
    my ( $base, $dir1, $dir2, $diffs ) = @_;
    
    #print "Checking $base\n";
    my $files1 = $dir1->{'files'};
    my $files2 = $dir2->{'files'};
    # new and updated files
    for my $key2 ( keys %$files2 ) {
        if( !$files1->{ $key2 } ) { # new file
            print "New File $base/$key2\n";
            next;
        }
        compare_files( $base, $key2, $files1->{ $key2 }, $files2->{ $key2 }, $diffs );
    }
    # deleted files
    for my $key1 ( keys %$files1 ) {
        next if defined( $files2->{ $key1 } );
        print "Deleted File $base/$key1\n";
    }
    
    my $dirs1 = $dir1->{'dirs'};
    my $dirs2 = $dir2->{'dirs'};
    # new and updated dirs
    for my $dir2 ( keys %$dirs2 ) {
        if( !$dirs1->{ $dir2 } ) { # new file
            print "New Dir $base/$dir2\n";
            next;
        }
        compare_dirs( "$base/$dir2", $dirs1->{ $dir2 }, $dirs2->{ $dir2 }, $diffs );
    }
    # deleted dirs
    for my $dir1 ( keys %$dirs1 ) {
        next if defined( $dirs2->{ $dir1 } );
        print "Deleted Dir $base/$dir1\n";
    }
}

sub compare_files {
    my ( $base, $name, $file1, $file2, $diffs ) = @_;
    my $type1 = $file1->{'type'} || 'file';
    my $type2 = $file2->{'type'} || 'file';
    if( $type1 ne $type2 ) {
        print "File changed type from $type1 to $type2: $name\n";
        return;
    }
    if( $type1 eq 'file' ) {
        my $hash1 = $file1->{'hash'};
        my $hash2 = $file2->{'hash'};
        #if( $name =~ m/\.pl/ ) {
        #    print "File: $base/$name\n";
        #    print Dumper( $file1 );
        #    print Dumper( $file2 );
        #}
        
        my $mtime1 = $file1->{'mtime'};
        my $mtime2 = $file2->{'mtime'};
        if( $mtime1 != $mtime2 ) {
            print "File mod date changed: $base/$name\n";
        }
        
        my $size1 = $file1->{'size'};
        my $size2 = $file2->{'size'};
        if( $size1 != $size2 ) {
            print "File size changed: $base/$name $size1 -> $size2\n";
        }
        
        my $md51 = $hash1->{'md5'} || '';
        my $md52 = $hash2->{'md5'} || '';
        if( $md51 ne $md52 ) {
            print "File contents changed: $base/$name\n";
        }
    }
}

sub report_to_xml {
    my $report = shift;
    my $xmlnode = report_to_xmlnode( ".", $report );
    my $xml = XML::Bare::Object::xml( 0, $xmlnode );
    return $xml;
}

sub report_to_xmlnode {
    my ( $dirname, $report ) = @_;
    my $node = dir_report_to_xmlnode( $dirname, $report );
    
    if( $report->{'extracted_image_path'} ) {
        $node->{'extracted_image_path'} = { value => $report->{'extracted_image_path'} };
    }
    if( $report->{'layers'} ) {
        $node->{'layer'} = report_layers_to_xmlnode( $report->{'layers'} );
    }
    
    return $node;
}

sub report_layers_to_xmlnode {
    my $report_layers = shift;
    my @layers;
    for my $report_layer ( @$report_layers ) {
        my $num = $report_layer->{'num'};
        my $tar = $report_layer->{'tar'};
        push( @layers, {
            num => { value => $num, _att => 1 },
            tar => { value => $tar, _att => 1 }
        } );
    }
    return \@layers;
}

sub xmlnode_to_report_layers {
    my $layersXML = shift;
    return $layersXML;
}

sub dir_report_to_json {
    my $report = shift;
    my $jsonnode = $report;#dir_report_to_jsonnode( ".", $report );
    my $coder = JSON::XS->new->ascii->pretty;
    return $coder->encode( $jsonnode );
}

sub json_to_dir_report {
    my $json = shift;
    my $coder = JSON::XS->new;
    return $coder->decode( $json );
}

sub dir_report_to_xmlnode {
    my ( $dirname, $report ) = @_;
    my $node = { name => { value => $dirname, _att => 1 } };
    my $files = $report->{'files'};
    my $dirs = $report->{'dirs'};
    if( $files && %$files ) {
        my @filenodes;
        $node->{'file'} = \@filenodes;
        for my $file ( keys %$files ) {
            push( @filenodes, file_report_to_xmlnode( $file, $files->{ $file } ) );
        }
    }
    if( $dirs && %$dirs ) {
        my @dirnodes;
        $node->{'dir'} = \@dirnodes;
        for my $dir ( keys %$dirs ) {
            push( @dirnodes, dir_report_to_xmlnode( $dir, $dirs->{ $dir } ) );
        }
    }
    
    my @keys = qw/perms uid gid mtime/;
    for my $key ( @keys ) {
        if( defined $report->{ $key } ) {
            $node->{ $key } = { value => $report->{ $key }, _att => 1 };
        }
    }
    
    return $node;
}

sub file_report_to_xmlnode {
    my ( $file, $report ) = @_;
    my $node = { name => { value => $file, _att => 1 } };
    my @keys = qw/perms uid gid mtime size dest layer/;
    for my $key ( @keys ) {
        if( defined $report->{ $key } ) {
            $node->{ $key } = { value => $report->{ $key }, _att => 1 };
        }
    }
    my $type = $report->{'type'};
    if( $type ne 'file' ) {
        $node->{'type'} = { value => $report->{'type'}, _att => 1 };
    }
    
    my $size = $report->{'size'};
    if( $type eq 'file' && $size > 0 ) {
        my @hasharr = ();
        $node->{'hash'} = \@hasharr;
        my $hashes = $report->{'hash'};
        for my $hashtype ( keys %$hashes ) {
            push( @hasharr, {
                type => { value => $hashtype, _att => 1 },
                value => $hashes->{ $hashtype }
            } );
        }
    }
    
    return $node;
}

sub xml_to_report {
    my $xmltext = shift;
    my ( $ob, $xml ) = XML::Bare->simple( text => $xmltext );
    
    my $report = xmlnode_to_dir_report( $xml );
    
    if( $xml->{'extracted_image_path'} ) {
        $report->{'extracted_image_path'} = $xml->{'extracted_image_path'};
    }
    if( $xml->{'layer'} ) {
        $report->{'layers'} = xmlnode_to_report_layers( forcearray( $xml->{'layer'} ) );
    }
    
    return $report;
}

sub xmlnode_to_dir_report {
    my $node = shift;
    my %files;
    my %dirs;
    my $report = {
        files => \%files,
        dirs => \%dirs
    };
    my $filenodes = forcearray( $node->{'file'} );
    for my $filenode ( @$filenodes ) {
        $files{ $filenode->{'name'} } = xmlnode_to_file_report( $filenode );
    }
    my $dirnodes = forcearray( $node->{'dir'} );
    for my $dirnode ( @$dirnodes ) {
        $dirs{ $dirnode->{'name'} } = xmlnode_to_dir_report( $dirnode );
    }
    
    return $report;
}

sub xmlnode_to_file_report {
    my $node = shift;
    my $report = {};
    my @keys = qw/perms uid gid mtime size dest layer type/;
    for my $key ( @keys ) {
        if( defined $node->{ $key } ) {
            $report->{ $key } = $node->{ $key };
        }
    }
    if( !$node->{'type'} ) {
        $report->{'type'} = 'file';
    }
    return $report;
}

sub create_dir_report {
    my $base = shift;
    my $entries = dir_entries( $base );
    my $files = $entries->{'files'};
    my $dirs = $entries->{'dirs'};
    
    my %file_reports;
    my %dir_reports;
    my $report = {
        files => \%file_reports,
        dirs => \%dir_reports
    };
    for my $file ( @$files ) {
        $file_reports{ $file } = create_file_report( "$base/$file" );
    }
    for my $dir ( @$dirs ) {
        $dir_reports{ $dir } = create_dir_report( "$base/$dir" );
    }
    
    my ( $dev,$ino,$mode,$nlink,
         $uid,$gid,$rdev,$size,
         $atime,$mtime,$ctime,$blksize,
         $blocks ) = stat( $base );
    $report->{'perms'} = sprintf("\%o", S_IMODE( $mode ) ); # file permissions
    $report->{'uid'} = $uid;
    $report->{'gid'} = $gid;
    #$report->{'mtime'} = $mtime; # last modify time in seconds since the epoch
         
    return $report;
}

sub update_dir_report {
    my ( $base, $report ) = @_;
    my $entries = dir_entries( $base );
    my $files = $entries->{'files'};
    my $dirs = $entries->{'dirs'};
    
    my $file_reports = $report->{'files'};
    my $dir_reports = $report->{'dirs'};
    #my @orig_files = keys %$file_reports;
    #my @orig_dirs = keys %$dir_reports;
    my %new_file_reports;
    my %new_dir_reports;
    my $new_report = {
        files => \%new_file_reports,
        dirs => \%new_dir_reports
    };
    
    # handle modified and new files
    for my $file ( @$files ) {
        if( $file_reports->{ $file } ) { #modified
            $new_file_reports{ $file } = update_file_report( "$base/$file", $file_reports->{ $file } );
        }
        else { # new
            $new_file_reports{ $file } = create_file_report( "$base/$file" );
        }
    }
    # handle deleted files
    for my $delfile ( keys %$file_reports ) {
        next if( $new_file_reports{ $delfile } );
    }
    
    # handle modified and new directories
    for my $dir ( @$dirs ) {
        if( $dir_reports->{ $dir } ) { # modified
            $new_dir_reports{ $dir } = update_dir_report( "$base/$dir", $dir_reports->{ $dir } );
        }
        else { # new
            $new_dir_reports{ $dir } = create_dir_report( "$base/$dir" );
        }
    }
    # handle deleted directories
    for my $deldir ( keys %$dir_reports ) {
        next if( $new_dir_reports{ $deldir } );
    }
    
    return $new_report;
}

sub update_file_report {
    my ( $file, $report ) = @_;
    # check date and size
    # if those are the same skip update
    
    my ( $dev,$ino,$mode,$nlink,
         $uid,$gid,$rdev,$size,
         $atime,$mtime,$ctime,$blksize,
         $blocks ) = stat( $file );
         
    #$file =~ s|//|/|;
    my $type = S_IFMT( $mode );
    my $forcelink = 0;
    if( S_ISREG( $type ) ) { # is a regular file
        if( $report->{'size'} == $size && $report->{'mtime'} == $mtime ) {
            return;
        }
        
        my $hashes = $report->{'hash'};
        if( $size > 0 ) {
            my $newmd5 = hash_file_md5( $file );
            
            my $oldmd5 = $hashes->{'md5'} || ''; # could be empty if previously was 0 bytes
            if( $oldmd5 eq $newmd5 ) {
                return; # size or mtime differed, but hash is the same
            }
            $hashes->{'md5'} = $newmd5;
        }
        else { # size is 0
            my $oldsize = $report->{'size'};
            if( $oldsize ) {
                # file has been zeroed
                delete $hashes->{'md5'};
            }
        }
    }
    else {
        if( S_ISDIR( $type ) && ( -l $file ) ) {
            $forcelink = 1;
        }
        if( S_ISLNK( $type ) || $forcelink ) {
            $report->{'dest'} = readlink( $file );
        }
        elsif( S_ISDIR( $type ) ) {
            die "create_file_report should not be called with directories";
        }
    }
    
    $report->{'perms'} = sprintf("\%o", S_IMODE( $mode ) ); # file permissions
    my $minitype = S_IFMT( $mode ) >> 12;
    if( $minitype == 004 && $forcelink ) {
        $minitype = 012;
    }
                                         
    $report->{'type'} = texttype( $minitype );# if( $minitype != 010 );
    $report->{'uid'} = $uid;
    $report->{'gid'} = $gid;
    $report->{'mtime'} = $mtime; # last modify time in seconds since the epoch
    $report->{'size'} = $size; # size in bytes
}

sub create_file_report {
    my $file = shift;
    my %hashes;
    my $report = {
        hash => \%hashes
    };
    
    my ( $dev,$ino,$mode,$nlink,
         $uid,$gid,$rdev,$size,
         $atime,$mtime,$ctime,$blksize,
         $blocks ) = stat( $file );
    
    my $type = S_IFMT( $mode );
    my $forcelink = 0;
    if( S_ISREG( $type ) ) { # is a regular file
        if( $size > 0 ) {
            $hashes{'md5'} = hash_file_md5( $file );
        }
    }
    else {
        if( S_ISDIR( $type ) && ( -l $file ) ) {
            $forcelink = 1;
        }
        if( S_ISLNK( $type ) || $forcelink ) {
            $report->{'dest'} = readlink( $file );
        }
        elsif( S_ISDIR( $type ) ) {
            die "create_file_report should not be called with directories";
        }
    }
        
    $report->{'perms'} = sprintf("\%o", S_IMODE( $mode ) ); # file permissions
    my $minitype = $type >> 12; # file type; 6 bits ( 2 octal bytes )

    if( $minitype == 004 && $forcelink ) {
        $minitype = 012;
    }
    $report->{'type'} = texttype( $minitype );# if( $minitype != 010 );
    
    $report->{'uid'} = $uid;
    $report->{'gid'} = $gid;
    $report->{'mtime'} = $mtime; # last modify time in seconds since the epoch
    $report->{'size'} = $size; # size in bytes
               
    return $report;
}

sub texttype {
    my $minitype = shift;
    my %types = (
        001 => 'fifo',
        002 => 'char',# character device
        004 => 'dir',
        006 => 'block',# block device
        010 => 'file',
        012 => 'link',
        014 => 'socket'
    );
    return $types{ $minitype };
}

sub hash_file_md5 {
    my $file = shift;
    my $ctx = Digest::MD5->new;
    open( my $fh, "<$file" ) or return 'na';
    $ctx->addfile( $fh );
    my $md5hex = $ctx->hexdigest;
    close( $fh );
    return $md5hex;
}

sub dir_entries {
    my $dir = shift;
    my $raw_entries = raw_dir_entries( $dir );
    return split_dir_entries( $dir, $raw_entries );
}

# Find the files/dirs directly in directory and return their names
# Excluse . and ..
sub raw_dir_entries {
    my $dir = shift;
    opendir( my $dh, $dir );
    my @all_entries = readdir( $dh );
    closedir( $dh );
    my @entries;
    for my $entry ( @all_entries ) {
        next if( $entry =~ m/^\.\.?$/ ); # exclude . and ..
        push( @entries, $entry );
    }
    return \@entries;
}

# Split up directory entries into files and directories
# base = the base path the entry names are from
# entries = arrayref of filenames within the base directory
sub split_dir_entries {
    my ( $base, $entries ) = @_;
    my @files;
    my @dirs;
    my $result = {
        files => \@files,
        dirs => \@dirs
    };
    for my $entry ( @$entries ) {
        my $full = "$base/$entry";
        if( ( -d $full ) && ( ! -l $full ) ) {
            push( @dirs, $entry );
        }
        else {
            push( @files, $entry );
        }
    }
    return $result;
}