use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Net::BitTorrent::Protocol::BEP23 v2.0.0 {
    use Socket qw[inet_aton inet_ntoa];
    use Carp qw[croak];

    sub pack_peers_ipv4 (@peers) {
        my $packed = '';
        for my $peer (@peers) {

            # $peer is { ip => '...', port => ... }
            my $ip = inet_aton( $peer->{ip} );
            croak "Invalid IPv4 address: $peer->{ip}" unless defined $ip;
            $packed .= $ip . pack( 'n', $peer->{port} );
        }
        $packed;
    }

    sub unpack_peers_ipv4 ($data) {
        croak 'Compact peer list must be a multiple of 6 bytes' if length($data) % 6 != 0;
        my @peers;
        for ( my $i = 0; $i < length($data); $i += 6 ) {
            my $chunk = substr( $data, $i, 6 );
            my ( $ip_raw, $port ) = unpack( 'a4 n', $chunk );
            push @peers, { ip => inet_ntoa($ip_raw), port => $port };
        }
        \@peers;
    }

    sub pack_peers_ipv6 (@peers) {
        use Socket qw[inet_pton AF_INET6];
        my $packed = '';
        for my $peer (@peers) {
            my $ip = inet_pton( AF_INET6, $peer->{ip} );
            croak "Invalid IPv6 address: $peer->{ip}" unless defined $ip;
            $packed .= $ip . pack( 'n', $peer->{port} );
        }
        $packed;
    }

    sub unpack_peers_ipv6 ($data) {
        use Socket qw[inet_ntop AF_INET6];
        croak 'Compact IPv6 peer list must be a multiple of 18 bytes' if length($data) % 18 != 0;
        my @peers;
        for ( my $i = 0; $i < length($data); $i += 18 ) {
            my $chunk = substr( $data, $i, 18 );
            my ( $ip_raw, $port ) = unpack( 'a16 n', $chunk );
            push @peers, { ip => inet_ntop( AF_INET6, $ip_raw ), port => $port };
        }
        \@peers;
    }
};
#
1;
