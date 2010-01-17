package DatLine::ShortenURL;

use strict;
use warnings;
use utf8;

use Encode();
use LWP::UserAgent;
use URI;
use JSON::Any qw/XS JSON/;

use version;
our $VERSION = qv('0.0.1');

my $ua;
my $json_agent;
my $cache;

my $url_regex = join('|',
    'http://(?:bit\.ly|j\.mp)/\w+',
    'http://tinyurl\.com/[\w\(\)]+',
    'http://tinylink\.com/\w+',
    'http://4sq.com/\w+',
    'http://ow.ly/\w+',
    'http://flic.kr/p/\w+',
);

sub new {
    my ($class, $arg) = @_;

    my $self = bless +{
        conf => $arg->{conf},
    }, $class;

    $ua ||= LWP::UserAgent->new(
        timeout => 15,
        requests_redirectable => [],
        env_proxy => 1,
        agent => "$self/$VERSION",
    );

    $json_agent ||= JSON::Any->new(utf8 => 1);

    if (eval { require DatLine::ShortenURL::Cache; }) {
        warn __PACKAGE__, ": Cache module available.\n";
        $cache ||= DatLine::ShortenURL::Cache->new({
            db_dir => $arg->{db_dir},
            term_encoder => $arg->{term_encoder},
        });
    }
    else {
        warn __PACKAGE__, ": Cache module unavailable.\n";
    }

    return $self;
}

sub get_url_regex { qr{$url_regex}; }

sub to_short {
    my ($self, $long_url) = @_;

    $long_url or return;

    if (exists $self->{conf}->{bitly}) {
        return $self->to_short_bitly($long_url);
    }

    return;
}

sub to_short_bitly {
    my ($self, $long_url) = @_;

    my $account = $self->{conf}->{bitly};

    my $req_url = URI->new('http://api.bit.ly/shorten');
    $req_url->query_form({
        version => '2.0.1',
        'format' => 'json',
        longUrl => $long_url,
        %$account,
    });

    my $res = $ua->get($req_url);
    if (! $res->is_success) {
        carp("to_short_bitly: get short url failed: ", $res->status_line);
        return;
    }

    my $result = eval { $json_agent->from_json($res->decoded_content) };
    if ($@) {
        carp("to_short_bitly: JSON parse failed: $@");
        return;
    }
    elsif (! $result->{statusCode} || $result->{statusCode} ne 'OK') {
        my $msg = $result->{errorMessage} || '(unknown)';
        carp("to_short_bitly: API Call failed: $msg");
        return;
    }

    return $result->{results}->{$long_url}->{shortUrl};
}


sub to_long {
    my ($self, $short_uri) = @_;
    $short_uri or return;
    $short_uri =~ m/$url_regex/ or return;

    if ($cache) {
        my $result = $cache->get($short_uri);
        if ($result) {
            warn "to_long: expanded $result (cached)\n";
            return $result;
        }
    }

    my $res = $ua->get($short_uri);
    $res->is_redirect or return;

    my $result = $res->header('Location') or return;

    $cache and $cache->put($short_uri, $result);

    return $result;
}

sub to_long_bitly {
    my ($self, $long_url) = @_;

    my $account = $self->{conf}->{bitly};
    my $req_uri = URI->new('http://api.bit.ly/shorten');
    $req_uri->query_form({
        version => '2.0.1',
        'format' => 'json',
        longUrl => $long_url,
        %$account,
    });

    my $res = $ua->get($req_uri);
    if (! $res->is_success) {
        carp("get short url failed: ", $res->status_line);
        return;
    }

    my $result = eval { $json_agent->from_json($res->decoded_content) };
    if ($@) {
        carp("JSON parse failed: $@");
        return;
    }
    elsif (! $result->{statusCode} || $result->{statusCode} ne 'OK') {
        my $msg = $result->{errorMessage} || '(unknown)';
        carp("API Call failed: $msg");
        return;
    }

    return $result->{results}->{$long_url}->{shortUrl};
}

1;
