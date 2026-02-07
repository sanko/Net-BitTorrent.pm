use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Net::BitTorrent::Protocol::BEP09 v2.0.0 : isa(Net::BitTorrent::Protocol::BEP10) {
    use Net::BitTorrent::Protocol::BEP03::Bencode qw[bencode bdecode];

    # BEP 09 Message Types
    use constant { METADATA_REQUEST => 0, METADATA_DATA => 1, METADATA_REJECT => 2 };

    method send_metadata_request ($piece) {
        return unless exists $self->remote_extensions->{ut_metadata};
        $self->_emit( debug => 'Sending metadata request for piece ' . $piece );
        my $payload = bencode( { msg_type => METADATA_REQUEST, piece => $piece, } );
        $self->send_ext_message( ut_metadata => $payload );
    }

    method send_metadata_data ( $piece, $total_size, $data ) {
        return unless exists $self->remote_extensions->{ut_metadata};
        my $header = bencode( { msg_type => METADATA_DATA, piece => $piece, total_size => $total_size, } );
        $self->send_ext_message( ut_metadata => $header . $data );
    }

    method send_metadata_reject ($piece) {
        return unless exists $self->remote_extensions->{ut_metadata};
        my $payload = bencode( { msg_type => METADATA_REJECT, piece => $piece, } );
        $self->send_ext_message( ut_metadata => $payload );
    }

    method on_extended_message ( $name, $payload ) {
        if ( $name eq 'ut_metadata' ) {
            my ( $dict, $remaining );
            eval {
                my @res = bdecode( $payload, 1 );
                if ( ref $res[0] eq 'HASH' ) {
                    ( $dict, $remaining ) = @res;
                }
                elsif ( @res % 2 == 0 ) {    # It's a list of keys and values + leftover? No, that would be odd.

                    # Wait, if it returned a list of KV pairs + leftover, total elements is odd.
                    $remaining = pop @res;
                    $dict      = {@res};
                }
                else {                       # Odd number of elements: KV pairs + leftover
                    $remaining = pop @res;
                    $dict      = {@res};
                }
            };
            if ( $@ || ref $dict ne 'HASH' ) {
                $self->_emit( debug => 'Malformed ut_metadata message: ' . $@ );
                return;
            }
            my $type = $dict->{msg_type};
            if ( !defined $type ) {
                $self->_emit( debug => 'ut_metadata message missing msg_type' );
                return;
            }
            if ( $type == METADATA_REQUEST ) {
                $self->on_metadata_request( $dict->{piece} );
            }
            elsif ( $type == METADATA_DATA ) {
                $self->_emit( debug => "Received metadata data for piece $dict->{piece} (len " . length($remaining) . ')' );
                $self->on_metadata_data( $dict->{piece}, $dict->{total_size}, $remaining );
            }
            elsif ( $type == METADATA_REJECT ) {
                $self->on_metadata_reject( $dict->{piece} );
            }
            else {
                $self->_emit( debug => 'Unknown ut_metadata msg_type: ' . $type );
            }
        }
        else {
            $self->SUPER::on_extended_message( $name, $payload );
        }
    }

    # Overridable callbacks
    method on_metadata_request ($piece)                       { }
    method on_metadata_data    ( $piece, $total_size, $data ) { }
    method on_metadata_reject  ($piece)                       { }
};
#
1;
