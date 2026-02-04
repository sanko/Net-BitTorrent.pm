use v5.40;
use feature 'class';
no warnings 'experimental::class';
class Net::BitTorrent::Tracker::Base v2.0.0 {
    field $url : param : reader;

    method perform_announce ( $params, $cb = undef ) {
        die 'Not implemented in base class';
    }

    method perform_scrape ( $info_hashes, $cb = undef ) {
        die 'Not implemented in base class';
    }
} 1;
