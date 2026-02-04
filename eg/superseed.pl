use v5.40;
use lib '../lib';
use Net::BitTorrent;
use Path::Tiny;
my ( $torrent_path, $data_dir ) = @ARGV;
if ( !$torrent_path || !$data_dir ) {
    say "Usage: $0 <torrent_file> <data_directory>";
    exit 1;
}
my $client  = Net::BitTorrent->new();
my $torrent = $client->add_torrent( $torrent_path, $data_dir );
say "Checking existing data for " . ( $torrent->metadata->{info}{name} // 'torrent' ) . "...";
my $total_pieces = $torrent->bitfield->size;
for my $i ( 0 .. $total_pieces - 1 ) {
    my $data = $torrent->storage->read_piece_v1($i);
    if ( length $data ) {
        $client->queue_verification( $torrent, $i, $data );
    }
}
while ( $client->hashing_queue_size > 0 ) {
    $client->tick(0.01);
    printf "\rVerification: %.2f%%", ( $torrent->bitfield->count / $total_pieces ) * 100;
}
say "\nDone.";
if ( $torrent->bitfield->count < $total_pieces ) {
    say "Error: You must have 100% of the data to superseed.";
    say "Current: " . $torrent->bitfield->count . " / $total_pieces";
    exit 1;
}
say "Enabling Superseed mode (BEP 16)...";
$torrent->set_superseed(1);
say "Starting swarm seeding...";
$torrent->start();
$torrent->on(
    'status_update',
    sub ( $t, $stats ) {
        printf "\rSeeding to %d peers. Uploaded: %d bytes. Rate: %.2f KiB/s    ", $stats->{peers}, $stats->{uploaded}, $stats->{uploaded} / 1024;
    }
);
while (1) {
    $client->tick(0.1);
    sleep(0.1);
}
