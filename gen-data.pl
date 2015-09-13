#!perl -w
use strict;
use Imager;
use MIME::Base64 'encode_base64';

# We really need Jpeg-support
die "We really need jpeg support but your version of Imager doesn't support it"
    unless $Imager::formats{'jpeg'};

sub get_imager {
    my( $file ) = @_;
    # We should check that Imager can write jpeg images
    Imager->new( file => $file )
        or die "Couldn't read $file: " . Imager->errstr();
}

sub compress_image {
    my( $file ) = @_;
    my $imager = get_imager( $file );
    
    # Rotate if portrait, this wrecks our headers :-((:
    if( 0 and my $orientation = $imager->tags(name => 'exif_orientation')) {
        my %rotate = (
            1 => 0,
            #2 => 180,
            3 => 180,
            #4 => 0,
            #5 => 90,
            6 => 270,
            #7 => 0,
            8 => 90,
        );
        my $deg = $rotate{ $orientation };
        $imager = $imager->rotate( right => $deg );
    };
    
    # Resize
    $imager = $imager->scale(xpixels=>42, ypixels=>42, type=>'min');    
    # Write with Q20
    #$imager->set_file_limits( width => 42, height => 42 );
    $imager->write(type => 'jpeg', data => \my $data, jpegquality => 20);

    #(my $data64 = encode_base64($data)) =~ s!\s+!!g;
    #print $data64,"\n";
    
    my( $width,$height ) = ($imager->getheight, $imager->getwidth);
    return ($width,$height,$data);
}

sub strip_header {
    my( $width,$height,$jpeg ) = @_;
    
    # Deparse the JPEG file into its sections
    my @sections;
    while($jpeg =~ /\G(((\x{ff}[^\0\x{d8}\x{d9}])(..))|\x{ff}\x{d8}|\x{ff}\x{d9})/csg) {
        my $header = $3 || $1;
        my $payload;
        if( $header eq "\x{ff}\x{da}" ) {
            # Start of scan
            $payload = substr( $jpeg, pos($jpeg)-2, length($jpeg)-pos($jpeg)+2);
            pos($jpeg) = pos($jpeg) + length $payload;
        } elsif( $header eq "\x{ff}\x{d8}" ) {
            # Start of image
            $payload = "";
        } elsif( $header eq "\x{ff}\x{d9}" ) {
            # End of Image
            $payload = "";
        } else {
            my $length = unpack "n", $4;
            $payload = substr( $jpeg, pos($jpeg)-2, $length );
            pos($jpeg) = pos($jpeg) + $length -2;
        };
        push @sections, { type => $header, payload => $payload }
    };

    my %priority = (
        "\x{ff}\x{d8}" =>  0,
        "\x{ff}\x{c4}" =>  1,
        "\x{ff}\x{db}" =>  2,
        "\x{ff}\x{c0}" => 50,
        "\x{ff}\x{da}" => 98,
        "\x{ff}\x{d9}" => 99,
    );
    
    # Only keep the important sections
    @sections = grep { exists $priority{ $_->{type}}} @sections;
    # Reorder them so that the image dimensions are at the end
    @sections = sort {$priority{$a->{type}} <=> $priority{$b->{type}}} @sections;
    
    #for my $s (@sections) {
    #    print sprintf "%02x%02x - %04d\n", unpack( "CC", $s->{type}), length $s->{payload};
    #};

    # Reassemble the (relevant) sections
    my $header = join "",
                 map { $_->{type}, $_->{payload }}
                 grep { $_->{type} ne "\x{ff}\x{da}" and $_->{type} ne "\x{ff}\x{d9}" }
                 @sections;
    
    my $payload = join "",
                 map { $_->{type}, $_->{payload }}
                 grep { $_->{type} eq "\x{ff}\x{da}" or $_->{type} eq "\x{ff}\x{d9}" }
                 @sections;

    my $min_header = $header;
                 
    # Do the actual packing
    my $stripped = pack "CCA*", $width, $height, $payload;

    ($stripped,$min_header)
};

