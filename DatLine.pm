package DatLine;
# TL => .dat
#

use strict;
use warnings;
use utf8;

use Carp;
use DateTime;
use DateTime::Format::Strptime;
use Encode ();
use File::Spec;
use JSON::Any qw/XS JSON/;
use List::MoreUtils qw(any);
use LWP::UserAgent;
use Net::Twitter::Lite;
use URI;
use YAML::Syck;

use version;
our $VERSION = qv('0.0.1');
sub VERSION { $VERSION }

use base qw(Class::Accessor::Fast);
__PACKAGE__->mk_accessors(qw(conf encoder subject_list latest_id res_list tw thread_fh));

sub new {
    my ($class, $param) = @_;

    my $self = bless {
        conf => {},
        subject_list => [],
        latest_id => 0,
        res_list => {},
        thread_fh => 0,
    }, $class;

    # 設定ファイル読み込み
    $self->conf(_load_config($param->{config_dir}));
    if (exists $self->conf->{term_encoding}) {
        my $enc = $self->conf->{term_encoding};
        binmode STDOUT, ":encoding($enc)";
        binmode STDERR, ":encoding($enc)";
    }

    # Twitter API Agent
    $self->{tw} = Net::Twitter::Lite->new(
            ssl => 1,
            %{ $self->conf->{twitter} },
    );

    # Twitter の日付文字列解析用
    $self->{tw_strp} = DateTime::Format::Strptime->new(
        pattern => '%a %b %d %T %z %Y', time_zone => 'Asia/Tokyo',
    );

    # コンソールのエンコーディング指定
    my $encoding = $self->conf->{dat_encoding} || 'cp932';
    $self->{encoder} = Encode::find_encoding($encoding)
        or croak("Cannot find encoding '$encoding'.");

    # 短縮 URL 向け
    if (exists $self->conf->{shorturl}) {
        warn "Short URL Service available.\n";
        $self->{json_agent} = JSON::Any->new(utf8 => 1);
    }

    # subject.txt 読み込み
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
    my $cnt = 0;
    while (<$in_fh>) {
        chomp;
        my @data = split /<>/, $enc->decode($_, Encode::HTMLCREF);
        my ($title, $count) = $data[1] =~ m/^(.*)\((\d+)\)/;
        $count or next;
        push @list, [$data[0], _unescape_html($title), $count];
        warn "Load thread: title[$title], count[$count]\n";
        last if ++$cnt > 4;
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
    my $cnt = 0;
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
        last if ++$cnt > 4;
    }

    close $out_fh;

    return $self;
}

sub create_thread {
    my ($self, $args) = @_;
    $args ||= {};

    my $now = DateTime->now();
    $now->set_time_zone('Asia/Tokyo');
    $now->set_locale('ja');

    my $fname = $now->epoch . '.dat';
    my $title = (exists $args->{title})
        ? $args->{title} . ' ' . $now->strftime('%Y/%m/%d(%a) %T')
        : $now->strftime('%Y/%m/%d(%a) %T') . ' に立てられたスレッド';

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

        $self->thread_fh($fh);
        my %res_list;

        my $latest_id;
        my $cnt = 0;
        my $enc = $self->encoder;
        while (<$fh>) {
            chomp;
            my @data = split /<>/, $enc->decode($_, Encode::FB_HTMLCREF);
            (@data > 3 and $data[1]) or next;

            my $screenname;
            ($latest_id, $screenname) = split '@', $data[1];
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
        open my $fh, '>', $fname
            or croak("Cannot open file $fname: $!");

        $self->thread_fh($fh);
        $self->res_list( +{} );
    }

    return $thread;
}

sub close_thread {
    my $self = shift;

    $self->thread_fh or return;
    undef $self->{thread_fh};

    $self->save_subject;

    return $self;
}

sub write_res {
    my ($self, $item) = @_;

    my $out_fh = $self->thread_fh;
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

    eval { $self->tw->update(\%param) };
    if (my $error = $@) {
        if (blessed $error && $error->isa('Net::Twitter::Lite::Error')
            && $error->code() == 502) {
            $error = "Fail Whale!";
        }
        warn "$error";
        return;
    }

    return 1;
}

