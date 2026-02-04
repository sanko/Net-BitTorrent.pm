use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Net::BitTorrent::Protocol::BEP52 : isa(Net::BitTorrent::Protocol::BEP03) {
    use Carp qw[croak];

    # BEP 52 Hash Request
    # infohash (v2 only), pieces root, proof layer, base layer, index, length
    method send_hash_request ( $pieces_root, $proof_layer, $base_layer, $index, $length ) {
        $self->send_message( $self->HASH_REQUEST, pack( 'a32 C C N N', $pieces_root, $proof_layer, $base_layer, $index, $length ) );
    }

    # BEP 52 Hashes
    # pieces root, proof layer, base layer, index, length, hashes
    method send_hashes ( $pieces_root, $proof_layer, $base_layer, $index, $length, $hashes ) {
        $self->send_message( $self->HASHES, pack( 'a32 C C N N a*', $pieces_root, $proof_layer, $base_layer, $index, $length, $hashes ) );
    }

    # BEP 52 Hash Reject
    method send_hash_reject ( $pieces_root, $proof_layer, $base_layer, $index, $length ) {
        $self->send_message( $self->HASH_REJECT, pack( 'a32 C C N N', $pieces_root, $proof_layer, $base_layer, $index, $length ) );
    }

    method _handle_message ( $id, $payload ) {
        if ( $id == $self->HASH_REQUEST ) {
            $self->on_hash_request( unpack( 'a32 C C N N', $payload ) );
        }
        elsif ( $id == $self->HASHES ) {
            my ( $root, $proof, $base, $idx, $len, $hashes ) = unpack( 'a32 C C N N a*', $payload );
            $self->on_hashes( $root, $proof, $base, $idx, $len, $hashes );
        }
        elsif ( $id == $self->HASH_REJECT ) {
            $self->on_hash_reject( unpack( 'a32 C C N N', $payload ) );
        }
        else {
            $self->SUPER::_handle_message( $id, $payload );
        }
    }

    # Event callbacks to be overridden by the user/client
    method on_hash_request (@args) { }
    method on_hashes       (@args) { }
    method on_hash_reject  (@args) { }
}
1;
__END__

=pod

=head1 NAME

Net::BitTorrent::Protocol::BEP52 - BitTorrent v2 Protocol Extensions

=head1 DESCRIPTION

This module extends BEP 03 with BitTorrent v2 specific messages as defined in BEP 52.

=head1 METHODS

=head2 send_hash_request($pieces_root, $proof_layer, $base_layer, $index, $length)

Sends a request for a range of hashes from a Merkle tree.

=head2 send_hashes($pieces_root, $proof_layer, $base_layer, $index, $length, $hashes)

Sends a response containing Merkle tree hashes and proof nodes.

=head2 send_hash_reject($pieces_root, $proof_layer, $base_layer, $index, $length)

Rejects a hash request.

=head2 on_hash_request(...)

Callback triggered when a hash request is received.

=head2 on_hashes(...)

Callback triggered when hashes are received.

=head2 on_hash_reject(...)

Callback triggered when a hash request is rejected.

=cut
