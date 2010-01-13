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
use File::Basename;
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

    # dat ファイルのエンコーディング指定
    my $encoding = $self->conf->{dat_encoding} || 'cp932';
    $self->{encoder} = Encode::find_encoding($encoding)
        or croak("Cannot find encoding '$encoding'.");

    # subject.txt に保持する最大スレッド件数
    $self->{max_thread} ||= 100;

    # Twitter API Agent
    if (exists $self->conf->{oauth}) {
        # OAuth
        warn __PACKAGE__, ": OAuth mode\n";

        my ($ckey, $csecret) =
            ($self->conf->{oauth}->{consumer_key}, $self->conf->{oauth}->{consumer_secret});

        warn __PACKAGE__, ": Consumer key $ckey, Secret $csecret\n";

        $self->{tw} = Net::Twitter::Lite->new(
            #ssl => 1,
            consumer_key => $ckey,
            consumer_secret => $csecret,
        );
        if ($@) {
            die "Twitter OAuth failed: $@";
        }
        elsif (! $self->get_access_token) {
            if (! eval { require Net::OAuth::Simple }) {
                die "Need the module Net::OAuth::Simple to auth via OAuth but not found";
            }

            require ExtUtils::MakeMaker;

            print "OAuth 認証 開始\n";
            #$self->tw->request_token_url('https://twitter.com/oauth/request_token');
            #$self->tw->authorization_url('https://twitter.com/oauth/authorize');

            my $url = eval { $self->tw->get_authorization_url };
            if ($@) {
                die __PACKAGE__, ": Get authorization URL failed: $@";
            }

            print "認証用 URL:\n$url\n";
            my $pin =
                ExtUtils::MakeMaker::prompt("上記の URL にアクセスして確認した PIN# を入力してください: ");

            chomp $pin;
            $pin or Carp::croak("Invalid pin");

            my ($access_token, $access_token_secret, $user_id, $screen_name) =
                $self->tw->request_access_token(verifier => $pin);

            if (! $access_token || ! $access_token_secret) {
                Carp::croak("OAuth 認証に失敗しました。時間をおいて再試行してみてください。");
            }

            warn __PACKAGE__, ": Get Access Token succeed.\n";

            $self->save_token($access_token, $access_token_secret);
            exit 0;
        }
    }
    else {
        # BASIC Authorization
        warn __PACKAGE__, ": Basic Auth mode\n";
        $self->{tw} = Net::Twitter::Lite->new(
                ssl => 1,
                %{ $self->conf->{twitter} },
        );
    }

    # Twitter の日付文字列解析用
    $self->{tw_strp} = DateTime::Format::Strptime->new(
        pattern => '%a %b %d %T %z %Y', time_zone => 'Asia/Tokyo',
    );

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
    if ($num > $self->{max_thread}) {
        my $fname = File::Spec->catfile($self->conf->{data_dir}, 'dat', "$num.dat");
        if (open my $in_fh, '<', $fname) {
            warn "get_thread: Direct open dat file $fname\n";

            my $enc = $self->encoder;
            my $cnt = 0;
            my $title;
            while (<$in_fh>) {
                chomp;
                my @data = split '<>', $enc->decode($_);
                next if @data < 3;
                ++$cnt;
                $title = $data[4] if @data > 4;
            }
            close $in_fh;

            $thread = [basename($fname), $title, $cnt];
        }
        else {
            carp("get_thread: cannot find dat file $num");
            return;
        }
    }
    else {
        $thread = $sub_list->[$num];
    }

    if (! $thread || $thread->[2] > $self->conf->{max_res}) {
        $thread = $self->create_thread;
    }

    return $thread;
}

sub get_thread_filename {
    my ($self, $stuff) = @_;

    my $fname;
    if ($stuff && ref($stuff) && ref($stuff) eq 'ARRAY') {
        $fname = $stuff->[0];
    }
    else {
        my $thread = $self->get_thread($stuff);
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
        my ($title, $count) = $data[1] =~ m/^(.*) \((\d+)\)/;
        $count or next;
        push @list, [$data[0], _unescape_html($title), $count];
        warn "Load thread: title[$title], count[$count]\n";
        last if ++$cnt > $self->{max_thread};
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
            ' (',
            $subject->[2],
            ')'
        );

        print {$out_fh} $enc->encode($s, Encode::HTMLCREF);
        print {$out_fh} $enc->encode("\n");

        warn "Save thread: title\[$subject->[1]], count\[$subject->[2]]\n";
        last if ++$cnt > $self->{max_thread};
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

        warn "open_thread: open dat file $fname\n";
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

        warn "open_thread: create dat file $fname\n";
        $self->thread_fh($fh);
        $self->res_list( +{} );
    }

    return $thread;
}