sub get_timeline {
    my ($self) = @_;

    # 取得する件数
    my $tl_count = $self->conf->{get_tl_count} || 60;

    # リクエストパラメータ
    my %param = (count => $tl_count);

    # dat ファイルオープン
    my $thread = $self->current_thread;
    if (! $thread) {
        carp("get_timeline(): open thread failed.");
        return;
    }

    $self->open_thread;
    warn "Thread filename: $thread->[0]\n";

    # 最新スレの最後のレス ID
    $param{since_id} = $self->latest_id if $self->latest_id;

    # TL 取得
    my $ret = eval { $self->tw->home_timeline(\%param) };
    if (! $ret) {
        # スレを閉じる
        $self->close_thread;
        carp(qq{Twitter API "home_timeline()" failed: $@});
        return;
    }

    # dat 書き込み
    my $exceed_id_list = $self->conf->{timeline}->{exceed_id};
    warn "get_timeline: Exceed ID: ", join(', ', @$exceed_id_list), "\n";
    for my $item (@$ret) {
        next if any { $_ eq $item->{user}->{screen_name} } @$exceed_id_list;

        # 短縮 URL を展開
        my $text = $item->{text};
        if (my @short_url_list = $text =~ m{(http://(?:bit\.ly|j\.mp)/[0-9a-zA-Z]+)}g) {
            for my $url (@short_url_list) {
                warn "get_timeline: Found short URL: $url\n";
                if (my $long_url = $self->get_expand_url($url)) {
                    warn "get_timeline: expand URL $url => $long_url\n";
                    $text =~ s/$url/$long_url/;
                }
            }

            $item->{text} = $text;
        }

        $self->write_res($item);
    }

    # スレを閉じる
    $self->close_thread;

    return;
}

sub _escape_html {
    my $stuff = shift;

    $stuff =~ s/&(?![a-z]{2,4};)/&amp;/g;
    $stuff =~ s/</&lt;/g;
    $stuff =~ s/>/&gt;/g;
    $stuff =~ s/"/&quot;/g;
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

sub get_shorten_url {
    my ($self, $long_url) = @_;

    return if ! exists $self->{json_agent};

    my $json_agent = $self->{json_agent};
    my $ua = $self->tw->{ua};
    my $account = $self->conf->{shorturl};

    my $req_url = URI->new('http://api.bit.ly/shorten');
    $req_url->query_form({
        version => '2.0.1',
        'format' => 'json',
        longUrl => $long_url,
        %$account,
    });

    my $res = $ua->get($req_url);
    if (! $res->is_success) {
        carp("get_shorten_url: get short url failed: ", $res->status_line);
        return;
    }

    my $result = eval { $json_agent->from_json($res->decoded_content) };
    if ($@) {
        carp("get_shorten_url: JSON parse failed: $@");
        return;
    }
    elsif (! $result->{statusCode} || $result->{statusCode} ne 'OK') {
        my $msg = $result->{errorMessage} || '(unknown)';
        carp("get_shorten_url: API Call failed: $msg");
        return;
    }

    return $result->{results}->{$long_url}->{shortUrl};
}

sub get_expand_url {
    my ($self, $arg) = @_;

    if (! $arg || ! exists $self->{json_agent}) {
        carp("cannot expand shorten url.");
        return;
    }

    my $json_agent = $self->{json_agent};
    my $ua = $self->tw->{ua};
    my $account = $self->conf->{shorturl};

    my $short_url = (ref($arg) && ref($arg) eq 'URI')
        ? $arg
        : URI->new($arg);

    my $req_url = URI->new('http://api.bit.ly/expand');
    $req_url->query_form({
        version => '2.0.1',
        'format' => 'json',
        shortUrl => $short_url,
        %$account,
    });

    my $res = $ua->get($req_url);
    warn "get_expand_url: GET $req_url\n";
    if (! $res->is_success) {
        carp("get_shorten_url: get short url failed: " . $res->status_line);
        return;
    }

    my $result = eval { $json_agent->from_json($res->decoded_content) };
    if ($@) {
        carp("get_shorten_url: JSON parse failed: $@");
        return;
    }
    elsif (! $result->{statusCode} || $result->{statusCode} ne 'OK') {
        my $msg = $result->{errorMessage} || '(unknown)';
        carp("get_shorten_url: API Call failed: $msg");
        return;
    }

    my $path = substr $short_url->path, 1;
    my $long_url = $result->{results}->{$path}->{longUrl};
    warn "get_expand_url: SUCCESS ", $long_url, "\n";

    return $long_url;
}


1;

__END__
