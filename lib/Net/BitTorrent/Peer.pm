use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Net::BitTorrent::Emitter;
class Net::BitTorrent::Peer v2.0.0 : isa(Net::BitTorrent::Emitter) {
    use Net::BitTorrent::Types qw[:encryption];
    field $protocol : param;

    # Instance of Net::BitTorrent::Protocol::BEP03 or subclass
    field $torrent   : param : reader;                            # Parent Net::BitTorrent::Torrent object
    field $transport : param : reader;                            # Net::BitTorrent::Transport::*
    field $ip              : param : reader = undef;
    field $port            : param : reader = undef;
    field $am_choking      : reader = 1;
    field $am_interested   : reader = 0;
    field $peer_choking    : reader = 1;
    field $peer_interested : reader = 0;
    field $blocks_inflight : reader = 0;
    field $bitfield_status : reader : writer = undef;             # 'all', 'none', or raw data
    field $offered_piece = undef;
    field $bytes_down    = 0;
    field $bytes_up      = 0;
    field $rate_down  : reader = 0;
    field $rate_up    : reader = 0;
    field $reputation : reader = 100;                             # Start at 100
    field $debug      : param : reader = 0;
    field $encryption : param : reader = ENCRYPTION_PREFERRED;    # none, preferred, required
    field $mse        : param = undef;
    field @allowed_fast_set;                                      # Pieces we are allowed to request even if choked
    field @suggested_pieces;
    field $pwp_handshake_sent = 0;
    method protocol ()     {$protocol}
    method is_encrypted () { defined $mse             && $mse->state eq 'PAYLOAD' }
    method is_seeder ()    { defined $bitfield_status && $bitfield_status eq 'all' }

