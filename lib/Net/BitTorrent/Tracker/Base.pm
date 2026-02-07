use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Net::BitTorrent::Tracker::Base v2.0.0 : isa(Net::BitTorrent::Emitter) {
    field $url : param : reader;
    method perform_announce ( $params, $cb      = undef ) {...}
    method perform_scrape   ( $info_hashes, $cb = undef ) {...}
};
#
1;
