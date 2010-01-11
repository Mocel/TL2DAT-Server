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

my $DatLine = DatLine->new({ config_dir => $FindBin::Bin });
my $CONF = $DatLine->conf;

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
    $heap->{datline} = $DatLine;
    $heap->{next_alarm} = int(time()) + 1;
    $kern->alarm(tick => $heap->{next_alarm});
}

sub get_tl_handler {
    my ($kern, $heap, $sess) = @_[KERNEL, HEAP, SESSION];

    my $datline = $heap->{datline};
    $datline->get_timeline;

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

    warn "tl_handler: Request ", $req->uri, "\n";

    if (my $temp = dump_headers($req)) {
        warn "tl_handler: HTTP Header: $temp\n";
    }

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

    my $response_filename;
    if ($ext eq '.dat') {
        # .dat ファイルの要求
        warn "tl_handler: DAT Request $filename\n";

        $response_filename = File::Spec->catfile($CONF->{data_dir}, 'dat', $filename);
    }
    elsif ($filename eq 'subject.txt') {
        # subject.txt の要求
        warn "tl_handler: subject.txt Request\n";

        $response_filename = File::Spec->catfile($CONF->{data_dir}, 'subject.txt');
    }

    if ($response_filename) {
        my $in_fh;
        if (! open $in_fh, '<:raw', $response_filename) {
            # ファイルのオープンに失敗
            warn "Cannot open file $response_filename: $!";
            set_error($res, 404, '404 NOT FOUND');
            return RC_OK;
        }

        warn "tl_handler: Open file $response_filename\n";
        my @file_stat = stat $in_fh;

        # If-Modified-Since ヘッダ処理
        if (my $if_mod_val = $req->header('If-Modified-Since')) {
            my $if_mod = str2time($if_mod_val);
            warn "tl_handler: If-Modified-Since = $if_mod, target file modified = $file_stat[9]\n";
            if ($if_mod && $file_stat[9] <= $if_mod) {
                warn "tl_handler: Not modified. skip.\n";
                set_error($res, 304, '304 Not Modified');
                return RC_OK;
            }
        }

        # Range リクエスト処理
        my ($readlen, $offset) = ($file_stat[7], 0);
        if (my $range = $req->header('Range')) {
            my ($start) = $range =~ /^bytes=(\d+)-/;
            warn "tl_handler: Range start = $start\n";
            if ($start && $start > 0) {
                my $len = $file_stat[7];
                $res->header('Accept-Ranges' => $start);
                $res->header('Content-Range' => "bytes $start-$len/$len");
                $offset = $start;
                $readlen -= $offset;
                sysseek $in_fh, $offset, 0;
                warn "tl_handler: Content-Range = " . $res->header('Content-Range') . "\n";
            }
        }

        warn "tl_handler: Read length $readlen, Offset $offset\n";
        my $content = '';
        my $sysread_len = sysread $in_fh, $content, $readlen;
        close $in_fh;

        if (! $sysread_len) {
            # ファイル読み込みエラー
            warn "tl_handler: Error! sysread() returned undef.\n";
            set_error($res, '500', '500 Internal Server Error');
            return RC_OK;
        }

        warn "tl_handler: Length ", length $content, ", sysread() length $sysread_len\n";
        $res->code(200);
        $res->content_type('text/plain');
        $res->content($content);

        if (my $con_len = $res->header('Content-Length')) {
            warn "tl_handler: Content-Length = $con_len\n";
        }

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


sub dump_headers {
    my $req = shift;

    my $headers = $req->headers or return;

    my @result;
    for my $name ($headers->header_field_names) {
        push @result, qq{Header "$name": } . $headers->header($name);
    }

    return join ', ', @result;
}

sub bbs_handler {
    my ($req, $res) = @_;

    warn "bbs_handler: Request ", $req->uri, "\n";

    if (my $temp = dump_headers($req)) {
        warn "$temp\n";
    }

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
            my %args;

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
            my $result;
            if (! $DatLine->update_status(\%args)) {
                $result = '書き込みに失敗しました。<br><br>元の画面に戻ってやり直してみてください。'
            }
            else {
                $result = '書きこみが終わりました。<br><br>画面を切り替えるまでしばらくお待ち下さい。';
            }

            $poe_kernel->post($tl_session => 'tick');
            @content = (qq{<html><head><title>書きこみました。</title><meta http-equiv="Content-Type" content="text/html; charset=Shift_JIS"><META content=5;URL=../casket/ http-equiv=refresh></head><body>$result<br>});
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
