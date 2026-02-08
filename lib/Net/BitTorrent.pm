use v5.40;
use feature 'class', 'try';
no warnings 'experimental::class', 'experimental::builtin', 'experimental::try';
use Net::BitTorrent::Emitter;
class Net::BitTorrent v2.0.0 : isa(Net::BitTorrent::Emitter) {
    use Net::BitTorrent::Torrent;
    use Net::BitTorrent::DHT;
    use Net::uTP::Manager;    # Standalone spin-off
    use Digest::SHA qw[sha1];
    use version;
    use Time::HiRes            qw[time];
    use Net::BitTorrent::Types qw[:encryption];
    #
    field %torrents;          # info_hash => Torrent object
    field %pending_peers;     # transport => Peer object
    field $dht;
    field $tcp_listener;
    field $tick_debt = 0;
    field $utp : reader = Net::uTP::Manager->new();
    field $lpd;
    field $node_id : reader : writer;
    field %dht_queries;       # tid => { cb => sub, type => ... }
    field %dht_index;         # info_hash_hex => timestamp (BEP 51 crawling)
    field $port_mapper : reader;
    field $port       : param : reader = 49152 + int( rand(10000) );
    field $user_agent : param : reader //= join '/', __CLASS__, our $VERSION;
    field $debug      : param = 0;
    field $encryption : param : reader = ENCRYPTION_REQUIRED;

    # Feature Toggles (Default to enabled)
    field $bep05        : param = 1;    # DHT
    field $bep06        : param = 1;    # Fast Extension
    field $bep09        : param = 1;    # Metadata Exchange
    field $bep10        : param = 1;    # Extension Protocol
    field $bep11        : param = 1;    # PEX
    field $bep52        : param = 1;    # v2
    field $bep55        : param = 1;    # Holepunching
    field $limit_up     : reader;
    field $limit_down   : reader;
    field $upnp_enabled : param = 0;

    # Verification Throttling
    field @hashing_queue;                                      # Array of { torrent => $t, index => $i, data => $d }
    field $hashing_rate_limit : writer = 1024 * 1024 * 500;    # 500MB/s limit for hashing
    field $hashing_allowance = 0;

