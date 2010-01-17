package DatLine::Subjects;

use strict;
use warnings;
use utf8;

use Carp;
use Encode ();
use File::Basename;
use File::Spec;
use List::MoreUtils qw(firstidx);

use DatLine::Util;

use version;
our $VERSION = qv('0.0.1');
sub VERSION { $VERSION }

use base qw(Class::Accessor::Fast);
__PACKAGE__->mk_accessors(qw(subject_list subject_filename));


sub new {
    my ($class, $arg) = @_;

    if (! exists $arg->{subject_dir} || ! $arg->{subject_dir}) {
        carp('Parameter "subject_dir" is invalid.');
    }
    elsif (! exists $arg->{encoder} || ! $arg->{encoder} || ! ref($arg->{encoder})
            || ref($arg->{encoder}) ne 'Encode::XS') {
        carp('Parameter "encoder" is invalid.');
    }

    my $subject_fname = File::Spec->catfile($arg->{subject_dir}, 'subject.txt');

    my $self = bless +{
        subject_filename => $subject_fname,
        subject_list => [],
        encoder => $arg->{encoder},
        _encoder => Encode::find_encoding('cp932'),
        subject_max => $arg->{subject_max} || 100,
    }, $class;

    return $self;
}

sub load {
    my $self = shift;

    my $fname = $self->{subject_filename};
    my $encoder = $self->{encoder};

    return if ! -e $encoder->encode($fname);

    open my $in_fh, '<', $encoder->encode($fname)
        or Carp::carp("Cannot open file $fname: $!");

    my $c_encoder = $self->{_encoder};

    my @list;
    my $cnt = 0;
    my $max = $self->{subject_max};
    while (<$in_fh>) {
        chomp;
        my @data = split /<>/, $c_encoder->decode($_, Encode::FB_HTMLCREF);
        next if @data < 2;
        my ($title, $count) = $data[1] =~ m/^(.*) \((\d+)\)/;
        $title or next;

        push @list, [$data[0], unescape_html($title), $count];

        ++$cnt < $max or last;
    }

    close $in_fh;

    $self->{subject_list} = \@list;

    return $self;
}

sub save {
    my $self = shift;

    my $fname = $self->{subject_filename};
    my $encoder = $self->{encoder};

    open my $out_fh, '>', $encoder->encode($fname)
        or Carp::carp("Cannot open file $fname: $!");

    my $c_encoder = $self->{_encoder};
    my $max = $self->{subject_max};
    my $cnt = 0;
    for my $subject (@{ $self->{subject_list} }) {
        my $s = join('',
            $subject->[0],
            '<>',
            escape_html($subject->[1]),
            ' (',
            $subject->[2],
            ")\n",
        );

        print {$out_fh} $c_encoder->encode($s, Encode::FB_HTMLCREF);
        ++$cnt < $max or last;
    }

    close $out_fh;

    return $self;
}

sub unshift {
    my $self = shift;
    my $subject = (@_ > 1) ? [ @_ ] : $_[0];

    unshift @{ $self->{subject_list} }, $subject;
    return $self;
}

sub shift {
    my $self = shift;

    my $ret = shift @{ $self->{subject_list} };
    return $ret;
}

sub get {
    my ($self, $idx) = @_;
    $idx ||= 0;

    my $list = $self->{subject_list};

    if (ref($idx) && ref($idx) eq 'Regexp') {
        my $i = firstidx { $_->[1] =~ $idx } @$list;
        return if $i == -1;
        return $list->[$i];
    }
    if ($idx =~ /\.dat$/) {
        my $i = firstidx { $_->[0] eq $idx } @$list;
        return if $i == -1;
        return $list->[$i];
    }

    $idx < @$list or return;
    return $list->[$idx];
}

sub put {
    my ($self, $idx, $subject) = @_;
    (defined $idx and $subject) or return;
    $self->{subject_list}->[$idx] = $subject;
    return $self;
}


1;
