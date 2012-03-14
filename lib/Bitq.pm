package Bitq;
use Mouse;
use AnyEvent::HTTP qw(http_get);
use AnyEvent::Handle ();
use AnyEvent::Socket ();
use Bit::Vector;
use File::Path ();
use Log::Minimal;
use Bitq::Peer;
use Bitq::Store;
use Bitq::Tracker::PSGI;
use Bitq::Bencode qw(bdecode);
use Bitq::Protocol::BEP03 qw(build_handshake unpack_handshake);
use Bitq::Protocol::BEP23 qw(uncompact_ipv4);

our $VERSION;
our $MONIKER;
BEGIN {
    my $major = 1;
    my $minor = 0;
    my $dev   = 1;
    $VERSION = $dev > 0 ?
        sprintf '%d.%d_%d', $major, $minor, $dev :
        sprintf '%d.%d', $major, $minor
    ;
    $MONIKER = sprintf '%d%s', $major * 1000 + $minor, $dev > 0 ? 'U' : 'S';

    $Log::Minimal::PRINT = sub {
        printf "%s [%s] %s\n", @_;
    };
}

has peer_id => (
    is => 'ro',
    default => sub { $MONIKER },
);
has host => (
    is => 'ro',
    default => '127.0.0.1',
);

has port => (
    is => 'ro',
    isa => 'Int',
    default => 6688
);

has torrents => (
    is => 'ro',
    default => sub { +{} }
);


# XXX RETHINK
has scrape_urls => (
    is => 'ro',
    default => sub { +{} },
);

has peers => (
    is => 'ro',
    default => sub { +{} },
);

has leechers => (
    is => 'ro',
    default => sub { +{} },
);

has work_dir => (
    is => 'rw',
    required => 1,
    trigger => sub {
        my ($self, $new_value) = @_;
        my @subdirs = (
            File::Spec->catdir( $new_value, "work" ),
            File::Spec->catdir( $new_value, "completed" ),
        );
        foreach my $dir (@subdirs) {
            if (! -d $dir) {
                if (! File::Path::make_path( $dir ) || ! -d $dir ) {
                    die "Failed to create directory $dir: $!";
                }
            }
        }
    }
);

has store => (
    is => 'ro',
    lazy => 1,
    default => sub {
        my $self = shift;
        Bitq::Store->new( app => $self );
    }
);

AnyEvent::Handle::register_read_type(
    "bittorrent.packet" => sub {
        my ($self, $cb) = @_;

        my %state = (
            len     => 0,
            type    => 0,
        );
        sub {
            if ( ! $state{len} ) {
                # Check the first 4 bytes to figure out the length of the
                # payload. The next byte contains 1 byte that describes the
                # message type, then the payload. 
                if ( length $_[0]{rbuf} < 5 ) {
                    return;
                }
                my $preamble = bytes::substr( $_[0]{rbuf}, 0, 5, '' );
                ($state{len}, $state{type}) = unpack "l c", $preamble;

                # len contains the len for the type byte, so subtract that
                $state{len} -= 1;
            }

            if ( length( $_[0]{rbuf} ) < $state{len} ) {
                return;
            }

            my ($len, $type) = ($state{len}, $state{type});
            my $buffer = bytes::substr( $_[0]{rbuf}, 0, $len, '' );
            undef %state;

            $cb->( $_[0], $type, $buffer );
            return 1;
        }
    }
);

AnyEvent::Handle::register_read_type(
    "bittorrent.handshake" => sub {
        my ($self, $cb) = @_;

        my %state = (
            preamble => 0,
        );
        sub {
            if ( ! $state{preamble} ) {
                # Handshakes consiste of 69 bytes total. The first byte is 0x13
                if ( !defined $_[0]{rbuf} || length $_[0]{rbuf} < 1 ) {
                    return;
                }

                my $byte = substr $_[0]{rbuf}, 0, 1;
                if ( unpack("c", $byte) != 0x13 ) {
                    undef %state;
                    critf "Expected 0x13 as first byte in stream, but got %s", unpack "c", $byte;
                    $cb->($_[0], "Bad handshake");
                    return 1;
                }
                $state{preamble} = 1;
            }

            if ( length $_[0]{rbuf} < 68 ) {
                return;
            }

            # whippee we got 68 bytes
            undef %state;
            my @payload = unpack_handshake( substr $_[0]{rbuf}, 0, 68, '' );
            $cb->( $_[0], @payload );
            return 1;
        }

    }
);

AnyEvent::Handle::register_write_type(
    "bittorrent.packet" => sub {
        my ($self, $type, $string) = @_;
        $string ||= '';

        my $len = bytes::length($type) + bytes::length($string);
        infof "Writing $type $string ($len bytes)";
        return pack( "l c", $len, $type ) . $string;
    }
);

