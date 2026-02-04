use v5.40;
use lib '../lib';
use Net::BitTorrent;
use Path::Tiny;
use Time::HiRes                               qw[sleep];
use Net::BitTorrent::Protocol::BEP03::Bencode qw[bencode];
$|++;
my ( $magnet_uri, $data_dir ) = @ARGV;

if ( !$magnet_uri || !$data_dir ) {
    say "Usage: $0 <magnet_uri> <data_directory>";
    say "Example: $0 \"magnet:?xt=urn:btih:deadbeef...\" ./downloads";
    exit 1;
}
path($data_dir)->mkpath;
my $client  = Net::BitTorrent->new( debug => 1, encryption => 'required' );
my $torrent = $client->add_magnet( $magnet_uri, $data_dir );
my $ih_hex  = unpack( 'H*', $torrent->info_hash_v2 || $torrent->info_hash_v1 );
say "Added magnet: $ih_hex";
say "Waiting for metadata...";
$torrent->on(
    'peer_discovered',
    sub ( $t, $peer ) {
        say "  [PEER] Discovered: $peer->{ip}:$peer->{port}";
    }
);
$torrent->on(
    'status_update',
    sub ( $t, $stats ) {
        printf "\rPeers: %d | DL: %d | UL: %d", $stats->{peers}, $stats->{downloaded}, $stats->{uploaded};
    }
);
$torrent->on(
    'started',
    sub ($t) {
        say "\nMetadata received! Torrent name: " . $t->metadata->{info}{name};

        # Save the metadata for future use
        my $out_file = path($data_dir)->child( $t->metadata->{info}{name} . ".torrent" );
        $out_file->spew_raw( bencode( $t->metadata ) );
        say "Saved metainfo to: $out_file";
        say "Files:";
        my $tree = $t->file_tree;
        _print_tree( $tree, "" );
    }
);
$torrent->on(
    'piece_verified',
    sub ( $t, $index ) {
        printf "\rDownloaded piece %d/%d (%.2f%%)", $t->bitfield->count, $t->bitfield->size, ( $t->bitfield->count / $t->bitfield->size ) * 100;
    }
);
$torrent->start();
my $start_time = time();
while (1) {
    $client->tick(0.1);
    sleep(0.1);
    if ( time() - $start_time > 180 ) {
        say "\nTimeout reached (180s). Exiting...";
        last;
    }

    # Stop if we finished (though a real client would keep seeding)
    if ( $torrent->bitfield && $torrent->bitfield->count == $torrent->bitfield->size ) {
        say "\nDownload complete!";
        last;
    }
}

sub _print_tree ( $tree, $indent ) {
    for my $name ( sort keys %$tree ) {
        my $node = $tree->{$name};
        if ( exists $node->{''} ) {
            say "$indent- $name (" . $node->{''}{length} . " bytes)";
        }
        else {
            say "$indent+ $name/";
            _print_tree( $node, $indent . "  " );
        }
    }
}
