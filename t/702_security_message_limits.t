use v5.40;
use feature 'class', 'try';
use Test2::V1 -ipP;
no warnings;
#
# CVE-2026-57080
#
use lib 'lib', '../lib';
use Net::BitTorrent;
use Digest::SHA qw[sha1 sha256];
use Path::Tiny;
use Net::BitTorrent::Protocol::BEP03::Bencode qw[bencode];
use Net::BitTorrent::Protocol::BEP03;
use Errno;
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
class MockTransport2 {
    field $sent = '';
    field %on;
    method on ( $e, $cb ) { push $on{$e}->@*, $cb }

    method emit ( $e, @args ) {
        for my $cb ( $on{$e}->@* ) { $cb->(@args) }
    }
    method send_data ($d) { $sent .= $d; return length $d }
    field $filter : reader = undef;
    method set_filter ($f) { $filter = $f }
    method pop_buffer () { my $t = $sent; $sent = ''; return $t }
}
subtest 'HAVE out-of-range index rejected (reputation penalty)' => sub {
    my $temp   = Path::Tiny->tempdir;
    my $client = Net::BitTorrent->new();
    my $ih     = 'H' x 20;
    my $data   = 'X' x 16384;
    my $info   = {
        name           => 'test.txt',
        'piece length' => 16384,
        pieces         => sha1($data),
        'file tree'    => { 'test.txt' => { '' => { length => 16384, 'pieces root' => sha256($data) } } },
    };
    require Net::BitTorrent::Protocol::BEP03::Bencode;
    my $torrent_file = $temp->child('test.torrent');
    $torrent_file->spew_raw( Net::BitTorrent::Protocol::BEP03::Bencode::bencode( { info => $info } ) );
    my $torrent = $client->add_torrent( $torrent_file, $temp );
    $torrent->start();
    require Net::BitTorrent::Protocol::PeerHandler;
    require Net::BitTorrent::Peer;
    my $ph        = Net::BitTorrent::Protocol::PeerHandler->new( infohash => $ih, peer_id => 'PEER' . '0' x 16, features => { bep11 => 0 } );
    my $transport = MockTransport2->new();
    my $peer
        = Net::BitTorrent::Peer->new( protocol => $ph, torrent => $torrent, transport => $transport, ip => '5.5.5.5', port => 5555, encryption => 0 );
    $ph->set_peer($peer);
    $torrent->register_peer_object($peer);

    # Send valid HAVE first (index 0 exists)
    $peer->handle_message( 4, pack( 'N', 0 ) );
    my $rep_after_valid = $peer->reputation;

    # Send HAVE with index way beyond num_pieces
    $peer->handle_message( 4, pack( 'N', 999 ) );
    ok $peer->reputation < $rep_after_valid, 'HAVE with out-of-range index lowered reputation';
};
subtest 'REQUEST with out-of-range index silently rejected' => sub {
    my $temp   = Path::Tiny->tempdir;
    my $client = Net::BitTorrent->new();
    my $data   = 'Y' x 16384;
    my $info   = {
        name           => 'test2.txt',
        'piece length' => 16384,
        pieces         => sha1($data),
        'file tree'    => { 'test2.txt' => { '' => { length => 16384, 'pieces root' => sha256($data) } } },
    };
    require Net::BitTorrent::Protocol::BEP03::Bencode;
    my $torrent_file = $temp->child('test2.torrent');
    $torrent_file->spew_raw( Net::BitTorrent::Protocol::BEP03::Bencode::bencode( { info => $info } ) );
    my $client2 = Net::BitTorrent->new();
    my $torrent = $client2->add_torrent( $torrent_file, $temp );
    $torrent->start();
    require Net::BitTorrent::Protocol::PeerHandler;
    require Net::BitTorrent::Peer;
    my $ih   = 'R' x 20;
    my $ph   = Net::BitTorrent::Protocol::PeerHandler->new( infohash => $ih, peer_id => 'PEER2' . '0' x 15, features => { bep11 => 0 } );
    my $tr   = MockTransport2->new();
    my $peer = Net::BitTorrent::Peer->new( protocol => $ph, torrent => $torrent, transport => $tr, ip => '6.6.6.6', port => 6666, encryption => 0 );
    $ph->set_peer($peer);
    $torrent->register_peer_object($peer);

    # REQUEST with out-of-range index should not die
    my $ok = eval { $peer->handle_message( 6, pack( 'N N N', 999, 0, 16384 ) ); 1 };
    ok $ok, 'REQUEST with out-of-range index did not die';
};
subtest 'REQUEST with len=0 silently rejected' => sub {
    my $temp   = Path::Tiny->tempdir;
    my $client = Net::BitTorrent->new();
    my $data   = 'Z' x 16384;
    my $info   = {
        name           => 'test3.txt',
        'piece length' => 16384,
        pieces         => sha1($data),
        'file tree'    => { 'test3.txt' => { '' => { length => 16384, 'pieces root' => sha256($data) } } },
    };
    require Net::BitTorrent::Protocol::BEP03::Bencode;
    my $torrent_file = $temp->child('test3.torrent');
    $torrent_file->spew_raw( Net::BitTorrent::Protocol::BEP03::Bencode::bencode( { info => $info } ) );
    my $client3 = Net::BitTorrent->new();
    my $torrent = $client3->add_torrent( $torrent_file, $temp );
    $torrent->start();
    require Net::BitTorrent::Protocol::PeerHandler;
    require Net::BitTorrent::Peer;
    my $ih   = 'S' x 20;
    my $ph   = Net::BitTorrent::Protocol::PeerHandler->new( infohash => $ih, peer_id => 'PEER3' . '0' x 15, features => { bep11 => 0 } );
    my $tr   = MockTransport2->new();
    my $peer = Net::BitTorrent::Peer->new( protocol => $ph, torrent => $torrent, transport => $tr, ip => '7.7.7.7', port => 7777, encryption => 0 );
    $ph->set_peer($peer);
    $torrent->register_peer_object($peer);

    # len=0
    my $ok = eval { $peer->handle_message( 6, pack( 'N N N', 0, 0, 0 ) ); 1 };
    ok $ok, 'REQUEST with len=0 did not die';

    # len > 131072 (128 KiB)
    $ok = eval { $peer->handle_message( 6, pack( 'N N N', 0, 0, 131073 ) ); 1 };
    ok $ok, 'REQUEST with len=131073 did not die';
};
subtest 'REQUEST beyond piece boundary silently rejected' => sub {
    my $temp   = Path::Tiny->tempdir;
    my $client = Net::BitTorrent->new();
    my $data   = 'W' x 16384;
    my $info   = {
        name           => 'test4.txt',
        'piece length' => 16384,
        pieces         => sha1($data),
        'file tree'    => { 'test4.txt' => { '' => { length => 16384, 'pieces root' => sha256($data) } } }
    };
    require Net::BitTorrent::Protocol::BEP03::Bencode;
    my $torrent_file = $temp->child('test4.torrent');
    $torrent_file->spew_raw( Net::BitTorrent::Protocol::BEP03::Bencode::bencode( { info => $info } ) );
    my $client4 = Net::BitTorrent->new();
    my $torrent = $client4->add_torrent( $torrent_file, $temp );
    $torrent->start();
    require Net::BitTorrent::Protocol::PeerHandler;
    require Net::BitTorrent::Peer;
    my $ih   = 'T' x 20;
    my $ph   = Net::BitTorrent::Protocol::PeerHandler->new( infohash => $ih, peer_id => 'PEER4' . '0' x 15, features => { bep11 => 0 } );
    my $tr   = MockTransport2->new();
    my $peer = Net::BitTorrent::Peer->new( protocol => $ph, torrent => $torrent, transport => $tr, ip => '8.8.8.8', port => 8888, encryption => 0 );
    $ph->set_peer($peer);
    $torrent->register_peer_object($peer);

    # begin + len > piece_length (16384)
    my $ok = eval { $peer->handle_message( 6, pack( 'N N N', 0, 16000, 400 ) ); 1 };
    ok $ok, 'REQUEST extending beyond piece boundary did not die';
};
#
sub _make_peer_for_payload ($ih) {
    my $temp   = Path::Tiny->tempdir;
    my $client = Net::BitTorrent->new();
    my $data   = 'P' x 16384;
    my $info   = {
        name           => 'payload_test.txt',
        'piece length' => 16384,
        pieces         => sha1($data),
        'file tree'    => { 'payload_test.txt' => { '' => { length => 16384, 'pieces root' => sha256($data) } } }
    };
    my $torrent_file = $temp->child('test.torrent');
    $torrent_file->spew_raw( bencode( { info => $info } ) );
    my $torrent = $client->add_torrent( $torrent_file, $temp );
    $torrent->start();
    require Net::BitTorrent::Protocol::PeerHandler;
    require Net::BitTorrent::Peer;
    my $ph   = Net::BitTorrent::Protocol::PeerHandler->new( infohash => $ih, peer_id => 'PEER' . '0' x 16, features => { bep11 => 0 } );
    my $tr   = MockTransport2->new();
    my $peer = Net::BitTorrent::Peer->new( protocol => $ph, torrent => $torrent, transport => $tr, ip => '9.9.9.9', port => 9999, encryption => 0 );
    $ph->set_peer($peer);
    $torrent->register_peer_object($peer);
    return $peer;
}
#
subtest 'CHOKE with non-zero payload rejected' => sub {
    my $peer = _make_peer_for_payload( 'C' x 20 );
    my $rep  = $peer->reputation;
    $peer->handle_message( 0, pack( 'C', 0 ) );
    ok $peer->reputation < $rep, 'reputation lowered for CHOKE with wrong payload length';
};
#
subtest 'UNCHOKE with non-zero payload rejected' => sub {
    my $peer = _make_peer_for_payload( 'U' x 20 );
    my $rep  = $peer->reputation;
    $peer->handle_message( 1, pack( 'N', 0 ) );
    ok $peer->reputation < $rep, 'reputation lowered for UNCHOKE with wrong payload length';
};
#
subtest 'INTERESTED with non-zero payload rejected' => sub {
    my $peer = _make_peer_for_payload( 'I' x 20 );
    my $rep  = $peer->reputation;
    $peer->handle_message( 2, "\x00" );
    ok $peer->reputation < $rep, 'reputation lowered for INTERESTED with wrong payload length';
};
#
subtest 'HAVE with wrong length rejected' => sub {
    my $peer = _make_peer_for_payload( 'H' x 20 );
    my $rep  = $peer->reputation;
    $peer->handle_message( 4, pack( 'N', 0 ) . "\x00" );
    ok $peer->reputation < $rep, 'reputation lowered for HAVE with 5-byte payload';
};
#
subtest 'HAVE with correct length accepted' => sub {
    my $peer = _make_peer_for_payload( 'J' x 20 );
    my $rep  = $peer->reputation;
    $peer->handle_message( 4, pack( 'N', 0 ) );
    is $peer->reputation, $rep, 'reputation unchanged for valid HAVE';
};
#
subtest 'REQUEST with wrong length rejected' => sub {
    my $peer = _make_peer_for_payload( 'R' x 20 );
    my $rep  = $peer->reputation;
    $peer->handle_message( 6, pack( 'N N', 0, 0 ) );
    ok $peer->reputation < $rep, 'reputation lowered for REQUEST with 8-byte payload';
};
#
subtest 'REQUEST with correct length accepted (even if out-of-range)' => sub {
    my $peer = _make_peer_for_payload( 'S' x 20 );
    my $ok   = eval { $peer->handle_message( 6, pack( 'N N N', 999, 0, 16384 ) ); 1 };
    ok $ok, 'REQUEST with valid length did not die';
};
#
subtest 'PIECE with too-short payload rejected' => sub {
    my $peer = _make_peer_for_payload( 'D' x 20 );
    my $rep  = $peer->reputation;
    $peer->handle_message( 7, pack( 'N', 0 ) );
    ok $peer->reputation < $rep, 'reputation lowered for PIECE with 4-byte payload';
};
#
subtest 'REJECT with wrong length rejected' => sub {
    my $peer = _make_peer_for_payload( 'X' x 20 );
    my $rep  = $peer->reputation;
    $peer->handle_message( 16, pack( 'N', 0 ) );
    ok $peer->reputation < $rep, 'reputation lowered for REJECT with 4-byte payload';
};
#
subtest 'SUGGEST_PIECE with wrong length rejected' => sub {
    my $peer = _make_peer_for_payload( 'G' x 20 );
    my $rep  = $peer->reputation;
    $peer->handle_message( 13, '' );
    ok $peer->reputation < $rep, 'reputation lowered for SUGGEST_PIECE with 0-byte payload';
};
#
subtest 'ALLOWED_FAST with wrong length rejected' => sub {
    my $peer = _make_peer_for_payload( 'F' x 20 );
    my $rep  = $peer->reputation;
    $peer->handle_message( 17, pack( 'N N', 0, 0 ) );
    ok $peer->reputation < $rep, 'reputation lowered for ALLOWED_FAST with 8-byte payload';
};
#
subtest 'HAVE_ALL with non-zero payload rejected' => sub {
    my $peer = _make_peer_for_payload( 'A' x 20 );
    my $rep  = $peer->reputation;
    $peer->handle_message( 14, "\x00" );
    ok $peer->reputation < $rep, 'reputation lowered for HAVE_ALL with 1-byte payload';
};
#
subtest 'HAVE_NONE with non-zero payload rejected' => sub {
    my $peer = _make_peer_for_payload( 'N' x 20 );
    my $rep  = $peer->reputation;
    $peer->handle_message( 15, pack( 'N', 0 ) );
    ok $peer->reputation < $rep, 'reputation lowered for HAVE_NONE with 4-byte payload';
};
#
subtest 'Unknown message type passes through (no crash)' => sub {
    my $peer = _make_peer_for_payload( 'Z' x 20 );
    my $ok   = eval { $peer->handle_message( 99, "some data" ); 1 };
    ok $ok, 'unknown message type did not die';
};
#
class MockSocketNoDrain {
    field $written = '';
    method syswrite   { return undef }
    method peerhost   {'1.2.3.4'}
    method peerport   {12345}
    method opened     {1}
    method blocking   {1}
    method getsockopt { return Errno::EWOULDBLOCK() }
}
#
class MockSocketDrain {
    field $written = '';