my $counter = 0;
sub gen_img {
    my( $file ) = @_;
    my($width,$height, $data) = compress_image( $file );
    print sprintf "Length          : %d bytes\n", length $data;
    my( $payload, $min_header ) = strip_header( $width,$height,$data );
    print sprintf "  without header: %d bytes\n", length $payload;
    print sprintf "Minimal header  : %d bytes\n", length $min_header;
   
    (my $payload64 = encode_base64($payload)) =~ s!\s+!!g;
    (my $min_header64 = encode_base64($min_header)) =~ s!\s+!!g;
    #print "$min_header64\n";

    $file =~ s!\\!/!g;
    $file = "file:///C|/$file";
    
    #(my $data64 = encode_base64($data)) =~ s!\s+!!g;
    $counter++;
    return <<HTML, $min_header64;
<img width="640px" height="480px" id="$counter"
   data-preview="$payload64"
   src="$file"
   />
HTML
}

sub gen_html {
    my $min_header;
    my @tags;
    for my $file (@_) {
        my($html,$hdr) = gen_img($file);
        $min_header ||= $hdr;
        if( $min_header ne $hdr ) {
            warn "Inconsistent JPEG headers?!";
        };
        push @tags, $html;
    };
    
    my $html = <<HTML;
<!DOCTYPE html><html><meta charset='utf-8'>
<head>
</head>
<body>
@tags
<script>
"use strict";

var header = atob("$min_header");
function reconstruct(data) {
    // Reconstruct a JPEG header from our special data structure
    var raw = atob(data);
    // Keep as "char" so we don't have to bother with Unicode vs. ASCII
    var width  = raw.charAt(0);
    var height = raw.charAt(1);
    var payload = raw.substring(2,raw.length);
    var dimension_patch = width+height;
    var patched_header = header.substring(0,header.length-13)
                       + width
                       + header.substring(header.length-12,header.length-11)
                       + height
                       + header.substring(header.length-10,header.length);
    var reconstructed = patched_header+payload;
    // XXX Patch appropriate width and height into the header
    var encoded = "data:image/jpeg;base64,"+btoa(reconstructed);
    // Why are we missing this part?! Or some parts at all?!
    //encoded = encoded.substring(0,encoded.length-3)+"//Z";
    return encoded;
}

var image_it = document.evaluate("//img[\@data-preview]",document, null, XPathResult.ANY_TYPE, null);
var images = [];
var el = image_it.iterateNext();
while( el ) {
    images.push(el);
    el = image_it.iterateNext();
};

for( var i = 0; i < images.length; i++ ) {
    var el = images[ i ];
    if( !el.complete || el.naturalWidth == 0 || el.naturalHeight == 0) {
    
        var fullsrc = el.src;
        var loadsrc = reconstruct( el.getAttribute("data-preview"));
        el.src = loadsrc;
        el.style.filter = "blur(16px)";
        var parent = el.parentNode;
        var img = document.createElement('img');
        img.width = el.width;
        img.height = el.height;
        // Shouldn't we also copy the style and maybe even some events?!
        // img = el.cloneNode(true); // except this doesn't copy the eventListeners etc. Duh.
        (function(img,el) {
            img.onload = function() {
                // Put the loaded child in the place of the preloaded data
                //alert(el.id);
                window.setTimeout(function(){
                parent.replaceChild(img,el);
                }, 500+Math.random(15000));
            };
        }(img,el));
        // Kick off the loading
        img.src = fullsrc;
    } else {
        // Image has already been loaded (from cache), nothing to do here
    };
};
</script>
</body>
</html>
HTML

    return ($html);
}

use File::Glob 'bsd_glob';
@ARGV= map { bsd_glob $_ } @ARGV;

my($html) = gen_html(@ARGV);
my $fh;
#open my $fh, '>', 'tmp.jpeg'
#    or die "Couldn't write 'tmp.jpeg': $!";
#binmode $fh;
#print $fh $data;

open $fh, '>', 'tmp.html'
    or die "Couldn't write 'tmp.html': $!";
binmode $fh;
print $fh $html;
