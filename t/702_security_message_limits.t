use v5.40;
use feature 'class', 'try';
use Test2::V1 -ipP;
no warnings;
#
# CVE-2026-57080
#
use lib 'lib', '../lib';
use Digest::SHA qw[sha1];
use Path::Tiny;
use Net::BitTorrent::Protocol::BEP03::Bencode qw[bencode];
use Net::BitTorrent::Protocol::BEP03;
#
ok defined Net::BitTorrent::Protocol::BEP03::MAX_MESSAGE_SIZE(),             'MAX_MESSAGE_SIZE is defined';
ok Net::BitTorrent::Protocol::BEP03::MAX_MESSAGE_SIZE() > 0,                 'MAX_MESSAGE_SIZE is positive';
ok Net::BitTorrent::Protocol::BEP03::MAX_MESSAGE_SIZE() <= 64 * 1024 * 1024, 'MAX_MESSAGE_SIZE <= 64 MiB';
#
# Helper: build a valid v1 handshake for given infohash + peer_id
sub _handshake ( $ih, $pid ) {
    pack( 'C A19 a8', 19, 'BitTorrent protocol', "\0" x 8 ) . $ih . $pid;
}
#
subtest 'Normal message accepted after handshake' => sub {
    require Net::BitTorrent::Protocol::BEP03;
    my $p = Net::BitTorrent::Protocol::BEP03->new( infohash => 'A' x 20, peer_id => 'B' x 20 );
    is $p->state, 'HANDSHAKE', 'initial state is HANDSHAKE';
    $p->receive_data( _handshake( 'A' x 20, 'C' x 20 ) );
    is $p->state, 'OPEN', 'state is OPEN after valid handshake';
    $p->receive_data( pack( 'N', 0 ) );
    is $p->state, 'OPEN', 'keep-alive processed without closing';
    $p->receive_data( pack( 'N C', 1, 0 ) );
    is $p->state, 'OPEN', 'CHOKE message (1 byte) accepted';
    $p->receive_data( pack( 'N C', 5, 0 ) . "\x01" );
    is $p->state, 'OPEN', 'BITFIELD message (2 bytes) accepted';
};
#
subtest 'Oversized message rejected with fatal die' => sub {
    require Net::BitTorrent::Protocol::BEP03;
    my $p = Net::BitTorrent::Protocol::BEP03->new( infohash => 'A' x 20, peer_id => 'B' x 20 );
    $p->receive_data( _handshake( 'A' x 20, 'C' x 20 ) );
    is $p->state, 'OPEN', 'handshake complete';
    my $oversize = Net::BitTorrent::Protocol::BEP03::MAX_MESSAGE_SIZE() + 1;
    my $died     = 0;
    try { $p->receive_data( pack( 'N', $oversize ) . pack( 'C', 6 ) ) }
    catch ($e) { $died = 1 };
    ok $died, 'oversized message triggers fatal die';
    is $p->state, 'CLOSED', 'state is CLOSED after oversized message';
};
#
subtest 'MAX_MESSAGE_SIZE + 1 rejected' => sub {
    require Net::BitTorrent::Protocol::BEP03;
    my $p = Net::BitTorrent::Protocol::BEP03->new( infohash => 'A' x 20, peer_id => 'B' x 20 );
    $p->receive_data( _handshake( 'A' x 20, 'C' x 20 ) );
    my $boundary = Net::BitTorrent::Protocol::BEP03::MAX_MESSAGE_SIZE() + 1;
    my $died     = 0;
    try { $p->receive_data( pack( 'N', $boundary ) ) }
    catch ($e) { $died = 1 };
    ok $died, 'MAX_MESSAGE_SIZE + 1 is rejected';
};
#
subtest 'Invalid handshake rejected' => sub {
    require Net::BitTorrent::Protocol::BEP03;
    my $p    = Net::BitTorrent::Protocol::BEP03->new( infohash => 'A' x 20, peer_id => 'B' x 20 );
    my $died = 0;
    try { $p->receive_data( pack( 'N', 0 ) ) }
    catch ($e) { $died = 1 };
    ok $died, 'invalid handshake (pstrlen=0) triggers fatal die';
    is $p->state, 'CLOSED', 'state is CLOSED after invalid handshake';
};
#
done_testing;
