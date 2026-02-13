use v5.40;
use feature 'class', 'try';
no warnings 'experimental::class', 'experimental::try';
class Net::BitTorrent::Protocol::BEP11 v2.0.0 : isa(Net::BitTorrent::Protocol::BEP09) {
    use Net::BitTorrent::Protocol::BEP03::Bencode qw[bencode bdecode];
    use Net::BitTorrent::Protocol::BEP23;
    ADJUST {
        $self->on(
            extended_message => sub ( $self, $name, $payload ) {
                return unless $name eq 'ut_pex';
                my $dict;
                try {
                    my @res = bdecode( $payload, 1 );
                    if ( @res > 2 ) {
                        pop @res;    # Discard leftover
                        $dict = {@res};
                    }
                    else {
                        $dict = $res[0];
                    }
                }
                catch ($e) {
                    $self->_emit( log => "  [ERROR] Malformed ut_pex message: $e\n", level => 'error' );
                    return;
                }
                if ( ref $dict ne 'HASH' ) {
                    $self->_emit( log => "  [ERROR] Malformed ut_pex message: dict is not a hash\n", level => 'error' );
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
                $self->_emit( pex => $added, $dropped, $added6, $dropped6 );
            }
        );
    }

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
} 1;
