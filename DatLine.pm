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
use Net::Twitter::Lite;
use YAML::Syck;

local $YAML::Syck::ImplicitUnicode = 1;

use DatLine::Subjects;
use DatLine::Util;
use DatLine::ShortenURL;

use version;
our $VERSION = qv('0.0.1');
sub VERSION { $VERSION }

use base qw(Class::Accessor::Fast);
__PACKAGE__->mk_accessors(qw(conf encoder subject_list latest_id res_list tw thread_fh));

my $http_regex =
    q{\b(?:https?|shttp)://(?:(?:[-_.!~*'()a-zA-Z0-9;:&=+$,]|%[0-9A-Fa-f][0-9A-Fa-f])*@)?(?:(?:[a-zA-Z0-9](?:[-a-zA-Z0-9]*[a-zA-Z0-9])?\.)*[a-zA-Z](?:[-a-zA-Z0-9]*[a-zA-Z0-9])?\.?|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(?::[0-9]*)?(?:/(?:[-_.!~*'()a-zA-Z0-9:@&=+$,]|%[0-9A-Fa-f][0-9A-Fa-f])*(?:;(?:[-_.!~*'()a-zA-Z0-9:@&=+$,]|%[0-9A-Fa-f][0-9A-Fa-f])*)*(?:/(?:[-_.!~*'()a-zA-Z0-9:@&=+$,]|%[0-9A-Fa-f][0-9A-Fa-f])*(?:;(?:[-_.!~*'()a-zA-Z0-9:@&=+$,]|%[0-9A-Fa-f][0-9A-Fa-f])*)*)*)?(?:\?(?:[-_.!~*'()a-zA-Z0-9;/?:@&=+$,]|%[0-9A-Fa-f][0-9A-Fa-f])*)?(?:#(?:[-_.!~*'()a-zA-Z0-9;/?:@&=+$,]|%[0-9A-Fa-f][0-9A-Fa-f])*)?};

sub new {
    my ($class, $param) = @_;

    my $self = bless {
        conf => {},
        latest_id => 0,
        res_list => {},
        thread_fh => 0,
    }, $class;

    # 設定ファイル読み込み
    $self->conf(_load_config($param->{config_dir}));

    my $term_enc;
    if (exists $self->conf->{term_encoding}) {
        $term_enc = delete $self->conf->{term_encoding};
    }
    elsif (eval { require Term::Encoding; } ) {
        $term_enc = Term::Encoding::term_encoding();
    }
    $term_enc ||= 'utf8';

    if ($term_enc) {
        $self->{term_encoder} = Encode::find_encoding($term_enc);
        binmode STDOUT, ":encoding($term_enc)";
        binmode STDERR, ":encoding($term_enc)";
    }

    $self->{subject_list} = DatLine::Subjects->new({
        subject_dir => $self->conf->{data_dir},
        encoder => $self->{term_encoder},
    });

    # dat ファイルのエンコーディング指定
    my $encoding = $self->conf->{dat_encoding} || 'cp932';
    $self->{encoder} = Encode::find_encoding($encoding)
        or croak("Cannot find encoding '$encoding'.");

    # subject.txt に保持する最大スレッド件数
    $self->{max_thread} ||= 100;

    # Twitter API Agent
    if (exists $self->conf->{oauth}) {
        # OAuth
        _put_log('OAuth mode');

        my ($ckey, $csecret) =
            ($self->conf->{oauth}->{consumer_key}, $self->conf->{oauth}->{consumer_secret});

        _put_log("Consumer key $ckey, Secret $csecret");

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

            my $url = eval { $self->tw->get_authorization_url };
            if ($@) {
                die __PACKAGE__, ": Get authorization URL failed: $@";
            }

            print "認証用 URL:\n$url\n";
            my $pin =
                ExtUtils::MakeMaker::prompt("上記の URL にアクセスして確認した PIN# を入力してください: ");

            chomp $pin;
            $pin or Carp::croak("Invalid pin");

            $pin = $self->{term_encoder}->decode($pin);
            _put_log("PIN#: $pin");

            my ($access_token, $access_token_secret, $user_id, $screen_name) =
                eval { $self->tw->request_access_token(verifier => $pin) };

            if ($@) {
                Carp::croak("OAuth 認証に失敗: $@");
            }
            elsif (! $access_token || ! $access_token_secret) {
                Carp::croak("OAuth 認証に失敗しました。時間をおいて再試行してみてください。");
            }

            _put_log("Get Access Token succeed.");

            $self->save_token($access_token, $access_token_secret);
        }
    }
    else {
        # BASIC Authorization
        _put_log('Basic Auth mode');
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
        _put_log('Short URL Service available.');
        $self->{shorten_url} = DatLine::ShortenURL->new({
            conf => $self->conf->{shorturl},
            db_dir => $self->{conf}->{db_dir},
            term_encoder => $self->{encoder},
        });
    }

    # subject.txt 読み込み
    $self->subject_list->load;

    return $self;
}

