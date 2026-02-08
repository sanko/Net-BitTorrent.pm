use v5.42;
use feature 'class';
use Test2::V1 -ipP;
no warnings;
use lib 'lib';
use Net::BitTorrent;
use Net::BitTorrent::Peer;
use Net::BitTorrent::Protocol::PeerHandler;
use Net::BitTorrent::Protocol::BEP03::Bencode qw[bencode];
use Path::Tiny;
use Digest::SHA qw[sha1];
use Net::BitTorrent::Emitter;
use Net::BitTorrent::Types;

class MockTransport : isa(Net::BitTorrent::Emitter) {
    field $buffer = '';
    method send_data ($d) { $buffer .= $d; return length $d }
    field $filter : reader = undef;
    method set_filter ($f) { $filter = $f }
    method pop_buffer () { my $tmp = $buffer; $buffer = ''; return $tmp }
    method close ()  { }
    method socket () { return undef }
}
subtest 'Full Stack Verification' => sub {
    my $temp         = Path::Tiny->tempdir;
    my $pieces_root  = pack( 'H*', '1bd4db450abc8914c2fac721cace2704ff4c16028e6d07293154dad289835694' );
    my $data         = 'A' x 16384;
    my $torrent_file = $temp->child('test.torrent');
    $torrent_file->spew_raw(
        bencode(
            {   info => {
                    name           => 'test',
                    'piece length' => 16384,
                    'pieces'       => sha1($data),
                    'file tree'    => { 'test.bin' => { '' => { length => 16384, 'pieces root' => $pieces_root } } }
                }
            }
        )
    );
    my $seeder_dir = $temp->child('seeder');
    my $client_s   = Net::BitTorrent->new();
    my $t_s        = $client_s->add( $torrent_file, $seeder_dir );
    $seeder_dir->mkpath;
    $seeder_dir->child('test.bin')->spew_raw($data);
    $t_s->bitfield->set(0);
    my $leecher_dir = $temp->child('leecher');
    my $client_l    = Net::BitTorrent->new();
    my $t_l         = $client_l->add( $torrent_file, $leecher_dir );
    $t_s->start();
    $t_l->start();
    my $ih      = $t_s->infohash_v2 || $t_s->infohash_v1;
    my $p_s     = Net::BitTorrent::Protocol::PeerHandler->new( infohash => $ih, peer_id => 'S' x 20, features => $t_s->features );
    my $p_l     = Net::BitTorrent::Protocol::PeerHandler->new( infohash => $ih, peer_id => 'L' x 20, features => $t_l->features );
    my $trans_s = MockTransport->new();
    my $trans_l = MockTransport->new();
    my $peer_s  = Net::BitTorrent::Peer->new(
        protocol   => $p_s,
        torrent    => $t_s,
        transport  => $trans_s,
        ip         => '1.1.1.1',
        port       => 1111,
        encryption => ENCRYPTION_NONE
    );
    my $peer_l = Net::BitTorrent::Peer->new(
        protocol   => $p_l,
        torrent    => $t_l,
        transport  => $trans_l,
        ip         => '2.2.2.2',
        port       => 2222,
        encryption => ENCRYPTION_NONE
    );
    $t_s->register_peer_object($peer_s);
    $t_l->register_peer_object($peer_l);

    # 4. Exchange
    my $exchange = sub {
        my $moved = 0;
        while (1) {
            my $local_moved = 0;
            $peer_l->write_buffer();
            if ( my $raw = $trans_l->pop_buffer ) {
                $peer_s->receive_data($raw);
                $local_moved++;
            }
            $peer_s->write_buffer();
            if ( my $raw = $trans_s->pop_buffer ) {
                $peer_l->receive_data($raw);
                $local_moved++;
            }
            last unless $local_moved;
            $moved += $local_moved;
        }
        $client_s->tick(0.1);
        $client_l->tick(0.1);
        return $moved;
    };

    # Handshake
    $trans_s->_emit('connected');
    $trans_l->_emit('connected');
    my $handshake_iter = 10;
    while ( ( $p_s->state ne 'OPEN' || $p_l->state ne 'OPEN' ) && $handshake_iter-- ) {
        $exchange->();
    }
    is $p_s->state, 'OPEN', 'Seeder state OPEN';
    is $p_l->state, 'OPEN', 'Leecher state OPEN';

    # Seeder unchokes and announces
    $p_s->send_message( 5, $t_s->bitfield->data );
    $peer_s->unchoke();
    my $max_iter = 100;
    while ( !$t_l->bitfield->get(0) && $max_iter-- ) {
        $exchange->();
    }
    $t_l->storage->explicit_flush();
    my $leecher_file = $leecher_dir->child('test.bin');
    ok $leecher_file->exists, 'Leecher file created on disk';
    is $leecher_file->slurp_raw, $data, 'Leecher file content is correct';
    ok $t_l->bitfield->get(0), 'Leecher bitfield updated';
};
done_testing;
