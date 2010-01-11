#!/usr/bin/perl
# Twitter の TL => 2ch 互換 dat
#

use strict;
use warnings;
use utf8;

use feature qw(say);
use CGI;
use FindBin;
use File::Basename;
use File::Spec;
use HTTP::Date;
use HTTP::Request::AsCGI;
use POE qw(Component::Server::HTTP);
#use POE::Kernel;
use Time::HiRes qw(time);
use YAML::Syck;

use DatLine;

my $CONF = load_config();

if (exists $CONF->{term_encoding}) {
    my $enc = $CONF->{term_encoding};
    binmode STDOUT, ":encoding($enc)";
    binmode STDERR, ":encoding($enc)";
}

my $TW;
my $DatLine;

# Web サーバー用のセッション
my $aliases = POE::Component::Server::HTTP->new(
    Port => $CONF->{server}->{port},
    ContentHandler => {
        '/timeline/' => \&tl_handler,
        '/' => \&bbs_handler,
    },
);

# TL 取得用のセッション
my $tl_session = POE::Session->create(
    inline_states => {
        _start => \&start_handler,
        get_tl => \&get_tl_handler,
        tick => \&tick_handler,
    },
);

POE::Kernel->run;

sub start_handler {
    my ($kern, $heap, $sess) = @_[KERNEL, HEAP, SESSION];
    $DatLine ||= DatLine->new({ config_dir => $FindBin::Bin });
    $heap->{datline} = $DatLine;
    $TW ||= Net::Twitter::Lite->new(
        ssl => 1,
        username => $CONF->{twitter}->{id},
        password => $CONF->{twitter}->{password},
    );
    $heap->{tw} = $TW;
    $heap->{next_alarm} = int(time()) + 1;
    $kern->alarm(tick => $heap->{next_alarm});
}

sub get_tl_handler {
    my ($kern, $heap, $sess) = @_[KERNEL, HEAP, SESSION];

    my $datline = $heap->{datline};
    my $tw = $heap->{tw};

    my $thread = $datline->current_thread;
    say "Thread filename: $thread->[0]";

    # dat ファイル オープン
    $datline->open_thread;
    my $latest_id = $datline->latest_id;

    # TL 取得
    my $tl_count = $CONF->{get_tl_count} || 50;
    my %param = ( count => $tl_count );
    $param{since_id} = $latest_id if $latest_id;

    my $ret = eval { $tw->home_timeline(\%param); };
    #my $ret = eval { $tw->user_timeline({screen_name => 'Mocel', count => 100}); };
    if (! $ret) {
        warn "home_timeline() failed: $@";
        return;
    }

    for my $item (reverse @$ret) {
        $datline->write_res($item);
    }

    $datline->close_thread;
    return;
}

sub tick_handler {
    my ($kern, $heap, $sess) = @_[KERNEL, HEAP, SESSION];

    $kern->yield('get_tl');
    my $interval = $CONF->{interval} || 60;
    $heap->{next_alarm} += $interval;
    say "Next to get Timeline: ", scalar localtime($heap->{next_alarm});
    $kern->alarm(tick => $heap->{next_alarm});
    return;
}

