use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Net::BitTorrent::Emitter;
class Net::BitTorrent::Protocol::BEP23 v2.0.0 : isa(Net::BitTorrent::Emitter) {
    use Socket qw[inet_pton inet_ntop AF_INET];

    sub pack_peers_ipv4 (@peers) {
        my $packed = '';
        for my $peer (@peers) {

            # $peer is { ip => '...', port => ... }
            my $ip = inet_pton( AF_INET, $peer->{ip} );
            die "Invalid IPv4 address: $peer->{ip}" unless defined $ip;
            $packed .= $ip . pack( 'n', $peer->{port} );
        }
        return $packed;
    }

    sub unpack_peers_ipv4 ($data) {
        die 'Compact peer list must be a multiple of 6 bytes' if length($data) % 6 != 0;
        my @peers;
        for ( my $i = 0; $i < length($data); $i += 6 ) {
            my $chunk = substr( $data, $i, 6 );
            my ( $ip_raw, $port ) = unpack( 'a4 n', $chunk );
            push @peers, { ip => inet_ntop( AF_INET, $ip_raw ), port => $port };
        }
        return \@peers;
    }

    sub pack_peers_ipv6 (@peers) {
        use Socket qw[inet_pton AF_INET6];
        my $packed = '';
        for my $peer (@peers) {
            my $ip = inet_pton( AF_INET6, $peer->{ip} );
            die "Invalid IPv6 address: $peer->{ip}" unless defined $ip;
            $packed .= $ip . pack( 'n', $peer->{port} );
        }
        return $packed;
    }

    sub unpack_peers_ipv6 ($data) {
        use Socket qw[inet_ntop AF_INET6];
        die 'Compact IPv6 peer list must be a multiple of 18 bytes' if length($data) % 18 != 0;
        my @peers;
        for ( my $i = 0; $i < length($data); $i += 18 ) {
            my $chunk = substr( $data, $i, 18 );
            my ( $ip_raw, $port ) = unpack( 'a16 n', $chunk );
            push @peers, { ip => inet_ntop( AF_INET6, $ip_raw ), port => $port };
        }
        return \@peers;
    }
} 1;
__END__

=pod

=head1 NAME

Net::BitTorrent::Protocol::BEP23 - Compact Peer Lists (IPv4 and IPv6)

=head1 SYNOPSIS

    use Net::BitTorrent::Protocol::BEP23;

    my $packed_v4 = Net::BitTorrent::Protocol::BEP23::pack_peers_ipv4(
        { ip => '127.0.0.1', port => 6881 }
    );

    my $packed_v6 = Net::BitTorrent::Protocol::BEP23::pack_peers_ipv6(
        { ip => '::1', port => 6881 }
    );

=head1 DESCRIPTION

This module implements the compact peer list format defined in BEP 23 (IPv4) and BEP 07 (IPv6).

=head1 FUNCTIONS

=head2 pack_peers_ipv4(@peers)

Returns a binary string of packed IPv4 addresses and ports.

=head2 unpack_peers_ipv4($data)

Returns an array reference of peer hashes from a binary string.

=head2 pack_peers_ipv6(@peers)

Returns a binary string of packed IPv6 addresses and ports.

=head2 unpack_peers_ipv6($data)

Returns an array reference of peer hashes from a binary string.

=cut
