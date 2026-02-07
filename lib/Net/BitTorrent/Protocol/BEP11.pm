use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Net::BitTorrent::Protocol::BEP11 : isa(Net::BitTorrent::Protocol::BEP09) {
    use Net::BitTorrent::Protocol::BEP03::Bencode qw[bencode bdecode];
    use Net::BitTorrent::Protocol::BEP23;
    use Carp qw[croak];

    method send_pex ( $added = [], $dropped = [], $added6 = [], $dropped6 = [] ) {
        return unless exists $self->remote_extensions->{ut_pex};
        my $payload = {
            added   => Net::BitTorrent::Protocol::BEP23::pack_peers_ipv4(@$added),
            dropped => Net::BitTorrent::Protocol::BEP23::pack_peers_ipv4(@$dropped),
        };
        $payload->{'added.f'} = pack( 'C*', map { $_->{flags} // 0 } @$added ) if @$added;
        if ( @$added6 || @$dropped6 ) {
            $payload->{added6}     = Net::BitTorrent::Protocol::BEP23::pack_peers_ipv6(@$added6);
            $payload->{dropped6}   = Net::BitTorrent::Protocol::BEP23::pack_peers_ipv6(@$dropped6);
            $payload->{'added6.f'} = pack( 'C*', map { $_->{flags} // 0 } @$added6 ) if @$added6;
        }
        $self->send_ext_message( 'ut_pex', bencode($payload) );
    }

    method on_extended_message ( $name, $payload ) {
        if ( $name eq 'ut_pex' ) {
            my $dict;
            eval {
                my @res = bdecode( $payload, 1 );
                if ( @res > 2 ) {
                    pop @res;    # Discard leftover
                    $dict = {@res};
                }
                else {
                    $dict = $res[0];
                }
            };
            if ( $@ || ref $dict ne 'HASH' ) {
                warn "  [ERROR] Malformed ut_pex message: $@\n";
                return;
            }
            my $added    = Net::BitTorrent::Protocol::BEP23::unpack_peers_ipv4( $dict->{added}   // '' );
            my $dropped  = Net::BitTorrent::Protocol::BEP23::unpack_peers_ipv4( $dict->{dropped} // '' );
            my $added6   = $dict->{added6}   ? Net::BitTorrent::Protocol::BEP23::unpack_peers_ipv6( $dict->{added6} )   : [];
            my $dropped6 = $dict->{dropped6} ? Net::BitTorrent::Protocol::BEP23::unpack_peers_ipv6( $dict->{dropped6} ) : [];

            # Extract flags if present
            if ( $dict->{'added.f'} ) {
                my @flags = unpack( 'C*', $dict->{'added.f'} );
                for my $i ( 0 .. $#$added ) {
                    $added->[$i]{flags} = $flags[$i] if defined $flags[$i];
                }
            }
            if ( $dict->{'added6.f'} ) {
                my @flags = unpack( 'C*', $dict->{'added6.f'} );
                for my $i ( 0 .. $#$added6 ) {
                    $added6->[$i]{flags} = $flags[$i] if defined $flags[$i];
                }
            }
            $self->on_pex( $added, $dropped, $added6, $dropped6 );
        }
        else {
            $self->SUPER::on_extended_message( $name, $payload );
        }
    }
    method on_pex ( $added, $dropped, $added6, $dropped6 ) { }
}
1;
__END__

=pod

=head1 NAME

Net::BitTorrent::Protocol::BEP11 - Peer Exchange (PEX) Implementation

=head1 DESCRIPTION

This module implements the Peer Exchange extension (BEP 11), allowing peers  to exchange lists of known peers in a
swarm. It supports both IPv4 and IPv6.

=head1 METHODS

=head2 send_pex($added, $dropped, $added6, $dropped6)

Sends a PEX message. Each argument is an array reference of peer hashes  (C<{ ip =E<gt> ..., port =E<gt> ... }>).

=head2 on_pex($added, $dropped, $added6, $dropped6)

Callback triggered when a PEX message is received.

=cut
