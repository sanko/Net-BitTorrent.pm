use v5.42;
use Test2::V1 -ipP;
no warnings;
use Net::BitTorrent::Protocol::BEP03;
subtest 'Handshake' => sub {
    my $ih  = 'A' x 20;
    my $id  = 'B' x 20;
    my $pwp = Net::BitTorrent::Protocol::BEP03->new( infohash => $ih, peer_id => $id );
    is $pwp->state, 'HANDSHAKE', 'Initial state is HANDSHAKE';
    $pwp->send_handshake();
    my $out = $pwp->write_buffer;
    is length($out), 68, 'Handshake length is 68';
    my ( $len, $proto, $res, $rih, $rid ) = unpack( 'C A19 a8 a20 a20', $out );
    is $proto, 'BitTorrent protocol', 'Protocol string correct';
    is $rih,   $ih,                   'Info hash matches';
    is $rid,   $id,                   'Peer ID matches';

    # Receive a handshake
    $pwp->receive_data($out);    # Echo back the same handshake
    is $pwp->state, 'OPEN', 'State changed to OPEN after valid handshake';
};
subtest 'Messages' => sub {
    my $ih  = 'A' x 20;
    my $id  = 'B' x 20;
    my $pwp = Net::BitTorrent::Protocol::BEP03->new( infohash => $ih, peer_id => $id );
    $pwp->send_handshake();
    $pwp->receive_data( $pwp->write_buffer );    # Open it
    $pwp->send_message(Net::BitTorrent::Protocol::BEP03::CHOKE);
    my $out = $pwp->write_buffer;
    is unpack( 'N C',  $out ), 1, 'Length 1 for Choke message';
    is unpack( 'x4 C', $out ), 0, 'ID 0 for Choke';
    $pwp->send_keepalive();
    $out = $pwp->write_buffer;
    is unpack( 'N', $out ), 0, 'Keep-alive is 4 zero bytes';
};
done_testing;
