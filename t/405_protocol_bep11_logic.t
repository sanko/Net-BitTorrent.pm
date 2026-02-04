use v5.42;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1 -ipP;
no warnings;
no warnings 'once';
use Net::BitTorrent;
use Net::BitTorrent::Peer;
use Net::BitTorrent::Protocol::PeerHandler;
use Path::Tiny;

class MockTransport {
    field %on;
    field $buffer = '';
    method on ( $e, $cb ) { push $on{$e}->@*, $cb }

    method emit ( $e, @args ) {
        for my $cb ( $on{$e}->@* ) { $cb->(@args) }
    }
    method send_data ($d) { $buffer .= $d; return length $d }
    field $filter : reader = undef;
    method set_filter ($f) { $filter = $f }
    method pop_buffer () { my $tmp = $buffer; $buffer = ''; return $tmp }
}
subtest 'PEX Logic Verification' => sub {
    my $temp   = Path::Tiny->tempdir;
    my $client = Net::BitTorrent->new();

    # Create a torrent
    my $ih      = '1' x 20;
    my $torrent = $client->add_magnet( 'magnet:?xt=urn:btih:' . unpack( 'H*', $ih ), $temp );
    $torrent->start();

    # Mock a PEX-supporting peer
    my $p_handler = Net::BitTorrent::Protocol::PeerHandler->new( info_hash => $ih, peer_id => 'PEER1' . ( '0' x 15 ), features => { bep11 => 1 } );
    my $transport = MockTransport->new();
    my $peer      = Net::BitTorrent::Peer->new( protocol => $p_handler, torrent => $torrent, transport => $transport, ip => '1.1.1.1', port => 1111 );
    $p_handler->set_peer($peer);
    $torrent->register_peer_object($peer);

    # Add a new peer to the torrent
    my $new_peer = { ip => '2.2.2.2', port => 2222 };
    $torrent->add_peer($new_peer);

    # Tick forward 60 seconds to trigger PEX broadcast
    my @sent_messages;
    local *Net::BitTorrent::Protocol::BEP11::send_pex = sub {
        my ( $self, $added, $dropped, $added6, $dropped6 ) = @_;
        push @sent_messages, { added => $added };
    };
    $torrent->tick(60);
    is scalar @sent_messages,             1,         'PEX broadcast triggered after 60s';
    is $sent_messages[0]->{added}[0]{ip}, '2.2.2.2', 'New peer was shared via PEX';

    # Simulate receiving a PEX message
    my $pex_peer = { ip => '3.3.3.3', port => 3333 };
    $p_handler->on_pex( [$pex_peer], [], [], [] );
    my $discovered = $torrent->discovered_peers;
    my %found;
    for my $p (@$discovered) {
        $found{"$p->{ip}:$p->{port}"} = 1;
    }
    ok $found{'3.3.3.3:3333'}, 'Peer discovered via incoming PEX';
};
done_testing;