    method features () {
        { bep05 => $bep05, bep06 => $bep06, bep09 => $bep09, bep10 => $bep10, bep11 => $bep11, bep52 => $bep52, bep55 => $bep55, };
    }
    ADJUST {
        $node_id //= _generate_peer_id();
        my $weak_self = $self;
        builtin::weaken($weak_self);

        # TCP Listener
        use IO::Socket::IP;
        $tcp_listener = IO::Socket::IP->new( LocalPort => $port, Listen => 5, ReuseAddr => 1, Blocking => 0, );
        if ($tcp_listener) {
            $self->_emit( log => "    [DEBUG] TCP listener started on port $port\n", level => 'debug' ) if $debug;
        }
        else {
            $self->_emit( log => "    [ERROR] Could not start TCP listener on port $port: $!\n", level => 'error' );
        }
        $utp->on(
            'new_connection',
            sub ( $utp_conn, $ip, $port ) {
                return unless $weak_self;

                #~ warn "    [uTP] Incoming connection from $ip:$port\n";
                use Net::BitTorrent::Protocol::HandshakeOnly;
                use Net::BitTorrent::Peer;
                my $proto = Net::BitTorrent::Protocol::HandshakeOnly->new(
                    info_hash       => undef,                  # Dummy, will be overwritten by any incoming
                    peer_id         => $weak_self->node_id,    # Dummy
                    on_handshake_cb => sub ( $ih, $id ) {
                        $weak_self->_upgrade_pending_peer( $utp_conn, $ih, $id, $ip, $port );
                    }
                );
                my $peer = Net::BitTorrent::Peer->new(
                    protocol  => $proto,
                    torrent   => undef,                        # Not known yet
                    transport => $utp_conn,
                    ip        => $ip,
                    port      => $port,
                    debug     => $debug
                );
                $pending_peers{$utp_conn} = $peer;
            }
        );
        use Algorithm::RateLimiter::TokenBucket;
        $limit_up   = Algorithm::RateLimiter::TokenBucket->new( limit => 0 );
        $limit_down = Algorithm::RateLimiter::TokenBucket->new( limit => 0 );

        # Initialize LPD (BEP 14)
        use Net::Multicast::PeerDiscovery;
        $lpd = Net::Multicast::PeerDiscovery->new();
        $lpd->on(
            'peer_found',
            sub ($p_info) {
                return unless $weak_self;
                if ( my $t = $torrents{ $p_info->{info_hash} } ) {
                    $t->add_peer( { ip => $p_info->{ip}, port => $p_info->{port} } );
                }
            }
        );

        # Initialize PortMapper if enabled and available
        if ($upnp_enabled) {
            builtin::load_module 'Acme::UPnP';
            my $mapper = Acme::UPnP->new();
            if ( $mapper->is_available() ) {
                $port_mapper = $mapper;
            }
            else {
                #~ warn "    [UPnP] UPnP requested but Net::UPnP::ControlPoint not available. Skipping.\n";
                $upnp_enabled = 0;        # Disable UPnP if module not available
                $port_mapper  = undef;    # Explicitly set to undef
            }
        }
        else {
            $port_mapper = undef;         # Ensure it's undef if UPnP is disabled
        }

        # Register PortMapper events if port_mapper is initialized
        if ($port_mapper) {

            #~ $port_mapper->on( 'device_found',     sub ($name_hash) { warn "    [UPnP] Device found: $name_hash->{name}\n"; } );
            #~ $port_mapper->on( 'device_not_found', sub { warn "    [UPnP] No device found.\n"; } );
            #~ $port_mapper->on( 'map_success',
            #~ sub ($args) { warn "    [UPnP] Port mapped: $args->{ext_p}/$args->{proto} for $args->{int_p} ($args->{desc})\n"; } );
            #~ $port_mapper->on( 'map_failed',    sub ($args) { warn "    [UPnP] Port map failed: $args->{err_c} - $args->{err_d}\n"; } );
            #~ $port_mapper->on( 'unmap_success', sub ($args) { warn "    [UPnP] Port unmapped: $args->{ext_p}/$args->{proto}\n"; } );
            #~ $port_mapper->on( 'unmap_failed',  sub ($args) { warn "    [UPnP] Port unmap failed: $args->{err_c} - $args->{err_d}\n"; } );
            $self->forward_ports();
        }
    }

    sub _generate_peer_id () {
        my $v_id  = '200';                                                                  # Hardcoded version for stability in ID generation
        my $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
        return pack( 'a20', sprintf( '-NB%sS-%sSanko', $v_id, join( '', map { substr( $chars, rand(66), 1 ) } 1 .. 7 ) ) );

        #~ $self->_emit( log => '    [DEBUG] Generated Peer ID: ' . unpack( 'H*', $id ) . " (" . $id . ")\n", level => 'debug' ) if $self->debug;
    }

    method forward_ports () {
        if ($port_mapper) {
            $port_mapper->discover_device();
        }
    }

    method shutdown () {
        if ($port_mapper) {
            $port_mapper->unmap_port( 6881, 'TCP' );
            $port_mapper->unmap_port( 6881, 'UDP' );
        }
        for my $t ( values %torrents ) {
            $t->stop if $t;
        }
    }

    method DESTROY () {
        $self->shutdown();
    }

    method handle_udp_packet ( $data, $addr ) {
        return unless length $data;
        my $first = substr( $data, 0, 1 );
        if ( $first eq 'd' ) {

            # Likely DHT
            return $self->dht->handle_incoming( $data, $addr ) if $self->dht;
        }
        elsif ( ord($first) >> 4 == 1 ) {

            # Likely uTP (version 1)
            my $res = $utp->handle_packet( $data, $addr );
            if ($res) {

                # Send response back
                $self->dht->socket->send( $res, 0, $addr );
            }
        }
    }

