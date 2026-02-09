use v5.40;
use lib 'lib', '../lib';
use Net::BitTorrent::DHT;
use Net::BitTorrent::DHT::Security;
use Net::BitTorrent::Protocol::BEP03::Bencode qw[bencode];
use Digest::SHA                               qw[sha1];
$|++;

# Distributed Blob Storage Demo (BEP 44)
# This script fragments a message, stores it on remote nodes,
# updates the fragments, and then retrieves/reconstructs it.
eval { require Crypt::PK::Ed25519; 1 } or die '[ERROR] Crypt::PK::Ed25519 is required for mutable data demos.';
my $message_v1 = 'The quick brown fox jumps over the lazy dog.';
my $message_v2 = 'Jumps over the lazy dog. The quick brown fox.';
my $chunk_size = 10;                                                # Small chunks to ensure we hit multiple targets

# Initialize
my $sec = Net::BitTorrent::DHT::Security->new();
my $id  = $sec->generate_node_id('127.0.0.1');
my $dht = Net::BitTorrent::DHT->new(
    node_id_bin => $id,
    port        => 6881 + int( rand(100) ),
    bep42       => 0,                         # Disable strict BEP 42 validation for this demo
    debug       => 1                          # Enable debug logging
);
my $pk  = Crypt::PK::Ed25519->new()->generate_key();
my $pub = $pk->export_key_raw('public');
say '[INFO] Bootstrapping DHT...';
$dht->bootstrap();

# Search for some popular infohashes to build the routing table
say '[INFO] Warming up routing table...';
my $warm_start = time;
my @popular    = (
    pack( 'H*', '86f635034839f1ebe81ab96bee4ac59f61db9dde' ),    # Debian
    pack( 'H*', 'c8295ce630f2064f08440db1534e4992cfe4862a' ),    # Ubuntu
);
while ( time - $warm_start < 20 ) {
    $dht->tick(0.5);
    if ( ( time - $warm_start ) % 5 == 0 ) {
        for my $target (@popular) {
            my @closest;
            push @closest, $dht->routing_table_v4->find_closest( $target, 8 );
            push @closest, $dht->routing_table_v6->find_closest( $target, 8 ) if $dht->can('routing_table_v6');
            if ( !@closest ) {

                # Just call bootstrap again, it uses @_resolved_boot_nodes now
                $dht->bootstrap();
            }
            else {
                for my $n (@closest) {
                    $dht->find_node_remote( $target, $n->{data}{ip}, $n->{data}{port} );
                }
            }
        }
    }
    my $rt_size = $dht->routing_table_v4->size;
    $rt_size += $dht->routing_table_v6->size if $dht->can('routing_table_v6');
    last                                     if $rt_size > 10;
    say '[INFO] RT size: ' . $rt_size;
}
my $rt_size = $dht->routing_table_v4->size;
$rt_size += $dht->routing_table_v6->size if $dht->can('routing_table_v6');
say '[INFO] Routing table warmed up: ' . $rt_size . ' nodes.';

# Split message into chunks
my @chunks_v1;
my @chunks_v2;
my $tmp_msg1 = $message_v1;
push @chunks_v1, substr( $tmp_msg1, 0, $chunk_size, '' ) while length $tmp_msg1;
my $tmp_msg2 = $message_v2;
push @chunks_v2, substr( $tmp_msg2, 0, $chunk_size, '' ) while length $tmp_msg2;
say '[INFO] Message split into ' . scalar(@chunks_v1) . ' fragments.';

# Search state
my %targets;
for my $i ( 0 .. $#chunks_v1 ) {
    my $salt = 'chunk_' . $i;
    $targets{$salt} = { target => sha1( $pub . $salt ), v1 => $chunks_v1[$i], v2 => $chunks_v2[$i], nodes => {}, stored_v1 => 0, found_v2 => undef };
}

# Phase 1: Find nodes and get tokens
say '[PHASE 1] Searching for storage nodes...';
my $start = time;
while ( time - $start < 60 ) {
    my ( $nodes, $peers, $data ) = $dht->tick(0.1);
    if ( $data && $data->{token} ) {
        my $addr   = "$data->{ip}:$data->{port}";
        my $target = $data->{queried_target};
        if ($target) {
            for my $salt ( keys %targets ) {
                if ( $targets{$salt}{target} eq $target ) {
                    if ( !exists $targets{$salt}{nodes}{$addr} ) {
                        say "[INFO] Received token for $salt from $addr";
                        $targets{$salt}{nodes}{$addr} = $data->{token};
                    }
                }
            }
        }
    }
    state $last_query = 0;
    if ( time - $last_query > 3 ) {
        for my $salt ( keys %targets ) {
            my $t = $targets{$salt};
            my @closest;
            push @closest, $dht->routing_table_v4->find_closest( $t->{target}, 12 );
            push @closest, $dht->routing_table_v6->find_closest( $t->{target}, 12 ) if $dht->can('routing_table_v6');
            if ( !@closest ) {

                # _send now handles the [host, port] array refs from boot_nodes
                $dht->get_peers( $t->{target}, $_ ) for $dht->boot_nodes->@*;
            }
            else {
                $dht->get_peers( $t->{target}, $_->{data}{ip}, $_->{data}{port} ) for @closest;
            }
        }
        $last_query = time;
        my $targets_with_tokens = grep { scalar( keys $_->{nodes}->%* ) > 0 } values %targets;
        my $total_rt_size       = $dht->routing_table_v4->size;
        $total_rt_size += $dht->routing_table_v6->size if $dht->can('routing_table_v6');
        say sprintf '[INFO] RT: %d | Targets with tokens: %d/%d', $total_rt_size, $targets_with_tokens, scalar( keys %targets );
        last if $targets_with_tokens == scalar( keys %targets );
    }
}

