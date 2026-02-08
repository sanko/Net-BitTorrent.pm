use v5.42;
use feature 'class';
use Test2::V1 -ipP;
no warnings;
use Net::BitTorrent::Protocol::PeerHandler;

class MockBEP06 : isa(Net::BitTorrent::Protocol::PeerHandler) {
    field $got_all   : reader = 0;
    field $got_none  : reader = 0;
    field $suggested : reader;
    method on_have_all ()    { $got_all   = 1 }
    method on_have_none ()   { $got_none  = 1 }
    method on_suggest ($idx) { $suggested = $idx }
}
subtest 'Fast Extension Messages' => sub {
    my $pwp = MockBEP06->new( infohash => 'A' x 20, peer_id => 'B' x 20 );

    # Check bits in the reserved bytes
    # byte 7: 0x04 (Fast) | 0x01 (DHT) = 0x05
    my $res = $pwp->reserved;
    is ord( substr( $res, 7, 1 ) ) & 0x05, 0x05, 'Fast and DHT bits set in reserved bytes';
    is ord( substr( $res, 5, 1 ) ) & 0x10, 0x10, 'Extension Protocol bit set in reserved bytes';

    # Complete handshake to enter OPEN state
    $pwp->send_handshake();
    my $handshake = $pwp->write_buffer;
    $pwp->receive_data($handshake);
    is $pwp->state, 'OPEN', 'State is OPEN';

    # Receive HAVE_ALL (ID 14)
    $pwp->receive_data( pack( 'N C', 1, 14 ) );
    ok $pwp->got_all, 'Received HAVE_ALL';

    # Receive SUGGEST (ID 13)
    $pwp->receive_data( pack( 'N C N', 5, 13, 123 ) );
    is $pwp->suggested, 123, 'Received SUGGEST for piece 123';
};
#
done_testing;