    method flags () {
        my $f = 0;
        $f |= 0x01 if $self->is_encrypted;
        $f |= 0x02 if $self->is_seeder;
        return $f;
    }
    ADJUST {
        $self->set_parent_emitter($torrent);
        builtin::weaken($torrent) if defined $torrent;
        if ( $protocol->can('set_peer') ) {
            $protocol->set_peer($self);
        }
        if ( !$mse && $encryption != ENCRYPTION_NONE ) {
            use Net::BitTorrent::Protocol::MSE;
            $mse = Net::BitTorrent::Protocol::MSE->new(
                info_hash       => $torrent ? ( $torrent->info_hash_v1 // $torrent->info_hash_v2 ) : undef,
                is_initiator    => 1,                                                                         # Outgoing
                allow_plaintext => ( $encryption == ENCRYPTION_PREFERRED ? 1 : 0 ),
            );
            if ( $mse->supported ) {
                $transport->set_filter($mse);
            }
            else {
                $mse = undef;
            }
        }
        my $weak_self = $self;
        builtin::weaken($weak_self);
        $transport->on(
            'data',
            sub ( $trans, $data ) {
                $weak_self->receive_data($data) if $weak_self;
            }
        );
        $transport->on(
            'disconnected',
            sub ( $trans, @args ) {
                $weak_self->disconnected() if $weak_self;
            }
        );
        $transport->on(
            'filter_failed',
            sub ( $trans, $leftover ) {
                return unless $weak_self;
                return if $weak_self->encryption == ENCRYPTION_REQUIRED;
                $weak_self->_emit( log => "    [DEBUG] Falling back to plaintext handshake...\n", level => 'debug' ) if $weak_self->debug;

                # We can't easily change $mse from here because it's a field
                # but we can call a method or just use it.
                # Actually $mse is in scope but it's a field.
                # In ADJUST, we can access fields.
                $mse = undef;
                $protocol->send_handshake();
                $pwp_handshake_sent = 1;
            }
        );
        $transport->on(
            'connected',
            sub ( $trans, @args ) {
                return unless $weak_self;
                if ($mse) {
                    $weak_self->_emit( log => "    [DEBUG] Starting MSE handshake...\n", level => 'debug' ) if $weak_self->debug;

                    # Handshake is driven by transport filter's write_buffer in tick()
                }
                else {
                    $protocol->send_handshake();
                    $pwp_handshake_sent = 1;
                }
            }
        );
        $self->on(
            'handshake_complete',
            sub ( $emitter, @args ) {
                return unless $weak_self;

                # Some peers need us to be unchoked/interested to talk to us
                # but we'll stay choked until we have metadata if we want to be safe.
                # However, we MUST send bitfield/have_none to be protocol compliant.
                # BEP 03: Send bitfield if we have one
                if ( $torrent && $torrent->bitfield ) {
                    $protocol->send_bitfield( $torrent->bitfield->data );
                }

                # BEP 06: Send HAVE_NONE ONLY if remote supports Fast Extension
                elsif ( ord( substr( $protocol->reserved, 7, 1 ) ) & 0x04 ) {
                    if ( $protocol->can('send_have_none') ) {
                        $protocol->send_have_none();
                    }
                }

                # If in METADATA mode, we don't send unchoke/interested yet
                return if $torrent && $torrent->state eq 'METADATA';
                $weak_self->unchoke();
                $weak_self->_check_interest();

                # BEP 06: Send Allowed Fast set immediately after handshake
                if ( $protocol->isa('Net::BitTorrent::Protocol::BEP06') ) {
                    my $set = $torrent->get_allowed_fast_set( $weak_self->ip );
                    for my $idx (@$set) {
                        $protocol->send_allowed_fast($idx);
                    }
                }
            }
        );
    }

    method send_suggest ($index) {
        $protocol->send_suggest($index) if $protocol->can('send_suggest');
    }

    method send_allowed_fast ($index) {
        $protocol->send_allowed_fast($index) if $protocol->can('send_allowed_fast');
    }

    method on_data ($data) {
        $self->receive_data($data);
    }

    method set_protocol ($p) {
        $protocol = $p;
    }

    method set_torrent ($t) {
        $torrent = $t;
    }

    method receive_data ($data) {
        $self->_emit( log => "    [DEBUG] Peer received " . length($data) . " bytes of data\n", level => 'debug' ) if $debug;
        $torrent->can_read( length $data );
        $protocol->receive_data($data);
    }

    method write_buffer () {
        my $raw = $protocol->write_buffer();
        return '' unless length $raw;

        # Rate limiting logic
        my $allowed = length $raw;
        if ($torrent) {
            $allowed = $torrent->can_write( length $raw );
        }
        if ( $allowed < length $raw ) {

            # Simplified: if we can't send all, we send none or partial.
            # TRULY correct rate limiting for loop-agnostic core requires
            # the loop itself to check can_read/can_write BEFORE calling these.
        }
        return $transport->send_data($raw);
    }

    method handle_hash_request ( $root, $proof_layer, $base_layer, $index, $length ) {
        my $file = $torrent->storage->get_file_by_root($root);
        if ( !$file || !$file->merkle ) {
            $protocol->send_hash_reject( $root, $proof_layer, $base_layer, $index, $length ) if $protocol->can('send_hash_reject');
            return;
        }
        my $hashes = $file->merkle->get_hashes( $base_layer, $index, $length );

        # Simplified: no proof nodes added yet
        $protocol->send_hashes( $root, $proof_layer, $base_layer, $index, $length, $hashes ) if $protocol->can('send_hashes');
    }

    method handle_hashes ( $root, $proof_layer, $base_layer, $index, $length, $hashes ) {
        my $file = $torrent->storage->get_file_by_root($root);
        return unless $file && $file->merkle;
        my $node_size  = 32;
        my $num_hashes = length($hashes) / $node_size;

        # BEP 52: index and length refer to the range of nodes at base_layer.
        # The hashes string contains these nodes concatenated.
        for ( my $i = 0; $i < $num_hashes; $i++ ) {
            my $hash = substr( $hashes, $i * $node_size, $node_size );
            $file->merkle->set_node( $base_layer, $index + $i, $hash );
        }
        $self->_emit(
            log   => "    [DEBUG] Received and stored $num_hashes hashes for root " . unpack( 'H*', $root ) . " at layer $base_layer\n",
            level => 'debug'
        ) if $debug;
    }

    method handle_hash_reject ( $root, $proof_layer, $base_layer, $index, $length ) {
        $self->_emit( log => "    [DEBUG] Peer rejected hash request for root " . unpack( 'H*', $root ) . "\n", level => 'debug' ) if $debug;
    }

    method handle_metadata_request ($piece) {
        $torrent->handle_metadata_request( $self, $piece );
    }

    method handle_metadata_data ( $piece, $total_size, $data ) {
        $torrent->handle_metadata_data( $self, $piece, $total_size, $data );
    }

    method handle_metadata_reject ($piece) {
        $torrent->handle_metadata_reject( $self, $piece );
    }

    method handle_pex ( $added, $dropped, $added6, $dropped6 ) {
        for my $p ( @$added, @$added6 ) {
            $torrent->add_peer($p);
        }
    }

    method handle_hp_rendezvous ($id) {

        # Remote wants to connect to a node with $id via us.
        # Find node in our swarm.
        my $target;
        for my $p ( values $torrent->peer_objects_hash->%* ) {
            if ( $p->protocol->can('peer_id') && $p->protocol->peer_id eq $id ) {
                $target = $p;
                last;
            }
        }
        if ( $target && exists $target->protocol->remote_extensions->{ut_holepunch} ) {

            # Relay connect instruction to target
            $target->protocol->send_hp_connect( $self->ip, $self->port );

            # Acknowledge to source (optional, BEP 55 says relay then ack?)
            # Actually, BEP says relay 'connect' to target.
        }
        else {
            $protocol->send_hp_error(0x01) if $protocol->can('send_hp_error');    # 0x01 = peer not found
        }
    }

    method handle_hp_connect ( $ip, $port ) {
        $self->_emit( log => "    [BEP 55] Instructed to connect to $ip:$port\n", level => 'info' ) if $debug;

        # Trigger uTP connection
        $torrent->client->connect_to_peer( $ip, $port, $torrent->info_hash_v2 || $torrent->info_hash_v1 );
    }

    method handle_hp_error ($err) {
        $self->_emit( log => "    [BEP 55] Received holepunch error: $err\n", level => 'error' ) if $debug;
    }

    method handle_message ( $id, $payload ) {

        # warn '  [DEBUG] Peer ' . ($socket ? $socket->peerhost : 'sim') . " sent message ID $id (len " . length($payload) . ")\n";
        if ( $id == 0 ) {    # CHOKE
            $peer_choking = 1;
            $self->_emit('choked');
        }
        elsif ( $id == 1 ) {    # UNCHOKE
            $peer_choking = 0;
            $self->_emit('unchoked');
            $self->_request_next_block();
        }
        elsif ( $id == 2 ) {    # INTERESTED
            $peer_interested = 1;
            $self->_emit('interested');
        }
        elsif ( $id == 3 ) {    # NOT_INTERESTED
            $peer_interested = 0;
            $self->_emit('not_interested');
        }
        elsif ( $id == 4 ) {    # HAVE
            my $index = unpack( 'N', $payload );
            $torrent->update_peer_have( $self, $index );

            # BEP 16: If we see this peer (or others) have our offered piece,
            # we can offer a new one. (Simplified global check)
            if ( defined $offered_piece && $index == $offered_piece ) {
                $offered_piece = undef;
            }
            $self->_check_interest();
        }
        elsif ( $id == 5 ) {    # BITFIELD
            $bitfield_status = $payload;
            $torrent->set_peer_bitfield( $self, $payload );
            $self->_emit( bitfield => $torrent->peer_bitfields->{$self} );

            # BEP 16: If superseeding, we don't send our real bitfield.
            # Instead, we wait for interest and then offer pieces.
            $self->_check_interest();
        }
        elsif ( $id == 6 ) {    # REQUEST
            my ( $index, $begin, $len ) = unpack( 'N N N', $payload );
            $self->_handle_request( $index, $begin, $len );
        }
        elsif ( $id == 7 ) {    # PIECE
            my ( $index, $begin ) = unpack( 'N N', substr( $payload, 0, 8, '' ) );
            $self->_handle_piece_data( $index, $begin, $payload );
        }
        elsif ( $id == 13 ) {    # SUGGEST_PIECE
            my $index = unpack( 'N', $payload );
            push @suggested_pieces, $index;
            $self->_check_interest();
        }
        elsif ( $id == 14 ) {    # HAVE_ALL
            $bitfield_status = 'all';
            $torrent->set_peer_have_all($self);
            $self->_emit('have_all');
            $self->_check_interest();
        }
        elsif ( $id == 15 ) {    # HAVE_NONE
            $bitfield_status = 'none';
            $torrent->set_peer_have_none($self);
            $self->_emit('have_none');
        }
        elsif ( $id == 16 ) {    # REJECT
            my ( $index, $begin, $len ) = unpack( 'N N N', $payload );
            $self->_handle_reject( $index, $begin, $len );
        }
        elsif ( $id == 17 ) {    # ALLOWED_FAST
            my $index = unpack( 'N', $payload );
            push @allowed_fast_set, $index;
            $self->_check_interest();
        }
    }

    method _handle_reject ( $index, $begin, $len ) {
        $blocks_inflight--;

        # Ideally tell torrent to un-pending this block
        # For now, we just proceed to request next.
        $self->_request_next_block();
    }

    method _check_interest () {
        if ( $torrent->is_superseed ) {
            $self->_check_superseed();
        }
        if ( !$am_interested ) {

            # In a real client, we check if the peer has any piece we lack
            $am_interested = 1;
            $protocol->send_message(2);    # INTERESTED
        }
    }

    method _check_superseed () {
        return if defined $offered_piece;

        # Pick a piece to offer
        my $bitfield = $torrent->bitfield;
        my $p_bfs    = $torrent->peer_bitfields;
        my $p_bf     = $p_bfs->{$self};
        return unless $p_bf;
        for ( my $i = 0; $i < $bitfield->size; $i++ ) {
            if ( $bitfield->get($i) && !$p_bf->get($i) ) {
                $offered_piece = $i;
                $protocol->send_message( 4, pack( 'N', $i ) );    # HAVE
                last;
            }
        }
    }

    method _request_next_block () {
        while ( $blocks_inflight < 5 ) {
            my $req = $torrent->get_next_request($self);
            if ($req) {

                # BEP 06: Can request if not choked OR if piece is in allowed_fast_set
                if ( !$peer_choking || $self->is_allowed_fast( $req->{index} ) ) {
                    $protocol->send_message( 6, pack( 'N N N', $req->{index}, $req->{begin}, $req->{length} ) );
                    $blocks_inflight++;
                }
                else {
                    # We picked a piece but we are choked and it's not fast-allowed.
                    # We must un-pending it so others can pick it.
                    delete $torrent->blocks_pending->{ $req->{index} }{ $req->{begin} };
                    last;
                }
            }
            else {
                last;
            }
        }
    }

    method is_allowed_fast ($index) {
        return grep { $_ == $index } @allowed_fast_set;
    }

    method _handle_request ( $index, $begin, $len ) {
        return if $am_choking;

        # Reputation checks
        # Do we even have this piece?
        if ( !$torrent->bitfield->get($index) ) {
            $self->adjust_reputation(-5);
            return;
        }

        # Does the peer already have this piece?
        my $p_bf = $torrent->peer_bitfields->{$self};
        if ( $p_bf && $p_bf->get($index) ) {
            $self->adjust_reputation(-5);
            return;
        }
        my $piece_len  = $torrent->metadata->{info}{'piece length'} // 16384;
        my $abs_offset = ( $index * $piece_len ) + $begin;
        my $data       = $torrent->storage->read_global( $abs_offset, $len );
        if ($data) {
            $bytes_up += length($data);
            $protocol->send_message( 7, pack( 'N N', $index, $begin ) . $data );
        }
    }

    method _handle_piece_data ( $index, $begin, $data ) {
        $self->_emit( log => "    [DEBUG] Received " . length($data) . " bytes for piece $index at $begin\n", level => 'debug' ) if $debug;
        $bytes_down += length($data);
        $blocks_inflight--;
        my $status = $torrent->receive_block( $self, $index, $begin, $data );
        if ( $status == 1 ) {

            # Verified and saved
        }
        elsif ( $status == -1 ) {

            # Failed verification
        }
        $self->_request_next_block();
    }

    method disconnected () {
        $torrent->peer_disconnected($self) if $torrent;
        $transport->close()                if $transport;
        $self->_emit('disconnected');
    }

    method unchoke () {
        $am_choking = 0;
        $protocol->send_message(1);    # UNCHOKE
    }

    method choke () {
        $am_choking = 1;
        $protocol->send_message(0);    # CHOKE
    }

    method interested () {
        $am_interested = 1;
        $protocol->send_message(2);    # INTERESTED
    }

    method not_interested () {
        $am_interested = 0;
        $protocol->send_message(3);    # NOT_INTERESTED
    }

    method request ( $index, $begin, $len ) {
        $blocks_inflight++;
        $protocol->send_message( 6, pack( 'N N N', $index, $begin, $len ) );
    }

    method tick () {

        # Simple moving average / decay
        $rate_down  = ( $rate_down * 0.8 ) + ( $bytes_down * 0.2 );
        $rate_up    = ( $rate_up * 0.8 ) + ( $bytes_up * 0.2 );
        $bytes_down = 0;
        $bytes_up   = 0;
        $transport->tick() if $transport->can('tick');

        # MSE Transition Check
        if ( $mse && $mse->state eq 'PAYLOAD' && !$pwp_handshake_sent ) {
            $self->_emit( log => "    [DEBUG] MSE handshake complete, sending protocol handshake...\n", level => 'debug' ) if $debug;
            $protocol->send_handshake();
            $pwp_handshake_sent = 1;
        }

        # Fatal Protocol Error Check
        if ( $protocol->state eq 'CLOSED' ) {
            $self->_emit( log => "    [PEER] Fatal protocol error from $ip:$port. Disconnecting.\n", level => 'error' ) if $debug;
            $self->disconnected();
            return;
        }
        $self->write_buffer();
    }

    method adjust_reputation ($delta) {
        $reputation += $delta;
        if ( $reputation <= 50 ) {
            $self->_emit( log => "    [PEER] Blacklisting peer $ip:$port due to low reputation ($reputation)\n", level => 'error' ) if $debug;
            $self->disconnected();
        }
    }
} 1;