    method syswrite ($data) {
        $written .= $data;
        return length $data;
    }
    method peerhost   {'1.2.3.4'}
    method peerport   {12345}
    method opened     {1}
    method blocking   {1}
    method getsockopt {0}
}
#
subtest 'Write buffer cap disconnects slow peer' => sub {
    require Net::BitTorrent::Transport::TCP;
    my $sock2      = MockSocketNoDrain->new();
    my $transport2 = Net::BitTorrent::Transport::TCP->new( socket => $sock2, connecting => 0 );
    my $disc2      = 0;
    $transport2->on( 'disconnected', sub { $disc2 = 1 } );
    my $chunk = 'X' x 65536;
    for ( 1 .. 80 ) {
        $transport2->send_data($chunk);
        last if $disc2;
    }
    ok $disc2, 'disconnected fired when write buffer exceeded cap';
};
#
subtest 'Write buffer within cap does not disconnect' => sub {
    require Net::BitTorrent::Transport::TCP;
    my $sock      = MockSocketDrain->new();
    my $transport = Net::BitTorrent::Transport::TCP->new( socket => $sock, connecting => 0 );
    my $disc      = 0;
    $transport->on( 'disconnected', sub { $disc = 1 } );
    $transport->send_data( 'Y' x 102400 );
    ok !$disc, 'no disconnect when write buffer is within cap';
};
#
done_testing;
