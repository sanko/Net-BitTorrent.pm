use v5.40;
use feature 'class';
no warnings 'experimental::class';
class Net::BitTorrent::Storage::File v2.0.0 {
    use Digest::Merkle::SHA256;
    use Path::Tiny  qw();
    use Carp        qw[croak];
    use Digest::SHA qw[sha256];
    field $file_path   : param(path) : reader(path);
    field $size        : param       : reader;
    field $pieces_root : param       : reader = undef;
    field $piece_size  : param       : reader = 0;
    field $merkle      : reader;
    ADJUST {
        $file_path = Path::Tiny::path($file_path);
        if ($pieces_root) {
            $merkle = Digest::Merkle::SHA256->new( file_size => $size );
        }
    }

    method verify_block ( $index, $data ) {
        croak 'File does not have Merkle tree (no pieces root)' unless $merkle;
        my $old_hash = $merkle->get_node( $merkle->height, $index );
        my $hash     = sha256($data);
        $merkle->set_block( $index, $hash );
        if ( $merkle->root eq $pieces_root ) {
            return 1;
        }
        else {
            $merkle->set_block( $index, $old_hash );
            return 0;
        }
    }

    method verify_block_audit ( $index, $data, $audit_path ) {
        croak 'File does not have pieces root' unless $pieces_root;
        return Digest::Merkle::SHA256->verify_hash( $index, sha256($data), $audit_path, $pieces_root );
    }

    method verify_piece_v2 ( $index, $data, $expected_hash ) {

        # In BT v2, piece layer hashes are nodes at a specific level in the file's merkle tree.
        # If the piece size == block size (16KiB), the hash is just sha256(data).
        # Otherwise, it's the root of a mini-tree of the blocks in that piece.
        my $block_size       = $merkle ? $merkle->block_size : 16384;
        my $blocks_per_piece = int( $piece_size / $block_size );
        my $num_blocks       = int( ( length($data) + $block_size - 1 ) / $block_size );
        my $actual_hash;
        if ( $num_blocks == 1 ) {
            $actual_hash = sha256($data);
        }
        else {
            my $tmp_merkle = Digest::Merkle::SHA256->new( file_size => length($data), block_size => $block_size );
            for ( my $i = 0; $i < $num_blocks; $i++ ) {
                $tmp_merkle->set_block( $i, sha256( substr( $data, $i * $block_size, $block_size ) ) );
            }
            $actual_hash = $tmp_merkle->root;
        }
        if ( $actual_hash eq $expected_hash ) {

            # If we have a full merkle tree, we can populate its leaves now
            if ($merkle) {
                for ( my $i = 0; $i < $num_blocks; $i++ ) {
                    $merkle->set_block( $index * $blocks_per_piece + $i, sha256( substr( $data, $i * $block_size, $block_size ) ) );
                }
            }
            return 1;
        }
        return 0;
    }

    method read ( $offset, $length ) {
        return '' if $length <= 0;
        return undef unless $file_path->exists;
        my $fh = $file_path->openr_raw;
        seek $fh, $offset, 0;
        read( $fh, my $chunk, $length );
        return $chunk;
    }

    method write ( $offset, $data ) {
        $self->_ensure_exists();
        warn "    [DEBUG] Writing " . length($data) . " bytes to $file_path at offset $offset\n";
        my $fh = $file_path->openrw_raw;
        seek $fh, $offset, 0;
        print {$fh} $data or die "Failed to write to $file_path: $!";
        $fh->flush();
    }

    method _ensure_exists () {
        if ( !$file_path->exists ) {
            $file_path->parent->mkpath;
            if ( $size > 0 ) {
                my $fh = $file_path->openw_raw;
                seek $fh, $size - 1, 0;
                print {$fh} "\0";
            }
            else {
                $file_path->touch;
            }
        }
    }

    method dump_state () {
        return { merkle => ( $merkle ? $merkle->dump_state : undef ), };
    }

    method load_state ($state) {
        if ( $merkle && $state->{merkle} ) {
            $merkle->load_state( $state->{merkle} );
        }
    }
} 1;