    method _handle_new_tcp_transport ($transport) {
        my $weak_self = $self;
        builtin::weaken($weak_self);
        my $weak_transport = $transport;
        builtin::weaken($weak_transport);

        # We wait for the first chunk of data to decide if it's PWP or MSE
        $transport->on(
            'data',
            sub ( $trans, $data ) {
                return unless $weak_self && $weak_transport;
                my $entry = $weak_self->pending_peers_hash->{$weak_transport};
                return unless $entry;
                if ( $entry->{peer} ) {
                    $entry->{peer}->on_data($data);
                }
                else {
                    $weak_self->_autodetect_protocol( $weak_transport, $data );
                }
            }
        );

        # Store in pending_peers to keep it alive
        $pending_peers{$transport} = { transport => $transport, timestamp => time() };
    }

    method _autodetect_protocol ( $transport, $data ) {
        my $entry = $pending_peers{$transport};
        return unless $entry;
        return if $entry->{detected};

        # If we already have a peer object or a filter, this data is for them.
        if ( $entry->{peer} || $transport->filter ) {
            return;
        }
        $entry->{detected} = 1;
        my $first_byte = ord( substr( $data, 0, 1 ) );
        if ( $first_byte == 0x13 ) {
            if ( $encryption == ENCRYPTION_REQUIRED ) {
                $self->_emit( log => "    [DEBUG] Rejecting plaintext connection because encryption is required\n", level => 'debug' ) if $debug;
                $transport->socket->close();
                delete $pending_peers{$transport};
                return;
            }
            $self->_emit( log => "    [DEBUG] Autodetected PWP handshake\n", level => 'debug' ) if $debug;
            use Net::BitTorrent::Protocol::HandshakeOnly;
            my $proto = Net::BitTorrent::Protocol::HandshakeOnly->new(
                info_hash       => undef,
                peer_id         => $self->node_id,
                on_handshake_cb => sub ( $ih, $id ) {
                    $self->_upgrade_pending_peer( $transport, $ih, $id, $transport->socket->peerhost, $transport->socket->peerport );
                }
            );
            $entry->{peer} = Net::BitTorrent::Peer->new(
                protocol  => $proto,
                transport => $transport,
                torrent   => undef,
                ip        => $transport->socket->peerhost,
                port      => $transport->socket->peerport,
                debug     => $debug
            );

            # Feed the data we already read to the new protocol handler
            $entry->{peer}->on_data($data);
        }
        else {
            $self->_emit( log => "    [DEBUG] Autodetected potential MSE handshake\n", level => 'debug' ) if $debug;

            # MSE handling will be complex because we don't know the info_hash yet
            # We need an MSE object that can try ALL our hosted info_hashes?
            # No, MSE spec says Req2 is XORed with the info_hash.
            # We must wait until we have Req2, then XOR it with each IH we have until one matches.
            $self->_handle_incoming_mse( $transport, $data );
        }
    }

    method _handle_incoming_mse ( $transport, $data ) {
        use Net::BitTorrent::Protocol::MSE;
        my $weak_self = $self;
        builtin::weaken($weak_self);
        my $mse = Net::BitTorrent::Protocol::MSE->new(
            info_hash          => undef,                              # Not known yet
            is_initiator       => 0,
            on_info_hash_probe => sub ( $mse_obj, $xor_part, $s ) {
                return undef unless $weak_self;
                my $torrents = $weak_self->torrents();
                for my $t (@$torrents) {
                    my $ih1 = $t->info_hash_v1;
                    my $ih2 = $t->info_hash_v2;
                    for my $ih ( grep {defined} ( $ih1, $ih2 ) ) {
                        my $expected_xor = $mse_obj->_xor_strings( sha1( 'req2' . $ih ), sha1( 'req3' . $s ) );
                        if ( $xor_part eq $expected_xor ) {
                            $weak_self->_emit( log => "    [DEBUG] MSE matched info_hash: " . unpack( 'H*', $ih ) . "\n", level => 'debug' )
                                if $weak_self->debug;
                            return $ih;
                        }
                    }
                }
                return undef;
            }
        );
        my $weak_transport = $transport;
        builtin::weaken($weak_transport);
        $mse->on(
            'info_hash_identified',
            sub ( $mse_obj, $ih ) {
                return unless $weak_self && $weak_transport;
                $weak_self->_upgrade_pending_peer( $weak_transport, $ih, undef, $weak_transport->socket->peerhost,
                    $weak_transport->socket->peerport );
            }
        );
        $transport->set_filter($mse);
        $self->_emit( log => "    [DEBUG] Incoming MSE handshake started\n", level => 'debug' ) if $debug;

        # Feed the data we already have
        $mse->receive_data($data);
        my $entry = $pending_peers{$transport};
        $entry->{mse} = $mse;
    }

