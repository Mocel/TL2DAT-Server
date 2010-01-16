package DatLine::Util;

use strict;
use warnings;

require 5.008;

use version;
our $VERSION = qv('0.0.1');
sub VERSION { $VERSION }

require Exporter;
use base qw(Exporter);
our @EXPORT = qw(escape_html unescape_html);

sub escape_html {
    my $stuff = shift;

    $stuff =~ s/&(?![a-z]{2,4};)/&amp;/g;
    $stuff =~ s/</&lt;/g;
    $stuff =~ s/>/&gt;/g;
    $stuff =~ s/"/&quot;/g;

    # 改行コードの統一
    $stuff =~ s/\x0D\x0A/\n/g;
    $stuff =~ tr/\x0D\x0A/\n\n/;

    $stuff =~ s/\n/<br>/g;

    return $stuff;
}

sub unescape_html {
    my $stuff = shift;

    $stuff =~ s/&apos;/'/g;
    $stuff =~ s/&quot;/"/g;
    $stuff =~ s/&gt;/>/g;
    $stuff =~ s/&lt;/</g;
    $stuff =~ s/&amp;/&/g;

    return $stuff;
}

1;
