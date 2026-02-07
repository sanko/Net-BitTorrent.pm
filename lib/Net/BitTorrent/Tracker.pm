use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Net::BitTorrent::Tracker v2.0.0 {
    use Net::BitTorrent::Tracker::HTTP;
    use Net::BitTorrent::Tracker::UDP;
    use List::Util qw[shuffle];
    #
    field $tiers_raw : param;    # [ [url1, url2], [url3] ]
    field $debug : param = 0;
    field @tiers;                # [ [ { obj, last_announce, interval, ... }, ... ], ... ]
    ADJUST {
        for my $tier_list (@$tiers_raw) {
            my @tier;
            for my $url (@$tier_list) {
                push @tier,
                    {
                    obj                  => $self->_create_tracker($url),
                    last_announce        => 0,
                    interval             => 0,
                    min_interval         => 0,
                    tracker_id           => undef,
                    consecutive_failures => 0
                    };
            }

            # BEP 12: shuffle within tier
            @tier = shuffle @tier;
            push @tiers, \@tier;
        }
    }

    method _create_tracker ($url) {
        if    ( $url =~ /^udp:/ )    { return Net::BitTorrent::Tracker::UDP->new( url => $url ) }
        elsif ( $url =~ /^https?:/ ) { return Net::BitTorrent::Tracker::HTTP->new( url => $url ) }
        warn "Unsupported tracker protocol: $url";
        return;
    }

    method announce_all ( $params, $cb = undef ) {
        my %unique_peers;
        my $now = time();

        # If we have multiple info_hashes (hybrid), we should ideally announce all.
        # Standard $params has 'info_hash'.
        my @ihs = ref( $params->{info_hash} ) eq 'ARRAY' ? @{ $params->{info_hash} } : ( $params->{info_hash} );
        for my $tier (@tiers) {
            my $tier_success = 0;
            for ( my $i = 0; $i < scalar @$tier; $i++ ) {
                my $entry = $tier->[$i];

                # Check interval (unless event is set like 'started', 'stopped')
                if ( !$params->{event} && $entry->{last_announce} + ( $entry->{interval} || 60 ) > $now ) {
                    $tier_success = 1 if $i == 0 && $entry->{last_announce} > 0;
                    next;
                }
                for my $ih (@ihs) {
                    my $ih_params = { %$params, info_hash => $ih };
                    $ih_params->{trackerid} = $entry->{tracker_id} if $entry->{tracker_id};
                    my $on_res = sub ($res) {
                        $entry->{last_announce}        = time();
                        $entry->{interval}             = $res->{interval}       // 1800;
                        $entry->{min_interval}         = $res->{'min interval'} // 0;
                        $entry->{tracker_id}           = $res->{trackerid} if $res->{trackerid};
                        $entry->{consecutive_failures} = 0;
                        for my $peer ( @{ $res->{peers} // [] } ) {
                            my $key = "$peer->{ip}:$peer->{port}";
                            $unique_peers{$key} = $peer;
                        }

                        # Promote successful tracker to front of tier
                        if ( $i > 0 ) {
                            splice( @$tier, $i, 1 );
                            unshift( @$tier, $entry );
                        }
                        $cb->( [ values %unique_peers ] ) if $cb;
                    };
                    eval {
                        $entry->{obj}->perform_announce( $ih_params, $on_res );
                        $tier_success = 1;
                    };
                    if ($@) {
                        warn '  [DEBUG] Announce to ' . $entry->{obj}->url . " failed: $@\n" if $debug;
                        $entry->{consecutive_failures}++;
                    }
                }
                last if $tier_success;
            }
        }
        return [ values %unique_peers ];
    }

    method scrape_all ( $info_hashes, $cb = undef ) {
        my %results;
        for my $tier (@tiers) {
            for my $entry (@$tier) {
                my $on_res = sub ($res) {
                    if ( ref $res->{files} eq 'ARRAY' ) {
                        for ( my $j = 0; $j < scalar @$info_hashes; $j++ ) {
                            $self->_merge_scrape_stats( \%results, $info_hashes->[$j], $res->{files}[$j] );
                        }
                    }
                    else {
                        for my $ih ( keys %{ $res->{files} // {} } ) {
                            $self->_merge_scrape_stats( \%results, $ih, $res->{files}{$ih} );
                        }
                    }
                    $cb->( \%results ) if $cb;
                };
                eval { $entry->{obj}->perform_scrape( $info_hashes, $on_res ) };
            }
        }
        return \%results;
    }

    method _merge_scrape_stats ( $results, $ih, $stats ) {
        $results->{$ih} //= { complete => 0, downloaded => 0, incomplete => 0 };
        $results->{$ih}{complete}   = $stats->{complete}   if ( $stats->{complete}   // 0 ) > $results->{$ih}{complete};
        $results->{$ih}{incomplete} = $stats->{incomplete} if ( $stats->{incomplete} // 0 ) > $results->{$ih}{incomplete};
        $results->{$ih}{downloaded} = $stats->{downloaded} if ( $stats->{downloaded} // 0 ) > $results->{$ih}{downloaded};
    }

    method trackers () {
        return [
            map {
                map { $_->{obj}->url }
                    @$_
            } @tiers
        ];
    }

    method add_tracker ($url) {

        # Check if already present
        for my $tier (@tiers) {
            for my $entry (@$tier) {
                return if $entry->{obj}->url eq $url;
            }
        }
        push @tiers,
            [
            {   obj                  => $self->_create_tracker($url),
                last_announce        => 0,
                interval             => 0,
                min_interval         => 0,
                tracker_id           => undef,
                consecutive_failures => 0
            }
            ];
    }
};
#
1;