    method _upgrade_pending_peer ( $transport, $ih, $peer_id, $ip, $port ) {
        my $entry = $pending_peers{$transport};
        if ( !$entry ) {

            # Already upgraded or timed out
            return;
        }
        delete $pending_peers{$transport};
        my $torrent = $torrents{$ih};
        if ( !$torrent ) {
            $self->_emit( log => "    [DEBUG] Handshake for unknown torrent " . unpack( 'H*', $ih ) . " from $ip:$port\n", level => 'debug' )
                if $debug;
            $transport->socket->close() if $transport->socket;
            return;
        }
        use Net::BitTorrent::Protocol::PeerHandler;
        my $p_handler = Net::BitTorrent::Protocol::PeerHandler->new(
            info_hash     => $ih,
            peer_id       => $self->node_id,
            features      => $torrent->features,
            debug         => $debug,
            metadata_size => $torrent->metadata ? length( Net::BitTorrent::Protocol::BEP03::Bencode::bencode( $torrent->metadata->{info} ) ) : 0,
        );
        my $peer;
        if ( $entry->{peer} ) {
            $peer = $entry->{peer};
            $peer->set_protocol($p_handler);
            $peer->set_torrent($torrent);
        }
        else {
            $peer = Net::BitTorrent::Peer->new(
                protocol   => $p_handler,
                torrent    => $torrent,
                transport  => $transport,
                ip         => $ip,
                port       => $port,
                debug      => $debug,
                mse        => $entry->{mse},
                encryption => $encryption,
            );
        }
        $p_handler->set_peer($peer);
        $p_handler->set_parent_emitter($peer);
        if ( defined $peer_id ) {
            $p_handler->on_handshake( $ih, $peer_id );
        }
        $torrent->register_peer_object($peer);
    }
    method set_limit_down ($val) { $limit_down->set_limit($val) }
    method hashing_queue_size () { scalar @hashing_queue }

    method queue_verification ( $torrent, $index, $data ) {
        $self->_emit( log => "\n    [LOUD] PIECE $index: Queuing for verification (" . length($data) . " bytes)\n", level => 'info' );
        push @hashing_queue, { torrent => $torrent, index => $index, data => $data };
    }

    method _process_hashing_queue ($delta) {
        $hashing_allowance += $hashing_rate_limit * $delta;
        if ( @hashing_queue && $hashing_allowance < length( $hashing_queue[0]{data} ) ) {
            $self->_emit(
                log => sprintf( "\r    [LOUD] Hashing Throttled: %.2f%% of next piece ready",
                    ( $hashing_allowance / length( $hashing_queue[0]{data} ) ) * 100 ),
                level => 'info'
            );
        }
        while (@hashing_queue) {
            my $task = $hashing_queue[0];
            my $len  = length( $task->{data} );
            if ( $hashing_allowance >= $len ) {
                shift @hashing_queue;
                $hashing_allowance -= $len;
                $self->_emit( log => "\n    [LOUD] PIECE $task->{index}: Processing hash...\n", level => 'info' );
                $task->{torrent}->_verify_queued_piece( $task->{index}, $task->{data} );
            }
            else {
                # Not enough allowance to finish this piece yet
                last;
            }
        }
    }

    method dht_get ( $target, $cb ) {
        return unless $self->dht;

        # First, iterative find_node to get close to target.
        # Then call get_remote on closest nodes
        # Simplified: trigger iterative lookup and register callback
        $self->dht->find_node_remote( $target, $_->[0], $_->[1] ) for @{ $self->dht->boot_nodes };
        $dht_queries{$target} = { cb => $cb, type => 'get' };
    }

    method dht_put ( $value, $cb = undef ) {
        return unless $self->dht;
        my $target = Digest::SHA::sha1($value);

        # Simplified: find nodes and then put
        $self->dht->find_node_remote( $target, $_->[0], $_->[1] ) for @{ $self->dht->boot_nodes };
        $dht_queries{$target} = { cb => $cb, type => 'put', value => $value };
    }

