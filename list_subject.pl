#!/usr/bin/perl
# 漢字

use strict;
use warnings;
use utf8;

use Encode;
use File::Spec;
use File::Basename;
use FindBin;
use YAML::Syck;

local $YAML::Syck::ImplicitUnicode = 1;

main();


sub main {
    my $conf = load_config();

    my $enc;
    if (exists $conf->{term_encoding}) {
        $enc = $conf->{term_encoding};
    }
    elsif ( eval { require Term::Encoding; } ) {
        $enc = Term::Encoding::term_encoding();
    }
    $enc ||= 'utf8';

    warn "Term encoding: $enc\n";
    my $decoder = Encode::find_encoding($enc);
    binmode STDOUT, ":encoding($enc)";
    binmode STDERR, ":encoding($enc)";

    my $dir_name = File::Spec->catdir($conf->{data_dir}, 'dat');
    warn "Target dir: $dir_name\n";

    opendir my $dh, $dir_name
        or die $!;

    my $dat_decoder = Encode::find_encoding('cp932');

    my @subject_list;
    for my $fname (reverse sort grep /^\d+\.dat$/, readdir $dh) {
        my $fullpath = File::Spec->catfile($dir_name, $fname);

        warn "Open dat file: $fname\n";
        open my $in_fh, '<', $fullpath or die $!;

        my $cnt = 0;
        my $title;
        while (<$in_fh>) {
            chomp;
            my @data = split '<>', $dat_decoder->decode($_, Encode::HTMLCREF);
            next if @data < 3;

            $title = $data[4] if @data > 4;
            ++$cnt;
        }
        close $in_fh;

        push @subject_list, [$fname, $title, $cnt];
        warn "スレッド: $title ($cnt)\n";
    }

    closedir $dh;

    if (@subject_list) {
        my $subject_fname = File::Spec->catfile($conf->{data_dir}, 'subject.txt.new');
        warn "Open subject file: $subject_fname\n";

        open my $out_fh, '>', $decoder->encode($subject_fname)
            or die $!;

        for my $item (@subject_list) {
            my @data = (
                $item->[0],
                '<>',
                escape_html($item->[1]),
                ' (',
                $item->[2],
                ')');

            my $output = join('', @data), Encode::HTMLCREF;
            print {$out_fh} $dat_decoder->encode($output), "\n";
            warn "Output: $output\n";

        }

        close $out_fh;
    }

    return 0;
}

sub load_config {
    my $fname = File::Spec->catfile($FindBin::Bin, 'config.yml');
    my $yaml = YAML::Syck::LoadFile($fname);

    return $yaml;
}

sub escape_html {
    my $stuff = shift;

    $stuff =~ s/&(?![a-z]{2,4};)/&amp;/g;
    $stuff =~ s/</&lt;/g;
    $stuff =~ s/>/&gt;/g;
    $stuff =~ s/"/&quot;/g;
    $stuff =~ s/\x0D?\x0A/<br>/g;

    return $stuff;
}

__END__

