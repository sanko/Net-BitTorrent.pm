use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Net::BitTorrent::Protocol::HandshakeOnly : isa(Net::BitTorrent::Protocol::BEP03) {
    field $on_handshake_cb : param;

    method on_handshake ( $ih, $id ) {
        $on_handshake_cb->( $ih, $id );
    }
}
1;
