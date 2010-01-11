package DatLine;
# TL => .dat
#

use strict;
use warnings;
use utf8;

use Carp;
use DateTime;
use DateTime::Format::Strptime;
use File::Spec;
use FindBin;
use Net::Twitter::Lite;
use YAML::Syck;

use version;
our $VERSION = qv('0.0.1');
sub VERSION { $VERSION }

use base qw(Class::Accessor::Fast);
__PACKAGE__->mk_accessors(qw(conf encoder subject_list latest_id res_list));

sub new {
    my ($class, $param) = @_;

    my $self = bless {
        conf => {},
        subject_list => [],
        latest_id => 0,
        res_list => {},
    }, $class;

    $self->conf(_load_config($param->{config_dir}));
    $self->{subject_list} = [];
    $self->{tw_strp} = DateTime::Format::Strptime->new(
        pattern => '%a %b %d %T %z %Y', time_zone => 'Asia/Tokyo',
    );

    $self->{encoder} = Encode::find_encoding('cp932')
        or croak("Cannot find encoding 'CP932'");

    $self->load_subject;

    return $self;
}

sub DESTROY {
    my $self = shift;

    if (defined $self->{thread_fh}) {
        $self->close_thread;
    }

    return;
}

sub push_subject {
    my $self = shift;
    my $thread = [ @_ ];

    unshift @{ $self->subject_list }, $thread;
    return $thread;
}

sub current_thread {
    my ($self, $thread) = @_;

    if (defined $thread && ref($thread) && ref($thread) eq 'ARRAY') {
        $self->{current_thread} = $thread;
    }
    elsif (! defined $self->{current_thread}) {
        $self->{current_thread} = $self->get_thread;
    }

    return $self->{current_thread};
}

sub get_thread {
    my ($self, $num) = @_;
    $num ||= 0;

    my $sub_list = $self->subject_list;

    my $thread;
    if (defined $num) {
        for my $item (@$sub_list) {
            my ($no) = $item->[0] =~ /^(\d+)\./;
            $no or next;
            if ($no == $num) {
                $thread = $item;
                last;
            }
        }
        $thread ||= $sub_list->[$num];
    }

    if (! $thread || $thread->[2] > $self->conf->{max_res}) {
        $thread = $self->create_thread;
    }

    return $thread;
}

sub get_thread_filename {
    my ($self, $num) = @_;

    my $fname;
    if ($num && ref($num) && ref($num) eq 'ARRAY') {
        $fname = $num->[0];
    }
    else {
        my $thread = $self->get_thread($num);
        $fname = $thread->[0];
    }

    return File::Spec->catfile($self->conf->{data_dir}, 'dat', $fname);
}

sub load_subject {
    my $self = shift;

    my $fname = File::Spec->catfile($self->conf->{data_dir}, 'subject.txt');
    return if ! -e $fname;

    open my $in_fh, '<', $fname
        or croak("Cannot open file $fname: $!");

    my $enc = $self->encoder;
    my @list;

    while (<$in_fh>) {
        chomp;
        my @data = split /<>/, $enc->decode($_, Encode::HTMLCREF);
        my ($title, $count) = $data[1] =~ m/^(.*)\((\d+)\)/;
        $count or next;
        push @list, [$data[0], _unescape_html($title), $count];
        warn "Load thread: title[$title], count[$count]\n";
    }

    close $in_fh;

    $self->subject_list(\@list);

    return $self;
}

sub save_subject {
    my $self = shift;

    my $fname = File::Spec->catfile($self->conf->{data_dir}, 'subject.txt');

    open my $out_fh, '>', $fname
        or croak("Cannot open file $fname: $!");

    my $enc = $self->encoder;
    for my $subject (@{ $self->subject_list }) {
        my $s = join('',
            $subject->[0],
            '<>',
            _escape_html($subject->[1]),
            '(',
            $subject->[2],
            ')'
        );

        print {$out_fh} $enc->encode($s, Encode::HTMLCREF);
        print {$out_fh} $enc->encode("\r\n");

        warn "Save thread: title\[$subject->[1]], count\[$subject->[2]]\n";
    }

    close $out_fh;

    return $self;
}

sub create_thread {
    my $self = shift;

    my $now = DateTime->now();
    $now->set_time_zone('Asia/Tokyo');
    $now->set_locale('ja');

    my $fname = $now->epoch . '.dat';
    my $title = $now->strftime('%Y/%m/%d(%a) %T') . ' に立てられたスレッド';

    return $self->push_subject($fname, $title, 0);
}

sub open_thread {
    my ($self, $arg) = @_;

    my $thread = (defined $arg)
        ? $self->get_thread($arg)
        : $self->current_thread;

    if (! $thread) {
        carp('Thread not found: ' . (defined $arg) ? $arg : '');
        return $thread;
    }

    my $fname = $self->get_thread_filename($thread);

    # .dat ファイルが既存なら最新の Tweet ID を取得
    if (-e $fname) {
        open my $fh, '+<', $fname
            or croak("Cannot open file $fname: $!");

        $self->{thread_fh} = $fh;
        my %res_list;

        my $latest_id;
        my $cnt = 0;
        my $enc = $self->encoder;
        while (<$fh>) {
            chomp;
            my @data = split /<>/, $enc->decode($_, Encode::FB_HTMLCREF);
            (@data > 3 and $data[1]) or next;

            my $screenname;
            ($latest_id, $screenname) = $data[1] =~ /^(\d+)(?:\@(.*))?$/;
            $latest_id or next;

            # スレ番より ID のほうが圧倒的に大だから同じハッシュに
            # 「ID => スレ番」と「スレ番 => ID」を格納してしまう
            $res_list{$latest_id} = ++$cnt;
            $res_list{$cnt} = $latest_id;
            $res_list{"$cnt\@user"} = $screenname if $screenname;
        }

        $latest_id ||= 0;
        $thread->[2] = $cnt;

        $self->latest_id($latest_id);
        $self->res_list(\%res_list);
    }
    else {
        open $self->{thread_fh}, '>', $fname
            or croak("Cannot open file $fname: $!");

        $self->res_list( +{} );
    }

    return $thread;
}