sub close_thread {
    my $self = shift;

    $self->thread_fh or return;
    close $self->{thread_fh};
    $self->{thread_fh} = undef;
    $self->{current_thread} = undef;

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

    my $id = " ID:$item->{user}->{screen_name}";
    $id =~ s/[-_]/+/g;
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

    print {$out_fh} "\n";

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
    if (exists $args->{in_reply_to} && exists $args->{in_reply_to_thread}) {
        my $no = $args->{in_reply_to};
        my $thread_id = $args->{in_reply_to_thread};

        if (! $no) {
            carp("Invalid res no!");
            return;
        }
        elsif (! $thread_id) {
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
            warn "Found reply_to id: $thread_id\:$no => $reply_id\n";
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
    $self->load_subject;

    my $thread = $self->current_thread;
    if (! $thread) {
        carp("get_timeline(): open thread failed.");
        return;
    }

    $self->open_thread;
    warn "Thread filename: $thread->[0]\n";

    # 最新スレの最後のレス ID
    $param{since_id} = $self->latest_id if $self->latest_id;

    # 短縮 URL のキャッシュ用
    my %longurl_cache;

    # TL 取得
    my $ret = eval { $self->tw->home_timeline(\%param) };
    if (! $ret) {
        # スレを閉じる
        $self->close_thread;
        carp(qq{Twitter API "home_timeline()" failed: $@});
        return;
    }

    # 最終取得の Tweet ID を保存
    $self->latest_id($ret->[0]->{id});

    # dat 書き込み
    my $exceed_id_list = $self->conf->{timeline}->{exceed_id};
    $exceed_id_list ||= [];
    warn "get_timeline: Exceed ID: ", join(', ', @$exceed_id_list), "\n";
    for my $item (reverse @$ret) {
        my $screen_name = $item->{user}->{screen_name};
        if (! $screen_name) {
            carp("Cannot find screen_name!");
            next;
        }
        if (any { $_ eq $screen_name } @$exceed_id_list) {
            warn "get_timeline: \[$screen_name] is listed on exceed. skipped.\n";
            next;
        }

        # 短縮 URL を展開
        my $text = $item->{text};
        if (my @short_url_list = $text =~ m{(http://(?:bit\.ly|j\.mp)/[0-9a-zA-Z]+)}g) {
            for my $url (@short_url_list) {
                warn "get_timeline: Found short URL: $url\n";
                my $long_url;
                if (exists $longurl_cache{$url}) {
                    warn "get_timeline: expand URL $url => $long_url (cached)\n";
                    $long_url = $longurl_cache{$url};
                    $text =~ s/$url/$long_url/;
                }
                elsif ($long_url = $self->get_expand_url($url)) {
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

    $self->save_subject;

    return;
}

sub _escape_html {
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

sub save_token {
    my ($self, $token, $secret) = @_;

    my $enc_name = exists $self->conf->{term_encoding}
        ? $self->conf->{term_encoding}
        : 'utf8';

    my $coder = Encode::find_encoding($enc_name);

    my $config_fname = File::Spec->catfile($FindBin::Bin, 'config.yml');
    open my $fh, '<', $coder->encode($config_fname)
        or Carp::croak("Cannot open config file $config_fname: $!");

    my $new_config_fname = "$config_fname.new";
    open my $out_fh, '>', $coder->encode($new_config_fname)
        or Carp::croak("Connot open config file $new_config_fname: $!");

    my $f = 0;
    while (<$fh>) {
        chomp;
        my $line = Encode::decode_utf8($_);

        if ($f == 1) {
            # oauth: まで読んだ
            $line =~ /^\s+consumer_key:/ and ++$f;
            warn "save_token: Found [consukey_key]\n";
        }
        elsif ($f == 2 && $line =~ /^(\s+)consumer_secret:/) {
            # consumer_key: まで読んだ
            warn "save_token: Found [consukey_secret]\n";
            my $indent = $1;

            print {$out_fh} "$line\n";
            print {$out_fh} $indent, "access_token: $token\n";
            print {$out_fh} $indent, "access_token_secret: $secret\n";

            # 残りの行をすべて書き出す
            print {$out_fh} $_ for <$fh>;
            last;
        }
        else {
            # その他
            $line =~ /^oauth:/ and $f = 1;
        }

        print {$out_fh} "$line\n";
    }

    close $out_fh;
    close $fh;

    return 1;
}

sub get_access_token {
    my $self = shift;

    my $tw = $self->tw;
    my $conf = $self->conf->{oauth};

    if (! exists $conf->{access_token} || ! exists $conf->{access_token_secret}) {
        warn "get_access_token: token not found.\n";
        return;
    }

    my ($access_token, $access_secret) =
        @$conf{qw(access_token access_token_secret)};

    if (! $access_token || ! $access_secret) {
        warn "get_access_token: invalid token.\n";
        return;
    }

    warn "get_access_token: Found Access token and Secret.\n";

    $tw->access_token($access_token);
    $tw->access_token_secret($access_secret);

    eval { $tw->authorized };
    return if $@;

    return 1;
}
1;

__END__