AnyEvent::Handle::register_write_type(
    "bittorrent.handshake" => sub {
        my ($self, $reserved, $info_hash, $peer_id) = @_;

        if (! defined $reserved) {
            my @reserved = (0, 0, 0, 0, 0, 0, 0, 0);
            $reserved[5] |= 0x10;    # Ext Protocol
            $reserved[7] |= 0x04;    # Fast Ext
            $reserved = join '', map {chr} @reserved;
        }

        return build_handshake(
            $reserved,
            $info_hash,
            $peer_id,
        );
    }
);

has tracker => (
    is => 'rw'
);

sub start_tracker {
    my $self = shift;
    my $tracker = Bitq::Tracker::PSGI->new(
        app   => $self,
        store => $self->store,
    );
    $tracker->start;
    $self->tracker( $tracker );

    return $tracker;
}

sub add_leecher {
    my ($self, $info_hash, $peer) = @_;
    $self->leechers->{$info_hash} = $peer;
}

sub add_peer {
    my ($self, $info_hash, $peer) = @_;
    infof "Registering new peer %s", $info_hash;
    $self->peers->{$info_hash} = $peer;
}

sub start {
    my $self = shift;

    infof "Listening to *:%s", $self->port;
    my $guard = AnyEvent::Socket::tcp_server( undef, $self->port,  sub {
        my ($fh, $host, $port) = @_;
        if (! $fh ) {
            infof "Something wrong in tcp_server";
            return;
        }

        infof "New incoming connection from $host:$port";
        Bitq::Peer->accept_handle(
            app    => $self,
            host   => $host,
            port   => $port,
            handle => AnyEvent::Handle->new(
                fh => $fh,
            ),
        );
    } );

    my $cv = AE::cv {
        undef $guard;
    };
    return $cv;
}

sub register_peer {
    my ($self, $handle, $host, $port) = @_;
    my $peer = Bitq::Peer->new(
        client  => $self,
        host    => $host,
        port    => $port,
        handle  => $handle,
    );
use feature 'state';
    state $FOO = {};
    $FOO->{$peer} = $peer;
}

sub find_torrent {
    my ($self, $info_hash) = @_;
    $self->torrents->{ $info_hash };
}

sub add_torrent {
    my ($self, $torrent) = @_;

    infof "Adding torrent with hash %s", $torrent->info_hash;
    $self->torrents->{ $torrent->info_hash } = $torrent;

    my $bitfield = $torrent->calc_bitfield( $self->work_dir );
    if ($bitfield->is_full) {
        infof "We have complete file";
        $self->store->record_completed( {
            address    => $self->host,
            port       => $self->port,
            info_hash  => $torrent->info_hash,
            peer_id    => $self->peer_id,
            tracker_id => $self->peer_id,
        } );
    }

    infof "Finished analyzing torrent $torrent";
    # after we're done, announce
    $self->announce_torrent( $torrent );
}

sub announce_torrent {
    my ($self, $torrent) = @_;

    my $uri = URI->new($torrent->announce);
    $uri->query_form( {
        port       => $self->port || 0,
        peer_id    => $self->peer_id || '',
        info_hash  => $torrent->info_hash || '',
        left       => $torrent->total_size || 0,
        uploaded   => 0,
        downloaded => 0,
        key        => "DUMMY",
        event      => "started", 
        compact    => 1,
    } );

    infof "Annoucing to tracker %s", $uri;

    http_get $uri, sub {
        my ($res, $hdrs) = @_;
        if ( $hdrs->{Status} ne 200 ) {
            local $Log::Minimal::AUTODUMP = 1;
            infof "Something wrong in request to %s: %s", $hdrs->{URL}, $hdrs;
            return;
        }

        my $reply = bdecode( $res );

        local $Log::Minimal::AUTODUMP = 1;
        infof "Tracker replied with %s", $reply;

        return unless $reply->{peers};

        my @peers = uncompact_ipv4($reply->{peers});
        infof "Got peers: %s", \@peers;
        # if we don't have everything completed, connect to peers
        foreach my $peer ( @peers ) {
            infof "Torrent incomplete. Starting a leecher peer";
            $self->start_download( $torrent, $peer );
        }
    };
}

sub schedule_scrape {
    my ($self, $url, $interval) = @_;

    $self->scrape_urls->{$url} = AE::timer 0, $interval, sub {
        my $uri = URI->new($url);
        $uri->query_form(
            # XXX 
            map { (info_hash => $_) } keys %{ $self->torrents }
        );

        http_get $uri, sub {
use Data::Dumper::Concise;
warn Dumper( bdecode $_[0] );
        };
    };
}

sub start_download {
    my ($self, $torrent, $host_port) = @_;

    my ($host, $port) = split /:/, $host_port;

    Bitq::Peer->start_download( 
        app     => $self,
        torrent => $torrent,
        host    => $host,
        port    => $port
    );
}


1;