use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Net::BitTorrent::Emitter;
#
class Net::BitTorrent::Tracker::Base v2.0.0 : isa(Net::BitTorrent::Emitter) {
    field $url : param : reader;

    method perform_announce ( $params, $cb = undef ) {
        $self->_emit( log => 'Not implemented in base class', level => 'fatal' );
    }

    method perform_scrape ( $infohashes, $cb = undef ) {
        $self->_emit( log => 'Not implemented in base class', level => 'fatal' );
    }
};
1;
