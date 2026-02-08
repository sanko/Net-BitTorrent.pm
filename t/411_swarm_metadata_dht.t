use v5.40;
use feature 'class', 'try';
no warnings 'experimental::class', 'experimental::try';
use Test2::V1 -ipP;
no warnings;
use lib 'lib', '../lib';
use Net::BitTorrent;
use Net::BitTorrent::Peer;
use Net::BitTorrent::Protocol::PeerHandler;
use Net::BitTorrent::Protocol::BEP03::Bencode qw[bencode];
use Net::BitTorrent::Types;
use Path::Tiny;
use Digest::SHA qw[sha1];

class MockTransport : isa(Net::BitTorrent::Emitter) {
    field $ip   : param : reader;
    field $port : param : reader;
    field $buffer = '';
    field $name : param : reader;

    method send_data ($d) {
        $buffer .= $d;
        return length $d;
    }
    field $filter : reader = undef;
    method set_filter ($f) { $filter = $f }
    method pop_buffer () { my $tmp = $buffer; $buffer = ''; return $tmp }
    method close ()  { }
    method socket () { return undef }
}
subtest 'Metadata Exchange' => sub {
    my $temp = Path::Tiny->tempdir;
    my $data = 'A' x 16384;
    my $info = { name => 'test_metadata', 'piece length' => 16384, pieces => sha1($data), length => length($data), };
    my $ih   = sha1( bencode($info) );

    # 1. Seeder with full metadata and data
    my $seeder_dir = $temp->child('seeder');
    $seeder_dir->mkpath;
    $seeder_dir->child('test_metadata')->spew_raw($data);
    my $torrent_file = $temp->child('test.torrent');
    $torrent_file->spew_raw( bencode( { info => $info } ) );
    my $client_s = Net::BitTorrent->new( debug => 0, bep05 => 0, upnp_enabled => 0 );
    my $t_s      = $client_s->add( $torrent_file, $seeder_dir );
    $t_s->bitfield->set(0);
    $t_s->start();

    # 2. Leecher with only infohash
    my $leecher_dir = $temp->child('leecher');
    $leecher_dir->mkpath;
    my $client_l = Net::BitTorrent->new( debug => 0, bep05 => 0, upnp_enabled => 0 );
    my $t_l      = $client_l->add( 'magnet:?xt=urn:btih:' . unpack( 'H*', $ih ), $leecher_dir );
    $t_l->start();
    is $t_l->state, STATE_METADATA, 'Leecher starts in METADATA state';

    # 3. Connections
    my $trans_s = MockTransport->new( ip => '1.1.1.1', port => 1111, name => 'S' );
    my $trans_l = MockTransport->new( ip => '2.2.2.2', port => 2222, name => 'L' );
    my $p_s     = Net::BitTorrent::Protocol::PeerHandler->new(
        infohash      => $ih,
        peer_id       => 'S' x 20,
        features      => $client_s->features,
        debug         => 0,
        metadata_size => length( bencode($info) )
    );
    my $p_l    = Net::BitTorrent::Protocol::PeerHandler->new( infohash => $ih, peer_id => 'L' x 20, features => $client_l->features, debug => 0 );
    my $peer_s = Net::BitTorrent::Peer->new(
        protocol   => $p_s,
        torrent    => $t_s,
        transport  => $trans_s,
        ip         => '1.1.1.1',
        port       => 1111,
        debug      => 0,
        encryption => ENCRYPTION_NONE
    );
    my $peer_l = Net::BitTorrent::Peer->new(
        protocol   => $p_l,
        torrent    => $t_l,
        transport  => $trans_l,
        ip         => '2.2.2.2',
        port       => 2222,
        debug      => 0,
        encryption => ENCRYPTION_NONE
    );
    $t_s->register_peer_object($peer_s);
    $t_l->register_peer_object($peer_l);

    # Trigger handshakes
    $trans_s->_emit('connected');
    $trans_l->_emit('connected');
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

    # First exchange loop for metadata
    my $meta_iter = 100;
    while ( !$t_l->metadata && $meta_iter-- ) {
        $exchange->();
    }
    ok $t_l->metadata, 'Leecher successfully fetched metadata';
    is $t_l->state, STATE_RUNNING, 'Leecher state is now RUNNING';

    # Notify leecher that seeder has pieces
    $t_l->set_peer_have_all($peer_l);
    $peer_s->unchoke();    # Seeder unchokes leecher

    # Second exchange loop for data
    my $data_iter = 200;
    while ( !$t_l->bitfield->get(0) && $data_iter-- ) {
        $exchange->();
    }
    ok $t_l->bitfield->get(0), 'Leecher successfully fetched piece 0';
    $t_l->storage->explicit_flush;
    ok $leecher_dir->child('test_metadata')->exists, 'Leecher file exists';
    is $leecher_dir->child('test_metadata')->slurp_raw, $data, 'Leecher file content matches';
};
subtest 'DHT Peer Discovery' => sub {
    my $client     = Net::BitTorrent->new();
    my $ih         = 'A' x 20;
    my $t          = $client->add( 'magnet:?xt=urn:btih:' . unpack( 'H*', $ih ), '.' );
    my $discovered = 0;
    $t->on( 'peer_discovered', sub ( $emitter, $peer ) { $discovered++ } );
    $t->add_peer( { ip => '3.3.3.3', port => 3333 } );
    is $discovered, 1, 'Peer discovery event emitted via add_peer (simulating DHT)';
};
subtest 'Bridge Node (Metadata only)' => sub {
    my $temp     = Path::Tiny->tempdir;
    my $data     = 'B' x 16384;
    my $info     = { name => 'bridge_test', 'piece length' => 16384, pieces => sha1($data), length => 16384 };
    my $ih       = sha1( bencode($info) );
    my $client_b = Net::BitTorrent->new( bep05 => 0, upnp_enabled => 0 );
    my $t_b      = $client_b->add( 'magnet:?xt=urn:btih:' . unpack( 'H*', $ih ), $temp->child('bridge') );
    $t_b->handle_metadata_data( undef, 0, length( bencode($info) ), bencode($info) );
    $t_b->start();
    my $client_c = Net::BitTorrent->new( bep05 => 0, upnp_enabled => 0 );
    my $t_c      = $client_c->add( 'magnet:?xt=urn:btih:' . unpack( 'H*', $ih ), $temp->child('leecher') );
    $t_c->start();
    my $trans_b = MockTransport->new( ip => '1.2.3.4', port => 80, name => 'B' );
    my $trans_c = MockTransport->new( ip => '4.3.2.1', port => 80, name => 'C' );
    my $p_b     = Net::BitTorrent::Protocol::PeerHandler->new(
        infohash      => $ih,
        peer_id       => 'B' x 20,
        features      => $client_b->features,
        metadata_size => length( bencode($info) )
    );
    my $p_c    = Net::BitTorrent::Protocol::PeerHandler->new( infohash => $ih, peer_id => 'C' x 20, features => $client_c->features );
    my $peer_b = Net::BitTorrent::Peer->new(
        protocol   => $p_b,
        torrent    => $t_b,
        transport  => $trans_b,
        ip         => '1.2.3.4',
        port       => 80,
        encryption => ENCRYPTION_NONE
    );
    my $peer_c = Net::BitTorrent::Peer->new(
        protocol   => $p_c,
        torrent    => $t_c,
        transport  => $trans_c,
        ip         => '4.3.2.1',
        port       => 80,
        encryption => ENCRYPTION_NONE
    );
    $t_b->register_peer_object($peer_b);
    $t_c->register_peer_object($peer_c);
    $trans_b->_emit('connected');
    $trans_c->_emit('connected');
    my $bridge_exchange = sub {
        my $moved = 0;
        while (1) {
            my $m = 0;
            $peer_c->write_buffer;
            if ( my $r = $trans_c->pop_buffer ) { $peer_b->receive_data($r); $m++ }
            $peer_b->write_buffer;
            if ( my $r = $trans_b->pop_buffer ) { $peer_c->receive_data($r); $m++ }
            last unless $m;
            $moved += $m;
        }
        $client_b->tick(0.1);
        $client_c->tick(0.1);
        return $moved;
    };
    my $max_iter = 100;
    while ( !$t_c->metadata && $max_iter-- ) {
        $bridge_exchange->();
    }
    ok $t_c->metadata, 'Leecher got metadata from bridge node';
};
done_testing;
