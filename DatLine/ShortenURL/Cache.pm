package DatLine::ShortenURL::Cache;

use strict;
use warnings;
use utf8;

use Carp;
use DBI;
use Encode();
use File::Spec;
use List::MoreUtils qw(firstidx);

use version;
our $VERSION = qv('0.0.1');

sub new {
    my ($class, $args) = @_;

    my $self = bless +{
        key_list => [],
        cache => +{},
    }, $class;

    $self->{term_encoder} = $args->{term_encoder};

    my $db_filename = File::Spec->catfile($args->{db_dir}, 'shortenurl_cache.db');

    $self->create_dbhandle($db_filename);

    return $self;
}

sub create_dbhandle {
    my ($self, $fname) = @_;

    my $enc_fname = $self->{term_encoder}->encode($fname);

    my $sql;
    if (! -e $enc_fname) {
        $sql =
              q{CREATE TABLE shorturl_cache (}
            . q{ short_url TEXT NOT NULL PRIMARY KEY,}
            . q{ long_url TEXT NOT NULL,}
            . q{ modified TIMESTAMP NOT NULL}
            . q{)};
    }

    my $dbh = DBI->connect("dbi:SQLite:dbname=$enc_fname", '', '',
        { RaiseError => 0, sqlite_unicode => 1}
    );

    if ($sql && ! defined $dbh->do($sql)) {
        Carp::croak("Cannot create datebase file $fname: ", $dbh->errstr);
    }

    $self->{dbh} = $dbh;
    return;
}

sub get {
    my ($self, $url) = @_;

    if (my $stored = $self->get_from_cache($url)) {
        warn __PACKAGE__, ": Found '$url' from memory cache.\n";
        return $stored;
    }

    warn __PACKAGE__, ": search $url from cache\n";

    my $sql = 'SELECT long_url FROM shorturl_cache WHERE short_url = ?';
    my $sth = $self->{dbh}->prepare($sql)
        or Carp::croak("expand shorten url $url from cache failed: ", $self->{dbh}->errstr);

    my $rv = $sth->execute($url);

    if (! defined $rv) {
        Carp::croak("expand shorten url $url from cache failed: ", $sth->errstr);
    }

    if (my $row = $sth->fetch) {
        my $long_url = $row->[0];
        warn __PACKAGE__, ": found long_url $long_url\n";
        $self->put_into_cache($url, $long_url);
        return $long_url;
    }

    warn __PACKAGE__, ": not found long url ($rv)\n";
    return;
}

sub put {
    my ($self, $short_url, $long_url) = @_;

    my $sql = 'INSERT INTO shorturl_cache(short_url, long_url, modified) VALUES(?, ?, ?)';
    my $sth = $self->{dbh}->prepare($sql)
        or Carp::croak("store a shorten url '$short_url' to cache: ", $self->{dbh}->errstr);

    my $rv = $sth->execute($short_url, $long_url, time());

    if (! defined $rv) {
        Carp::croak("store a shorten url '$short_url' to cache: ", $self->{dbh}->errstr);
    }

    return 1;
}

sub get_from_cache {
    my ($self, $key) = @_;

    exists $self->{cache}->{$key} or return;

    my $list = $self->{key_list};

    my $idx = firstidx { $key eq $_ } @$list;
    splice @$list, $idx, 1;
    unshift @$list, $key;

    return $self->{cache}->{$key};
}

sub put_into_cache {
    my ($self, $key, $val) = @_;

    $self->{cache}->{$key} = $val;
    my $cnt = unshift @{ $self->{key_list} }, $key;

    if ($cnt > 100) {
        my $old_key = pop @{ $self->{key_list} };
        delete $self->{cache}->{$old_key};
    }

    return;
}

1;

__END__