# Phase 2: Store and Verify V1
say '[PHASE 2] Storing and Verifying fragments (V1)...';
for my $salt ( keys %targets ) {
    my $t       = $targets{$salt};
    my $seq     = 1;
    my $v       = $t->{v1};
    my $to_sign = '';
    $to_sign .= '4:salt' . bencode($salt) if defined $salt && length $salt;
    $to_sign .= '3:seq' . bencode($seq);
    $to_sign .= '1:v' . bencode($v);
    my $sig = $pk->sign_message($to_sign);

    for my $addr ( keys $t->{nodes}->%* ) {
        my ( $ip, $port ) = $addr =~ /^(.*):(\d+)$/;
        $dht->put_remote( { v => $v, k => $pub, seq => $seq, sig => $sig, salt => $salt, token => $t->{nodes}{$addr} }, $ip, $port );
    }
}
my $debug = 1;

# Quick verification wait
$start = time;
while ( time - $start < 15 ) {
    my ( $nodes, $peers, $data ) = $dht->tick(0.1);
    if ( $data && defined $data->{v} ) {
        if ($debug) {
            say sprintf '[DEBUG] Received V%s fragment from %s:%s (salt=%s)', ( $data->{seq} // '?' ), $data->{ip}, $data->{port},
                ( $data->{salt} // 'undef' );
        }
        for my $salt ( keys %targets ) {

            # Match by salt or unique value
            if ( ( $data->{salt} // '' ) eq $salt || $data->{v} eq $targets{$salt}{v1} ) {
                $targets{$salt}{stored_v1} = 1;
            }
        }
    }
    state $last_verify = 0;
    if ( time - $last_verify > 3 ) {
        for my $salt ( keys %targets ) {
            next if $targets{$salt}{stored_v1};
            my $t = $targets{$salt};
            for my $addr ( keys $t->{nodes}->%* ) {
                my ( $ip, $port ) = $addr =~ /^(.*):(\d+)$/;
                $dht->get_remote( $t->{target}, $ip, $port );
            }
        }
        $last_verify = time;
    }
    last if ( grep { $_->{stored_v1} } values %targets ) == scalar( keys %targets );
}
my $verified_v1 = grep { $_->{stored_v1} } values %targets;
say sprintf '[INFO] V1 verification: %d/%d fragments verified.', $verified_v1, scalar( keys %targets );

# Phase 3: Update to V2
say '[PHASE 3] Updating fragments (V2)...';
for my $salt ( keys %targets ) {
    my $t = $targets{$salt};
    next unless scalar( keys $t->{nodes}->%* ) > 0;
    my $seq     = 2;
    my $v       = $t->{v2};
    my $to_sign = '';
    $to_sign .= '4:salt' . bencode($salt) if defined $salt && length $salt;
    $to_sign .= '3:seq' . bencode($seq);
    $to_sign .= '1:v' . bencode($v);
    my $sig = $pk->sign_message($to_sign);

    for my $addr ( keys $t->{nodes}->%* ) {
        my ( $ip, $port ) = $addr =~ /^(.*):(\d+)$/;
        say "[DEBUG] Sending V2 update for $salt to $addr" if $debug;
        $dht->put_remote( { v => $v, k => $pub, seq => $seq, sig => $sig, salt => $salt, token => $t->{nodes}{$addr} }, $ip, $port );
    }
}
$dht->tick(1);

# Phase 4: Retrieve and Reconstruct
say '[PHASE 4] Retrieving fragments...';
$start = time;
while ( time - $start < 30 ) {
    my ( $nodes, $peers, $data ) = $dht->tick(0.1);
    if ( $data && defined $data->{v} ) {
        if ($debug) {
            say sprintf '[DEBUG] Received V%s fragment from %s:%s (salt=%s)', ( $data->{seq} // '?' ), $data->{ip}, $data->{port},
                ( $data->{salt} // 'undef' );
        }
        for my $salt ( keys %targets ) {

            # Match by salt or unique value
            if ( ( $data->{salt} // '' ) eq $salt || $data->{v} eq $targets{$salt}{v2} ) {
                if ( ( $data->{seq} // 0 ) == 2 ) {
                    $targets{$salt}{found_v2} = $data->{v};
                }
                else {
                    say '[DEBUG] Found old version (seq=' . ( $data->{seq} // '?' ) . ') for $salt' if $debug;
                }
            }
        }
    }
    state $last_get = 0;
    if ( time - $last_get > 3 ) {
        for my $salt ( keys %targets ) {
            next if defined $targets{$salt}{found_v2};
            my $t = $targets{$salt};
            for my $addr ( keys $t->{nodes}->%* ) {
                my ( $ip, $port ) = $addr =~ /^(.*):(\d+)$/;
                $dht->get_remote( $t->{target}, $ip, $port );
            }
        }
        $last_get = time;
    }
    my $found_count = grep { defined $_->{found_v2} } values %targets;
    last if $found_count == scalar( keys %targets );
}

# Final Reconstruction
my $final_message = '';
my @sorted_salts  = sort { substr( $a, 6 ) <=> substr( $b, 6 ) } keys %targets;
my $missing       = 0;
for my $salt (@sorted_salts) {
    if ( defined $targets{$salt}{found_v2} ) {
        $final_message .= $targets{$salt}{found_v2};
    }
    else {
        $final_message .= '[MISSING]';
        $missing++;
    }
}
say '[RESULT] Reconstructed message: ' . $final_message;
if ( $missing == 0 && $final_message eq $message_v2 ) {
    say '[SUCCESS] Verified data integrity across distributed nodes.';
}
else {
    say "[FAILURE] Could not reconstruct original message. ($missing fragments missing)";
}