    method dht_scrape ( $info_hash, $cb ) {
        return unless $self->dht;
        $self->dht->scrape($info_hash);
        $dht_queries{$info_hash} = { cb => $cb, type => 'scrape' };
    }

    method dht_crawl () {
        return unless $self->dht;

        # Random sample to discover new info-hashes
        my $random_target = pack( 'H*', join( '', map { sprintf( '%02x', rand(256) ) } 1 .. 20 ) );
        $self->dht->sample($random_target);
    }
    method dht_index () { return \%dht_index }

    method connect_to_peer ( $ip, $port, $ih ) {
        use IO::Socket::IP;
        my $socket = IO::Socket::IP->new( PeerHost => $ip, PeerPort => $port, Type => SOCK_STREAM, Blocking => 0, );
        return unless $socket;
        $self->_emit( log => "    [DEBUG] Connecting to $ip:$port for " . unpack( 'H*', $ih ) . "\n", level => 'debug' ) if $debug;
        use Net::BitTorrent::Transport::TCP;
        my $transport = Net::BitTorrent::Transport::TCP->new( socket => $socket, connecting => 1 );

        # Add to pending_peers immediately
        $pending_peers{$transport} = { transport => $transport, timestamp => time() };
        my $weak_self = $self;
        builtin::weaken($weak_self);
        my $weak_transport = $transport;
        builtin::weaken($weak_transport);
        if ( $encryption == ENCRYPTION_REQUIRED || $encryption == ENCRYPTION_PREFERRED ) {
            use Net::BitTorrent::Protocol::MSE;
            my $mse = Net::BitTorrent::Protocol::MSE->new( info_hash => $ih, is_initiator => 1, );
            $mse->on(
                'info_hash_identified',
                sub ( $mse_obj, $ih ) {
                    return unless $weak_self && $weak_transport;
                    $weak_self->_upgrade_pending_peer(
                        $weak_transport, $ih, undef,
                        $weak_transport->socket->peerhost,
                        $weak_transport->socket->peerport
                    );
                }
            );
            $transport->set_filter($mse);
            $pending_peers{$transport}{mse} = $mse;
            $transport->on(
                'filter_failed',
                sub ( $trans, $leftover ) {
                    return unless $weak_self && $weak_transport;
                    $weak_self->_emit( log => "    [DEBUG] connect_to_peer: MSE failed, falling back to plaintext\n", level => 'debug' )
                        if $weak_self->debug;
                    $weak_self->_upgrade_pending_peer(
                        $weak_transport, $ih, undef,
                        $weak_transport->socket->peerhost,
                        $weak_transport->socket->peerport
                    );
                }
            );
        }
        else {
            # Plaintext outgoing: create peer immediately
            $self->_upgrade_pending_peer( $transport, $ih, undef, $ip, $port );
        }

        # Reuse incoming data handler logic
        $transport->on(
            'data',
            sub ( $trans, $data ) {
                return unless $weak_self && $weak_transport;
                my $entry = $weak_self->pending_peers_hash->{$weak_transport};
                return unless $entry;    # Might have been upgraded already
                if ( $entry->{peer} ) {
                    $entry->{peer}->on_data($data);
                }
                else {
                    $weak_self->_autodetect_protocol( $weak_transport, $data );
                }
            }
        );
        return $transport;
    }
    method pending_peers_hash () { \%pending_peers }

    method add ( $thing, $base_path, %args ) {
        if ( $thing =~ /^magnet:/i ) {
            return $self->add_magnet( $thing, $base_path, %args );
        }
        elsif ( length($thing) == 20 || ( length($thing) == 40 && $thing =~ /^[0-9a-f]+$/i ) ) {
            return $self->add_info_hash( $thing, $base_path, %args );
        }
        elsif ( -f $thing ) {
            return $self->add_torrent( $thing, $base_path, %args );
        }
        $self->_emit( log => "Don't know how to add '$thing'", level => 'fatal' );
        return undef;
    }

