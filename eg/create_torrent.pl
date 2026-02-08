use v5.40;
use Net::BitTorrent::Torrent::Generator;
use Path::Tiny;
my ( $source_dir, $output_file, $type ) = @ARGV;
if ( !$source_dir || !$output_file ) {
    say "Usage: $0 <source_directory> <output_file> [v1|v2|hybrid]";
    exit 1;
}
$type //= 'hybrid';
my $gen = Net::BitTorrent::Torrent::Generator->new(
    base_path    => $source_dir,
    piece_length => 262144         # 256 KiB
);
say "Adding files from $source_dir...";
my $dir = path($source_dir);
$dir->visit(
    sub ( $path, $state ) {
        return if $path->is_dir;
        my $rel = $path->relative($dir)->stringify;
        say "  + $rel";
        $gen->add_file($rel);
    },
    { recurse => 1 }
);
$gen->add_tracker("udp://tracker.opentrackr.org:1337/announce");
$gen->add_tracker("http://tracker.torrent.eu.org:8080/announce");
say "Generating $type torrent...";
my $data;
if    ( $type eq 'v1' )     { $data = $gen->generate_v1(); }
elsif ( $type eq 'v2' )     { $data = $gen->generate_v2(); }
elsif ( $type eq 'hybrid' ) { $data = $gen->generate_hybrid(); }
else                        { die "Unknown type: $type"; }
path($output_file)->spew_raw($data);
say "Done! Torrent saved to $output_file";
