use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Net::BitTorrent::Protocol::PeerHandler v2.0.0 : isa(Net::BitTorrent::Protocol::BEP06) {
    field $peer : reader;
    field $features : param = {};
    #
    method set_peer ($p) {
        $peer = $p;
        builtin::weaken($peer) if defined $peer;
    }
    ADJUST {
        # Default all features to 1 if not provided
        $features->{bep05} //= 1;    # DHT
        $features->{bep06} //= 1;    # Fast Extension
        $features->{bep09} //= 1;    # Metadata
        $features->{bep10} //= 1;    # Extension Protocol
        $features->{bep11} //= 1;    # PEX

        # Populate local extensions for BEP 10
        my $ext = $self->local_extensions;
        $ext->{ut_metadata}  = 1 if $features->{bep09};
        $ext->{ut_pex}       = 2 if $features->{bep11};
        $ext->{ut_holepunch} = 3;

        # Set bits for Extension Protocol (byte 5, 0x10), DHT (byte 7, 0x01), Fast (byte 7, 0x04)
        $self->set_reserved_bit( 5, 0x10 ) if $features->{bep10};
        $self->set_reserved_bit( 7, 0x01 ) if $features->{bep05};
        $self->set_reserved_bit( 7, 0x04 ) if $features->{bep06};
    }

    method _handle_message ( $id, $payload ) {

        # Feature check for Fast Extension (BEP 06) message IDs
        return if !$features->{bep06} && ( $id >= 13 && $id <= 17 );

        # Feature check for Extension Protocol (BEP 10)
        return                                 if !$features->{bep10} && $id == 20;
        $peer->handle_message( $id, $payload ) if $peer;
        $self->SUPER::_handle_message( $id, $payload );
    }

    method on_handshake ( $ih, $id ) {
        if ( $id eq $self->peer_id ) {
            $self->_emit( debug => 'Closing self-connection and banning endpoint' );
            $peer->torrent->ban_peer( $peer->ip, $peer->port ) if $peer && $peer->torrent;
            $peer->disconnected()                              if $peer;
            return;
        }
        if ( $features->{bep10} ) {
            my $res = $self->reserved;
            if ( ord( substr( $res, 5, 1 ) ) & 0x10 ) {
                $self->_emit( debug => 'Remote supports BEP 10, sending extended handshake' );
                $self->send_ext_handshake();
            }
        }
        $peer->_emit('handshake_complete') if $peer;
    }

    method on_ext_handshake ($data) {
        $self->_emit('Received extended handshake from peer');
    }

    method on_metadata_request ($piece) {
        $peer->handle_metadata_request($piece) if $peer;
    }

    method on_metadata_data ( $piece, $total_size, $data ) {
        $peer->handle_metadata_data( $piece, $total_size, $data ) if $peer;
    }

    method on_metadata_reject ($piece) {
        $peer->handle_metadata_reject($piece) if $peer;
    }

    method on_hash_request ( $root, $proof_layer, $base_layer, $index, $length ) {
        $peer->handle_hash_request( $root, $proof_layer, $base_layer, $index, $length ) if $peer;
    }

    method on_hashes ( $root, $proof_layer, $base_layer, $index, $length, $hashes ) {
        $peer->handle_hashes( $root, $proof_layer, $base_layer, $index, $length, $hashes ) if $peer;
    }

    method on_hash_reject ( $root, $proof_layer, $base_layer, $index, $length ) {
        $peer->handle_hash_reject( $root, $proof_layer, $base_layer, $index, $length ) if $peer;
    }

    method on_pex ( $added, $dropped, $added6, $dropped6 ) {
        $peer->handle_pex( $added, $dropped, $added6, $dropped6 ) if $peer;
    }

    method on_hp_rendezvous ($id) {
        $peer->handle_hp_rendezvous($id) if $peer && $peer->can('handle_hp_rendezvous');
    }

    method on_hp_connect ( $ip, $port ) {
        $peer->handle_hp_connect( $ip, $port ) if $peer && $peer->can('handle_hp_connect');
    }

    method on_hp_error ($err) {
        $peer->handle_hp_error($err) if $peer && $peer->can('handle_hp_error');
    }
};
#
1;