    method add_torrent ( $path, $base_path, %args ) {
        my $t = Net::BitTorrent::Torrent->new( path => $path, base_path => $base_path, client => $self, debug => $debug, peer_id => $node_id, %args );
        $torrents{ $t->info_hash_v1 } = $t if $t->info_hash_v1;
        $torrents{ $t->info_hash_v2 } = $t if $t->info_hash_v2;
        $self->_emit( 'torrent_added', $t );
        return $t;
    }

    method add_info_hash ( $ih, $base_path, %args ) {
        my $t = Net::BitTorrent::Torrent->new( info_hash => $ih, base_path => $base_path, client => $self, debug => $debug, peer_id => $node_id,
            %args );
        $torrents{ $t->info_hash_v1 } = $t if $t->info_hash_v1;
        $torrents{ $t->info_hash_v2 } = $t if $t->info_hash_v2;
        $self->_emit( 'torrent_added', $t );
        return $t;
    }

    method add_magnet ( $uri, $base_path, %args ) {
        use Net::BitTorrent::Protocol::BEP53;
        my $m = Net::BitTorrent::Protocol::BEP53->parse($uri);
        my $t = Net::BitTorrent::Torrent->new(
            info_hash_v1     => $m->info_hash_v1,
            info_hash_v2     => $m->info_hash_v2,
            initial_trackers => $m->trackers,
            initial_peers    => $m->nodes,          # x.pe
            base_path        => $base_path,
            client           => $self,
            debug            => $debug,
            peer_id          => $node_id,
            %args
        );
        $torrents{ $t->info_hash_v1 } = $t if $t->info_hash_v1;
        $torrents{ $t->info_hash_v2 } = $t if $t->info_hash_v2;
        $self->_emit( 'torrent_added', $t );
        return $t;
    }

    method torrents () {
        return [ values %torrents ];
    }

    method dht () {
        return undef unless $bep05;
        if ( !$dht ) {
            $dht = Net::BitTorrent::DHT->new(
                node_id_bin => $node_id,
                port        => $port,
                want_v6     => 1,
                bep32       => 1,
                bep42       => 0,
                debug       => $debug,
                boot_nodes  => [ [ 'router.bittorrent.com', 6881 ], [ 'router.utorrent.com', 6881 ], [ 'dht.transmissionbt.com', 6881 ], ]
            );
            my $weak_self = $self;
            builtin::weaken($weak_self);
            $dht->on(
                'external_ip_detected',
                sub ($ip) {
                    return unless $weak_self;

                    #~ warn "    [DHT] External IP detected: $ip. Rotating node_id.\n";
                    # my $sec    = Net::BitTorrent::DHT::Security->new();
                    # my $new_id = $sec->generate_node_id($ip);
                    # $weak_self->set_node_id($new_id);
                    # $dht->set_node_id($new_id);
                }
            );
            $dht->bootstrap();
        }
        return $dht;
    }

    method tick ( $timeout //= 0.1 ) {
        $tick_debt += $timeout;
        $tick_debt = 5.0 if $tick_debt > 5.0;    # Max debt to avoid huge bursts
        my $real_start = time();
        while ( $tick_debt >= 0.01 ) {
            my $slice = 0.1;
            $slice = $tick_debt if $tick_debt < $slice;
            $self->_run_one_tick($slice);
            $tick_debt -= $slice;

            # Don't block the caller's main loop for more than 200ms
            last if ( time() - $real_start ) > 0.2;
        }
    }