sub close_thread {
    my $self = shift;

    $self->{thread_fh} or return;
    undef $self->{thread_fh};

    $self->save_subject;

    return $self;
}

sub write_res {
    my ($self, $item) = @_;

    my $out_fh = $self->{thread_fh};
    defined $out_fh or return;

    my $enc = $self->encoder;
    my $thread = $self->current_thread;
    my $res_list = $self->res_list;
    my $strp = $self->{tw_strp};

    my $dt = $strp->parse_datetime($item->{created_at});
    $dt->set_locale('ja');

    my $id = '';
    if ($item->{retweeted_status}) {
        $id .= ' RT';
    }

    my $body = $item->{text};
    my $reply_to_id = $item->{in_reply_to_status_id};
    if ($reply_to_id && exists $res_list->{$reply_to_id}) {
        my $res_no = $res_list->{$reply_to_id};
        $body = ">>$res_no\x0D\x0A" . $body;
        warn "Found reply: $item->{id} => $reply_to_id\n";
    }

    my @res = (
        $item->{user}->{name},
        "$item->{id}\@$item->{user}->{screen_name}",
        $dt->strftime('%Y/%m/%d(%a) %T') . $id,
        $body,
    );


    print {$out_fh} $enc->encode(
        join('<>', map(_escape_html($_), @res)) . '<>', Encode::FB_HTMLCREF);


    # 1 レス目ならスレッドタイトルも書き込む
    if ($thread->[2] == 0) {
        print {$out_fh} $enc->encode($thread->[1], Encode::FB_HTMLCREF);
    }

    print {$out_fh} $enc->encode("\x0D\x0A");

    if (++$thread->[2] == $self->conf->{max_res}) {
        $self->close_thread;

        $thread = $self->create_thread;
        $self->current_thread($thread);
        $self->open_thread;
    }
    else {
        $self->res_list->{$item->{id}} = $thread->[2];
    }

    warn 'Write res[', $thread->[2], ']: ', join(', ', @res), "\n";

    return $self;
}

sub update_status {
    my ($self, $args) = @_;

    if (! $args || ! ref($args) || ref($args) ne 'HASH') {
        carp("invalid arguments.");
        return;
    }

    my $text = $args->{status};

    if (! $text) {
        carp("Status is empty!");
        return;
    }

    my %param;

    # Reply 先の ID を取得
    if (exists $args->{in_reply_to} && $args->{in_reply_to}) {
        my $no = $args->{in_reply_to};
        my $thread_id = $args->{in_reply_to_thread};

        if (! $thread_id) {
            carp("Invalid thread id");
            return;
        }

        my $thread = $self->open_thread($thread_id);
        if (! $thread) {
            carp("Thread not found: $thread_id");
            return;
        }
        my $res_list = $self->{res_list};
        if (exists $res_list->{$no}) {
            my $reply_id = $res_list->{$no};
            $param{in_reply_to_status_id} = $reply_id;
            carp("Found reply_to id: $thread_id\:$no => $reply_id");
        }

        if (exists $res_list->{"$no\@user"}) {
            my $name = $res_list->{"$no\@user"};
            $text = "\@$name " . $text;
        }

        $self->close_thread;
    }

    $param{status} = $text;

    my @temp;
    for my $k (sort keys %param) {
        push @temp, "Key \[$k] = $param{$k}";
    }
    warn "update_status: ", join(', ', @temp), "\n";

    eval { $args->{tw}->update(\%param) };
    if (my $error = $@) {
        if (blessed $error && $error->isa('Net::Twitter::Lite::Error')
            && $error->code() == 502) {
            $error = "Fail Whale!";
        }
        warn "$error";
    }

    return;
}


sub _escape_html {
    my $stuff = shift;

    $stuff =~ s/&(?![a-z]{2,4};)/&amp;/g;
    $stuff =~ s/</&lt;/g;
    $stuff =~ s/>/&gt;/g;
    $stuff =~ s/"/&quot;/g;
#    $stuff =~ s/'/&apos;/g;
    $stuff =~ s/\x0D?\x0A/<br>/g;

    return $stuff;
}

sub _unescape_html {
    my $stuff = shift;

    $stuff =~ s/&apos;/'/g;
    $stuff =~ s/&quot;/"/g;
    $stuff =~ s/&gt;/>/g;
    $stuff =~ s/&lt;/</g;
    $stuff =~ s/&amp;/&/g;

    return $stuff;
}

sub _load_config {
    my $dir = shift;
    my $fname = File::Spec->catfile($dir, 'config.yml');
    return LoadFile($fname);
}

1;

__END__