use v5.40;
use feature 'class';
use Test2::V1 -ipP;
use lib 'lib', '../lib';
no warnings;
use Net::BitTorrent;
#
# Verify CVE-2026-57082 fix didn't break anything
#
subtest Client => sub {
    subtest 'unique node IDs across instances' => sub {
        my %seen = map { Net::BitTorrent->new()->node_id => 1 } 1 .. 5;
        is scalar keys %seen, 5, '5 clients produce 5 distinct node IDs';

        #~ diag $_ for keys %seen;
    };
    is length Net::BitTorrent->new()->node_id, 20, 'node ID is exactly 20 bytes';
    like Net::BitTorrent->new()->node_id, qr/^-NB\d{3}[SU]-.*\S{5}$/, 'node ID matches pattern';
};
#
subtest DHT => sub {
    subtest 'unique node IDs across instances' => sub {
        my %seen = map { Net::BitTorrent::DHT->new( port => 0 )->node_id_bin => 1 } 1 .. 5;
        is scalar keys %seen, 5, '5 clients produce 5 distinct node IDs';

        #~ diag $_ for keys %seen;
    };
    #
    subtest 'unique token secrets across instances' => sub {
        my %seen = map { Net::BitTorrent::DHT->new( port => 0 )->_generate_token('192.168.1.1') => 1 } 1 .. 5;
        is scalar keys %seen, 5, '5 DHT instances produce 5 distinct tokens for same IP';

        #~ diag $_ for keys %seen;
    };
    #
    subtest 'different IPs produce different tokens' => sub {
        my $d    = Net::BitTorrent::DHT->new( port => 0 );
        my %seen = map { $d->_generate_token($_) => 1 } qw[10.0.0.1 10.0.0.2 10.0.0.3 192.168.1.1 172.16.0.1];
        is scalar keys %seen, 5, '5 different IPv4s produce 5 distinct tokens';
    };
    #
    subtest 'unique node IDs from same IP' => sub {
        my $sec  = Net::BitTorrent::DHT::Security->new();
        my %seen = map { $sec->generate_node_id('192.168.1.1') => 1 } 1 .. 10;
        is scalar keys %seen, 10, '10 calls produce 10 distinct node IDs for same IP';
    };
    #
    subtest 'DHT::Security — node IDs pass validation' => sub {
        my $sec = Net::BitTorrent::DHT::Security->new();
        for my $ip ( '192.168.1.1', '10.0.0.1', '172.16.0.1' ) {
            my $id = $sec->generate_node_id($ip);
            ok $sec->validate_node_id( $id, $ip ), "generated node ID validates for $ip";
        }
    }
};
#
subtest MSE => sub {
    subtest 'DH key exchange produces valid shared secret' => sub {
        my $ih    = 'A' x 20;
        my $alice = Net::BitTorrent::Protocol::MSE::KeyExchange->new( infohash => $ih, is_initiator => 1 );
        my $bob   = Net::BitTorrent::Protocol::MSE::KeyExchange->new( infohash => $ih, is_initiator => 0 );
        is length( $alice->public_key ), 96,               'Alice public key is 96 bytes';
        is length( $bob->public_key ),   96,               'Bob public key is 96 bytes';
        isnt $alice->public_key,         $bob->public_key, 'Alice and Bob have different public keys';
        my $secret_a = $alice->compute_secret( $bob->public_key );
        my $secret_b = $bob->compute_secret( $alice->public_key );
        is $secret_a, D(),       'Alice computed shared secret';
        is $secret_b, D(),       'Bob computed shared secret';
        is $secret_a, $secret_b, 'shared secrets match';
    };
    #
    subtest 'unique private keys across instances' => sub {
        my $ih   = 'B' x 20;
        my %seen = map { Net::BitTorrent::Protocol::MSE::KeyExchange->new( infohash => $ih, is_initiator => 1 )->public_key => 1 } 1 .. 5;
        is scalar keys %seen, 5, '5 KeyExchange instances produce 5 distinct public keys';
    };
};
#
subtest 'UDP tracker' => sub {
    subtest 'unique transaction IDs for UDP trackers' => sub {
        my $t    = Net::BitTorrent::Tracker::UDP->new( url => 'udp://tracker.example.com:8080/announce', ssrf_bypass => 1 );
        my %seen = map { $t->_new_transaction_id() => 1 } 1 .. 100;
        ok scalar keys %seen > 95, '100 transaction IDs have high uniqueness (>95 distinct)';
        diag 'Actual uniqueness: ' . scalar keys %seen;
        ok !( grep { $_ < 0 || $_ > 0x7FFFFFFF } keys %seen ), 'all transaction IDs are 31bit non-negative';
    }
};
#
done_testing;