    method _run_one_tick ($timeout) {
        $self->_emit( log => "  [DEBUG] Net::BitTorrent::_run_one_tick starting (timeout=$timeout)\n", level => 'debug' ) if $debug > 1;
        my $start = time();
        $limit_up->tick($timeout);
        $limit_down->tick($timeout);

        # Accept incoming TCP connections
        if ($tcp_listener) {
            my $sel = IO::Select->new($tcp_listener);
            if ( $sel->can_read(0) ) {
                while ( my $socket = $tcp_listener->accept() ) {
                    $socket->blocking(0);
                    $self->_emit(
                        log   => "    [DEBUG] Accepted TCP connection from " . $socket->peerhost . ":" . $socket->peerport . "\n",
                        level => 'debug'
                    ) if $debug;
                    use Net::BitTorrent::Transport::TCP;
                    my $transport = Net::BitTorrent::Transport::TCP->new( socket => $socket, connecting => 0 );

                    # Autodetect MSE vs PWP will happen in the first data received
                    $self->_handle_new_tcp_transport($transport);
                }
            }
        }
        else {
            $self->_emit( log => "    [DEBUG] No TCP listener active\n", level => 'debug' ) if $debug > 1;
        }

        # Process hashing queue (throttled)
        $self->_process_hashing_queue($timeout);

        # Update LPD
        $lpd->tick($timeout) if $lpd;

        # Update torrents (including trackers and storage)
        for my $ih ( keys %torrents ) {
            $torrents{$ih}->tick($timeout);
        }

        # Update pending peers (ones being autodetected or in handshake)
        for my $t_key ( keys %pending_peers ) {
            my $entry     = $pending_peers{$t_key};
            my $transport = $entry->{transport};
            if ( $entry->{peer} ) {
                $entry->{peer}->tick();
            }
            else {
                # If no peer object yet, we still need to tick the transport
                # to read the autodetection data.
                $transport->tick();
            }

            # Timeout old pending connections (30s)
            if ( time() - $entry->{timestamp} > 30 ) {
                if ($debug) {
                    my $host = 'unknown';
                    try {
                        if ( $transport->socket ) {
                            $host = $transport->socket->peerhost // 'unknown';
                        }
                    }
                    catch ($e) { }
                    $self->_emit( log => "    [DEBUG] Timing out pending connection from $host\n", level => 'debug' );
                }
                $transport->socket->close() if $transport->socket;
                delete $pending_peers{$t_key};
            }
        }

        # Collect DHT events from direct packet processing
        my ( @packet_nodes, @packet_peers, @packet_data );

        # Read from UDP socket (DHT/uTP)
        if ( $dht && $dht->socket ) {
            my $sel = IO::Select->new( $dht->socket );
            while ( $sel->can_read(0) ) {
                my $remote_addr = $dht->socket->recv( my $data, 65535 );
                if ($remote_addr) {
                    my @res = $self->handle_udp_packet( $data, $remote_addr );
                    if (@res) {
                        push @packet_nodes, @{ $res[0] } if ref $res[0] eq 'ARRAY';
                        push @packet_peers, @{ $res[1] } if ref $res[1] eq 'ARRAY';
                        push @packet_data,  $res[2]      if $res[2];
                    }
                }
            }
        }

        # Update uTP
        my $utp_packets = $utp->tick($timeout);
        for my $pkt (@$utp_packets) {

            # Send retransmissions etc.
            # We use the DHT socket for convenience if it exists
            if ( $dht && $dht->socket ) {

                # Need to convert ip/port to sockaddr
                use Socket qw[pack_sockaddr_in inet_aton];
                my $addr = pack_sockaddr_in( $pkt->{port}, inet_aton( $pkt->{ip} ) );
                $dht->socket->send( $pkt->{data}, 0, $addr );
            }
        }

        # Update DHT
        if ($dht) {
            my ( $tick_nodes, $tick_peers, $tick_data ) = $dht->tick($timeout);
            my @all_nodes = ( @{ $tick_nodes // [] }, @packet_nodes );
            my @all_peers = ( @{ $tick_peers // [] }, @packet_peers );

            # Merge packet-derived data with tick-derived data
            my @all_data = grep {defined} ( $tick_data, @packet_data );
            if ( $debug && ( @all_nodes || @all_peers || @all_data ) ) {
                $self->_emit(
                    log => sprintf(
                        "    [DEBUG] DHT tick+packets: nodes=%d, peers=%d, data=%d\n",
                        scalar(@all_nodes), scalar(@all_peers), scalar(@all_data)
                    ),
                    level => 'debug'
                );
            }

            # If we found new nodes, add them to the frontier of starving torrents
            if (@all_nodes) {
                for my $t ( values %torrents ) {
                    next if scalar( @{ $t->peer_objects // [] } ) >= 20;
                    $t->add_dht_nodes( \@all_nodes );
                }
            }

            # Dispatch peers to relevant torrents
            # Net::BitTorrent::DHT::handle_incoming returns (nodes, peers, data)
            # The 'data' (result) hash contains 'queried_target' which is the info_hash
            # we were looking for when these peers were returned.
            for my $d (@all_data) {
                my $ih = $d->{queried_target};
                if ( $ih && ( my $t = $torrents{$ih} ) ) {
                    if ( $debug && @all_peers ) {
                        $self->_emit(
                            log   => "    [DEBUG] Dispatching " . scalar(@all_peers) . " peers to torrent " . unpack( "H*", $ih ) . "\n",
                            level => 'debug'
                        );
                    }
                    for my $peer (@all_peers) {
                        $t->add_peer($peer);
                    }
                }
                elsif ( $debug && $ih ) {
                    $self->_emit( log => "    [DEBUG] DHT result for unknown info_hash " . unpack( "H*", $ih ) . "\n", level => 'debug' );
                }
            }

            # Handle BEP 33, 44, 51 data
            for my $d (@all_data) {
                if ( exists $d->{samples} ) {    # BEP 51
                    for my $ih ( @{ $d->{samples} } ) {
                        my $key = unpack( 'H*', $ih );
                        $dht_index{$key} = time();
                        if ( keys %dht_index > 1000 ) {

                            # Remove oldest or just random?
                            # For simplicity, remove first key (random in Perl)
                            delete $dht_index{ ( keys %dht_index )[0] };
                        }
                    }
                }
                if ( exists $d->{v} ) {    # BEP 44

                    # Calculate target (immutable) or use key (mutable)
                    my $target = Digest::SHA::sha1( $d->{v} );
                    if ( my $q = delete $dht_queries{$target} ) {
                        $q->{cb}->( $d->{v}, $d ) if $q->{cb};
                    }
                }
                if ( exists $d->{sn} ) {    # BEP 33

                    # Scrape result - find matching torrent
                    if ( my $ih = $d->{queried_target} ) {
                        if ( my $t = $torrents{$ih} ) {
                            $t->handle_dht_scrape($d);
                        }
                    }
                }
            }
        }

        # Update all torrents (evaluates choking, etc.)
        for my $t ( values %torrents ) {
            $t->tick($timeout);

            # BEP 14: Periodically announce on local network
            # (Simplified: every ~60s if we tracked a timer, here we just do it occasionally)
            if ( rand() < 0.01 ) {    # Hack for now
                if ($lpd) {
                    $lpd->announce( $t->info_hash_v2, 6881 ) if $t->info_hash_v2;
                    $lpd->announce( $t->info_hash_v1, 6881 ) if $t->info_hash_v1;
                }
            }
        }
    }

    method save_state ($path) {
        use JSON::PP   qw[encode_json];
        use Path::Tiny qw[path];
        my %data = ( node_id => $node_id, torrents => {}, );
        my %seen;
        for my $ih ( keys %torrents ) {
            my $t = $torrents{$ih};
            next if $seen{ builtin::refaddr($t) }++;
            $data{torrents}{ unpack( 'H*', $ih ) } = $t->dump_state();
        }
        path($path)->spew_utf8( encode_json( \%data ) );
    }

    method load_state ($path) {
        use JSON::PP   qw[decode_json];
        use Path::Tiny qw[path];
        return unless path($path)->exists;
        my $data = decode_json( path($path)->slurp_utf8 );
        $node_id = $data->{node_id} if $data->{node_id};
        for my $ih_hex ( keys %{ $data->{torrents} // {} } ) {
            my $ih = pack( 'H*', $ih_hex );
            if ( my $t = $torrents{$ih} ) {
                $t->load_state( $data->{torrents}{$ih_hex} );
            }
        }
    }

    method finished () {
        return [ grep { $_->is_finished } values %torrents ];
    }

    method wait ( $condition = undef, $timeout = undef ) {
        my $start = time();
        $condition //= sub {
            my @t = values %torrents;
            return 1 if !@t;
            return ( grep { $_->is_finished } @t ) == @t;
        };
        while ( !$condition->($self) ) {
            $self->tick(0.1);
            if ( defined $timeout && ( time() - $start ) > $timeout ) {
                return 0;
            }
            select( undef, undef, undef, 0.05 );
        }
        return 1;
    }
};
#
1;