sub tl_handler {
    my ($req, $res) = @_;

    #$res->headers->header(CacheControl => 'no-cache');
    #$res->headers->header(Expires => '-1');

    my @path = split '/', $req->uri->path;
    my $filename = pop @path;
    my $ext = (fileparse($filename, '.txt', '.dat'))[2];

    warn "tl_handler: $filename, $ext";

    if (! @path || ! $filename || ! $ext) {
        # エラー
        warn "tl_handler: bad requst: ", $req->uri, "\n";

        set_error($res, 403, '403 FORBIDDEN');
        return RC_OK;
    }
    elsif ($ext eq '.dat') {
        # .dat ファイルの要求
        warn "tl_handler: DAT Request $filename\n";

        my $filename = File::Spec->catfile($CONF->{data_dir}, 'dat', $filename);
        
        my $in_fh;
        if (! open $in_fh, '<', $filename) {
            # ファイルのオープンに失敗
            warn "Cannot open file $filename: $!";
            set_error($res, 404, '404 NOT FOUND');
            return RC_OK;
        }

        warn "tl_handler: Open file $filename\n";

        my $content = do { local $/; <$in_fh> };
        close $in_fh;

        $res->code(200);
        $res->content_type('text/plain');
        $res->content($content);

        return RC_OK;
    }
    elsif ($filename eq 'subject.txt') {
        # subject.txt の要求
        warn "tl_handler: subject.txt Request\n";

        my $filename = File::Spec->catfile($CONF->{data_dir}, 'subject.txt');

        my $in_fh;
        if (! open $in_fh, '<', $filename) {
            # ファイルのオープンに失敗
            warn "Cannot open file $filename: $!";
            set_error($res, 404, '404 NOT FOUND');
            return RC_OK;
        }

        warn "tl_handler: Open file $filename\n";

        my $content = do { local $/; <$in_fh> };
        close $in_fh;

        $res->code(200);
        $res->content_type('text/plain');
        $res->content($content);

        return RC_OK;
    }
    else {
        # その他のエラー
        warn "tl_handler: Request error ", $req->uri, "\n";

        set_error($res, '403', '403 FORBIDDEN');
        return RC_OK;
    }
}

sub set_error {
    my ($res, $code, $text) = @_;

    #$res->headers->header(CacheControl => 'no-cache');
    #$res->headers->header(Expires => '-1');
    $res->code($code);
    $res->content_type('text/html');
    $res->content("<html><head><title>$text</title></head><body><h1>$text</h1></body></html>");

    return $res;
}


sub bbs_handler {
    my ($req, $res) = @_;

    warn "bbs_handler: Request ", $req->uri, "\n";

    my @content;

    my $decoder = $DatLine->encoder;
    if ($req->method eq 'POST' && $req->uri->path eq '/test/bbs.cgi') {
        my $c = HTTP::Request::AsCGI->new($req)->setup;
        my $q = CGI->new;

        my $text = $decoder->decode($q->param('MESSAGE'));

        # 改行コードを統一
        $text =~ s/\x0D\x0A/\n/g;
        $text =~ tr/\x0D\x0A/\n\n/;

        # 文末の空白文字は削除する
        $text =~ s/\s+\z//;

        my $thread_id = $q->param('key');
        my $from = $decoder->decode($q->param('FROM'));
        if ($text && $thread_id) {
            my %args = (
                tw => $TW,
            );

            if ($text =~ /^>>(\d+)/) {
                $args{in_reply_to} = $1;
                $args{in_reply_to_thread} = $thread_id;
                $text =~ s/^>>\d+\s*//;
            }

            $args{status} = $text;

            for my $k (sort keys %args) {
                push @content, "Key \[$k] = $args{$k}";
            }

            warn 'Post data: ', join(', ', @content), "\n";
            $DatLine->update_status(\%args);

            $poe_kernel->post($tl_session => 'tick');

            @content = ( '<html><head><title>書きこみました。</title><meta http-equiv="Content-Type" content="text/html; charset=Shift_JIS"><META content=5;URL=../casket/ http-equiv=refresh></head><body>書きこみが終わりました。<br><br>画面を切り替えるまでしばらくお待ち下さい。<br>' );
        }
    }
    else {
        @content = (
           '<html><head><title>リザルト</title><meta http-equiv="Content-Type" content="text/html; charset=Shift_JIS"></head><body>リクエスト結果<br>',
            'Fetched: ' . $req->uri->path,
            'Date: ' . localtime,
            'Method: ' . $req->method,
        );
    }

    push @content, '</body></html>';

    warn "Response: ", join(', ', @content, "\n");

    $res->content_type('text/html');
    #$res->headers->header(CacheControl => 'no-cache');
    #$res->headers->header(Expires => '-1');
    $res->content($decoder->encode(join("<br>\r\n", @content)));
    $res->code(200);

    return RC_OK;
}

sub load_config {
    my $fname = File::Spec->catfile($FindBin::Bin, 'config.yml');
    
    return LoadFile($fname);
}