sub DESTROY {
    my $self = shift;

    if (defined $self->{thread_fh}) {
        $self->close_thread;
    }

    return;
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

    my $thread;
    if ($num > $self->{max_thread}) {
        my $fname = File::Spec->catfile($self->conf->{data_dir}, 'dat', "$num.dat");
        my $term_encoder = $self->{term_encoder};
        if (open my $in_fh, '<', $term_encoder->encode($fname)) {
            _put_log("Direct open dat file $fname");

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

            $thread = [basename($fname), unescape_html($title), $cnt];
        }
        else {
            carp("get_thread: cannot find dat file $num");
            return;
        }
    }
    else {
        $thread = $self->subject_list->get($num);
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

sub create_thread {
    my ($self, $args) = @_;
    $args ||= {};

    my $now = DateTime->now();
    $now->set_time_zone('Asia/Tokyo');
    $now->set_locale('ja');

    my $fname = $now->epoch . '.dat';
    my $title = (exists $args->{title})
        ? $args->{title} . ' ' . $now->strftime('%Y/%m/%d(%a) %T')
        : 'タイムライン ' . $now->strftime('%Y/%m/%d(%a) %T');

    my $subject = [$fname, $title, 0];
    $self->subject_list->unshift($subject);

    return $subject;
}

sub open_thread {
    my ($self, $arg) = @_;

    my $thread = (defined $arg)
        ? $self->get_thread($arg)
        : $self->current_thread;

    if (! $thread) {
        carp('Thread not found: ' . (defined $arg) ? $arg : '');
        return;
    }

    my $fname = $self->get_thread_filename($thread);

    # .dat ファイルが既存なら最新の Tweet ID を取得
    if (-e $fname) {
        open my $fh, '+<', $fname
            or croak("Cannot open file $fname: $!");

        _put_log("open dat file $fname");
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

        _put_log("create dat file $fname");
        $self->thread_fh($fh);
        $self->res_list( +{} );
    }

    return $thread;
}

sub close_thread {
    my $self = shift;

    $self->thread_fh or return;
    close $self->{thread_fh};
    delete $self->{thread_fh};
    delete $self->{current_thread};

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
        _put_log("Found reply $item->{id} => $reply_to_id");
    }

    my @res = (
        $item->{user}->{name},
        "$item->{id}\@$item->{user}->{screen_name}",
        $dt->strftime('%Y/%m/%d(%a) %T') . $id,
        $body,
    );


    print {$out_fh} $enc->encode(
        join('<>', map(escape_html($_), @res)) . '<>', Encode::FB_HTMLCREF);


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

    # URL の短縮化
    if (my $shorten_agent = $self->{shorten_url}) {
        for my $url ($text =~ /($http_regex)/g) {
            my $short_url = $shorten_agent->to_short($url);
            $short_url or next;
            $text =~ s/$url/$short_url/;
            _put_log('shorten URL ', $url, ' => ', $short_url);
        }
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
            _put_log('Found reply_to id ', $thread_id, ':', $no, ' => ', $reply_id);
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
    _put_log(join(', ', @temp));

    eval { $self->tw->update(\%param) };
    if (my $error = $@) {
        if (blessed $error && $error->isa('Net::Twitter::Lite::Error')
            && $error->code() == 502) {
            $error = "Fail Whale!";
        }
        _put_log($error);
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

    # subject.txt 読み込み
    $self->subject_list->load;

    my $thread = $self->current_thread;
    if (! $thread) {
        carp("get_timeline(): open thread failed.");
        return;
    }

    $self->open_thread;
    _put_log('Thread filename: ', $thread);

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

    # 最終取得の Tweet ID を保存
    $self->latest_id($ret->[0]->{id});

    # dat 書き込み
    my $exceed_id_list = $self->conf->{timeline}->{exceed_id};
    $exceed_id_list ||= [];
    _put_log('Exceed ID ', join(', ', @$exceed_id_list));

    my $url_regex;
    if (defined $self->{shorten_url}) {
        $url_regex = $self->{shorten_url}->get_url_regex;
        _put_log('Shorten URL Regex ', $url_regex);
    }

    for my $item (reverse @$ret) {
        my $screen_name = $item->{user}->{screen_name};
        if (! $screen_name) {
            carp("Cannot find screen_name!");
            next;
        }
        if (any { $_ eq $screen_name } @$exceed_id_list) {
            _put_log("\[$screen_name] is listed on exceed. skipped.");
            next;
        }

        # 短縮 URL を展開
        $item->{text} = $self->expand_shorten_url($item->{text}, $url_regex)
            if defined $url_regex;

        $self->write_res($item);
    }

    # スレを閉じる
    $self->close_thread;

    _put_log("converted ", scalar @$ret, " tweet(s).");

    $self->subject_list->save;

    return;
}

sub expand_shorten_url {
    my ($self, $text, $url_regex) = @_;

    defined $self->{shorten_url} or return $text;

    if (my @short_url_list = $text =~ /($url_regex)/g) {
        for my $url (@short_url_list) {
            _put_log("Found short URL $url");
            if (my $long_url = $self->{shorten_url}->to_long($url)) {
                $text =~ s/$url/$long_url/;
                _put_log("expand URL $url => $long_url");
            }
            else {
                _put_log("cannot expand shorten url. $url");
            }
        }
    }

    return $text;
}

sub _load_config {
    my $dir = shift;
    my $fname = File::Spec->catfile($dir, 'config.yml');
    return LoadFile($fname);
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
            _put_log("Found \[consukey_key]");
        }
        elsif ($f == 2 && $line =~ /^(\s+)consumer_secret:/) {
            # consumer_key: まで読んだ
            _put_log("Found \[consukey_secret]");
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

    _put_log("Saved an access token and secret.");

    return 1;
}

sub get_access_token {
    my $self = shift;

    my $tw = $self->tw;
    my $conf = $self->conf->{oauth};

    if (! exists $conf->{access_token} || ! exists $conf->{access_token_secret}) {
        _put_log('token not found.');
        return;
    }

    my ($access_token, $access_secret) =
        @$conf{qw(access_token access_token_secret)};

    if (! $access_token || ! $access_secret) {
        _put_log('invalid token.');
        return;
    }

    _put_log('Found Access token and Secret.');

    $tw->access_token($access_token);
    $tw->access_token_secret($access_secret);

    eval { $tw->authorized };
    return if $@;

    return 1;
}

sub get_api_limit {
    my $self = shift;

    my $result = eval { $self->tw->rate_limit_status };
    if ($@) {
        carp("get_api_limit: get information failed: $@");
        return;
    }

    if (my $dt = $self->{tw_strp}->parse_datetime($result->{reset_time})) {
        $dt->set_locale('ja');
        $result->{reset_time} = $dt->strftime('%Y/%m/%d(%a) %T');
    }

    return $result;
}


sub _put_log {
    my @caller = caller(1);
    warn "$caller[3]: ", @_, "\n";
    return;
}

1;

__END__
